#!/usr/bin/env python3
"""Validate Peras testnet properties by reading the logs of a run.

Usage:
  scripts/check_peras_logs.py [RESULTS_DIR] [--wait SECONDS] [--poll SECONDS]

RESULTS_DIR defaults to devnet-env and must contain
  logs/*_<port>/node-*.json      (cardano-tracer logs, one dir per node;
                                  the first file holds the startup trace)
  dijkstra-genesis.json          (quorum safety margin)

Without --wait the logs are analysed once. With --wait the checks are re-run
every --poll seconds until none is PENDING (e.g. cooldown not yet entered or
not yet recovered from) or the timeout expires, so it can run next to a live
testnet.

Exit code: 0 all PASS/WARN, 1 some FAIL, 2 still PENDING at timeout.
"""
import argparse, collections, json, os, re, sys, time
from fractions import Fraction as F

import peras_tracer as pt

PASS, FAIL, WARN, PENDING = "PASS", "FAIL", "WARN", "PENDING"

# If a duplicate VoteDB add for the same (round, seat) arrives this long after
# the vote was issued (forged), report it.
DUPLICATE_VOTE_LATE_THRESHOLD_S = 30.0


class Run:
    
    def __init__(self, root):
        self.root = root
        self.nodes = {}
        tracer = pt.PerasTracer()
        for src in pt.filesystem_sources(root):
            tracer.add_source(src)
        for ne in tracer:
            nd = self.nodes.get(ne.node)
            if nd is None:
                nd = self._new_node_state(ne.port)
                self.nodes[ne.node] = nd
            self._apply_event(nd, ne)

    @staticmethod
    def _new_node_state(port: str) -> dict:
        return {
            "port": port,
            "nokey": 0,
            "dec": {},          # round -> Vote | NoVote
            "dec_t": {},        # round -> time (first decision event for the round)
            "notvoter": [],
            "forged": {},       # round -> (seat, persistent)
            "forged_votes": {}, # (round, seat) -> time (vote issued / forged)
            "incl_err": 0,
            "votes": {},        # (round, seat) -> (time, generated cert, weight)
            "votes_dups": [],   # [(round, seat), time, generated cert, weight] duplicates (if any)
            "certs": [],        # (round, time, result)
            "invalid_forged": 0,
        }

    @staticmethod
    def _apply_event(nd: dict, ne: pt.NodeEvent) -> None:
        t, ev = ne.t, ne.event
        if isinstance(ev, pt.CantReadEnv):
            nd["nokey"] += 1
        elif isinstance(ev, pt.VoteRulesDecision):
            nd["dec"][ev.round] = "Vote" if ev.is_vote else "NoVote"
            nd["dec_t"].setdefault(ev.round, t)
        elif isinstance(ev, pt.NotAVoterInRound):
            nd["notvoter"].append(ev.round)
        elif isinstance(ev, pt.ForgedVote):
            nd["forged"][ev.round] = (ev.seat, ev.persistent)
            nd["forged_votes"][(ev.round, ev.seat)] = t
        elif isinstance(ev, pt.InclusionError):
            nd["incl_err"] += 1
        elif isinstance(ev, pt.VoteDbAddVote):
            key = (ev.round, ev.seat)
            w = ev.weight if ev.weight is not None else F(0)
            if key not in nd["votes"]:
                nd["votes"][key] = (t, ev.generated_cert, w)
            else:
                nd["votes_dups"].append((key, t, ev.generated_cert, w))
        elif isinstance(ev, pt.CertDbAddCert):
            nd["certs"].append((ev.round, t, ev.result))
        elif isinstance(ev, pt.ForgedInvalidBlock):
            nd["invalid_forged"] += 1

    def threshold(self):
        """Quorum threshold + safety margin. The base quorum is not traced, so the default 3/4 is assumed."""
        try:
            g = json.load(open(os.path.join(self.root, "dijkstra-genesis.json")))
            margin = F(str(g["perasQuorumThresholdSafetyMargin"]))
        except (OSError, KeyError, ValueError):
            return None
        return F(3, 4) + margin


