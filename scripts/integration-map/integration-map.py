#!/usr/bin/env python3
"""Render an integration map of kosmos lockstep steps and the integration branches they pin, as one HTML file.

Usage: integration-map.py CONFIG.toml OUT.html

Everything comes from local git, except what git does not record, which the configuration declares (see README.md).
"""
import html
import json
import math
import os
import re
import subprocess
import sys
import tomllib

config_path, out = sys.argv[1], sys.argv[2]
with open(config_path, "rb") as f:
    CONFIG = tomllib.load(f)

GH = "https://github.com/"
KOSMOS = os.path.expanduser(CONFIG["kosmos"].get("path") or subprocess.check_output(
    ["git", "-C", os.path.dirname(os.path.abspath(__file__)), "rev-parse", "--show-toplevel"], text=True).strip())
KOSMOS_BASE = CONFIG["kosmos"]["base"]
KOSMOS_BRANCH = CONFIG["kosmos"]["branch"]
REPO_ORDER = [r["name"] for r in CONFIG["repo"]]
# repo -> (local clone, fork slug, integration base)
FORK = {r["name"]: (os.path.expanduser(r["path"]), r["fork"], r["base"]) for r in CONFIG["repo"]}
INT_BRANCH = {r["name"]: r["branch"] for r in CONFIG["repo"]}
BASE_PR = {r["name"]: (r["base_label"], r["base_url"]) for r in CONFIG["repo"]}


def pr(entry):
    """An open PR: "slug#number", its title, whether it is a draft, its head when last checked, and the PR commit a
    cherry-picked changeset was taken from (when the PR could not be merged as-is)."""
    slug, n = entry["pr"].split("#")
    return {"label": f"{slug.split('/')[1]}#{n}" if slug.startswith("IntersectMBO") else f"tweag#{n}",
            "url": f"{GH}{slug}/pull/{n}", "title": entry["title"], "slug": slug, "draft": entry.get("draft", False),
            "head": entry.get("head"), "adapted_from": entry.get("adapted_from")}


def by_changeset(entries):
    d = {}
    for x in entries:
        d.setdefault((x["repo"], x["ref"]), []).append(pr(x))
    return d


PRS = by_changeset(CONFIG.get("pr", []))
INCLUDES = by_changeset(CONFIG.get("includes", []))
KIND_OVERRIDE = {(x["repo"], x["ref"]): {"kind": x["kind"], "note": x["note"], "url": x["url"]}
                 for x in CONFIG.get("kind_override", [])}
KOSMOS_SIDE = {int(k): v for k, v in CONFIG.get("kosmos_side", {}).items()}
REQUIRES = [((x["repo"], x["ref"]), (x["needs_repo"], x["needs_ref"]), x["how"], x["why"])
            for x in CONFIG.get("requires", [])]


def git(wt, *args):
    return subprocess.check_output(["git", "-C", wt, *args], text=True, stderr=subprocess.DEVNULL).strip()


def is_ancestor(wt, a, b):
    return subprocess.run(["git", "-C", wt, "merge-base", "--is-ancestor", a, b]).returncode == 0



# ---- kosmos steps and their pins --------------------------------------------
# A step is a kosmos commit that moves at least one subrepo pin; other commits (kosmos-only tooling) are not steps.
ksteps = []
last_pins = None
for c in git(KOSMOS, "rev-list", "--reverse", f"{KOSMOS_BASE}..{KOSMOS_BRANCH}").split():
    pins = {}
    for name in REPO_ORDER:
        try:
            cfg = git(KOSMOS, "show", f"{c}:packages/{name}/.gitrepo")
        except subprocess.CalledProcessError:
            continue
        pins[name] = re.search(r"commit = (\w+)", cfg).group(1)
    if pins == last_pins:
        continue
    last_pins = pins
    ksteps.append((c, git(KOSMOS, "log", "-1", "--format=%s", c), pins))

# ---- per-repo merges --------------------------------------------------------
repos = {}
for name in REPO_ORDER:
    wt = FORK[name][0]
    base = git(wt, "rev-parse", FORK[name][2])
    merges = []
    for m in git(wt, "rev-list", "--first-parent", "--reverse", f"{base}..{INT_BRANCH[name]}").split():
        p1, p2 = git(wt, "rev-parse", f"{m}^1"), git(wt, "rev-parse", f"{m}^2")
        ref, desc = re.match(r"Merge (.+?) \((.*)\)$", git(wt, "log", "-1", "--format=%s", m)).groups()
        override = KIND_OVERRIDE.get((name, ref), {})
        kind = override.get("kind") or ("local" if ref.startswith("kosmos-local/")
                                        else "compat" if ref.startswith("kosmos-compat/") else "up")
        commits = [tuple(l.split("\x1f")) for l in
                   git(wt, "log", "--reverse", "--format=%h\x1f%an\x1f%s", f"{p1}..{p2}").splitlines()]
        stat = git(wt, "diff", "--shortstat", p1, m)
        num = lambda w: int((re.search(rf"(\d+) {w}", stat) or [0, 0])[1])
        step = next(i for i, (_, _, pins) in enumerate(ksteps, 1)
                    if name in pins and is_ancestor(wt, m, pins[name]))
        mb = git(wt, "merge-base", p1, p2)
        merges.append({"sha": m[:9], "full": m, "p1": p1, "p2": p2, "mb": mb, "ref": ref, "desc": desc, "kind": kind,
                       "commits": commits, "step": step, "files": num("files? changed"),
                       "ins": num("insertions?"), "dels": num("deletions?"), "override": override,
                       "pr": "stub" if kind == "stub" else "open" if (name, ref) in PRS
                       else "na" if kind in ("local", "compat") else "none"})
    repos[name] = {"name": name, "base": base[:9], "head": git(wt, "rev-parse", "--short=9", INT_BRANCH[name]),
                   "merges": merges}


# ---- cross-repository requirements: resolve and check ------------------------
merge_by_ref = {(n, m["ref"]): m for n in REPO_ORDER for m in repos[n]["merges"]}
for n in REPO_ORDER:
    for m in repos[n]["merges"]:
        m["requires"], m["required_by"] = [], []
for (drepo, dref), (trepo, tref), how, why in REQUIRES:
    dm = merge_by_ref.get((drepo, dref))
    assert dm, f"REQUIRES: no merge {dref} in {drepo}"
    if tref == "@base":
        assert dm["step"] >= next(i for i, (_, _, pins) in enumerate(ksteps, 1) if trepo in pins), \
            f"REQUIRES: {drepo} {dref} needs {trepo} before kosmos pins it"
        dm["requires"].append({"repo": trepo, "ref": f"its base ({BASE_PR[trepo][0]})", "how": how, "why": why,
                               "step": None})
        continue
    tm = merge_by_ref.get((trepo, tref))
    assert tm, f"REQUIRES: no merge {tref} in {trepo}"
    assert tm["step"] <= dm["step"], \
        f"REQUIRES: {drepo} {dref} (step {dm['step']}) needs {trepo} {tref} (step {tm['step']})"
    dm["requires"].append({"repo": trepo, "ref": tref, "how": how, "why": why, "step": tm["step"]})
    tm["required_by"].append({"repo": drepo, "ref": dref, "how": how, "why": why, "step": dm["step"]})

