#!/usr/bin/env python3
"""Validate Peras testnet properties by reading the logs of a run.

Usage:
  scripts/check_peras_logs.py [RESULTS_DIR] [--wait SECONDS] [--poll SECONDS] [--no-cooldown]

RESULTS_DIR defaults to devnet-env and must contain
  logs/*_<port>/node-*.json      (cardano-tracer logs, one dir per node;
                                  the first file holds the startup trace)
  dijkstra-genesis.json          (quorum safety margin)

Without --wait the logs are analysed once. With --wait the checks are re-run
every --poll seconds until none is PENDING (e.g. cooldown not yet entered or
not yet recovered from) or the timeout expires, so it can run next to a live
testnet.

With --no-cooldown options script do not perform checks for cooldowns tests, because running
those tests requires introduction of the failure state.

Exit code: 0 all PASS/WARN, 1 some FAIL, 2 still PENDING at timeout.
"""
import argparse, collections, json, os, sys, time
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
            "votes": {},        # (round, seat) -> (vote, cert)
            "votes_dups": [],   # [(round, seat), (vote, cert)] duplicates (if any)
            "certs": [],        # (round, time, result)
            "invalid_forged": 0,
        }

    @staticmethod
    def _apply_event(nd: dict, ne: pt.NodeEvent) -> None:
        log_timestamp, ev = ne.log_timestamp, ne.event
        if isinstance(ev, pt.CantReadEnv):
            nd["nokey"] += 1
        elif isinstance(ev, pt.VoteRulesDecision):
            nd["dec"][ev.round] = "Vote" if ev.is_vote else "NoVote"
            nd["dec_t"].setdefault(ev.round, log_timestamp)
        elif isinstance(ev, pt.NotAVoterInRound):
            nd["notvoter"].append(ev.round)
        elif isinstance(ev, pt.ForgedVote):
            nd["forged"][ev.vote.round] = (ev.vote.seat, ev.vote.persistent)
            nd["forged_votes"][(ev.vote.round, ev.vote.seat)] = ev.vote.arrival_time
        elif isinstance(ev, pt.InclusionError):
            nd["incl_err"] += 1
        elif isinstance(ev, pt.VoteDbAddVote):
            key = (ev.vote.round, ev.vote.seat)
            if key not in nd["votes"]:
                nd["votes"][key] = (ev.vote, ev.cert)
            else:
                nd["votes_dups"].append((key, (ev.vote, ev.cert)))
        elif isinstance(ev, pt.CertDbAddCert):
            nd["certs"].append((ev.cert.round, ev.cert.arrival_time, ev.result))
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


# 1. non-stake nodes skip voting
def test_relays_nodes_skip_voting(run, add_report):
    test_name = "Node without a positive stake skips voting"
    nodes = run.nodes
    relays = run.relays

    if not relays:
        add_report(test_name, PENDING, "no node without stake found")
    else:
        bad = [n for n in relays if nodes[n]["forged"]]
        add_report(test_name, FAIL if bad else PASS,
            ", ".join(f"node{n}: {nodes[n]['nokey']} no-key lines, 0 votes forged" for n in relays))

# 2. eligible SPOs vote
def test_eligible_spos_vote(run, add_report):
    nodes = run.nodes
    spos = run.spos
    problems, info = [], []
    for n in spos:
        nd = nodes[n]
        vd = sorted(r for r, d in nd["dec"].items() if d == "Vote")
        fg = sorted(nd["forged"])
        persistent = bool(fg) and all(p for _, p in nd["forged"].values()) and not nd["notvoter"]
        if any(r not in vd for r in fg):
            problems.append(f"node{n} forged without a Vote decision")
        if persistent and fg != vd:
            problems.append(f"node{n} (persistent) voted {len(fg)}/{len(vd)} allowed rounds")
        info.append(f"node{n}: voted {len(fg)}/{len(vd)} allowed rounds" + (" (persistent)" if persistent else ""))
    if not any(nd["forged"] for nd in nodes.values()):
        add_report("eligible SPO votes", PENDING, "no vote forged yet")
    else:
        add_report("eligible SPO votes (persistent / non-persistent)", FAIL if problems else PASS,
            "; ".join(problems + info))

