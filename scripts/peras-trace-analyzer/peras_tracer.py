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
    s = s.rstrip("Z")
    if "." in s:
        a, b = s.split(".")
        s = a + "." + b.ljust(6, "0")[:6]
    return datetime.datetime.fromisoformat(s).timestamp()


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
class NodeEvent:
    node: int
    t: float
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
    round: int
    seat: int
    persistent: bool
    slot: Optional[int] = None
    weight: Optional[F] = None


@dataclasses.dataclass(frozen=True)
class VoteDbAddVote(PerasEvent):
    round: int
    seat: int
    generated_cert: bool
    weight: Optional[F] = None
    cert_round: Optional[int] = None


@dataclasses.dataclass(frozen=True)
class CertDbAddCert(PerasEvent):
    round: int
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
                t, ns, data = ts(j["at"]), j["ns"], j.get("data", {}) or {}
            except Exception:
                continue
            if not emitted_start:
                emitted_start = True
                yield NodeEvent(node=self.node, port=self.port, t=t, event=LogStart())
            ev = PerasTracer.parse_event(ns, data)
            if ev is None:
                continue
            yield NodeEvent(node=self.node, port=self.port, t=t, event=ev)


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
            heapq.heappush(heap, (ev.t, i, ev))
        while heap:
            _, i, ev = heapq.heappop(heap)
            yield ev
            try:
                nxt = next(iters[i])
            except StopIteration:
                continue
            heapq.heappush(heap, (nxt.t, i, nxt))

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
    vote = x["vote"]
    seat = int(re.search(r"unPerasSeatIndex = (\d+)", vote)[1])
    slot_m = re.search(r"Bytes32RealPoint \(SlotNo (\d+)\)", vote)
    persistent = "NonPersistentPerasVoteEligibilityProof" not in vote
    return ForgedVote(
        round=int(x["round"]),
        seat=seat,
        persistent=persistent,
        slot=int(slot_m[1]) if slot_m else None,
        weight=PerasTracer.parse_weight(vote),
    )


def _parse_vote_db_add_vote(x: dict) -> Optional[PerasEvent]:
    m = re.search(r"PerasRoundNo (\d+).*unPerasSeatIndex = (\d+)", x["voteId"])
    generated = "AndGenerated" in x.get("result", "")
    result_s = x.get("result", "")
    cert_m = re.search(r"pcRoundNo = PerasRoundNo (\d+)", result_s) if generated else None
    return VoteDbAddVote(
        round=int(m[1]),
        seat=int(m[2]),
        generated_cert=generated,
        weight=PerasTracer.parse_weight(x.get("vote", "")),
        cert_round=(int(cert_m[1]) if cert_m else None),
    )


def _parse_cert_db_add_cert(x: dict) -> Optional[PerasEvent]:
    return CertDbAddCert(round=int(re.search(r"\d+", x["round"])[0]), result=str(x["result"]))


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
