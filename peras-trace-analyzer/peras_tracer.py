#!/usr/bin/env python3
"""Peras tracer utilities.

This module provides a small tracing abstraction:

- A *source* is any iterable yielding sorted :class:`NodeEvent` objects.
- :class:`PerasTracer` merges multiple sources and yields a single sorted stream.
- :class:`FileTracer` is a concrete source for a single cardano-tracer JSONL log file.

The intent is that different backends (filesystem, victoria-logs, ...) can be
added as sources without changing downstream consumers.
"""

from __future__ import annotations

import ast
import dataclasses
import datetime
import glob
import heapq
import json
import os
import re
from fractions import Fraction as F
from typing import Callable, Dict, Iterable, Iterator, List, Optional, Sequence, Tuple


def ts(s: str) -> float:
    """Parse a tracer timestamp into epoch seconds.

    cardano-tracer uses ISO-8601 timestamps (usually with a trailing "Z" for UTC)
    and can emit sub-second precision beyond microseconds. Python's
    ``datetime.fromisoformat`` does not accept nanoseconds, and naive datetimes
    are interpreted in the *local* timezone when converted to epoch seconds.

    This function normalizes:
    - trailing "Z" to an explicit "+00:00" offset
    - fractional seconds to microsecond precision (truncate/pad)
    - missing timezone to UTC (best-effort)
    """
    s = str(s).strip()
    if not s:
        raise ValueError("empty timestamp")

    # Normalize UTC "Z" to an explicit offset so we don't create a naive datetime.
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"

    # Split a final offset (if any) from the main datetime part so we can safely
    # normalize fractional seconds without disturbing "+00:00".
    tz_m = re.search(r"([+-]\d{2}:\d{2})$", s)
    tz = tz_m.group(1) if tz_m else ""
    base = s[: -len(tz)] if tz else s
    base = base.rstrip()

    if "." in base:
        head, frac = base.split(".", 1)
        # Keep only digits from the fraction; logs should be digits only, but be resilient.
        frac_digits = "".join(ch for ch in frac if ch.isdigit())
        if frac_digits:
            frac_us = (frac_digits + "000000")[:6]
            base = head + "." + frac_us
        else:
            base = head

    dt = datetime.datetime.fromisoformat(base + tz)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.timestamp()


def node_number_from_dir(log_dir: str) -> Optional[int]:
    """N of node<N>, taken from the local socket path in a startup trace.

    cardano-tracer rotates files and `node.json` usually points to the newest
    log file, which may not contain the startup event. So this scans rotated
    files, in filename order, until it finds the socket path.
    """
    try:
        for path in sorted(glob.glob(os.path.join(log_dir, "node-*.json"))):
            for line in open(path, errors="replace"):
                if "Startup.DiffusionInit.CreatedLocalSocket" in line:
                    m = re.search(r"/node(\d+)/", line)
                    return int(m[1]) if m else None
    except (OSError, TypeError, ValueError):
        return None
    return None

@dataclasses.dataclass(frozen=True)
class Vote:
    round: int
    seat: int
    persistent: bool
    arrival_time: float
    weight: F
    boosted_block_hash: str

def _parse_vote(raw):
    round = int(re.search(r"pvRoundNo = PerasRoundNo (\d+)", raw)[1])
    seat = int(re.search(r"unPerasSeatIndex = (\d+)", raw)[1])
    persistent = "NonPersistentPerasVoteEligibilityProof" not in raw
    arrival_time = float(re.search(r"getArrivalTime = RelativeTime ([\d\.]+)s", raw)[1])
    weight_capture = re.search(r"unVoteWeight = (\d+) % (\d+)", raw)
    weight = F(numerator=int(weight_capture[1]), denominator=int(weight_capture[2]))
    boosted_block_hash = re.search(r"pbrHash = ([^\}]+)\}", raw)[1]
    return Vote(round, seat, persistent, arrival_time, weight, boosted_block_hash)

@dataclasses.dataclass(frozen=True)
class Cert:
    round: int
    arrival_time: float
    boosted_block_hash: str
    voters: set[int]
    boost: int

def _parse_cert_with_arrival_time(raw, arrival_time):
    round = int(re.search(r"pcRoundNo = PerasRoundNo (\d+)", raw)[1])
    boosted_block_hash = re.search(r"pbrHash = ([^\}]+)\}", raw)[1]
    boost = int(re.search(r"vpcCertBoost = PerasWeight (\d+)", raw)[1])
    voters_capture = re.search(r"bitmapBytes = (\[[^\]]*\])", raw)[1]
    voters_str = ""
    for octet in ast.literal_eval(voters_capture):
        voters_str += bin(octet)[2:]
    voters = set(idx for idx, votes in enumerate(voters_str) if votes == '1')
    return Cert(round, arrival_time, boosted_block_hash, voters, boost)

