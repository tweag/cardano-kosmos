#!/usr/bin/env python3
"""Draw a swim-lane diagram of a Peras testnet run from its cardano-tracer logs.

Usage:
  scripts/visualize_peras.py [RESULTS_DIR] [-o OUT.html] [--scale PX_PER_SEC]
                             [--from SEC] [--to SEC] [--blocks]
                             [--linear] [--gap SEC] [--burst PX_PER_SEC]
                             [--network-vote] [--network-cert] [--highlight]

RESULTS_DIR defaults to devnet-env (same layout as check_peras_logs.py). The
output is a self-contained HTML/SVG page: one lane per node, time flowing to
the right, one sub-row per kind of event. The shapes and colours follow the
Peras simulator (https://peras-simulation.cardano-scaling.org):

  block              (only with --blocks) sky-blue box (dodger-blue when it carries a certificate)
  vote               sandy-brown circle; dashed links to a small ring in the
                     "vote received" row of every node that added it to its VoteDB
  certificate        "generated": the vote-received ring (thick turquoise outline) of
                     the AddVote that reached quorum; "received": turquoise box
                     where it entered the CertDB through diffusion, with a link
                     from the first generator
  network            one arrow per object-diffusion message, from the sender's lane at the
                     time it sent it to the receiver's lane at the time it received it.
                     --network-vote draws the Vote protocol (Peras.Vote.Remote.*, solid
                     lines, "net vote" row), --network-cert the Cert protocol
                     (Peras.Cert.Remote.*, dashed lines, "net cert" row); they can be
                     combined. Colour = message type (Request/Reply ObjectIds / Objects,
                     Init). Only the messages around the busy periods are drawn.
  round boundary     dotted vertical line, labelled r<N>

Hover over any element for the full details.
"""
import argparse, collections, glob, html, json, os, re, sys
from fractions import Fraction as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_peras_logs import Run, ts  # noqa: E402

COLOUR = dict(vote_yes="#5cc96e", vote_no="#e45b5b", block="skyblue", block_cert="dodgerblue", vote="sandybrown",
              cert="turquoise", node="tomato", link="#999")
ROW_H, LEFT, TOP = 34, 80, 40
# Colour of every object-diffusion message type, shared by the Vote and the Cert protocol.
MSG_COLOUR = {"MsgInit": "#888888", "MsgRequestObjectIds": "#777777", "MsgReplyObjectIds": "#777777",
              "MsgRequestObjects": "#7c3aed", "MsgReplyObjects": "#7c3aed", "MsgDone": "#000000"}
# message -> (stroke width, dash pattern); requests are dashed, replies solid
MSG_STYLE = {"MsgRequestObjectIds": (0.5, "6 3"), "MsgReplyObjectIds": (0.5, "none"),
             "MsgRequestObjects": (0.5, "6 3"), "MsgReplyObjects": (0.8, "none")}
HL_CSS = (".edge{cursor:pointer}.vnode{cursor:pointer}"
          "svg.hovering .vnode:not(.hl){opacity:.4}svg.hovering .edge:not(.hl){opacity:.12}"
          ".edge.hl .vis{stroke-width:3!important;stroke-opacity:1!important;opacity:1!important}"
          ".vnode.hl circle{stroke:#000;stroke-width:2.5}"
          ".edge:hover .vis,.edge.sel .vis{stroke-width:3!important;stroke-opacity:1!important;opacity:1!important}"
          "svg.has-sel .edge:not(.sel):not(:hover) .vis{opacity:.08!important;stroke-opacity:.08!important}")
HL_HINT = ("<p style='font-size:12px;color:#666'>Hover over a line to highlight it, click to keep it "
           "highlighted (the rest fades), click the background to clear. Hover over a vote to see every node it "
           "reached, or over a received vote (small ring) to see its path from the sender. With --network-vote "
           "this highlights the real messages that carried the vote, otherwise a virtual line.</p>")
