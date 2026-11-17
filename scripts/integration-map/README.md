# Integration map

`integration-map.py` makes one HTML page. The page shows a kosmos lockstep branch and the integration branches that
its steps pin. The page has three views:

- A graph of the merges. Each repository has one column. The rows are in merge order. The arrows show the
  requirements between repositories.
- A list of the changesets of each repository.
- A table of the steps and the repositories.

To make the page, run this command from the root of the kosmos repository:

```
nix develop -c scripts/integration-map/integration-map.py scripts/integration-map/peras-integration-main.toml map.html
```

The script reads the data from git. Each repository must have a local clone. The clone must have the integration
branch and the topic branches that it merges.

A step is a commit of the kosmos branch that changes one or more subrepo pins. A commit that changes no pin is not a
step. For example, the commit that adds this script is not a step.

## Order

The script gets the order from git:

- The order of the steps is the order of the commits on the kosmos branch.
- A merge is in the first step whose pin contains it.
- In one repository, the order of the merges is the first-parent order of the integration branch.

Git does not give an order to merges in different repositories in the same step. A step moves all its pins in one
commit. Thus, the only relation between these merges is a requirement in the configuration. If the configuration does
not declare a requirement, the graph shows no relation.

## Configuration

`peras-integration-main.toml` is the configuration for the map of `peras/integration-main`. It gives the data that git
does not record.

| Table | Content |
|---|---|
| `[kosmos]` | `base`: the commit before the first step. `branch`: the lockstep branch. `path` (optional): the kosmos clone. If you do not set `path`, the script uses the clone that contains it. |
| `[[repo]]` | One entry for each repository. The order of the entries is the order of the columns. `name`: the repository. `path`: the local clone. `fork`: the GitHub slug. `base`: the upstream commit before the first merge. `base_label` and `base_url`: the text and link for this commit. `branch`: the integration branch. |
| `[[pr]]` | An open PR for a merged changeset (`repo`, `ref`). `pr`: `owner/repo#N`. `title`: the title of the PR. `draft`: `true` if the PR is a draft. `head`: the head of the PR at the last check. `adapted_from`: the PR commit that a cherry-picked changeset comes from. |
| `[[includes]]` | An other open PR that a changeset contains. The fields are the same as in `[[pr]]`. |
| `[[kind_override]]` | A changeset that has a different kind from its branch prefix. `kind`: `"stub"`. `note` and `url`: the text and link to show. |
| `[kosmos_side]` | The kosmos changes of a step. The key is the step number. |
| `[[requires]]` | A requirement between repositories: `repo` and `ref` need `needs_repo` and `needs_ref`. If `needs_ref` is `"@base"`, the requirement is the base of `needs_repo`. `how`: `"build"` or `"runtime"`. `why`: the evidence. |

A merged changeset has the reference that its merge message shows: `Merge <ref> (<description>)`.

The branch prefix gives the kind of a changeset:

- `kosmos-compat/`: kosmos-compat.
- `kosmos-local/`: test-only.
- All other prefixes: upstream-bound.

The script stops with an error in these conditions:

- A requirement refers to a changeset that does not exist.
- A requirement refers to a changeset that is in a later step than its dependent.