# ---- stack edges: a merged branch built on another merged branch ----------------
# B is built on A when B's branch is not based on the integration state it merges into (an upstream branch), shares
# commits with A's branch that the state A merges into lacks, and does not contain our merge of A. This catches PR
# stacks built on an older commit of their base PR too. Transitively reduced.
for n in REPO_ORDER:
    wt = FORK[n][0]
    ms = repos[n]["merges"]
    on = {}
    for j, b in enumerate(ms):
        on[j] = set()
        if b["mb"] == b["p1"]:
            b["stacked_on"] = []
            continue
        for i, a in enumerate(ms[:j]):
            if is_ancestor(wt, a["full"], b["p2"]):
                continue
            shared = git(wt, "merge-base", a["p2"], b["p2"])
            if shared and not is_ancestor(wt, shared, a["p1"]):
                on[j].add(i)
    for j, b in enumerate(ms):
        b["stacked_on"] = [ms[i] for i in sorted(on[j]) if not any(i in on[k] for k in on[j] if k != i)]

MAX_CHURN = max(m["ins"] + m["dels"] for r in repos.values() for m in r["merges"])


def compare_url(repo, mg):
    """GitHub comparison of the merge against the integration state it merges into."""
    return f"{GH}{FORK[repo][1]}/compare/{mg['p1']}...{mg['full']}"


def based_on(repo, mg):
    if mg["mb"] == mg["p1"]:
        return "on the state it merges into"
    return f"upstream branch, forks at {mg['mb'][:9]}"


def size(mg, compact=False):
    churn = mg["ins"] + mg["dels"]
    w = 4 + 56 * math.log10(churn + 1) / math.log10(MAX_CHURN + 1)
    gw = w * mg["ins"] / churn if churn else 0
    bar = (f'<span class="sbar" style="width:{w:.0f}px"><span class="sins" style="width:{gw:.0f}px"></span></span>')
    nums = f'<span class="sins-t">+{mg["ins"]:,}</span> <span class="sdel-t">−{mg["dels"]:,}</span>'
    if compact:
        return f'<span class="size" title="{mg["files"]} files, +{mg["ins"]} −{mg["dels"]}">{bar}{nums}</span>'
    return f'<span class="size">{bar}{nums} <span class="sfiles">{mg["files"]} file{"s" if mg["files"] != 1 else ""}</span></span>'


KIND_LABEL = {"up": "upstream-bound", "compat": "kosmos-compat", "local": "test-only", "stub": "stub / WIP"}

e = html.escape


def chip(kind):
    return f'<span class="chip k-{kind}"><span class="shape"></span>{KIND_LABEL[kind]}</span>'


def pr_link(x):
    draft = "<span class=draft>draft</span>" if x["draft"] else ""
    return (f'<a class="prlink" href="{e(x["url"])}" target="_blank" rel="noopener" title="{e(x["title"])}">'
            f'{e(x["label"])}{draft} ↗</a>')


def pr_relation(x, mg):
    """How the changeset relates to the PR: merged as-is, PR moved since, or adapted."""
    if x["adapted_from"]:
        return (f'<span class="rel rel-adapted" title="cherry-picked onto our base: the PR is built on a different base">'
                f'adapted from <code>{x["adapted_from"][:9]}</code></span>')
    if x["head"] and x["head"] != mg["p2"]:
        cmp = f'{GH}{x["slug"]}/compare/{mg["p2"]}...{x["head"]}'
        return (f'<a class="rel rel-moved" href="{e(cmp)}" target="_blank" rel="noopener" '
                f'title="we merged {mg["p2"][:9]}; the PR head is now {x["head"][:9]}">PR moved since ↗</a>')
    if x["head"]:
        return '<span class="rel rel-asis" title="we merged the current PR head">merged as-is</span>'
    return ""


def pr_badge(repo, mg):
    inc = INCLUDES.get((repo, mg["ref"]))
    extra = ('<span class="incl">includes</span>'
             + "".join(pr_link(x) + f'<span class="incltitle">{e(x["title"])}</span>' for x in inc)) if inc else ""
    if mg["pr"] == "open":
        prs = PRS[(repo, mg["ref"])]
        return ('<span class="pr pr-open">● open PR</span>'
                + "".join(pr_link(x) + pr_relation(x, mg) for x in prs) + extra)
    if mg["pr"] == "na":
        return ""
    if mg["pr"] == "stub":
        o = mg["override"]
        return (f'<a class="stubnote" href="{e(o["url"])}" target="_blank" rel="noopener">{e(o["note"])} ↗</a>'
                + extra)
    return f'<span class="pr pr-none">○ no PR yet</span>{extra}'


def pr_name(repo, mg):
    """The PR title, as the changeset's name."""
    prs = PRS.get((repo, mg["ref"]))
    return f'<div class="prname">{" · ".join(e(x["title"]) for x in prs)}</div>' if prs else ""


def pr_mark(repo, mg):
    """Compact marker for the lockstep cells."""
    if mg["pr"] == "open":
        x = PRS[(repo, mg["ref"])][0]
        rel = ("adapted" if x["adapted_from"] else "PR moved since" if x["head"] and x["head"] != mg["p2"]
               else "merged as-is")
        sym = "~" if x["adapted_from"] else "≠" if x["head"] and x["head"] != mg["p2"] else ""
        return (f'<a class="mark m-open" href="{e(x["url"])}" target="_blank" rel="noopener" '
                f'title="{e(x["label"])} {e(x["title"])}: {rel}">● #{e(x["label"].split("#")[1])}{sym}</a>')
    if mg["pr"] == "none":
        return '<span class="mark m-none" title="no PR yet">○ no PR</span>'
    if mg["pr"] == "stub":
        o = mg["override"]
        return (f'<a class="mark m-stub" href="{e(o["url"])}" target="_blank" rel="noopener" '
                f'title="{e(o["note"])}">#{e(o["url"].rsplit("/", 1)[1])} ↗</a>')
    return ""


def requires_block(mg):
    """Declared cross-repository requirements, both ways."""
    def item(r, arrow):
        where = f" (step {r['step']})" if r["step"] else ""
        return (f'<li><span class="rq-how rq-{r["how"]}">{r["how"]}</span> {arrow} '
                f'<span class="rq-repo">{e(r["repo"])}</span> <span class="rq-ref">{e(r["ref"])}</span>{where}'
                f'<span class="rq-why">: {e(r["why"])}</span></li>')
    rows = [item(r, "requires") for r in mg["requires"]] + [item(r, "required by") for r in mg["required_by"]]
    return f'<ul class="requires">{"".join(rows)}</ul>' if rows else ""


def commits_block(mg):
    cs = mg["commits"]
    rows = "".join(
        f'<li><code>{e(s)}</code> <span class="subj">{e(subj)}</span>'
        f' <span class="author">{e(a)}</span></li>' for s, a, subj in cs)
    label = f"{len(cs)} commit{'s' if len(cs) != 1 else ''}"
    return f'<details><summary>{label}</summary><ul class="commits">{rows}</ul></details>'


# ---- view 1: per repo -------------------------------------------------------
repo_cards = []
for name in REPO_ORDER:
    r = repos[name]
    items = []
    for mg in r["merges"]:
        items.append(f"""
      <li class="merge k-{mg['kind']} p-{mg['pr']}">
        <div class="mhead">
          <span class="ref">{e(mg['ref'])}</span>{chip(mg['kind'])}
          <span class="steplinks"><a class="steplink" href="#step-{mg['step']}" data-step="{mg['step']}">step {mg['step']}</a><a class="kcommit" href="{GH}tweag/cardano-kosmos/commit/{ksteps[mg['step'] - 1][0]}" target="_blank" rel="noopener" title="kosmos commit for this step on {KOSMOS_BRANCH}">kosmos <code>{ksteps[mg['step'] - 1][0][:7]}</code> ↗</a></span>
        </div>
        {pr_name(name, mg)}<div class="desc">{e(mg['desc'])}</div>{requires_block(mg)}
        <div class="sizerow">{size(mg)}</div>
        <div class="prrow">{pr_badge(name, mg)}<a class="cmp" href="{e(compare_url(name, mg))}" target="_blank" rel="noopener" title="exactly what this merge brings into the integration branch">changeset ↗</a></div>
        <div class="meta"><span>merge <code>{e(mg['sha'])}</code></span><span>{e(based_on(r, mg))}</span></div>
        {commits_block(mg)}
      </li>""")
    repo_cards.append(f"""
  <section class="repo" id="repo-{name}">
    <header>
      <h2>{name}</h2>
      <div class="range"><code>{r['base']}</code> <span class="arrow">→</span> <code>{r['head']}</code>
        <span class="count">{len(r['merges'])} merge{'s' if len(r['merges']) != 1 else ''}</span>
        {(lambda b: f'<div class="basepr">base: <a href="{b[1]}" target="_blank" rel="noopener">{b[0]} ↗</a></div>' if b else '')(BASE_PR.get(name))}</div>
    </header>
    <p class="hiddenn" hidden></p>
    <ol class="merges">{''.join(items)}
    </ol>
  </section>""")