SCRIPT = """<script>
const svg = document.querySelector('svg');
svg.addEventListener('mouseover', ev => {            // bring the hovered line to the front
  const g = ev.target.closest('.edge');
  if (g && g !== svg.lastElementChild) svg.appendChild(g);
});
// Hovering a vote: its source circle highlights every node it was transferred to (rings and links);
// hovering a ring highlights the path from its source (link and source circle) to that ring.
const hl = els => els.forEach(x => x.classList.add('hl'));
svg.addEventListener('mouseover', ev => {
  const n = ev.target.closest('.vnode');
  if (!n || !n.dataset.vote) return;
  svg.classList.add('hovering');
  // with --network-vote the lines are the real messages (data-votes / data-aid), otherwise virtual links
  if (n.classList.contains('vsrc'))
    hl(svg.querySelectorAll(`[data-vote="${n.dataset.vote}"], .edge[data-votes~="${n.dataset.vote}"]`));
  else {
    hl([n]);
    hl(svg.querySelectorAll(`.vsrc[data-vote="${n.dataset.vote}"], .edge[data-to="${n.dataset.id}"]`));
    (n.dataset.path || '').split(' ').filter(Boolean).forEach(
      id => hl(svg.querySelectorAll(`.edge[data-aid="${id}"]`)));
  }
});
svg.addEventListener('mouseout', () => {
  svg.classList.remove('hovering');
  svg.querySelectorAll('.hl').forEach(x => x.classList.remove('hl'));
});
svg.addEventListener('click', ev => {
  const g = ev.target.closest('.edge');
  if (g) g.classList.toggle('sel');
  else svg.querySelectorAll('.edge.sel').forEach(x => x.classList.remove('sel'));
  svg.classList.toggle('has-sel', !!svg.querySelector('.edge.sel'));
});
</script>"""
MAX_NET_LATENCY = 1.0           # s: a receive later than this is not the answer to the send
CLUSTER_MIN, GAP_W = 150, 70   # px: narrowest busy period, squeezed quiet period
HATCH = ('<defs><pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" '
         'patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="6" stroke="#ddd" stroke-width="1"/>'
         '</pattern></defs>')
# Block creation is switched off by default (too much data); use --blocks to draw it.
SHOW_BLOCKS = False


def load(root):
    """Return {node: events} with events as plain dicts, times in absolute seconds."""
    nodes = {}
    for d in sorted(glob.glob(os.path.join(root, "logs", "*_*"))):
        n = Run.node_number(d)
        if n is None:
            continue
        ev = dict(blocks={}, votes=[], vrecv={}, dec={}, gen=[], recv=[], rounds={}, incl={}, net=[], carry=[], start=float("inf"),
                  port=(re.search(r"_(\d+)$", d) or [None, "?"])[1])
        for f in sorted(glob.glob(os.path.join(d, "node-*.json"))):
            for l in open(f, errors="replace"):
                try:
                    j = json.loads(l)
                    t, ns, x = ts(j["at"]), j["ns"], j.get("data", {})
                except Exception:
                    continue
                ev["start"] = min(ev["start"], t)
                if ns == "Forge.Loop.ForgedBlock":
                    ev["blocks"][x["block"]] = dict(t=t, slot=x["slot"], no=x["blockNo"], prev=x["blockPrev"])
                elif ns == "Peras.Vote.Forging.ForgedVote":
                    m = re.search(r"unPerasSeatIndex = (\d+)", x["vote"])
                    s = re.search(r"Bytes32RealPoint \(SlotNo (\d+)\)", x["vote"])
                    w = re.search(r"unVoteWeight = (\d+) % (\d+)", x["vote"])
                    ev["votes"].append(dict(
                        t=t, round=x["round"], seat=int(m[1]), slot=int(s[1]) if s else None,
                        weight=F(int(w[1]), int(w[2])) if w else None,
                        persistent="NonPersistentPerasVoteEligibilityProof" not in x["vote"]))
                elif ns == "ChainDB.PerasVoteDbEvent.AddVote":
                    m = re.search(r"PerasRoundNo (\d+).*unPerasSeatIndex = (\d+)", x["voteId"])
                    gen = "AndGenerated" in x["result"]
                    ev["vrecv"][(int(m[1]), int(m[2]))] = (t, gen)
                    if gen:
                        ev["gen"].append(dict(t=t, round=int(re.search(r"pcRoundNo = PerasRoundNo (\d+)", x["result"])[1])))
                elif ns == "ChainDB.PerasCertDbEvent.AddCert":
                    ev["recv"].append(dict(t=t, round=int(re.search(r"\d+", x["round"])[0]), result=x["result"]))
                elif ns == "Peras.Vote.Forging.RulesDecision":
                    ev["rounds"].setdefault(x["round"], t)
                    ev["dec"][x["round"]] = (t, x["decision"].startswith("Vote"), x["decision"])
                elif ns == "Peras.Vote.Outbound.TraceObjectDiffusionOutboundSendMsgReplyObjects":
                    # the votes inside a MsgReplyObjects (the Remote trace of the message has no payload)
                    ev["carry"].append((t, int(x["peer"]["connectionId"].split()[-1].rsplit(":", 1)[1]),
                                        [(int(r_), int(s_)) for r_, s_ in re.findall(
                                            r"pvRoundNo = PerasRoundNo (\d+),.*?unPerasSeatIndex = (\d+)", x["payload"])]))
                elif re.match(r"Peras\.(Vote|Cert)\.Remote\.(Send|Receive)\.", ns):
                    _, proto, _, way, _ = ns.split(".", 4)
                    peer = int(x["peer"]["connectionId"].split()[-1].rsplit(":", 1)[1])
                    ev["net"].append((t, proto, way, x["msg"]["kind"], peer))
                elif ns == "Peras.Cert.Inclusion.RulesDecision" and x["decision"].startswith("IncludeCert"):
                    ev["incl"][x["slot"]] = x["round"]
        nodes[n] = ev
    return nodes