def _parse_cert(raw):
    arrival_time = float(re.search(r"getArrivalTime = RelativeTime ([\d\.]+)s", raw)[1])
    return _parse_cert_with_arrival_time(raw, arrival_time)

@dataclasses.dataclass(frozen=True)
class NodeEvent:
    node: int
    log_timestamp: float
    event: "PerasEvent"
    port: str = "?"


class PerasEvent:
    pass


@dataclasses.dataclass(frozen=True)
class UnknownEvent(PerasEvent):
    ns: str
    data: dict


@dataclasses.dataclass(frozen=True)
class LogStart(PerasEvent):
    """Marks the earliest timestamp observed in a log file source."""


@dataclasses.dataclass(frozen=True)
class ForgedBlock(PerasEvent):
    block: str
    block_no: int
    slot: int
    prev: str


@dataclasses.dataclass(frozen=True)
class CantReadEnv(PerasEvent):
    pass


@dataclasses.dataclass(frozen=True)
class VoteRulesDecision(PerasEvent):
    round: int
    decision: str
    is_vote: bool


@dataclasses.dataclass(frozen=True)
class NotAVoterInRound(PerasEvent):
    round: int


@dataclasses.dataclass(frozen=True)
class ForgedVote(PerasEvent):
    vote: Vote


@dataclasses.dataclass(frozen=True)
class VoteDbAddVote(PerasEvent):
    vote: Vote
    cert: Optional[Cert]


@dataclasses.dataclass(frozen=True)
class CertDbAddCert(PerasEvent):
    cert: Cert
    result: str


@dataclasses.dataclass(frozen=True)
class InclusionError(PerasEvent):
    pass


@dataclasses.dataclass(frozen=True)
class ForgedInvalidBlock(PerasEvent):
    pass


@dataclasses.dataclass(frozen=True)
class OutboundSendMsgReplyObjects(PerasEvent):
    peer_port: int
    votes: List[Tuple[int, int]]  # (round, seat)


@dataclasses.dataclass(frozen=True)
class RemoteMessage(PerasEvent):
    proto: str  # "Vote" | "Cert"
    way: str  # "Send" | "Receive"
    msg_kind: str
    peer_port: int


@dataclasses.dataclass(frozen=True)
class CertInclusionDecision(PerasEvent):
    slot: int
    round: int
    decision: str


class FileTracer:
    """A single log file source producing :class:`NodeEvent` items one by one."""

    def __init__(self, path: str, *, node: int, port: str = "?"):
        self.path = path
        self.node = node
        self.port = port

    def __iter__(self) -> Iterator[NodeEvent]:
        emitted_start = False
        for line in open(self.path, errors="replace"):
            try:
                j = json.loads(line)
                log_timestamp, ns, data = ts(j["at"]), j["ns"], j.get("data", {}) or {}
            except Exception:
                continue
            if not emitted_start:
                emitted_start = True
                yield NodeEvent(node=self.node, port=self.port, log_timestamp=log_timestamp, event=LogStart())
            ev = PerasTracer.parse_event(ns, data)
            if ev is None:
                continue
            yield NodeEvent(node=self.node, port=self.port, log_timestamp=log_timestamp, event=ev)


class PerasTracer:
    """Merge a set of sources into a single sorted stream of NodeEvents."""

    def __init__(self):
        self._sources: List[Iterable[NodeEvent]] = []

    def add_source(self, source: Iterable[NodeEvent]) -> "PerasTracer":
        self._sources.append(source)
        return self

    def __iter__(self) -> Iterator[NodeEvent]:
        return self.events()

    def events(self) -> Iterator[NodeEvent]:
        iters = [iter(s) for s in self._sources]
        heap: List[Tuple[float, int, NodeEvent]] = []
        for i, it in enumerate(iters):
            try:
                ev = next(it)
            except StopIteration:
                continue
            heapq.heappush(heap, (ev.log_timestamp, i, ev))
        while heap:
            _, i, ev = heapq.heappop(heap)
            yield ev
            try:
                nxt = next(iters[i])
            except StopIteration:
                continue
            heapq.heappush(heap, (nxt.log_timestamp, i, nxt))

    @staticmethod
    def parse_weight(s: str) -> Optional[F]:
        m = re.search(r"unVoteWeight = (\d+) % (\d+)", s)
        if not m:
            return None
        try:
            return F(int(m[1]), int(m[2]))
        except Exception:
            return None

    @staticmethod
    def parse_event(ns: str, x: dict) -> Optional[PerasEvent]:
        """Parse a cardano-tracer namespace + data into a typed :class:`PerasEvent`."""
        parser = _EVENT_PARSERS_EXACT.get(ns)
        if parser is None:
            for prefix, p in _EVENT_PARSERS_PREFIX.items():
                if ns.startswith(prefix):
                    parser = p
                    break
        if parser is None:
            return None
        try:
            return parser(x)
        except Exception:
            return UnknownEvent(ns=ns, data=x)