# 3. not eligible -> no vote
def test_not_eligible_skip_vote(run, add_report):
    nodes = run.nodes
    spos = run.spos
    nv = {n: nodes[n]["notvoter"] for n in spos if nodes[n]["notvoter"]}
    bad = [n for n in nv if set(nv[n]) & set(nodes[n]["forged"])]
    if not nv:
        add_report("spos node skips voting when not eligible", PENDING, "no NotAVoter round seen")
    else:
        add_report("spos node skips voting when not eligible", FAIL if bad else PASS,
            ", ".join(f"node{n}: {len(r)} rounds skipped" for n, r in nv.items()))

# 4. non-persistent voters change
def test_non_persistent_voters_change(run, add_report):
    nodes = run.nodes
    npseats = collections.Counter(s for nd in nodes.values() for (s, p) in nd["forged"].values() if not p)
    if not npseats:
        add_report("non-persistent voters change", PENDING, "no non-persistent vote yet")
    else:
        add_report("non-persistent voters change", PASS if len(npseats) > 1 else WARN,
            f"votes per non-persistent seat: {dict(npseats)}"
            + ("" if len(npseats) > 1 else " (only one seat ever voted)"))

# 5. vote diffusion
def test_vote_diffusion(run, add_report):
    nodes = run.nodes
    spos = run.spos
    seat_node = {s: n for n in spos for (s, _) in nodes[n]["forged"].values()}
    sets = {n: set(nd["votes"]) for n, nd in nodes.items()}
    union = set().union(*sets.values())
    missing = {n: len(union - s) for n, s in sets.items() if union - s}
    if not union:
        add_report("votes diffused to all nodes", PENDING, "no votes seen")
    else:
        lat = []
        for k in union:
            o = seat_node.get(k[1])
            if o and k in nodes[o]["votes"]:
                t0 = nodes[o]["votes"][k][0].arrival_time
                lat += [(nodes[n]["votes"][k][0].arrival_time - t0, n, k) for n in nodes if n != o and k in nodes[n]["votes"]]
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
def test_cert_generated_at_quorum(run, add_report):
    test_header = "cert generated when quorum reached"
    threshold = run.threshold()
    if threshold is None:
        add_report(test_header, FAIL, "found no threshold in logs")
        return
    generation_rounds, positive_anomalies, negative_anomalies = set(), [], []
    for node_id, node_data in run.nodes.items():

        break_off_by_round = {
            round: {
                "votes": {},                # seat -> vote
                "cert_with_pivot": None,    # (cert, seat) where "seat" issued the vote that created the cert
            }
            for round in run.all_rounds
        }
        for (round, seat), (vote, cert) in node_data["votes"].items():
            break_off_by_round[round]["votes"][seat] = vote
            if cert is not None:
                break_off_by_round[round]["cert_with_pivot"] = (cert, seat)

        for round, round_data in break_off_by_round.items():
            # If no certificate has been generated this round: check that either
            #   - we have received the certificate by the network,
            #   - or the threshold wasn't reached.
            if round_data["cert_with_pivot"] is None:
                if round in run.rounds_with_certs:
                    continue
                weight_by_block = {}
                for vote in round_data["votes"].values():
                    hash = vote.boosted_block_hash
                    weight_by_block[hash] = weight_by_block.get(hash, F(0)) + vote.weight
                for weight_sum in weight_by_block.values():
                    if weight_sum >= threshold:
                        negative_anomalies.append((node_id, round, float(weight_sum)))
            # If there has been a certificate in this round: check that it was generated
            # by the vote which passed the threshold
            else:
                generation_rounds.add(round)
                cert, pivot = round_data["cert_with_pivot"]
                votes = round_data["votes"]
                pivot_weight = votes[pivot].weight
                cert_weight = F(0)
                for voter in cert.voters:
                    vote = votes[voter]
                    if vote.boosted_block_hash == cert.boosted_block_hash:
                        cert_weight += vote.weight
                cert_weight_without_pivot = cert_weight - pivot_weight
                if cert_weight_without_pivot >= threshold or cert_weight < threshold:
                    positive_anomalies.append((node_id, round, float(cert_weight_without_pivot), float(cert_weight)))

    if not generation_rounds:
        add_report(test_header, PENDING, "no quorum threshold / cert yet")
    else:
        add_report(
            test_header,
            FAIL if positive_anomalies or negative_anomalies else PASS,
            f"threshold {float(threshold):.3f}; certs generated in rounds {sorted(generation_rounds)}"
            + (f"; positive anomalies (node, round, before, after): {positive_anomalies[:3]}" if positive_anomalies else "")
            + (f"; negative anomalies (node, round, total_weight): {negative_anomalies[:3]}" if negative_anomalies else "")
        )