def genesis_stakes(root):
    """Stake per node from shelley-genesis.json: the initialFunds of the base addresses are the stake
    delegated to a pool (their stake credential is mapped to a pool id in extraConfig.stakeCredentials,
    and pools-idxs-map.json gives the index of that pool). Pool N is run by node N. Funds of addresses
    without a stake credential (the 58-hex-digit enterprise addresses) are not staked.
    Returns ({node: lovelace}, total staked lovelace), or ({}, 0) if the files are not there."""
    try:
        extra = json.load(open(os.path.join(root, "shelley-genesis.json")))["extraConfig"]
        idx = json.load(open(os.path.join(root, "pools-idxs-map.json")))
        funds, creds = extra["initialFunds"]["data"], extra["stakeCredentials"]["data"]
    except (OSError, KeyError, ValueError):
        return {}, 0
    st = collections.Counter()
    for addr, lovelace in funds.items():
        pool = creds.get(addr[-56:]) if len(addr) == 114 else None   # base address: 1 + 28 + 28 bytes
        if pool in idx:
            st[idx[pool]] += lovelace
    return dict(st), sum(st.values())


def time_scale(times, gap, burst, pad=0.02):
    """Piecewise-linear time -> x mapping that stretches busy periods and squeezes quiet ones.

    Events closer than `gap` seconds form a cluster, drawn `burst` px per second (but at least
    CLUSTER_MIN px wide, so that the markers of one cluster fit). The quiet time between two
    clusters is squeezed into GAP_W px. Returns (X, clusters, gaps): X maps seconds to pixels,
    clusters is [(start_s, end_s, x0, x1)], gaps is [(from_s, to_s, x0, x1)]."""
    clusters, cur = [], None
    for t in sorted(times):
        if cur and t - cur[1] <= gap:
            cur[1] = t
        else:
            cur = [t, t]
            clusters.append(cur)
    knots, cl, gaps, x = [], [], [], LEFT
    for i, (a, b) in enumerate(clusters):
        a, b = a - pad, b + pad
        w = max(CLUSTER_MIN, (b - a) * burst)
        if i:
            gaps.append((cl[-1][1], a, x, x + GAP_W))
            knots += [(cl[-1][1], x), (a, x + GAP_W)]
            x += GAP_W
        knots += [(a, x), (b, x + w)]
        cl.append((a, b, x, x + w))
        x += w

    def X(t):
        if t <= knots[0][0]:
            return knots[0][1]
        for (t1, x1), (t2, x2) in zip(knots, knots[1:]):
            if t <= t2:
                return x1 + (x2 - x1) * ((t - t1) / (t2 - t1) if t2 > t1 else 0)
        return knots[-1][1]
    return X, cl, gaps