# ---- view 2: lockstep -------------------------------------------------------
pin_before = {}
for name in REPO_ORDER:
    try:
        pin_before[name] = re.search(r"commit = (\w+)", git(KOSMOS, "show", f"{KOSMOS_BASE}:packages/{name}/.gitrepo")).group(1)[:9]
    except subprocess.CalledProcessError:
        pin_before[name] = None  # not vendored on kosmos main
step_rows = []
for i, (ksha, ksubj, _) in enumerate(ksteps, start=1):
    cells = []
    for name in REPO_ORDER:
        ms = [mg for mg in repos[name]["merges"] if mg["step"] == i]
        if not ms:
            cells.append('<td class="empty"><span>·</span></td>')
            continue
        new = ms[-1]["sha"]
        old = pin_before[name]
        pin = (f'<div class="pin"><code>{old[:7]}</code> → <code>{new[:7]}</code></div>' if old
               else f'<div class="pin">new → <code>{new[:7]}</code></div>')
        pin_before[name] = new
        chips = "".join(
            f'<div class="cell-merge k-{mg["kind"]}" title="{e(mg["desc"])}">'
            f'<span class="shape"></span><a class="cref" href="{e(compare_url(name, mg))}" target="_blank" rel="noopener" title="compare with the state merged into">{e(mg["ref"])}</a>{size(mg, True)}{pr_mark(name, mg)}</div>' for mg in ms)
        cells.append(f'<td class="has" data-label="{name}">{pin}{chips}</td>')
    side = KOSMOS_SIDE.get(i, [])
    side_html = ("<ul class='side'>" + "".join(f"<li>{e(s)}</li>" for s in side) + "</ul>"
                 if side else '<span class="none">—</span>')
    step_rows.append(f"""
      <tr id="step-{i}">
        <th scope="row" class="stepcol">
          <div class="stepno">{i}</div>
          <div class="steptitle">{e(ksubj.removeprefix('Peras: '))}</div>
          <div class="stepmeta"><a class="kcommit" href="{GH}tweag/cardano-kosmos/commit/{ksha}" target="_blank" rel="noopener" title="kosmos commit on {KOSMOS_BRANCH}"><code>{ksha[:10]}</code> ↗</a></div>
        </th>
        {''.join(cells)}
        <td class="kosmos" data-label="kosmos">{side_html}</td>
      </tr>""")

heads = "".join(f"<th scope='col'>{n}</th>" for n in REPO_ORDER)
n_merges = sum(len(repos[n]["merges"]) for n in REPO_ORDER)
counts = {k: sum(1 for n in REPO_ORDER for m in repos[n]["merges"] if m["kind"] == k)
          for k in KIND_LABEL}
legend = "".join(
    f'<button type="button" class="kf" data-kind="{k}" aria-pressed="true"{" disabled" if not counts[k] else ""}>'
    f'{chip(k)} <span class="n">{counts[k]}</span></button>'
    for k in KIND_LABEL) + '<button type="button" class="kf-all" hidden>show all kinds</button>'
prc = {k: sum(1 for n in REPO_ORDER for m in repos[n]["merges"] if m["pr"] == k) for k in ("open", "none", "na")}
pr_legend = (f'<span class="leg"><span class="pr pr-open">● open PR</span> <span class="n">{prc["open"]}</span></span>'
             f'<span class="leg"><span class="pr pr-none">○ no PR yet</span> <span class="n">{prc["none"]}</span></span>'
             '')


# ---- view 3: graph (data; laid out in the page) ------------------------------
def short_ref(ref):
    return (ref.replace("IntersectMBO/ouroboros-", "").replace("IntersectMBO/cardano-", "")
               .replace("tweag/ouroboros-consensus#", "tweag#").replace("IntersectMBO/", ""))


def node_id(repo, mg):
    return f"{repo}:{repos[repo]['merges'].index(mg)}"


gnodes, gstack, greq = [], [], []
for n in REPO_ORDER:
    for i, mg in enumerate(repos[n]["merges"]):
        prs = PRS.get((n, mg["ref"]), [])
        gnodes.append({"id": f"{n}:{i}", "repo": n, "i": i, "step": mg["step"], "kind": mg["kind"],
                       "ref": mg["ref"], "short": short_ref(mg["ref"]), "desc": mg["desc"],
                       "url": compare_url(n, mg), "pr": [{"label": x["label"], "url": x["url"], "title": x["title"],
                                                          "draft": x["draft"]} for x in prs]})
        for a in mg["stacked_on"]:
            gstack.append([node_id(n, a), f"{n}:{i}"])
for (drepo, dref), (trepo, tref), how, why in REQUIRES:
    src = f"{trepo}:base" if tref == "@base" else node_id(trepo, merge_by_ref[(trepo, tref)])
    greq.append([src, node_id(drepo, merge_by_ref[(drepo, dref)]), how, why])
gbases = {n: {"step": next(i for i, (_, _, pins) in enumerate(ksteps, 1) if n in pins),
              "label": BASE_PR[n][0], "url": BASE_PR[n][1]} for n in REPO_ORDER}
