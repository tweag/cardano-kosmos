# Integration tools

Two scripts for the Peras lockstep integration:

- `kint` checks that the integration is consistent and writes down its current state.
- `integration-map.py` draws the integration as one HTML page.

Both read the same configuration, `peras-integration-main.toml`.

## Terms

- **Integration branch**: in each repository, the branch that kosmos vendors. It is the upstream base, then one
  `--no-ff` merge per changeset. Each merge message is `Merge <ref> (<description>)`.
- **Changeset**: what one merge brings. There are two sorts:
  - **external**: a PR (`owner/repo#N`) or another repository's branch (`owner/repo branch`). It is merged as-is and
    never rewritten.
  - **topic**: a branch of the fork (any other ref). It starts from the integration commit it merges into, so it can
    be rebuilt on a new state.
- **Step**: a kosmos commit that moves one or more subrepo pins. A kosmos commit that moves no pin, such as the commit
  that adds these scripts, is not a step.

## kint

```
scripts/integration-map/kint export
scripts/integration-map/kint verify
```

`kint export` reads git and writes:

- the `[[step]]` section of the configuration: every step and its merges, in order, without SHAs;
- the lock, `peras-integration-main.lock.toml`: the SHAs of the steps and the merges.

It keeps the fields that you write by hand: `kosmos_side`, `kosmos_files`, `pr`, `pr_title`, `pr_draft`. Run it after
every change to the branches. Do not edit the lock.

`kint verify` checks that:

- each integration branch is only `Merge <ref> (<description>)` merges on top of its base;
- each merge is in a step, and each pin is the last merge of its step (or the repository's base);
- the configuration and the lock describe what git has;
- each topic starts from the integration commit it merges into, and its local branch is what was merged;
- no message mentions an AI: merges, kosmos commits, and commits written with your git identity;
- each step vendors exactly the trees of its pins;
- each requirement, include and kind override names a changeset, and no requirement comes after its dependent.

It exits with 1 if a check fails.

## The map

```
nix develop -c scripts/integration-map/integration-map.py scripts/integration-map/peras-integration-main.toml map.html
```

The page has three views:

- **Graph**: one column per repository, one row per merge, arrows for the requirements.
- **By repository**: each changeset, with its kind, PR, size and requirements.
- **Lockstep**: steps × repositories.

The order comes from git. Steps are in kosmos commit order. A merge belongs to the first step whose pin contains it.
In one repository, merges are in first-parent order. Merges in different repositories in the same step have no order:
only a `[[requires]]` entry relates them.

The kind of a changeset comes from its ref: `kosmos-compat/` is kosmos-compat, `kosmos-local/` is test-only, anything
else is upstream-bound. A `[[kind_override]]` can mark it as a stub.

## Configuration

| Table | Content |
|---|---|
| `[kosmos]` | `base`: the commit before the first step. `branch`: the lockstep branch. `path` (optional): the kosmos clone; by default, the clone that contains the scripts. |
| `[[repo]]` | One per repository, in column order. `name`, `path` (local clone), `fork` (GitHub slug), `base` (upstream commit), `base_label` and `base_url` (how to show the base), `branch` (integration branch). |
| `[[step]]` | One per step, in order. `title`. `base` (optional): repositories the step vendors at their base. `kosmos_side` (optional): the step's kosmos changes. `kosmos_files` (optional): a directory of kosmos files the step adds. |
| `[[step.merge]]` | One per merge of the step. `repo`, `ref`, `desc` (as in the merge message). Optional: `pr` (`owner/repo#N`), `pr_title`, `pr_draft`. |
| `[[includes]]` | Another open PR that a changeset contains: `repo`, `ref`, `pr`, `title`, `draft`. |
| `[[kind_override]]` | `repo`, `ref`, `kind = "stub"`, `note` and `url` to show. |
| `[[requires]]` | `repo` and `ref` need `needs_repo` and `needs_ref` (`"@base"`: that repository's base). `how`: `"build"` or `"runtime"`. `why`: the evidence. |

The lock has, for each merge: `commit` (the merge), `source` (the merged commit), `pr_head` (the PR head at the last
check) and `adapted_from` (the PR commit a cherry-picked topic comes from).