def render(nodes, scale, t_from, t_to, show_blocks=SHOW_BLOCKS, linear=False, gap=1.0, burst=300, network=(), highlight=False,
           stakes=None, total_stake=0):
    stakes = stakes or {}
    rows = (["block"] if show_blocks else []) + ["vote", "vote received", "cert received"]
    rows += [f"net {p.lower()}" for p in ("Vote", "Cert") if p in network]
    row = {r: i for i, r in enumerate(rows)}
    LANE_H = 28 + len(rows) * ROW_H
    allt = [e["t"] for ev in nodes.values() for k in ("votes", "gen", "recv") for e in ev[k]]
    allt += [t for ev in nodes.values() for t, _ in ev["vrecv"].values()]
    allt += [t for ev in nodes.values() for t, _, _ in ev["dec"].values()]
    if show_blocks:
        allt += [b["t"] for ev in nodes.values() for b in ev["blocks"].values()]
    if not allt:
        sys.exit("no Peras/forging events found")
    t0 = min(ev["start"] for ev in nodes.values())   # first record of the earliest node: the run's time zero
    lo, hi = t_from, (t_to if t_to is not None else max(allt) - t0)
    lane = {n: i for i, n in enumerate(sorted(nodes))}
    clusters, gaps, pad = [], [], 0.02
    if linear:
        X = lambda t: LEFT + (t - t0 - lo) * scale
        width = LEFT + (hi - lo) * scale + 60
    else:
        tx, clusters, gaps = time_scale([t - t0 for t in allt if lo <= t - t0 <= hi], gap, burst, pad)
        X = lambda t: tx(t - t0)
        width = (clusters[-1][3] if clusters else LEFT) + 60
    Y = lambda n, row: TOP + lane[n] * LANE_H + 14 + row * ROW_H + ROW_H / 2
    inwin = lambda t: lo <= t - t0 <= hi
    height = TOP + len(nodes) * LANE_H + 10
    bg, out, links = [], [], []
    e = html.escape

    def box(x, y, label, fill, tip, w=44, h=26, stroke="none", dash=""):
        out.append(f'<g><title>{e(tip)}</title><rect x="{x-w/2:.1f}" y="{y-h/2:.1f}" width="{w}" height="{h}" rx="5" '
                   f'fill="{fill}" stroke="{stroke}" stroke-dasharray="{dash}"/>'
                   f'<text x="{x:.1f}" y="{y+4:.1f}" text-anchor="middle" font-size="10">{e(label)}</text></g>')

    # lanes, axis, round boundaries
    for n in lane:
        y = TOP + lane[n] * LANE_H
        bg.append(f'<rect x="0" y="{y}" width="{width}" height="{LANE_H}" fill="{"#f6f6f6" if lane[n] % 2 else "#fff"}"/>')
        s = stakes.get(n)
        st = (f"stake {s:,} lovelace = {s/total_stake*100:.2f}% of the staked funds in shelley-genesis.json "
              f"(initialFunds)" if s else "no stake delegated to this node's pool in shelley-genesis.json")
        out.append(f'<g><title>{e(st)}</title>'
                   f'<circle cx="34" cy="{y+LANE_H/2-8}" r="22" fill="{COLOUR["node"]}"/>'
                   f'<text x="34" y="{y+LANE_H/2-4}" text-anchor="middle" fill="white" font-size="12">Node {n}</text>'
                   f'<text x="34" y="{y+LANE_H/2+32}" text-anchor="middle" font-size="10" fill="#444">'
                   f'{f"stake {s/total_stake*100:.1f}%" if s else "no stake"}</text>'
                   + (f'<text x="34" y="{y+LANE_H/2+44}" text-anchor="middle" font-size="10" fill="#444">'
                      f'{s/1e12:.2f}M \u20b3</text>' if s else "")
                   + f'<text x="34" y="{y+LANE_H/2+(56 if s else 44)}" text-anchor="middle" '
                   f'font-size="10" fill="#444">port {nodes[n]["port"]}</text></g>')
        for r, i in row.items():
            out.append(f'<text x="{width-4}" y="{Y(n, i)+3}" text-anchor="end" font-size="9" fill="#aaa">{r}</text>')
    if linear:
        step = 10 if scale >= 3 else 60
        for sec in range(int(lo // step) * step, int(hi) + 1, step):
            if sec >= lo:
                out.append(f'<line x1="{X(t0+sec):.1f}" y1="{TOP-6}" x2="{X(t0+sec):.1f}" y2="{height}" stroke="#ddd"/>'
                           f'<text x="{X(t0+sec):.1f}" y="{TOP-10}" text-anchor="middle" font-size="10" fill="#666">{sec}s</text>')
    else:
        for (a, b, x0, x1) in clusters:    # a time label at the start of every busy period
            out.append(f'<line x1="{x0:.1f}" y1="{TOP-6}" x2="{x0:.1f}" y2="{height}" stroke="#ddd"/>'
                       f'<text x="{x0:.1f}" y="{TOP-10}" text-anchor="middle" font-size="10" fill="#666">{a+pad:.2f}s</text>')
        for (a, b, x0, x1) in gaps:        # quiet time is squeezed and hatched
            bg.append(f'<rect x="{x0:.1f}" y="{TOP}" width="{x1-x0:.1f}" height="{height-TOP}" fill="url(#hatch)"/>')
            out.append(f'<text x="{(x0+x1)/2:.1f}" y="{TOP+22}" text-anchor="middle" font-size="10" fill="#999">'
                       f'\u22ef {b-a:.1f}s \u22ef</text>')
    rounds = {}
    for ev in nodes.values():
        for r, t in ev["rounds"].items():
            rounds[r] = min(t, rounds.get(r, t))
    for r, t in sorted(rounds.items()):
        if inwin(t):
            out.append(f'<line x1="{X(t):.1f}" y1="{TOP}" x2="{X(t):.1f}" y2="{height}" stroke="#888" stroke-dasharray="2 4"/>'
                       f'<text x="{X(t)+3:.1f}" y="{TOP+10}" font-size="10" fill="#555">r{r}</text>')

    # index every block by slot, to link votes and chain parents
    by_slot, by_hash = {}, {}
    for n, ev in nodes.items():
        for h, b in ev["blocks"].items():
            by_slot[b["slot"]] = (n, h, b)
            by_hash[h] = (n, b)

    def edge(a, b, attrs, tip="", data=""):
        """A line that can be highlighted: a wide invisible line catches the pointer, the thin one is drawn."""
        pts = f'x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}"'
        if not highlight:
            return f'<g>' + (f'<title>{e(tip)}</title>' if tip else "") + f'<line {pts} {attrs}/></g>'
        return (f'<g class="edge" {data}>' + (f'<title>{e(tip)}</title>' if tip else "") +
                f'<line {pts} stroke="transparent" stroke-width="9"/><line class="vis" {pts} {attrs}/></g>')

    def link(a, b, colour, dash="4 3", data=""):
        links.append(edge(a, b, f'stroke="{colour}" stroke-width="1.2" stroke-dasharray="{dash}" '
                                f'opacity="{0.35 if not dash else 0.7}"', data=data))

    # blocks
    for n, ev in nodes.items():
        for h, b in (ev["blocks"].items() if show_blocks else ()):
            if not inwin(b["t"]):
                continue
            has_cert = b["slot"] in ev["incl"]
            box(X(b["t"]), Y(n, row["block"]), f"{h[:8]}", COLOUR["block_cert"] if has_cert else COLOUR["block"],
                f"block {h[:8]}\nslot {b['slot']}, block no {b['no']}\ncreator {n}\nt = {b['t']-t0:.1f}s"
                + (f"\ncarries certificate of round {ev['incl'][b['slot']]}" if has_cert else ""), w=54)
            p = by_hash.get(b["prev"])
            if p and inwin(p[1]["t"]):
                link((X(p[1]["t"]), Y(p[0], row["block"])), (X(b["t"]), Y(n, row["block"])), COLOUR["link"], "")

    # votes: the voting-rules decision of every round (green = vote, red = no vote);
    # a green circle sits at the time the vote was forged, or is dashed if none was
    forged = {(v["round"], v["seat"]): (n, v) for n, ev in nodes.items() for v in ev["votes"]}
    for n, ev in nodes.items():
        mine = {v["round"]: v for v in ev["votes"]}
        for r, (td, ok, text) in sorted(ev["dec"].items()):
            v = mine.get(r)
            t = v["t"] if v else td
            if not inwin(t):
                continue
            x, y = X(t), Y(n, row["vote"])
            tip = f"round {r}: {'Vote' if ok else 'NoVote'}\n{text}\nt = {td-t0:.1f}s"
            if v:
                tip += (f"\nvote forged by node {n} (seat {v['seat']}, "
                        f"{'persistent' if v['persistent'] else 'non-persistent'}) for block at slot {v['slot']}")
            elif ok:
                tip += "\nno vote forged"
            head = f'<g class="vnode vsrc" data-vote="{r}-{v["seat"]}">' if v else "<g>"   # only a forged vote has recipients
            out.append(f'{head}<title>{e(tip)}</title>'
                       f'<circle cx="{x:.1f}" cy="{y:.1f}" r="12" '
                       f'fill="{COLOUR["vote_yes"] if ok else COLOUR["vote_no"]}"'
                       + (' fill-opacity="0.35" stroke="#2a7" stroke-dasharray="3 2"' if ok and not v else "") +
                       f'/><text x="{x:.1f}" y="{y+3.5:.1f}" text-anchor="middle" font-size="10">r{r}</text></g>')
            tgt = by_slot.get(v["slot"]) if show_blocks and v else None
            if tgt and inwin(tgt[2]["t"]):
                link((x, y), (X(tgt[2]["t"]), Y(tgt[0], row["block"])), COLOUR["vote_yes"])

    # AddVote on every node: the source is found by (round, seat) among the forged votes. Every AddVote
    # is a "vote received" marker (labelled with the sender); the one that completed the quorum is
    # outlined and also linked to the certificate generation drawn below. Votes arrive within a few
    # milliseconds, so markers of one node are spread sideways (the tooltip has the real time).
    gen_ring = {}                            # round -> (time, x, y) of the first generating AddVote
    rings = []                               # (id, node, vote, time) of every vote-received ring
    for m, mev in nodes.items():
        prev_x = -1e9
        for (r, seat), (tr, gen) in sorted(mev["vrecv"].items(), key=lambda kv: kv[1][0]):
            if not inwin(tr):
                continue
            src = forged.get((r, seat))
            x = max(X(tr), prev_x + 17)
            prev_x = x
            y = Y(m, row["vote received"])
            who = "self" if src and src[0] == m else (f"node {src[0]}" if src else "unknown source")
            rid = f"v{m}-{r}-{seat}"
            rings.append((rid, m, (r, seat), tr))
            out.append(f'<g class="vnode vrecv" data-vote="{r}-{seat}" data-id="{rid}" data-path="@@{rid}@@">'
                       f'<title>vote round {r}, seat {seat} received by node {m} from {who}'
                       + (f', latency {(tr - src[1]["t"])*1000:.0f} ms' if src and src[0] != m else "")
                       + f'\nt = {tr-t0:.3f}s' + ("\ncompleted the quorum: certificate generated" if gen else "")
                       + f'</title><circle cx="{x:.1f}" cy="{y:.1f}" r="8" fill="#fbe3cf" '
                       f'stroke="{COLOUR["cert"] if gen else COLOUR["vote"]}" stroke-width="{2.5 if gen else 1}"/>'
                       f'<text x="{x:.1f}" y="{y+3:.1f}" text-anchor="middle" font-size="8">'
                       f'{src[0] if src else "?"}</text></g>')
            if src and src[0] != m and inwin(src[1]["t"]) and "Vote" not in network:
                # (with --network-vote the real messages are drawn instead of these virtual links)
                link((X(src[1]["t"]), Y(src[0], row["vote"])), (x, y), COLOUR["vote"],
                     data=f'data-vote="{r}-{seat}" data-to="{rid}"')
            if gen and (r not in gen_ring or tr < gen_ring[r][0]):
                gen_ring[r] = (tr, x, y)

    # certificates received through diffusion (a node that generated the cert itself shows it as the
    # outlined vote-received ring), linked from the first node that generated it
    for n, ev in nodes.items():
        generated = {g["round"] for g in ev["gen"]}
        for c in ev["recv"]:
            if c["round"] in generated or not inwin(c["t"]):
                continue
            box(X(c["t"]), Y(n, row["cert received"]), f"cert r{c['round']}", "#c9f2ec",
                f"certificate round {c['round']} received by node {n}\n{c['result']}\nt = {c['t']-t0:.1f}s",
                w=50, stroke=COLOUR["cert"], dash="3 2")
            g = gen_ring.get(c["round"])
            if g:
                link((g[1], g[2]), (X(c["t"]), Y(n, row["cert received"])), COLOUR["cert"])

    net = []
    hops = []                                    # {id, a, b, t1, t2, votes} of the arrows that carry votes
    if network:
        port2n = {ev["port"]: n for n, ev in nodes.items()}
        inside = lambda t: lo <= t - t0 <= hi and (linear or any(a <= t - t0 <= b for a, b, _, _ in clusters))
        sent, recvd = collections.defaultdict(list), collections.defaultdict(list)
        for n, ev in nodes.items():
            for t, proto, way, msg, peer in ev["net"]:
                m = port2n.get(str(peer))
                if m is None or proto not in network:
                    continue
                if way == "Send":
                    sent[proto, n, m, msg].append(t)
                else:
                    recvd[proto, m, n, msg].append(t)
        used = set()
        carry = collections.defaultdict(list)    # (node, peer port) -> [(time, votes)] of MsgReplyObjects
        for n, ev in nodes.items():
            for t, peer, votes in ev["carry"]:
                carry[n, str(peer)].append((t, votes))

        def votes_in(a_, b_, t1):
            best = min(carry.get((a_, nodes[b_]["port"]), []), key=lambda c: abs(c[0] - t1), default=None)
            return best[1] if best and abs(best[0] - t1) < 0.005 else []

        def pairs(snd, rcv):
            """Match every send with the first later receive of the same message on that link; a message
            without a counterpart in the logs (e.g. cut off at the end) is skipped, not shifted onto
            the next one."""
            j, rcv = 0, sorted(rcv)
            for t1 in sorted(snd):
                while j < len(rcv) and rcv[j] < t1 - 0.005:
                    j += 1
                if j < len(rcv) and rcv[j] - t1 <= MAX_NET_LATENCY:
                    yield t1, rcv[j]
                    j += 1

        for key, ts_ in sent.items():
            proto, a_, b_, msg = key
            for t1, t2 in pairs(ts_, recvd.get(key, [])):
                if not (inside(t1) and inside(t2)):
                    continue
                used.add(msg)
                c = MSG_COLOUR.get(msg, "#444")
                vs = votes_in(a_, b_, t1) if (proto, msg) == ("Vote", "MsgReplyObjects") else []
                aid = f"a{len(net)}"
                if vs:
                    hops.append(dict(id=aid, a=a_, b=b_, t1=t1, t2=t2, votes=vs))
                net.append(edge(
                    (X(t1), Y(a_, row["net " + proto.lower()])), (X(t2), Y(b_, row["net " + proto.lower()])),
                    f'stroke="{c}" stroke-width="{MSG_STYLE.get(msg, (0.6, "6 3"))[0]}" stroke-opacity="0.8" '
                    f'stroke-dasharray="{MSG_STYLE.get(msg, (0.6, "6 3"))[1]}" marker-end="url(#m{c[1:]})"',
                    f"{proto} {msg}\nnode {a_} -> node {b_}\nsent t = {t1-t0:.3f}s, "
                    f"received {(t2-t1)*1000:.1f} ms later"
                    + ("\ncarries votes (round, seat): " + ", ".join(f"({r_}, {s_})" for r_, s_ in vs) if vs else ""),
                    f'data-aid="{aid}"' + (f' data-votes="{" ".join(f"{r_}-{s_}" for r_, s_ in vs)}"' if vs else "")))
    # The path of a received vote: from the node it was received at, the last message that carried the
    # vote there, then the one that brought it to that message's sender, and so on up to the source node.
    paths = {}
    for rid, m, key, tr in rings:
        src, cur, tcur, path = forged.get(key), m, tr + 0.001, []
        while src and cur != src[0]:
            into = [h for h in hops if key in h["votes"] and h["b"] == cur and h["t2"] <= tcur]
            if not into:
                break
            h = max(into, key=lambda h: h["t2"])
            path.append(h["id"])
            cur, tcur = h["a"], h["t1"]
        paths[rid] = " ".join(path)
    out[:] = [re.sub(r"@@([^@]+)@@", lambda mm: paths.get(mm[1], ""), x) if "@@" in x else x for x in out]
    markers = "".join(f'<marker id="m{c[1:]}" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="4" markerHeight="4" '
                      f'orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="{c}"/></marker>' for c in MSG_COLOUR.values())
    netlegend = ("".join(f"<span style='color:#fff;background:{c}'>{m[3:]}</span>"
                         for m, c in MSG_COLOUR.items() if m in used) +
                 "<span style='border:1px solid #888'>grey: object ids, purple: objects; dashed: request, solid: reply</span>"
                 ) if network else ""
    legend = ("<div class=legend>"
              + (f"<span style='background:{COLOUR['block']}'>block</span>"
                 f"<span style='background:{COLOUR['block_cert']}'>block with certificate</span>"
                 if show_blocks else "") +
              f"<span style='background:{COLOUR['vote_yes']};border-radius:10px'>vote</span>"
              f"<span style='background:{COLOUR['vote_no']};border-radius:10px'>no vote</span>"
              f"<span style='background:#fbe3cf;border:1px solid {COLOUR['vote']};border-radius:10px'>vote received</span>"
              f"<span style='background:#fbe3cf;border:2.5px solid {COLOUR['cert']};border-radius:10px'>certificate generated</span>"
              f"<span style='background:#c9f2ec;border:1px dashed {COLOUR['cert']}'>certificate received</span>"
              + netlegend + "</div>")
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height}" '
           f'font-family="Helvetica,Arial,sans-serif">' + HATCH + f"<defs>{markers}</defs>" + "".join(bg) + "".join(links) + "".join(net) + "".join(out) + "</svg>")
    return (f"<!doctype html><meta charset=utf-8><title>Peras run</title><style>"
            "body{font-family:Helvetica,Arial,sans-serif;margin:8px}"
            ".legend span{display:inline-block;padding:3px 8px;margin-right:8px;border-radius:4px;font-size:12px}"
            ".w{overflow-x:auto;border:1px solid #ddd}"
            + (HL_CSS if highlight else "") + "</style>"
            f"<h3>Peras run: {len(nodes)} nodes, {hi - lo:.0f} s</h3>{legend}"
            + (HL_HINT if highlight else "") +
            f"<div class=w>{svg}</div>" + (SCRIPT if highlight else ""))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", nargs="?", default=os.path.join(here, "..", "devnet-env"))
    ap.add_argument("-o", "--output", default="peras.html")
    ap.add_argument("--blocks", action="store_true", help="also draw block creation (a lot of data)")
    ap.add_argument("--network-vote", action="store_true", help="also draw the Vote object-diffusion messages")
    ap.add_argument("--network-cert", action="store_true", help="also draw the Cert object-diffusion messages")
    ap.add_argument("--highlight", action="store_true",
                    help="make the page interactive: hover/click highlights lines and the path of a vote")
    ap.add_argument("--linear", action="store_true", help="plain linear time axis instead of the stretched one")
    ap.add_argument("--scale", type=float, default=8, help="pixels per second, with --linear (default 8)")
    ap.add_argument("--gap", type=float, default=1.0, help="seconds without events that end a busy period (default 1)")
    ap.add_argument("--burst", type=float, default=None,
                    help="pixels per second inside busy periods (default 300, or 20000 with --network-vote/--network-cert)")
    ap.add_argument("--from", dest="t_from", type=float, default=0, help="window start, seconds into the run")
    ap.add_argument("--to", dest="t_to", type=float, help="window end, seconds into the run")
    a = ap.parse_args()
    a.network = {p for p, on in (("Vote", a.network_vote), ("Cert", a.network_cert)) if on}
    if a.burst is None:
        a.burst = 20000 if a.network else 300
    nodes = load(a.results)
    if not nodes:
        sys.exit("no nodes found under logs/")
    open(a.output, "w").write(render(nodes, a.scale, a.t_from, a.t_to, a.blocks, a.linear, a.gap, a.burst, a.network, a.highlight,
                                         *genesis_stakes(a.results)))
    print(f"wrote {a.output}")


if __name__ == "__main__":
    main()