gdata = json.dumps({"repos": REPO_ORDER, "kinds": KIND_LABEL,
                    "steps": [{"n": i, "title": subj, "url": f"{GH}tweag/cardano-kosmos/commit/{c}"}
                              for i, (c, subj, _) in enumerate(ksteps, 1)],
                    "bases": gbases, "nodes": gnodes, "stack": gstack, "req": greq}).replace("</", "<\\/")

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Peras Integration Map</title>
<style>
:root {{
  --bg: #f7f6f3; --surface: #ffffff; --surface-2: #f0eee9; --border: #e2dfd8;
  --text: #1d1c1a; --muted: #6b6860; --accent: #2f5d8a;
  --k-up: #2f5d8a; --k-up-bg: #e3edf7; --k-up-mark: #3b6ea8;
  --k-compat: #8f5a0a; --k-compat-bg: #fbf0dc; --k-compat-mark: #c98a1b;
  --k-local: #a3214f; --k-local-bg: #fbe6ee; --k-local-mark: #c43a6a;
  --k-stub: #5b3f99; --k-stub-bg: #efeaf8; --k-stub-mark: #7a5cc4;
  --pr: #1d1c1a; --pr-text: #ffffff; --ins: #1a7f37; --del: #d1242f;
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --bg: #161615; --surface: #1f1f1d; --surface-2: #262623; --border: #34332f;
    --text: #ecebe7; --muted: #9d998f; --accent: #8bb4e0;
    --k-up: #9cc3ea; --k-up-bg: #1b2a3b; --k-up-mark: #8bb4e0;
    --k-compat: #ecbd6a; --k-compat-bg: #352a14; --k-compat-mark: #e4b260;
    --k-local: #f5a3c0; --k-local-bg: #3a1a27; --k-local-mark: #f28cb1;
    --k-stub: #c4b0f0; --k-stub-bg: #251f38; --k-stub-mark: #ad94ea;
    --pr: #ecebe7; --pr-text: #161615; --ins: #3fb950; --del: #f85149;
  }}
}}
:root[data-theme="dark"] {{
  --bg: #161615; --surface: #1f1f1d; --surface-2: #262623; --border: #34332f;
  --text: #ecebe7; --muted: #9d998f; --accent: #8bb4e0;
  --k-up: #9cc3ea; --k-up-bg: #1b2a3b; --k-up-mark: #8bb4e0;
  --k-compat: #ecbd6a; --k-compat-bg: #352a14; --k-compat-mark: #e4b260;
  --k-local: #f5a3c0; --k-local-bg: #3a1a27; --k-local-mark: #f28cb1;
  --k-stub: #c4b0f0; --k-stub-bg: #251f38; --k-stub-mark: #ad94ea;
  --pr: #ecebe7; --pr-text: #161615; --ins: #3fb950; --del: #f85149;
}}
:root[data-palette="cb"] {{
  --k-up: #005a8c; --k-up-bg: #e1eef8; --k-up-mark: #0072b2;
  --k-compat: #8a5000; --k-compat-bg: #fdf1dc; --k-compat-mark: #e69f00;
  --k-local: #4a4741; --k-local-bg: #ecebe7; --k-local-mark: #6b6860;
  --k-stub: #8a3b6e; --k-stub-bg: #f7e8f1; --k-stub-mark: #cc79a7;
  --ins: #0969da; --del: #bc4c00;
}}
@media (prefers-color-scheme: dark) {{
  :root[data-palette="cb"]:not([data-theme="light"]) {{
    --k-up: #7cc4ef; --k-up-bg: #13283a; --k-up-mark: #56b4e9;
    --k-compat: #f0b54a; --k-compat-bg: #33270f; --k-compat-mark: #e69f00;
    --k-local: #d4d0c7; --k-local-bg: #2a2a27; --k-local-mark: #a8a49a;
    --k-stub: #e6a6cc; --k-stub-bg: #34202d; --k-stub-mark: #cc79a7;
    --ins: #58a6ff; --del: #db6d28;
  }}
}}
:root[data-palette="cb"][data-theme="dark"] {{
  --k-up: #7cc4ef; --k-up-bg: #13283a; --k-up-mark: #56b4e9;
  --k-compat: #f0b54a; --k-compat-bg: #33270f; --k-compat-mark: #e69f00;
  --k-local: #d4d0c7; --k-local-bg: #2a2a27; --k-local-mark: #a8a49a;
  --k-stub: #e6a6cc; --k-stub-bg: #34202d; --k-stub-mark: #cc79a7;
  --ins: #58a6ff; --del: #db6d28;
}}
:root {{
  --pat-up: repeating-linear-gradient(135deg, rgb(128 128 128 / .18) 0 2px, transparent 2px 7px);
  --pat-compat: repeating-linear-gradient(45deg, rgb(128 128 128 / .17) 0 1.5px, transparent 1.5px 6px),
    repeating-linear-gradient(135deg, rgb(128 128 128 / .17) 0 1.5px, transparent 1.5px 6px);
  --pat-local: repeating-linear-gradient(90deg, rgb(128 128 128 / .2) 0 2px, transparent 2px 6px);
  --pat-stub: radial-gradient(circle, rgb(128 128 128 / .34) 1px, transparent 1.6px) 0 0 / 6px 6px;
}}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }}
code {{ font: 12.5px ui-monospace, "SF Mono", Menlo, Consolas, monospace; color: var(--muted); }}
.wrap {{ max-width: none; margin: 0; padding: 28px 24px 64px; }}
h1 {{ font-size: 24px; margin: 0 0 16px; letter-spacing: -0.01em; }}
.sub {{ color: var(--muted); margin: 0 0 20px; max-width: 75ch; }}
.bar {{ display: flex; flex-wrap: wrap; gap: 12px 20px; align-items: center; margin-bottom: 24px; }}
.tabs {{ display: inline-flex; background: var(--surface-2); border: 1px solid var(--border);
  border-radius: 10px; padding: 3px; }}
.tabs button {{ border: 0; background: transparent; color: var(--muted); font: inherit; font-weight: 550;
  padding: 6px 14px; border-radius: 7px; cursor: pointer; }}
.tabs button[aria-selected="true"], .tabs button[aria-pressed="true"] {{ background: var(--surface); color: var(--text);
  box-shadow: 0 1px 2px rgb(0 0 0 / .08); }}
.legend {{ display: flex; flex-wrap: wrap; gap: 8px 14px; }}
.filter {{ gap: 6px 8px; align-items: center; }}
.kf {{ font: inherit; display: inline-flex; align-items: center; gap: 6px; padding: 3px 8px 3px 4px; border-radius: 999px;
  border: 1px solid var(--border); background: var(--surface); color: var(--text); cursor: pointer; }}
.kf::before {{ content: "✓"; font-size: 12px; width: 12px; text-align: center; color: var(--text); }}
.kf[aria-pressed="false"] {{ background: transparent; border-style: dashed; }}
.kf[aria-pressed="false"]::before {{ content: ""; }}
.kf[aria-pressed="false"] .chip {{ opacity: .45; text-decoration: line-through; }}
.kf:disabled {{ cursor: default; opacity: .5; }}
.kf:focus-visible, .kf-all:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
.kf-all {{ font: inherit; font-size: 13px; border: 0; background: none; color: var(--accent); cursor: pointer; text-decoration: underline; }}
.requires {{ list-style: none; margin: 6px 0 0; padding: 0; font-size: 12.5px; }}
.requires li {{ padding: 1px 0; }}
.rq-how {{ font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: .03em; padding: 0 5px;
  border-radius: 4px; border: 1px solid var(--border); }}
.rq-runtime {{ border-style: dashed; }}
.rq-repo {{ font-weight: 600; }}
.rq-why {{ color: var(--muted); }}
.gnote {{ margin: 0 0 12px; }}
.gwrap {{ display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 16px; align-items: start; }}
@media (max-width: 1100px) {{ .gwrap {{ grid-template-columns: 1fr; }} }}
.gscroll {{ overflow: auto; border: 1px solid var(--border); border-radius: 12px; background: var(--surface); max-height: 85vh; }}
.gpanel {{ position: sticky; top: 12px; border: 1px solid var(--border); border-radius: 12px; background: var(--surface);
  padding: 14px; font-size: 13.5px; }}
.gpanel h3 {{ font-size: 15px; margin: 6px 0 4px; word-break: break-word; }}
.gpanel ul {{ margin: 6px 0; padding-left: 18px; }}
.gempty {{ color: var(--muted); margin: 0; }}
.gclose {{ float: right; font: inherit; font-size: 18px; line-height: 1; width: 28px; height: 28px; margin: -6px -6px 0 8px;
  border: 1px solid var(--border); border-radius: 6px; background: var(--surface-2); color: var(--text); cursor: pointer; }}
