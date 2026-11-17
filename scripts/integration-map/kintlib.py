"""Shared code of `kint` and `integration-map.py`: the spec, its lock, and the series as git records it.

The spec (`<name>.toml`) declares the series without SHAs: the steps, in order, and the merges of each step. The lock
(`<name>.lock.toml`, next to it) is generated: the SHAs that the spec resolved to when it was last exported.
"""
import json
import os
import re
import subprocess
import tomllib

GH = "https://github.com/"


def git(wt, *args):
    return subprocess.check_output(["git", "-C", wt, *args], text=True, stderr=subprocess.DEVNULL).strip()


def git_ok(wt, *args):
    return subprocess.run(["git", "-C", wt, *args], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def is_ancestor(wt, a, b):
    return git_ok(wt, "merge-base", "--is-ancestor", a, b)


def is_external(ref):
    """An external changeset (a PR, `owner/repo#N`, or another repository's branch, `owner/repo branch`) is merged
    as-is and never rewritten. Any other ref is a topic: a branch of the fork, rebuilt on the state it merges into."""
    return "#" in ref or " " in ref


def lock_path(spec_path):
    return re.sub(r"\.toml$", "", spec_path) + ".lock.toml"


class Spec:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.config = tomllib.load(f)
        c = self.config
        self.kosmos = os.path.expanduser(c["kosmos"].get("path") or git(
            os.path.dirname(os.path.abspath(__file__)), "rev-parse", "--show-toplevel"))
        self.kosmos_base = c["kosmos"]["base"]
        self.kosmos_branch = c["kosmos"]["branch"]
        self.repos = {r["name"]: dict(r, path=os.path.expanduser(r["path"])) for r in c["repo"]}
        self.repo_order = [r["name"] for r in c["repo"]]
        self.steps = c.get("step", [])
        try:
            with open(lock_path(path), "rb") as f:
                self.lock = tomllib.load(f)
        except FileNotFoundError:
            self.lock = {}
        self.lock_merges = {(m["repo"], m["ref"]): m for m in self.lock.get("merge", [])}

    def wt(self, repo):
        return self.repos[repo]["path"]

    def spec_merges(self):
        """(step number, merge entry) for every merge of the spec, in spec order."""
        return [(i, m) for i, s in enumerate(self.steps, 1) for m in s.get("merge", [])]


# ---- the series as git records it ---------------------------------------------

def pins_at(spec, commit):
    pins = {}
    for name in spec.repo_order:
        try:
            cfg = git(spec.kosmos, "show", f"{commit}:packages/{name}/.gitrepo")
        except subprocess.CalledProcessError:
            continue
        pins[name] = re.search(r"commit = (\w+)", cfg).group(1)
    return pins


def read_kosmos(spec):
    """The steps (kosmos commits that move a pin) and the kosmos-only commits of the lockstep branch."""
    steps, only = [], []
    last = pins_at(spec, spec.kosmos_base)
    for c in git(spec.kosmos, "rev-list", "--reverse", f"{spec.kosmos_base}..{spec.kosmos_branch}").split():
        pins = pins_at(spec, c)
        subject = git(spec.kosmos, "log", "-1", "--format=%s", c)
        if pins == last:
            only.append({"commit": c, "subject": subject})
            continue
        moved = sorted(n for n in pins if pins[n] != last.get(n))
        last = pins
        steps.append({"commit": c, "title": subject, "pins": pins, "moved": moved})
    return steps, only


MERGE_SUBJECT = re.compile(r"Merge (.+?) \((.*)\)$")


def read_merges(spec, repo, steps):
    """The first-parent merges of a repository's integration branch, each with the first step whose pin contains
    it (None if no step does). Non-merge commits on the first-parent history are returned with `ref` None."""
    wt = spec.wt(repo)
    r = spec.repos[repo]
    base = git(wt, "rev-parse", r["base"])
    out = []
    for m in git(wt, "rev-list", "--first-parent", "--reverse", f"{base}..{r['branch']}").split():
        parents = git(wt, "log", "-1", "--format=%P", m).split()
        subject = git(wt, "log", "-1", "--format=%s", m)
        match = MERGE_SUBJECT.match(subject)
        step = next((i for i, s in enumerate(steps, 1)
                     if repo in s["pins"] and is_ancestor(wt, m, s["pins"][repo])), None)
        out.append({"commit": m, "parents": parents, "subject": subject,
                    "ref": match and len(parents) == 2 and match.group(1),
                    "desc": match and match.group(2), "step": step})
    return base, out


# ---- TOML output (tomllib only reads) ---------------------------------------------

def tstr(s):
    return json.dumps(s, ensure_ascii=False)


def tval(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list):
        if not v:
            return "[]"
        return "[\n" + "".join(f"  {tstr(x)},\n" for x in v) + "]"
    return tstr(v)


def ttable(header, d, indent=""):
    lines = [f"{indent}{header}"]
    for k, v in d.items():
        if v is None:
            continue
        lines.append(f"{indent}{k} = {tval(v)}")
    return "\n".join(lines) + "\n"