# 7. no second generation
def test_no_second_generation(run, add_report):
    nodes = run.nodes
    dup = [
        (node_id, round, count) for node_id, node_data in nodes.items()
        for round, count in collections.Counter(
            round
            for (round, _), (_, cert) in node_data["votes"].items()
            if cert is not None
        ).items()
        if count > 1
    ]
    add_report("no second cert generation", FAIL if dup else (PASS if run.rounds_with_certs else PENDING),
        f"duplicates (node, round, count): {dup}" if dup else "exactly one generating vote per round per node")

# 8. certs reach every node's CertDB (diffusion / local add)
def test_certs_reach_certdb(run, add_report):
    nodes = run.nodes
    cert_rounds = run.rounds_with_certs
    absent = {r: [n for n, nd in nodes.items() if not any(c[0] == r for c in nd["certs"])]
              for r in sorted(cert_rounds)}
    absent = {r: m for r, m in absent.items() if m}
    already = sum(1 for nd in nodes.values() for c in nd["certs"] if c[2].startswith("PerasCertAlready"))
    if not cert_rounds:
        add_report("certs reach every node's CertDB", PENDING, "no cert yet")
    else:
        d = (f"generated by VoteDB but missing from CertDB (round: nodes): {absent}"
             if absent else "all generated certs present on all nodes")
        add_report("certs reach every node's CertDB", FAIL if absent else PASS,
            d + f"; {already} PerasCertAlreadyInDB events")

# 9/10. cooldown and recovery
def test_cooldown_and_recovery(run, add_report):
    cd, rec = [], []
    nodes = run.nodes
    spos = run.spos
    for n in spos:
        d = nodes[n]["dec"]
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

# 11. check vote/cert rounds consistency
def test_vote_cert_consistency(run, add_report):
    test_header = "vote/cert rounds consistency"
    vote_rounds, cert_rounds = run.rounds_with_votes, run.rounds_with_certs
    cert_no_vote = cert_rounds - vote_rounds
    if cert_no_vote:
        add_report(test_header, FAIL, f"rounds with certificate, but no votes: {sorted(cert_no_vote)}")
    elif vote_rounds:
        add_report(test_header, PASS, f"{len(cert_rounds)}/{len(vote_rounds)} rounds with vote also have certificates")
    else:
        add_report(test_header, PENDING, "no votes yet")