.gclose:hover {{ background: var(--surface); }}
.gclose:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
#graph text {{ fill: var(--text); font-size: 11.5px; }}
#graph .lanehead {{ font-weight: 700; font-size: 11.5px; }}
#graph .rowhit {{ fill: transparent; cursor: pointer; }}
#graph .rowhit:hover {{ fill: var(--surface-2); }}
#graph .rowhit.sel {{ fill: var(--k-up-bg); }}
#graph .lbl {{ cursor: pointer; }}
#graph .lrepo {{ fill: var(--muted); font-size: 11px; }}
#graph .lref {{ font-weight: 600; }}
#graph .ldesc {{ fill: var(--muted); }}
#graph .lon {{ font-size: 11px; }}
#graph .band {{ fill: var(--surface-2); }}
#graph .stepno {{ font-weight: 700; font-size: 13px; }}
#graph .steplabel {{ fill: var(--muted); }}
#graph .lane {{ stroke: var(--muted); stroke-width: 2; fill: none; opacity: .55; }}
#graph .lane.bridged {{ stroke-dasharray: 3 4; }}
#graph .badge {{ fill: var(--muted); font-size: 10.5px; }}
#graph .stack {{ stroke: var(--muted); stroke-width: 1.5; fill: none; }}
#graph .stack.bridged {{ stroke-dasharray: 3 3; }}
#graph .req {{ stroke: var(--accent); stroke-width: 1.6; fill: none; opacity: .8; }}
#graph .req.runtime {{ stroke-dasharray: 6 4; }}
#graph .node {{ cursor: pointer; }}
#graph .node .mark {{ fill: var(--km); stroke: var(--surface); stroke-width: 1.5; }}
#graph .node.k-stub .mark {{ fill: var(--surface); stroke: var(--km); stroke-width: 2.5; }}
#graph .node:focus {{ outline: none; }}
#graph .node:focus-visible .ring, #graph .node.sel .ring {{ stroke: var(--text); stroke-width: 2; fill: none; }}
#graph .base .mark {{ fill: var(--surface); stroke: var(--muted); stroke-width: 1.5; }}
#graph.focus .node:not(.hl), #graph.focus .lbl:not(.hl) {{ opacity: .3; }}
#graph.focus .req:not(.hl), #graph.focus .stack:not(.hl) {{ opacity: .08; }}
#graph .req.hl {{ stroke-width: 2.4; opacity: 1; }}
.hiddenn {{ font-size: 12.5px; color: var(--muted); margin: -4px 0 6px; }}
.isfiltered {{ display: none !important; }}
tr.allfiltered td, tr.allfiltered th {{ opacity: .35; }}
.leg .n {{ color: var(--muted); font-size: 13px; }}
.stats {{ color: var(--muted); font-size: 13px; }}
.chip {{ display: inline-block; font-size: 11.5px; font-weight: 600; padding: 1px 8px; border-radius: 999px;
  white-space: nowrap; }}
.chip {{ display: inline-flex; align-items: center; gap: 5px; }}
.shape {{ display: inline-block; width: 8px; height: 8px; flex: none; }}
.view[hidden] {{ display: none; }}
.prrow {{ display: flex; flex-wrap: wrap; gap: 4px 8px; align-items: center; margin-top: 4px; font-size: 12.5px; }}
.pr {{ font-size: 11px; font-weight: 700; padding: 1px 7px; border-radius: 4px; white-space: nowrap; }}
.pr-open {{ color: var(--pr-text); background: var(--pr); }}
.pr-none {{ color: var(--text); border: 1.5px dashed var(--muted); padding: 0 6px; }}
.prlink {{ color: var(--accent); text-decoration: none; font-weight: 600; white-space: nowrap; }}
.prlink:hover {{ text-decoration: underline; }}
.sizerow {{ margin-top: 3px; }}
.size {{ display: inline-flex; align-items: center; gap: 5px; font: 12px ui-monospace, "SF Mono", Menlo, Consolas, monospace; white-space: nowrap; }}
.sbar {{ display: inline-block; height: 7px; border-radius: 4px; background: var(--del); overflow: hidden; flex: none; }}
.sins {{ display: block; height: 100%; background: var(--ins); }}
.sins-t {{ color: var(--ins); }} .sdel-t {{ color: var(--del); }} .sfiles {{ color: var(--muted); }}
.cell-merge .size {{ font-size: 11px; }}
.cmp {{ margin-left: auto; color: var(--muted); text-decoration: none; font-size: 12px; white-space: nowrap; }}
.cmp:hover {{ color: var(--accent); text-decoration: underline; }}
a.cref {{ color: inherit; text-decoration: none; }} a.cref:hover {{ text-decoration: underline; }}
.draft {{ font-size: 10.5px; font-weight: 600; color: var(--muted); border: 1px solid var(--border);
  border-radius: 3px; padding: 0 4px; margin-left: 4px; }}
.incl {{ color: var(--muted); }}
.rel {{ font-size: 11.5px; color: var(--muted); white-space: nowrap; }}
.rel code {{ font-size: 11.5px; }}
a.rel-moved {{ color: var(--k-compat); text-decoration: none; font-weight: 600; }} a.rel-moved:hover {{ text-decoration: underline; }}
.rel-adapted {{ font-style: italic; }}
.basepr {{ margin-top: 2px; }} .basepr a {{ color: var(--accent); text-decoration: none; }}
.mark {{ margin-left: auto; font-size: 11px; font-weight: 700; white-space: nowrap; padding: 0 5px; border-radius: 4px; }}
.m-open {{ color: var(--pr-text); background: var(--pr); text-decoration: none; }}
.m-none {{ color: var(--text); border: 1.5px dashed var(--muted); }}
.m-stub {{ color: var(--k-stub); border: 1.5px solid var(--k-stub-mark); text-decoration: none; }}
.stubnote {{ color: var(--k-stub); font-size: 12px; font-weight: 600; text-decoration: none; }}
.stubnote:hover, .m-stub:hover {{ text-decoration: underline; }}

/* per repo */
.repos {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(440px, 1fr)); gap: 16px; }}
.repo {{ background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 16px 16px 8px; }}
.repo header {{ margin-bottom: 10px; }}
.repo h2 {{ font-size: 16px; margin: 0 0 2px; }}
.range {{ font-size: 13px; color: var(--muted); }}
.range .count {{ margin-left: 8px; }}
.arrow {{ color: var(--muted); }}
.merges {{ list-style: none; margin: 0; padding: 0; counter-reset: m; }}
.merge {{ position: relative; padding: 10px 0 10px 18px; border-top: 1px solid var(--border); }}
.merge .mhead > .shape {{ display: none; }}
.mhead {{ display: flex; flex-wrap: wrap; align-items: center; gap: 6px 8px; }}
.ref {{ font-weight: 600; font-size: 14px; word-break: break-word; }}
.steplinks {{ margin-left: auto; display: inline-flex; gap: 10px; align-items: baseline; }}
.steplink {{ font-size: 12px; color: var(--accent); text-decoration: none; white-space: nowrap; }}
.steplink:hover {{ text-decoration: underline; }}
.desc {{ font-size: 13.5px; margin-top: 2px; }}
.prname {{ font-size: 14px; font-weight: 600; margin-top: 3px; }}
.incltitle {{ font-size: 12px; color: var(--muted); }}
.meta {{ display: flex; flex-wrap: wrap; gap: 4px 14px; font-size: 12.5px; color: var(--muted); margin-top: 2px; }}
details {{ margin-top: 4px; font-size: 13px; }}
summary {{ cursor: pointer; color: var(--muted); }}
.commits {{ list-style: none; padding: 4px 0 0; margin: 0; }}
.commits li {{ padding: 2px 0; }}
.commits .author {{ color: var(--muted); font-size: 12px; }}

/* lockstep */
.tablewrap {{ overflow-x: auto; border: 1px solid var(--border); border-radius: 12px; background: var(--surface); }}
table {{ border-collapse: collapse; width: 100%; min-width: 1600px; }}
thead th {{ position: sticky; top: 0; background: var(--surface-2); font-size: 12.5px; font-weight: 600;
  text-align: left; padding: 10px; border-bottom: 1px solid var(--border); color: var(--muted); white-space: nowrap; }}
