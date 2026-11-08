#!/usr/bin/env python3
"""Extract Peras-related events for a single node from cardano-tracer logs.

Usage:
  scripts/extract_events NODE [RESULTS_DIR]

Outputs a single JSON array to stdout.
"""

from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
import sys
from typing import Dict, Iterable, Iterator, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import peras_tracer as pt  # noqa: E402


def _parse_slot_length_seconds(s: str) -> Optional[float]:
    s = str(s).strip()
    if s.endswith("s"):
        try:
            return float(s[:-1])
        except Exception:
            return None
    return None


def _parse_system_start_utc(s: str) -> Optional[float]:
    s = str(s).strip()
    # Examples seen in logs:
    #   "2026-11-06 09:00:46 UTC"
    #   "2026-11-06 09:00:46"
    if s.endswith("UTC"):
        s = s[:-3].strip()
    try:
        dt = datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


def _slot_of(t: float, *, system_start: float, slot_len: float) -> int:
    # Use floor; slot numbers are discrete and logs are within the slot window.
    return int((t - system_start) // slot_len)


def _find_chain_params(paths: List[str]) -> Tuple[float, float]:
    for path in paths:
        try:
            for line in open(path, errors="replace"):
                try:
                    j = json.loads(line)
                except Exception:
                    continue
                if j.get("ns") != "Startup.Byron":
                    continue
                data = j.get("data") or {}
                system_start = _parse_system_start_utc(data.get("systemStartTime", ""))
                slot_len = _parse_slot_length_seconds(data.get("slotLength", ""))
                if system_start is not None and slot_len is not None and slot_len > 0:
                    return system_start, slot_len
        except OSError:
            continue
    raise SystemExit("could not infer systemStartTime/slotLength (missing Startup.Byron?)")


def _parse_tip(s: str) -> Tuple[Optional[str], Optional[int]]:
    if not isinstance(s, str):
        return None, None
    if "@" not in s:
        return s, None
    h, sl = s.split("@", 1)
    try:
        return h, int(sl)
    except Exception:
        return h, None


def _iter_records(paths: List[str]) -> Iterator[dict]:
    # Files are rotated and named with timestamps; within a node, filename order is chronological.
    for path in sorted(paths):
        for line in open(path, errors="replace"):
            try:
                j = json.loads(line)
            except Exception:
                continue
            if isinstance(j, dict) and "at" in j and "ns" in j:
                yield j


def _extract_events(records: Iterable[dict], *, system_start: float, slot_len: float) -> Iterator[dict]:
    last_tip: Optional[str] = None
    seen_vote_received_first_at: Dict[Tuple[int, int], int] = {}
    for rec in records:
        try:
            t = pt.ts(rec["at"])
        except Exception:
            continue
        at_slot = _slot_of(t, system_start=system_start, slot_len=slot_len)
        # The node starts logging before chain system start (see Startup.Byron.systemStartTime),
        # so events in that window would map to negative slots. Peras events are only meaningful
        # after the system start; drop pre-start records.
        if at_slot < 0:
            continue
        ns = rec.get("ns", "")
        data = rec.get("data") or {}

        # Chain tip movement (used for BlockReceived + PreferredChain).
        if ns in ("ChainDB.AddBlockEvent.AddedToCurrentChain", "ChainDB.AddBlockEvent.SwitchedToAFork"):
            tip_hash, tip_slot = _parse_tip((data or {}).get("newtip", ""))
            sv = (data or {}).get("newSuffixSelectView") or {}
            issuer = sv.get("issuerHash")
            block_slot = sv.get("slotNo", tip_slot)

            yield {
                "tag": "PreferredChain",
                "pcAt": at_slot,
                "pcTip": tip_hash,
            }
            yield {
                "tag": "BlockReceived",
                "brAt": at_slot,
                "brId": tip_hash,
                "brSlot": block_slot,
                "brCreator": issuer,
                "brParent": last_tip,
                "brCert": None,
            }
            if tip_hash:
                last_tip = tip_hash
            continue

        ev = pt.PerasTracer.parse_event(ns, data if isinstance(data, dict) else {})
        if ev is None:
            continue

        if isinstance(ev, pt.ForgedVote):
            yield {
                "tag": "VoteCast",
                "vcAt": at_slot,
                "vcRound": ev.round,
                "vcSeat": ev.seat,
                "vcVoteId": f"{ev.round}-{ev.seat}",
                "vcVoter": None,
                "vcBlock": ev.boosted_block,
            }
            continue

        if isinstance(ev, pt.VoteDbAddVote):
            key = (ev.round, ev.seat)
            first_at = seen_vote_received_first_at.get(key)
            if first_at is not None:
                yield {
                    "tag": "VoteReceivedDuplicate",
                    "vrdAt": at_slot,
                    "vrdFirstAt": first_at,
                    "vrdRound": ev.round,
                    "vrdSeat": ev.seat,
                    "vrdVoteId": f"{ev.round}-{ev.seat}",
                    "vrdVoter": None,
                    "vrdBlock": ev.boosted_block,
                    "vrdGeneratedCert": bool(ev.generated_cert),
                }
                continue
            seen_vote_received_first_at[key] = at_slot
            yield {
                "tag": "VoteReceived",
                "vrAt": at_slot,
                "vrRound": ev.round,
                "vrSeat": ev.seat,
                "vrVoteId": f"{ev.round}-{ev.seat}",
                "vrVoter": None,
                "vrBlock": ev.boosted_block,
                "vrGeneratedCert": bool(ev.generated_cert),
            }
            if ev.generated_cert:
                yield {
                    "tag": "CertCreated",
                    "ccAt": at_slot,
                    "ccRound": (ev.cert_round if ev.cert_round is not None else ev.round),
#                    "ccBlock": ev.cert_boosted_block,
#                    "ccBoost": ev.cert_boost,
                    "ccFromVoteId": f"{ev.round}-{ev.seat}",
                }
            continue


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(prog="extract_events", add_help=True)
    ap.add_argument("node", type=int, help="node number (from /node<N>/ in local socket paths)")
    ap.add_argument("results_dir", nargs="?", default="devnet-env", help="run dir (default: devnet-env)")
    ap.add_argument(
        "--stream",
        action="store_true",
        help="output JSONL (one event per line) instead of a single JSON array",
    )
    args = ap.parse_args(argv)

    logs_root = os.path.join(args.results_dir, "logs")
    log_dirs = sorted(glob.glob(os.path.join(logs_root, "*_*")))
    selected_dirs = [d for d in log_dirs if pt.node_number_from_dir(d) == args.node]
    if not selected_dirs:
        raise SystemExit(f"no logs for node{args.node} under {logs_root}/")

    paths: List[str] = []
    for d in selected_dirs:
        paths.extend(sorted(glob.glob(os.path.join(d, "node-*.json"))))
    if not paths:
        raise SystemExit(f"no node-*.json files for node{args.node} under {logs_root}/")

    system_start, slot_len = _find_chain_params(paths)
    records = _iter_records(paths)
    events = _extract_events(records, system_start=system_start, slot_len=slot_len)

    if args.stream:
        for ev in events:
            json.dump(ev, sys.stdout, separators=(",", ":"), sort_keys=False)
            sys.stdout.write("\n")
    else:
        first = True
        sys.stdout.write("[\n")
        for ev in events:
            if not first:
                sys.stdout.write(",\n")
            json.dump(ev, sys.stdout, separators=(",", ":"), sort_keys=False)
            first = False
        sys.stdout.write("\n]\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