def checks(run):
    out = []

    def add_report(name, st, detail):
        out.append((name, st, detail))

    N = run.nodes
    if not N:
        return [("0", "logs found", FAIL, "no nodes under logs/")]
    keyless = [n for n, nd in N.items() if nd["nokey"] and not nd["dec"]]
    keyed = [n for n in N if n not in keyless]
    seat_node = {s: n for n in keyed for (s, _) in N[n]["forged"].values()}

    # 1. keyless nodes skip voting
    test_name = "Node without a positive stake skips voting"
    if not keyless:
        add_report(test_name, PENDING, "no node without stake found")
    else:
        bad = [n for n in keyless if N[n]["forged"]]
        add_report(test_name, FAIL if bad else PASS,
            ", ".join(f"node{n}: {N[n]['nokey']} no-key lines, 0 votes forged" for n in keyless))

    # 2. eligible SPOs vote
    problems, info = [], []
    for n in keyed:
        nd = N[n]
        vd = sorted(r for r, d in nd["dec"].items() if d == "Vote")
        fg = sorted(nd["forged"])
        persistent = bool(fg) and all(p for _, p in nd["forged"].values()) and not nd["notvoter"]
        if any(r not in vd for r in fg):
            problems.append(f"node{n} forged without a Vote decision")
        if persistent and fg != vd:
            problems.append(f"node{n} (persistent) voted {len(fg)}/{len(vd)} allowed rounds")
        info.append(f"node{n}: voted {len(fg)}/{len(vd)} allowed rounds" + (" (persistent)" if persistent else ""))
    if not any(nd["forged"] for nd in N.values()):
        add_report("eligible SPO votes", PENDING, "no vote forged yet")
    else:
        add_report("eligible SPO votes (persistent / non-persistent)", FAIL if problems else PASS,
            "; ".join(problems + info))

    # 3. not eligible -> no vote
    nv = {n: N[n]["notvoter"] for n in keyed if N[n]["notvoter"]}
    bad = [n for n in nv if set(nv[n]) & set(N[n]["forged"])]
    if not nv:
        add_report("keyed node skips voting when not eligible", PENDING, "no NotAVoter round seen")
    else:
        add_report("keyed node skips voting when not eligible", FAIL if bad else PASS,
            ", ".join(f"node{n}: {len(r)} rounds skipped" for n, r in nv.items()))

    # 4. non-persistent voters change
    npseats = collections.Counter(s for nd in N.values() for (s, p) in nd["forged"].values() if not p)
    if not npseats:
        add_report("non-persistent voters change", PENDING, "no non-persistent vote yet")
    else:
        add_report("non-persistent voters change", PASS if len(npseats) > 1 else WARN,
            f"votes per non-persistent seat: {dict(npseats)}"
            + ("" if len(npseats) > 1 else " (only one seat ever voted)"))

    # 5. vote diffusion
    sets = {n: set(nd["votes"]) for n, nd in N.items()}
    union = set().union(*sets.values())
    missing = {n: len(union - s) for n, s in sets.items() if union - s}
    if not union:
        add_report("votes diffused to all nodes", PENDING, "no votes seen")
    else:
        lat = []
        for k in union:
            o = seat_node.get(k[1])
            if o and k in N[o]["votes"]:
                t0 = N[o]["votes"][k][0]
                lat += [(N[n]["votes"][k][0] - t0, n, k) for n in N if n != o and k in N[n]["votes"]]
        ls = sorted(x[0] for x in lat)
        slow = [(round(l, 1), n, k) for l, n, k in lat if l > 1]
        d = f"{len(union)} distinct votes"
        if ls:
            d += f"; latency median {ls[len(ls)//2]*1000:.0f} ms, max {ls[-1]*1000:.0f} ms ({len(ls)} samples)"
        if slow:
            d += f"; {len(slow)} samples > 1 s, e.g. (latency, node, vote) = {slow[0]}"
        if missing:
            d += f"; votes missing per node: {missing}"
        add_report("votes diffused to all nodes", FAIL if missing else (WARN if slow else PASS), d)

    # 6. cert generated exactly at quorum
    thr = run.threshold()
    gen_rounds, anomalies = set(), []
    for n, nd in N.items():
        byr = collections.defaultdict(list)
        for k, v in nd["votes"].items():
            byr[k[0]].append(v)
        for r, vs in byr.items():
            cum = F(0)
            for t, gen, w in sorted(vs, key=lambda x: x[0]):
                before, cum = cum, cum + w
                if gen:
                    gen_rounds.add(r)
                if thr is not None and gen != (before < thr <= cum):
                    anomalies.append((n, r, float(before), float(cum), gen))
    if thr is None or not gen_rounds:
        add_report("cert generated when quorum reached", PENDING, "no quorum threshold / cert yet")
    else:
        add_report("cert generated when quorum reached", FAIL if anomalies else PASS,
            f"threshold {float(thr):.3f}; certs generated in rounds {sorted(gen_rounds)}"
            + (f"; anomalies (node, round, before, after, generated): {anomalies[:3]}" if anomalies else ""))

    # 7. no second generation
    dup = [(n, r, x) for n, nd in N.items()
           for r, x in collections.Counter(k[0] for k, v in nd["votes"].items() if v[1]).items() if x > 1]
    add_report("no second cert generation", FAIL if dup else (PASS if gen_rounds else PENDING),
        f"duplicates (node, round, count): {dup}" if dup else "exactly one generating vote per round per node")

    # 8. certs reach every node's CertDB (diffusion / local add)
    absent = {r: [n for n, nd in N.items() if not any(c[0] == r for c in nd["certs"])]
              for r in sorted(gen_rounds)}
    absent = {r: m for r, m in absent.items() if m}
    already = sum(1 for nd in N.values() for c in nd["certs"] if c[2].startswith("PerasCertAlready"))
    if not gen_rounds:
        add_report("certs reach every node's CertDB", PENDING, "no cert yet")
    else:
        d = (f"generated by VoteDB but missing from CertDB (round: nodes): {absent}"
             if absent else "all generated certs present on all nodes")
        add_report("certs reach every node's CertDB", FAIL if absent else PASS,
            d + f"; {already} PerasCertAlreadyInDB events")

    # 9/10. cooldown and recovery
    cd, rec = [], []
    for n in keyed:
        d = N[n]["dec"]
        rounds = sorted(d)
        first_no = next((r for r in rounds if d[r] == "NoVote"
                         and any(d[q] == "Vote" for q in rounds if q < r)), None)
        if first_no is not None:
            cd.append((n, first_no))
            back = next((r for r in rounds if r > first_no and d[r] == "Vote"), None)
            if back is not None:
                rec.append((n, first_no, back))
    if not cd:
        add_report("cooldown entered", PENDING, "no NoVote round after voting yet")
        add_report("cooldown recovery", PENDING, "not in cooldown")
    else:
        add_report("cooldown entered", PASS, "first NoVote round: " + ", ".join(f"node{n}: r{r}" for n, r in cd))
        stuck = [n for n, _ in cd if n not in {x[0] for x in rec}]
        if stuck:
            add_report("cooldown recovery", PENDING, f"no vote after cooldown yet on nodes {stuck}")
        else:
            add_report("cooldown recovery", PASS, ", ".join(f"node{n}: r{a} -> r{b}" for n, a, b in rec))

    # informational anomalies
    inv = {n: nd["invalid_forged"] for n, nd in N.items() if nd["invalid_forged"]}
    ie = {n: nd["incl_err"] for n, nd in N.items() if nd["incl_err"]}
    add_report("locally forged invalid blocks", WARN if inv else PASS, str(inv) if inv else "none")
    add_report("cert inclusion errors", WARN if ie else PASS, str(ie) if ie else "none")

    # Late duplicate deliveries (these can make visualisations misleading if the "latest"
    # delivery is picked instead of the first).
    issued = {}
    for n, nd in N.items():
        for k, t0 in nd.get("forged_votes", {}).items():
            issued.setdefault(k, (n, t0))
    # Fallback: if the forge event isn't traced, approximate the "issue time" as
    # the earliest VoteDB add time observed across nodes.
    for k in set().union(*(set(nd.get("votes", {})) for nd in N.values())):
        if k not in issued:
            best = None
            for n, nd in N.items():
                v = nd.get("votes", {}).get(k)
                if v is None:
                    continue
                t0 = v[0]
                best = (n, t0) if best is None or t0 < best[1] else best
            if best is not None:
                issued[k] = best

    late = []
    for recv_n, nd in N.items():
        for (k, t, gen, w) in nd.get("votes_dups", []):
            issuer = issued.get(k)
            if issuer is None:
                continue
            issuer_n, t0 = issuer
            delay = t - t0
            r, _seat = k
            next_round_t = nd.get("dec_t", {}).get(r + 1)
            received_next_round = (next_round_t is not None and t >= next_round_t + 1)
            if received_next_round or delay > DUPLICATE_VOTE_LATE_THRESHOLD_S:
                late.append((k, issuer_n, recv_n, delay, received_next_round))

    if not late:
        add_report(
            "late duplicate vote deliveries",
            PASS,
            f"none (> {DUPLICATE_VOTE_LATE_THRESHOLD_S:.0f}s from issue time, or received in next round)",
        )
    else:
        # Stable output order: vote id, then receiver.
        late.sort(key=lambda x: (x[0][0], x[0][1], x[2]))
        detail = ";\n ".join(
            (
                f"vote r{k[0]} seat{k[1]}: node{issuer_n} -> node{recv_n} "
                + (f"received later than next round (r{k[0] + 2})" if received_next_round else f"+{delay:.1f}s")
            )
            for (k, issuer_n, recv_n, delay, received_next_round) in late
        )
        add_report(
            "late duplicate vote deliveries",
            WARN,
            detail,
        )
    return out


def report(out):
    colour = {PASS: "\033[32m", FAIL: "\033[31m", WARN: "\033[33m", PENDING: "\033[36m"}
    for name, st, detail in out:
        s = f"{colour[st]}{st:7}\033[0m" if sys.stdout.isatty() else f"{st:7}"
        print(f"[{s}] {name}\n          {detail}")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", nargs="?", default=os.path.join(here, "..", "..", "devnet-env")) # CWD
    ap.add_argument("--wait", type=float, default=0, help="keep re-checking up to this many seconds")
    ap.add_argument("--poll", type=float, default=15)
    a = ap.parse_args()
    deadline = time.time() + a.wait
    while True:
        out = checks(Run(a.results))
        pend = [c for c in out if c[2] == PENDING]
        if not pend or time.time() >= deadline:
            break
        print(f"... {len(pend)} check(s) pending, retrying in {a.poll:.0f}s", file=sys.stderr)
        time.sleep(a.poll)
    report(out)
    if any(c[2] == FAIL for c in out):
        sys.exit(1)
    sys.exit(2 if pend else 0)


if __name__ == "__main__":
    main()