td, tbody th {{ vertical-align: top; padding: 10px; border-bottom: 1px solid var(--border); }}
tbody tr:last-child td, tbody tr:last-child th {{ border-bottom: 0; }}
tbody tr:target, tbody tr.flash {{ background: var(--surface-2); }}
.stepcol {{ text-align: left; min-width: 200px; font-weight: normal; }}
.stepno {{ font-size: 20px; font-weight: 700; line-height: 1; }}
.steptitle {{ font-weight: 600; margin: 4px 0; }}
.stepmeta {{ display: flex; gap: 8px; align-items: center; }}
.kcommit {{ color: var(--accent); text-decoration: none; font-size: 12.5px; }} .kcommit code {{ color: inherit; }}
.kcommit:hover {{ text-decoration: underline; }}
td.empty {{ text-align: center; color: var(--border); }}
.pin {{ font-size: 12px; color: var(--muted); margin-bottom: 4px; white-space: nowrap; }}
.cell-merge {{ display: flex; flex-wrap: wrap; gap: 4px 6px; align-items: baseline; font-size: 13px; padding: 3px 7px; border-radius: 6px;
  margin-top: 3px; }}
.cell-merge .shape {{ transform: translateY(-1px); }}
/* Kinds: each one differs in colour, marker shape, background pattern and border, so no single cue is needed. */
.k-up {{ --kc: var(--k-up); --kbg: var(--k-up-bg); --km: var(--k-up-mark); --kpat: var(--pat-up); }}
.k-compat {{ --kc: var(--k-compat); --kbg: var(--k-compat-bg); --km: var(--k-compat-mark); --kpat: var(--pat-compat); }}
.k-local {{ --kc: var(--k-local); --kbg: var(--k-local-bg); --km: var(--k-local-mark); --kpat: var(--pat-local); }}
.k-stub {{ --kc: var(--k-stub); --kbg: var(--k-stub-bg); --km: var(--k-stub-mark); --kpat: var(--pat-stub); }}
.chip, .cell-merge, .merge {{ background: var(--kpat), var(--kbg); }}
.chip {{ color: var(--kc); }}
.shape {{ background: var(--km); }}
.k-up .shape {{ border-radius: 50%; }}
.k-compat .shape {{ transform: rotate(45deg) scale(.82); }}
.k-local .shape {{ clip-path: polygon(50% 0, 100% 100%, 0 100%); width: 10px; height: 9px; }}
.k-stub .shape {{ background: transparent; border: 2px solid var(--km); }}
.chip.k-up, .cell-merge.k-up {{ box-shadow: inset 3px 0 0 var(--km); }}
.chip.k-compat, .cell-merge.k-compat {{ outline: 1.5px dashed var(--km); outline-offset: -1.5px; }}
.chip.k-local, .cell-merge.k-local {{ outline: 1.5px dotted var(--km); outline-offset: -1.5px; }}
.chip.k-stub, .cell-merge.k-stub {{ outline: 3px double var(--km); outline-offset: -3px; }}
.merge {{ margin: 0 -16px; padding-right: 16px; padding-left: 34px; }}
.merge.k-up {{ box-shadow: inset 4px 0 0 var(--km); }}
.merge.k-compat {{ outline: 1.5px dashed var(--km); outline-offset: -3px; }}
.merge.k-local {{ outline: 1.5px dotted var(--km); outline-offset: -3px; }}
.merge.k-stub {{ outline: 3px double var(--km); outline-offset: -4px; }}
.cref {{ white-space: nowrap; }}
td.has {{ min-width: 240px; }}
.kosmos {{ font-size: 13px; min-width: 280px; }}
.side {{ margin: 0; padding-left: 16px; }}
.none {{ color: var(--border); }}
.note {{ color: var(--muted); font-size: 13px; margin-top: 12px; max-width: 90ch; }}
@media (max-width: 640px) {{
  .repos {{ grid-template-columns: 1fr; }}
}}
</style>
</head>
<body>
<div class="wrap">
  <h1>Peras Integration Map</h1>
  <div class="bar">
    <div class="tabs" role="tablist">
      <button role="tab" aria-selected="true" data-view="graph">Graph</button>
      <button role="tab" aria-selected="false" data-view="repos">By repository</button>
      <button role="tab" aria-selected="false" data-view="steps">Lockstep</button>
    </div>
    <div class="tabs palette" role="group" aria-label="palette">
      <button aria-pressed="true" data-palette="std">Standard colors</button>
      <button aria-pressed="false" data-palette="cb">Colorblind-safe</button>
    </div>
    <div class="legend filter" role="group" aria-label="Show changesets of these kinds">{legend}</div>
    <div class="legend">{pr_legend}</div>
    <div class="stats" aria-live="polite"><span id="shown">{n_merges} merges</span> · {len(ksteps)} steps</div>
  </div>

  <div class="view" id="view-repos">
    <div class="repos">{''.join(repo_cards)}
    </div>
  </div>

  <div class="view" id="view-graph" hidden>
    <p class="note gnote">One column per repository (left), one row per merge (right), top to bottom in merge order.
      Within a repository the order is its integration branch's; across repositories only the steps order things:
      merges of one step land together. Within a step, rows are in ASAP order: each merge as early as what precedes it
      allows (the previous merge of its repository, and what it requires). Blue arrows point from a merge to what it
      requires, so always upwards (dashed: runtime only). "on #N": the branch was built on #N's branch.
      Click a row for details.</p>
    <div class="gwrap">
      <div class="gscroll"><svg id="graph" role="img" aria-label="Merge graph"></svg></div>
      <aside class="gpanel" id="gpanel" aria-live="polite"><p class="gempty">Select a merge to see its details.</p></aside>
    </div>
  </div>
  <div class="view" id="view-steps" hidden>
    <div class="tablewrap">
      <table>
        <thead><tr><th scope="col">step</th>{heads}<th scope="col">kosmos</th></tr></thead>
        <tbody>{''.join(step_rows)}
        </tbody>
      </table>
    </div>
  </div>
</div>
<script type="application/json" id="graph-data">{gdata}</script>
<script>
const tabs = document.querySelectorAll('.tabs[role="tablist"] button');
function show(view) {{
  tabs.forEach(b => b.setAttribute('aria-selected', String(b.dataset.view === view)));
  document.querySelectorAll('.view').forEach(v => v.hidden = v.id !== 'view-' + view);
  try {{ localStorage.setItem('peras-map-view', view); }} catch (_) {{}}
}}
tabs.forEach(b => b.addEventListener('click', () => show(b.dataset.view)));
document.querySelectorAll('.steplink').forEach(a => a.addEventListener('click', ev => {{
  ev.preventDefault(); show('steps');
  const row = document.getElementById('step-' + a.dataset.step);
  row.scrollIntoView({{block: 'center', behavior: 'smooth'}});
  row.classList.add('flash'); setTimeout(() => row.classList.remove('flash'), 1600);
}}));
const pals = document.querySelectorAll('.palette button');
function palette(p) {{
  document.documentElement.dataset.palette = p;
  pals.forEach(b => b.setAttribute('aria-pressed', String(b.dataset.palette === p)));
  try {{ localStorage.setItem('peras-map-palette', p); }} catch (_) {{}}
}}
pals.forEach(b => b.addEventListener('click', () => palette(b.dataset.palette)));
let pal = 'std';
try {{ pal = localStorage.getItem('peras-map-palette') || 'std'; }} catch (_) {{}}
palette(pal);