def checks(run, test_list, here):
    out = []

    def add_report(name, st, detail):
        out.append((name, st, detail))

    nodes = run.nodes
    if not nodes:
        return [("logs found", FAIL, "no nodes under logs/")]

    entries = json.load(open(os.path.join(here, "topologies.json")))
    spos = []
    spo_ports = []
    relays = []
    relay_ports = []
    for e in entries:
        node = e["node"]
        if node.get("role") == "spo":
            spos.append(node)
            spo_ports.append(int(e.get("port")))
        elif node.get("role") == "relay":
            relays.append(node)
            relay_ports.append(int(e.get("port")))

    run.spos = [n for n, nd in nodes.items() if int(nd["port"]) in spo_ports]
    run.relays = [n for n, nd in nodes.items() if int(nd["port"]) in relay_ports]

    run.rounds_with_votes = set(
        round
        for node_data in nodes.values()
        for (round, _) in node_data["votes"].keys()
    )

    run.rounds_with_certs = set(
        round
        for node_data in nodes.values()
        for (round, _time, _message) in node_data["certs"]
    )

    all_rounds = run.rounds_with_votes | run.rounds_with_certs
    for node_data in nodes.values():
        all_rounds.update(node_data["dec"].keys())
        all_rounds.update(node_data["dec_t"].keys())
        all_rounds.update(node_data["forged"].keys())
        all_rounds.update(
            round
            for (round, _seat) in node_data["forged_votes"].keys()
        )
    run.all_rounds = all_rounds
    run.max_round = max(all_rounds)

    run.votes = set(
        vote_id
        for node_data in nodes.values()
        for vote_id in node_data["votes"].keys()
    )

    for test in test_list:
        test(run, add_report)

    # informational anomalies
    inv = {n: nd["invalid_forged"] for n, nd in nodes.items() if nd["invalid_forged"]}
    ie = {n: nd["incl_err"] for n, nd in nodes.items() if nd["incl_err"]}
    add_report("locally forged invalid blocks", WARN if inv else PASS, str(inv) if inv else "none")
    add_report("cert inclusion errors", WARN if ie else PASS, str(ie) if ie else "none")

    # Late duplicate deliveries (these can make visualisations misleading if the "latest"
    # delivery is picked instead of the first).
    issued = {}
    for n, nd in nodes.items():
        for k, t0 in nd.get("forged_votes", {}).items():
            issued.setdefault(k, (n, t0))
    # Fallback: if the forge event isn't traced, approximate the "issue time" as
    # the earliest VoteDB add time observed across nodes.
    for k in set().union(*(set(nd.get("votes", {})) for nd in nodes.values())):
        if k not in issued:
            best = None
            for n, nd in nodes.items():
                v = nd.get("votes", {}).get(k)
                if v is None:
                    continue
                t0 = v[0].arrival_time
                best = (n, t0) if best is None or t0 < best[1] else best
            if best is not None:
                issued[k] = best

    late = []
    for recv_n, nd in nodes.items():
        for (k, (vote, _)) in nd.get("votes_dups", []):
            issuer = issued.get(k)
            if issuer is None:
                continue
            issuer_n, t0 = issuer
            delay = vote.arrival_time - t0
            r, _seat = k
            next_round_t = nd.get("dec_t", {}).get(r + 1)
            received_next_round = (next_round_t is not None and vote.arrival_time >= next_round_t + 1)
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
    return (out,run)


def report(out):
    colour = {PASS: "\033[32m", FAIL: "\033[31m", WARN: "\033[33m", PENDING: "\033[36m"}
    for name, st, detail in out:
        s = f"{colour[st]}{st:7}\033[0m" if sys.stdout.isatty() else f"{st:7}"
        print(f"[{s}] {name}\n          {detail}")

def report_stats(run, here):
    print ("Run statistics:")
    print(f"  Total nodes: {len(run.nodes)}")
    print(f"  Rounds with peras votes: {len(run.rounds_with_votes)}")
    print(f"  Rounds with peras certs: {len(run.rounds_with_certs)}")
    print(f"  Number of rounds: {run.max_round}") # rounds start at 1
    print(f"  Number of individual votes: {len(run.votes)}")
    print(f"  Nodes:")
    entries = json.load(open(os.path.join(here, "topologies.json")))
    for e in entries:
        node = e["node"]
        stake = node.get("stake")

        if stake is None:
            text_stake = "None"
        else:
            text_stake = str(stake)
        print(f"    {e.get("label")}: {node.get("role")} {text_stake}")

def main():
    here = os.getcwd()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", nargs="?", default=os.path.join(here, "devnet-env"))
    ap.add_argument("--wait", type=float, default=0, help="keep re-checking up to this many seconds")
    ap.add_argument("--poll", type=float, default=15)
    ap.add_argument("--no-cooldown", action="store_true", help="skip cooldown checks")
    a = ap.parse_args()
    deadline = time.time() + a.wait
    check_list = [ test_relays_nodes_skip_voting
        , test_eligible_spos_vote
        , test_not_eligible_skip_vote
        , test_non_persistent_voters_change
        , test_vote_diffusion
        , test_cert_generated_at_quorum
        , test_no_second_generation
        , test_certs_reach_certdb
        , test_vote_cert_consistency
        ]
    if not a.no_cooldown:
        check_list.append(test_cooldown_and_recovery)
    while True:
        (out, run) = checks(Run(a.results), check_list, a.results)
        pend = [c for c in out if c[1] == PENDING]
        if not pend or time.time() >= deadline:
            break
        print(f"... {len(pend)} check(s) pending, retrying in {a.poll:.0f}s", file=sys.stderr)
        time.sleep(a.poll)
    report_stats(run, a.results)
    report(out)
    if any(c[1] == FAIL for c in out):
        sys.exit(1)
    sys.exit(2 if pend else 0)

if __name__ == "__main__":
    main()