def filesystem_sources(results_dir: str) -> Sequence[FileTracer]:
    """Discover :class:`FileTracer` sources under a devnet-env style directory."""
    out: List[FileTracer] = []
    for d in sorted(glob.glob(os.path.join(results_dir, "logs", "*_*"))):
        node = node_number_from_dir(d)
        if node is None:
            continue
        port = (re.search(r"_(\d+)$", d) or [None, "?"])[1]
        for f in sorted(glob.glob(os.path.join(d, "node-*.json"))):
            out.append(FileTracer(f, node=node, port=port))
    return out


def _parse_forged_block(x: dict) -> Optional[PerasEvent]:
    return ForgedBlock(block=x["block"], block_no=int(x["blockNo"]), slot=int(x["slot"]), prev=x["blockPrev"])


def _parse_vote_rules_decision(x: dict) -> Optional[PerasEvent]:
    dec = x["decision"]
    return VoteRulesDecision(round=int(x["round"]), decision=dec, is_vote=str(dec).startswith("Vote"))


def _parse_not_a_voter_in_round(x: dict) -> Optional[PerasEvent]:
    return NotAVoterInRound(round=int(x["round"]))


def _parse_forged_vote(x: dict) -> Optional[PerasEvent]:
    return ForgedVote(vote=_parse_vote(x["vote"]))

def _parse_vote_db_add_vote(x: dict) -> Optional[PerasEvent]:
    result = x["result"]

    vote = _parse_vote(x["vote"])
    cert = _parse_cert_with_arrival_time(result, vote.arrival_time) if "AndGenerated" in result else None

    return VoteDbAddVote(vote=vote, cert=cert)

def _parse_cert_db_add_cert(x: dict) -> Optional[PerasEvent]:
    return CertDbAddCert(
        cert=_parse_cert(x["cert"]),
        result=x["result"],
    )


def _parse_outbound_reply_objects(x: dict) -> Optional[PerasEvent]:
    peer = int(x["peer"]["connectionId"].split()[-1].rsplit(":", 1)[1])
    votes = [(int(r_), int(s_)) for r_, s_ in re.findall(
        r"pvRoundNo = PerasRoundNo (\d+),.*?unPerasSeatIndex = (\d+)", x.get("payload", ""))]
    return OutboundSendMsgReplyObjects(peer_port=peer, votes=votes)


def _parse_remote_message(proto: str, way: str) -> Callable[[dict], Optional[PerasEvent]]:
    def parse(x: dict) -> Optional[PerasEvent]:
        peer = int(x["peer"]["connectionId"].split()[-1].rsplit(":", 1)[1])
        return RemoteMessage(proto=proto, way=way, msg_kind=x["msg"]["kind"], peer_port=peer)
    return parse


def _parse_cert_inclusion_rules_decision(x: dict) -> Optional[PerasEvent]:
    dec = str(x.get("decision", ""))
    if not dec.startswith("IncludeCert"):
        return None
    return CertInclusionDecision(slot=int(x["slot"]), round=int(x["round"]), decision=dec)


_EVENT_PARSERS_EXACT: Dict[str, Callable[[dict], Optional[PerasEvent]]] = {
    "Forge.Loop.ForgedBlock": _parse_forged_block,
    "Peras.Vote.Forging.CantReadEnv": lambda _: CantReadEnv(),
    "Peras.Vote.Forging.RulesDecision": _parse_vote_rules_decision,
    "Peras.Vote.Forging.NotAVoterInRound": _parse_not_a_voter_in_round,
    "Peras.Vote.Forging.ForgedVote": _parse_forged_vote,
    "ChainDB.PerasVoteDbEvent.AddVote": _parse_vote_db_add_vote,
    "ChainDB.PerasCertDbEvent.AddCert": _parse_cert_db_add_cert,
    "Peras.Cert.Inclusion.Error": lambda _: InclusionError(),
    "Forge.Loop.ForgedInvalidBlock": lambda _: ForgedInvalidBlock(),
    "Peras.Vote.Outbound.TraceObjectDiffusionOutboundSendMsgReplyObjects": _parse_outbound_reply_objects,
    "Peras.Cert.Inclusion.RulesDecision": _parse_cert_inclusion_rules_decision,
}

_EVENT_PARSERS_PREFIX: Dict[str, Callable[[dict], Optional[PerasEvent]]] = {
    "Peras.Vote.Remote.Send.": _parse_remote_message("Vote", "Send"),
    "Peras.Vote.Remote.Receive.": _parse_remote_message("Vote", "Receive"),
    "Peras.Cert.Remote.Send.": _parse_remote_message("Cert", "Send"),
    "Peras.Cert.Remote.Receive.": _parse_remote_message("Cert", "Receive"),
}