// Graph view: lanes per repo, rows by step; laid out from the data on every filter change.
const G = JSON.parse(document.getElementById('graph-data').textContent);
const svgNS = 'http://www.w3.org/2000/svg';
const LEFT = 250, LANEW = 210, TOP = 40, ROWH = 30, PAD = 8, EMPTYH = 18;
let gSel = null;
function el(tag, attrs, parent, text) {{
  const x = document.createElementNS(svgNS, tag);
  for (const k in attrs) x.setAttribute(k, attrs[k]);
  if (text !== undefined) x.textContent = text;
  if (parent) parent.appendChild(x);
  return x;
}}
function markPath(kind) {{
  switch (kind) {{
    case 'compat': return 'M0,-7 L7,0 L0,7 L-7,0 Z';
    case 'local': return 'M0,-7 L7,6 L-7,6 Z';
    case 'stub': return 'M-5.5,-5.5 H5.5 V5.5 H-5.5 Z';
    default: return 'M-6.5,0 A6.5,6.5 0 1,0 6.5,0 A6.5,6.5 0 1,0 -6.5,0';
  }}
}}
function trunc(t, n) {{ return t.length > n ? t.slice(0, n - 1) + '…' : t; }}
function renderGraph(hidden) {{
  // git-graph layout: one row per merge (and per repo base), grouped by step; lanes and edges on the left,
  // labels in a single column on the right, so edges never cross text.
  const svg = document.getElementById('graph');
  svg.textContent = '';
  const vis = n => !hidden.has(n.kind);
  const byId = Object.fromEntries(G.nodes.map(n => [n.id, n]));
  const LANEX = 18, GAP = 30, ROW = 24, STEPH = 30, HEAD = 92;
  const laneX = r => LANEX + G.repos.indexOf(r) * GAP;
  const TEXTX = laneX(G.repos[G.repos.length - 1]) + 34;
  const rows = [], pos = {{}}, DEPGAP = 10;
  // merges that require something get a little room above their row, where their arrow turns
  const incoming = new Set(G.req.filter(([a]) => !byId[a] || vis(byId[a])).map(r => r[1]));
  let y = HEAD;
  for (const st of G.steps) {{
    const items = [];
    G.repos.forEach(r => {{
      if (G.bases[r].step === st.n) items.push({{id: r + ':base', repo: r}});
      G.nodes.filter(n => n.repo === r && n.step === st.n && vis(n)).forEach(n => items.push({{id: n.id, repo: r, n}}));
    }});
    // ASAP order within the step: a merge's level is 1 + the highest level of what precedes it in this step (the
    // previous visible merge of its repo, and what it requires); rows go by level, then repository.
    const inStep = new Set(items.map(it => it.id)), level = {{}};
    const preds = it => {{
      const ps = G.req.filter(r => r[1] === it.id && inStep.has(r[0])).map(r => r[0]);
      const same = items.filter(o => o.repo === it.repo);
      const k = same.indexOf(it);
      if (k > 0) ps.push(same[k - 1].id);
      return ps;
    }};
    const lv = it => level[it.id] ?? (level[it.id] = Math.max(-1, ...preds(it).map(p => lv(items.find(o => o.id === p)))) + 1);
    items.forEach(lv);
    items.sort((a, b) => level[a.id] - level[b.id] || G.repos.indexOf(a.repo) - G.repos.indexOf(b.repo) ||
                         (a.n ? a.n.i : -1) - (b.n ? b.n.i : -1));
    rows.push({{step: st, y, h: STEPH}});
    y += STEPH;
    items.forEach(it => {{
      if (incoming.has(it.id)) y += DEPGAP;
      pos[it.id] = {{x: laneX(it.repo), y: y + ROW / 2}}; rows.push({{item: it, y}}); y += ROW;
    }});
  }}
  const W = TEXTX + 760, H = y + 12;
  svg.setAttribute('width', W); svg.setAttribute('height', H); svg.setAttribute('viewBox', `0 0 ${{W}} ${{H}}`);
  const defs = el('defs', {{}}, svg);
  const mk = el('marker', {{id: 'arrow', viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 6, markerHeight: 6,
                           orient: 'auto-start-reverse'}}, defs);
  el('path', {{d: 'M0,0 L10,5 L0,10 z', fill: 'var(--accent)'}}, mk);
  const gBg = el('g', {{}}, svg), gEdges = el('g', {{}}, svg), gNodes = el('g', {{}}, svg), gText = el('g', {{}}, svg);
  // lane headers, rotated
  G.repos.forEach(r => {{
    const t = el('text', {{class: 'lanehead', x: 0, y: 0, transform: `translate(${{laneX(r) + 4}},${{HEAD - 8}}) rotate(-50)`}}, gBg,
                 r.replace('ouroboros-', '').replace('cardano-', ''));
    el('title', {{}}, t, r);
  }});
  // step header rows and item rows
  rows.forEach(rw => {{
    if (rw.step) {{
      el('rect', {{class: 'band', x: 0, y: rw.y, width: W, height: rw.h}}, gBg);
      const a = el('a', {{href: rw.step.url, target: '_blank', rel: 'noopener'}}, gText);
      el('text', {{class: 'stepno', x: TEXTX, y: rw.y + 19}}, a, `Step ${{rw.step.n}}`);
      el('text', {{class: 'steplabel', x: TEXTX + 62, y: rw.y + 19}}, a, trunc(rw.step.title, 110));
    }} else {{
      const it = rw.item;
      el('rect', {{class: 'rowhit', x: 0, y: rw.y, width: W, height: ROW, 'data-id': it.id}}, gBg);
      const t = el('text', {{class: 'lbl', x: TEXTX, y: rw.y + 16, 'data-id': it.id}}, gText);
      el('tspan', {{class: 'lrepo'}}, t, it.repo.replace('ouroboros-', '').replace('cardano-', '') + '  ');
      if (it.n) {{
        el('tspan', {{class: 'lref'}}, t, it.n.short);
        const on = G.stack.filter(x => x[1] === it.id).map(x => byId[x[0]].short);
        if (on.length) el('tspan', {{class: 'lon'}}, t, ' · on ' + on.join(', '));
        el('tspan', {{class: 'ldesc'}}, t, '  ' + trunc(it.n.desc, on.length ? 80 : 92));
      }} else el('tspan', {{class: 'lref'}}, t, 'base: ' + G.bases[it.repo].label);
    }}
  }});
  // lanes: from each repo's base to its last visible merge, bridging hidden merges
  for (const r of G.repos) {{
    const seq = [r + ':base', ...G.nodes.filter(n => n.repo === r).map(n => n.id)];
    let prev = null, skipped = 0;
    for (const id of seq) {{
      const n = byId[id];
      if (n && !vis(n)) {{ skipped++; continue; }}
      if (prev) {{
        const a = pos[prev], b = pos[id];
        el('line', {{class: 'lane' + (skipped ? ' bridged' : ''), x1: a.x, y1: a.y, x2: b.x, y2: b.y}}, gEdges);
        if (skipped) el('text', {{class: 'badge', x: a.x + 5, y: (a.y + b.y) / 2 + 4}}, gEdges, '+' + skipped);
      }}
      prev = id; skipped = 0;
    }}
  }}
  // declared requirements, dependency -> dependent: down the dependency's lane, then across into the dependent
  G.req.forEach(([a, b, how, why]) => {{
    const na = byId[a], nb = byId[b];
    if ((na && !vis(na)) || !vis(nb)) return;
    // "b requires a": from the dependent b, across its row to a's column, then up into a
    const p = pos[a], q = pos[b], dir = Math.sign(p.x - q.x) || 1;
    const d = `M${{q.x + dir * 8}},${{q.y}} L${{p.x - dir * 10}},${{q.y}} Q${{p.x}},${{q.y}} ${{p.x}},${{q.y - 10}} L${{p.x}},${{p.y + 9}}`;
    const path = el('path', {{class: 'req ' + how, d, 'marker-end': 'url(#arrow)', 'data-a': a, 'data-b': b}}, gEdges);
    el('title', {{}}, path, `${{how}}: ${{why}}`);
  }});
  // nodes
  const addNode = (id, kind, title, cls) => {{
    const p = pos[id];
    const g = el('g', {{class: `node ${{cls}} k-${{kind}}`, transform: `translate(${{p.x}},${{p.y}})`, tabindex: 0,
                       role: 'button', 'aria-label': title, 'data-id': id}}, gNodes);
    el('circle', {{class: 'ring', r: 10, fill: 'none'}}, g);
    el('path', {{class: 'mark', d: markPath(kind)}}, g);
    el('title', {{}}, g, title);
    g.addEventListener('keydown', ev => {{ if (ev.key === 'Enter' || ev.key === ' ') {{ ev.preventDefault(); gSelect(id); }} }});
  }};
  G.repos.forEach(r => addNode(r + ':base', 'base', `${{r}} base: ${{G.bases[r].label}}`, 'base'));
  G.nodes.filter(vis).forEach(n => addNode(n.id, n.kind, `${{n.repo}}: ${{n.ref}} (step ${{n.step}})`, ''));
  svg.onclick = ev => {{
    const t = ev.target.closest('[data-id]');
    gSelect(t ? t.dataset.id : null);
  }};
  if (gSel && (gSel.endsWith(':base') || vis(byId[gSel]))) gSelect(gSel); else gSelect(null);
}}
document.getElementById('gpanel').addEventListener('click', ev => {{
  if (ev.target.closest('.gclose')) {{
    const id = gSel; gSelect(null);
    document.querySelector(`#graph .node[data-id="${{id}}"]`)?.focus();
  }}
}});
document.addEventListener('keydown', ev => {{
  if (ev.key === 'Escape' && gSel && !document.getElementById('view-graph').hidden) gSelect(null);
}});
function esc(t) {{ const d = document.createElement('div'); d.textContent = t; return d.innerHTML; }}
function gSelect(id) {{
  gSel = id;
  const svg = document.getElementById('graph'), panel = document.getElementById('gpanel');
  svg.classList.toggle('focus', !!id);
  svg.querySelectorAll('.hl, .sel').forEach(x => x.classList.remove('hl', 'sel'));
  if (!id) {{ panel.innerHTML = '<p class="gempty">Select a merge to see its details.</p>'; return; }}
  const near = new Set([id]);
  svg.querySelectorAll('.req, .stack').forEach(e => {{
    if (e.dataset.a === id || e.dataset.b === id) {{ e.classList.add('hl'); near.add(e.dataset.a); near.add(e.dataset.b); }}
  }});
  svg.querySelectorAll('.node, .lbl, .rowhit').forEach(x => {{ if (near.has(x.dataset.id)) x.classList.add('hl'); }});
  svg.querySelector(`.rowhit[data-id="${{id}}"]`)?.classList.add('sel');
  svg.querySelector(`.node[data-id="${{id}}"]`)?.classList.add('sel');
  if (id.endsWith(':base')) {{
    const r = id.slice(0, -5), b = G.bases[r];
    panel.innerHTML = `<button type="button" class="gclose" aria-label="Close details" title="Close (Esc)">×</button><div>${{esc(r)}}</div><h3>base: ${{esc(b.label)}}</h3><p>First pinned at step ${{b.step}}.</p>` +
      `<p><a href="${{b.url}}" target="_blank" rel="noopener">base commit ↗</a></p>`;
    return;
  }}
  const n = G.nodes.find(x => x.id === id), name = x => {{ const m = G.nodes.find(y => y.id === x);
    return m ? `${{esc(m.repo)}} <b>${{esc(m.short)}}</b> (step ${{m.step}})` : `${{esc(x.slice(0, -5))}} base`; }};
  const req = G.req.filter(r => r[1] === id).map(r => `<li>${{r[2]}}: ${{name(r[0])}}: ${{esc(r[3])}}</li>`);
  const by = G.req.filter(r => r[0] === id).map(r => `<li>${{r[2]}}: ${{name(r[1])}}: ${{esc(r[3])}}</li>`);
  const on = G.stack.filter(s => s[1] === id).map(s => `<li>${{name(s[0])}}</li>`);
  panel.innerHTML = `<button type="button" class="gclose" aria-label="Close details" title="Close (Esc)">×</button><div>${{esc(n.repo)}} · step ${{n.step}} · ${{esc(G.kinds[n.kind])}}</div><h3>${{esc(n.ref)}}</h3>` +
    `<p>${{esc(n.desc)}}</p>` +
    n.pr.map(p => `<p><a href="${{p.url}}" target="_blank" rel="noopener">${{esc(p.label)}} ↗</a> ${{esc(p.title)}}${{p.draft ? ' (draft)' : ''}}</p>`).join('') +
    `<p><a href="${{n.url}}" target="_blank" rel="noopener">changeset ↗</a></p>` +
    (on.length ? `<div>Built on</div><ul>${{on.join('')}}</ul>` : '') +
    (req.length ? `<div>Requires</div><ul>${{req.join('')}}</ul>` : '') +
    (by.length ? `<div>Required by</div><ul>${{by.join('')}}</ul>` : '');
}}
// Kind filter: the legend's toggle buttons; state in the URL hash (shareable) and localStorage.
const kfs = [...document.querySelectorAll('.kf')];
const kfAll = document.querySelector('.kf-all');
const kindOf = el => [...el.classList].find(c => c.startsWith('k-')).slice(2);
function applyFilter(hidden, persist) {{
  kfs.forEach(b => b.setAttribute('aria-pressed', String(!hidden.has(b.dataset.kind))));
  kfAll.hidden = hidden.size === 0;
  let shown = 0, total = 0;
  document.querySelectorAll('li.merge').forEach(li => {{
    const off = hidden.has(kindOf(li)); li.classList.toggle('isfiltered', off); total++; if (!off) shown++;
  }});
  document.querySelectorAll('section.repo').forEach(sec => {{
    const n = sec.querySelectorAll('li.merge.isfiltered').length, p = sec.querySelector('.hiddenn');
    p.hidden = n === 0; p.textContent = n + ' changeset' + (n === 1 ? '' : 's') + ' hidden by the kind filter';
  }});
  document.querySelectorAll('.cell-merge').forEach(c => c.classList.toggle('isfiltered', hidden.has(kindOf(c))));
  document.querySelectorAll('#view-steps tbody tr').forEach(tr => {{
    const all = tr.querySelectorAll('.cell-merge'), off = tr.querySelectorAll('.cell-merge.isfiltered');
    tr.classList.toggle('allfiltered', all.length > 0 && all.length === off.length);
  }});
  document.getElementById('shown').textContent =
    hidden.size ? `showing ${{shown}} of ${{total}} merges` : `${{total}} merges`;
  renderGraph(hidden);
  if (persist) {{
    const v = [...hidden].join(',');
    history.replaceState(null, '', v ? '#hide=' + v : location.pathname + location.search);
    try {{ localStorage.setItem('peras-map-hide', v); }} catch (_) {{}}
  }}
}}
function currentHidden() {{ return new Set(kfs.filter(b => b.getAttribute('aria-pressed') === 'false').map(b => b.dataset.kind)); }}
kfs.forEach(b => b.addEventListener('click', () => {{
  const h = currentHidden(); h.has(b.dataset.kind) ? h.delete(b.dataset.kind) : h.add(b.dataset.kind); applyFilter(h, true);
}}));
kfAll.addEventListener('click', () => applyFilter(new Set(), true));
let hideInit = '';
const m = location.hash.match(/^#hide=([a-z,]*)$/);
if (m) hideInit = m[1]; else {{ try {{ hideInit = localStorage.getItem('peras-map-hide') || ''; }} catch (_) {{}} }}
applyFilter(new Set(hideInit.split(',').filter(k => kfs.some(b => b.dataset.kind === k))), false);
let initial = 'graph';
try {{ initial = localStorage.getItem('peras-map-view') || 'graph'; }} catch (_) {{}}
show(initial);
</script>
</body>
</html>
"""
open(out, "w").write(page)
print(out)
