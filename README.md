# Cardano Kosmos

This is a monorepository of Cardano libraries for the development of [Peras](https://github.com/tweag/cardano-peras/).

The `main` branch follows [cardano-node](https://github.com/IntersectMBO/cardano-node)'s `master`, never catching up with it like [Sisyphus](https://en.wikipedia.org/wiki/Sisyphus). More details about the organization are below.

To start working, you simply need

```
nix develop
./scripts/run-peras-testnet.sh
```

That will build all necessary dependencies and start the Peras testnet process-compose.

To reconfigure the testnet or scenario params, change `nickel/scenarios/<scenario>.ncl` or `nickel/testnet.ncl` and reconfigure before run:

```
./scripts/setup-testnet-env.sh
./scripts/run-peras-testnet.sh
```

To isolate `node1` manually run in another `nix develop`:

```
toxiproxy-cli toggle node1
```

## Logs and Dashboards

Running `./scripts/run-peras-testnet.sh` will spin up a log collector and
metrics dashboard for the testnet. These are available at:

- [Logs](http://0.0.0.0:9428/select/vmui/), available once the `victoria-logs`
  process comes up
- [Dashboards](http://localhost:3000/d/da93ce09-7b06-49e0-812e-2872192a9bcf/default),
  available once the `grafana` process comes up. You shouldn't need to log in,
  but if you do, the credentials are `cardano/cardano`.

Some panels haven't yet been ported to grafana; it is expected that some panels
will fail with a `Datasource dbsync_uid was not found` error.


## Work organization

There are two options how the work can be done:

1. "Kosmos as devenv". The work happens in an external checkout, e.g. `packages: ../ouroboros-consensus/`.
2. Internally in this repository.

If your work happens in one package, you need to iterate fast, send PRs upstream, fetch from them constantly, etc., then option #1 works better.

Option #2 suits better for a long-term work across multiple packages. If the work happens in multuple packages, glueing components, there is no need to send changes upstream, etc. In this case sending patches upstream will require the usage of `git subrepo` command and external forks `tweag/cardano-node`, `tweag/ouroboros-consensus`, etc. See section below.

## How to send patch upstream

If your work has landed into Kosmos, you can push the changes to the upstream fork:

```
git subrepo push packages/ouroboros-consensus --branch <branch-name-in-remote>
```

That will push the changes relevant to `packages/ouroboros-consensus` to the remote repository `tweag/ouroboros-consensus:<branch-name-in-remote>`.

It's possible to open a PR from `tweag/ouroboros-consensus:<branch-name-in-remote>` to `IntersectMBO/ouroboros-consensus` now.

## How packages are organized in Kosmos

Kosmos's `main` branch obligations:
- Always contain the latest state of `IntersectMBO/ouroboros-consensus`'s `peras/the-big-pr`.
- Provide a working `cardano-node` binary that runs this version of consensus.
- Provide a working local testnet setup that runs this `cardano-node`.

All of this is achieved with the help of a tool called `git subrepo` and a set of external forks under the `tweag`'s organization.
The remote repos are vendored into `packages/*` directory and we always have the source code in our tree.
This helps us to fix the state of constantly changing tree of cardano repositories. PRs are being merged, commits squashed, etc.

`git subrepo status` will tell the current pins:

```
> git subrepo status
6 subrepos:

Git subrepo 'packages/cardano-api':
  Remote URL:      git@github.com:tweag/cardano-api.git
  Tracking Branch: 0024a90d94db11818c03a02da412904f12e147f6
  Pulled Commit:   0024a90
  Pull Parent:     c5ed8a3

...
```

As you can notice, there is no tracking branch, such as `peras/kosmos` for example. Why not?
The current practice is that we rebase a lot to keep up with the current upstream packages.
This approach does not provide a stable tracking branch yet.

