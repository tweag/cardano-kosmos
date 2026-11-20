# `cardano-config`

This package reads a `cardano-node` configuration. It gives you:

- a command-line option parser, `parseCliArgs`
- a configuration file parser, `parseConfigurationFiles`, for JSON and YAML
- `resolveConfiguration`, which combines the two into a `NodeConfiguration`

One parser serves every application that needs the node's configuration, such
as [`cardano-cli`](https://github.com/IntersectMBO/cardano-cli),
[`dmq-node`](https://github.com/IntersectMBO/dmq-node/) and
[the `ouroboros-consensus` tools](https://github.com/IntersectMBO/ouroboros-consensus/tree/main/ouroboros-consensus-cardano#consensus-db-tools).

The package also builds the `cardano-config` program. It has three
subcommands: `resolve`, `schema` and `migrate`.

## The configuration format

A configuration is one JSON or YAML object, in one file. The top level is an
envelope, which holds four keys and nothing else:

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/v2/schemas/config.schema.json",
  "Version": 2,
  "MinNodeVersion": "11.2",
  "Configuration": {
    "Protocol": {
      "RequiresNetworkMagic": "RequiresNoMagic",
      "ByronGenesisFile": "mainnet-byron-genesis.json",
      "ByronGenesisHash": "5f20df933584822601f9e3f8c024eb5eb252fe8cefb24d1317dc3d432e940ebb",
      "ShelleyGenesisFile": "mainnet-shelley-genesis.json",
      "ShelleyGenesisHash": "1a3be38bcbb7911969283716ad7aa550250226b76a61fc51cc9a9a35d9276d81",
      "AlonzoGenesisFile": "mainnet-alonzo-genesis.json",
      "AlonzoGenesisHash": "7e94a15f55d1e82d10f09203fa1d40f8eede58fd8066542cf6566008068ed874",
      "ConwayGenesisFile": "mainnet-conway-genesis.json",
      "ConwayGenesisHash": "15a199f895e461ec0ffc6dd4e4028af28a492ab4e806d39cb674c88f7643ef62"
    },
    "Storage": { "LedgerDB": { "Backend": "V2InMemory" } }
  }
}
```

`Configuration` holds the configuration itself. Each component goes inline
under its section key, such as `Protocol` or `Storage`. Tracing is
not a section. It is the single `HermodTracing` key beside them.

`$schema` names the schema the file follows. `Version` is the format version.
`MinNodeVersion` records the lowest `cardano-node` version you expect to run
this configuration. The parser records it for you to read. Nothing in this
library acts on it.

Declare the `$schema`, and pin it to the `vN` tag of the format version you
write for. Editors and validators use it to find the schema.

### Other referenced JSON files

Some fields reference other JSON files:

- the four genesis files, under `Protocol`
- the experimental genesis file, under `Testing`
- the tracing configuration, if `HermodTracing` is a string and not an object

## Mandatory keys

Eight keys have no default. Parsing fails when one is absent:

- `ByronGenesisFile` and `ByronGenesisHash`
- `ShelleyGenesisFile` and `ShelleyGenesisHash`
- `AlonzoGenesisFile` and `AlonzoGenesisHash`
- `ConwayGenesisFile` and `ConwayGenesisHash`

These values differ per network, so the defaults do not name them. Write them
into `Protocol` yourself.

## Defaults and layering

The package ships two default configurations, under [`defaults/`](defaults/):

- [`config.blockproducer.json`](defaults/config.blockproducer.json), for a node
  that forges blocks
- [`config.relay.json`](defaults/config.relay.json), for a node that does not

Each is a complete configuration, in the same envelope you write. Each holds
the defaults of every component. The two differ in three `Network`
values: `DeadlineTargetNumberOfRootPeers`, `DeadlineTargetNumberOfKnownPeers`
and `PeerSharing`. That difference is what the two roles mean here.

Neither file names a genesis, so neither is a configuration you can run. That
is also why neither declares a `$schema`. Both fail `config.schema.json` on
purpose, and an editor marks them invalid for a rule they are meant to
break.

`resolveConfiguration` applies three layers, from lowest to highest:

1. the default configuration for the node's role
2. your configuration file, merged on top key by key
3. the matching command-line flag, where one exists

`resolveConfiguration` picks the role from your credentials. A node with a
block-forging credential is a block producer. A node without one is a relay.

All three layers are applied at this one point, because the role comes from
the command line. `parseConfigurationFiles` returns what your file said, with
nothing filled in. It reads the genesis files your file names, and makes sure
that every section parses.

`cardano-config` is where these defaults live, but each component's defaults
belong to the team that implements the component.

## Porting an older configuration

Run `cardano-config migrate` to bring an older file up to the current format:

```console
$ cardano-config migrate old-config.json > config.json
```

It reshapes the document into the envelope, brings the key names up to date
and drops the keys that no longer exist. It keeps your values as you wrote
them, and fills in no defaults. The result comes out in the format it went
in: JSON for a JSON file, YAML for a YAML one. Run `cardano-config resolve --config <file>`
afterwards to make sure that the result parses.

[`MIGRATION.md`](MIGRATION.md) lists every change `migrate` makes, key by key,
so that you can audit the result.

## Format versions and schemas

`Version` is the format version. It is the first component of the package
version. `cardano-config-X.y.z.v` reads every format version up to and
including `X`, and writes `X`. It reads an older document by migrating it to
`X` first, in memory. The other three components of the package version carry
changes to the Haskell code alone.

Each format version has its own git tag, `v1`, `v2` and so on. The tag makes
the published schema address immutable:

```
https://raw.githubusercontent.com/IntersectMBO/cardano-config/v2/schemas/config.schema.json
```

Immutable covers the constraints. What a document must satisfy to be valid
never changes under a tag. A later release can still correct an annotation,
such as a `default`, a `description` or a `title`. A validator does not act on
those keys, so the tag moves to the corrected file. A change to what validates
needs a new format version, and that version gets its own tag.

One schema lives under [`schemas/`](schemas/). `config.schema.json` describes
the format above. Print it with `cardano-config schema`. Regenerate the
committed file with `scripts/gen-schemas.sh`.

The schema is draft-07 and self-contained, so any standard validator reads
it. To make sure that a configuration is valid, use
[`ajv`](https://github.com/ajv-validator/ajv-cli):

```console
$ ajv validate --spec=draft7 --strict=false -s schemas/config.schema.json -d my-config.json
```

Validate the whole file, envelope and all. `config.schema.json` requires
`$schema`, `Version` and `Configuration`, so a fragment of a configuration
fails it. Those three keys are what `migrate` always writes.
`MinNodeVersion` is optional, because `migrate` never invents one.

A validator reads the file and nothing else. It cannot make sure that a
genesis hash matches. It cannot apply a rule that spans the file, the command
line and the defaults. Run `resolve` for those.

An older document fails validation. It still parses, because `migrate`
rewrites it first, but the schema describes the current form alone.

CI runs `scripts/check-schemas.sh` over documents that must pass and documents
that must fail. The cases live in `test/schema-cases/`. Each one is a whole
configuration, so the check sees what you write.

## Warnings

Parsing and resolution return warnings next to the configuration. They do not
print them. You decide whether to print them, log them or treat them as
errors. `renderConfigWarning` gives you the one-line text that the
`cardano-config` program prints to standard error.

`parseConfigurationFiles` raises these:

| Warning | Raised when |
|---------|-------------|
| `OutdatedFormatVersion declared current` | The document is at an older format version, so `migrate` upgraded it in memory. A document with no `Version` key is version 1. |
| `MigratedToCurrentFormat` | The document is at the current version, but `migrate` still changed it. It was outside the envelope, or used an old key name, or carried an obsolete key. |
| `RenamedKeyCollision old new` | Both the old and the current name of a key are present at the same level. The current name wins. The other value is dropped. |
| `EnvelopeKeyCollision key` | A key sits both beside `Configuration` and inside it. The one inside wins. |
| `UnrecognisedKeys keys` | Keys at the `Configuration` level that no parser claims. They are ignored. |

`resolveConfiguration` adds one:

| Warning | Raised when |
|---------|-------------|
| `ConsistencyWarning description` | A check of warning severity did not hold on the resolved configuration. One example is a Mithril snapshot policy under the `V2LSM` backend with no `LSMExportPath`. The configuration is still accepted. See `ConfigCheck`. |

Only keys at the `Configuration` level are checked against the recognized set.
An unknown key inside a section is ignored without a warning.

## The gRPC endpoint

The schema describes the `Grpc*` keys of `LocalConnections`, one by one,
along with the rules that tie them together. Four facts about the endpoint do
not fit in a schema, so they are here.

The server listens on exactly one endpoint. The keys are alternatives, not a
set of independent settings, which is why `GrpcSocketPath` excludes the TCP
keys.

Without a `GrpcSocketPath`, the endpoint is a unix socket at `rpc.sock`,
beside the node socket. The consumer derives that path, so no default names
it.

`GrpcListenAddress` defaults to `127.0.0.1`. A port alone keeps the endpoint
on loopback.

Enabling gRPC needs a node socket path, from the file or from
`--socket-path`. The server serves every request over the node-to-client
socket, whichever endpoint it listens on. A validator cannot see this rule,
because the command line satisfies it too, so `resolve` reports it.

On the command line, `--grpc-socket-path` and `--grpc-listen-port` exclude
each other in the same way. A command-line endpoint replaces the endpoint in
the file whole. It does not merge into it, because the two describe one
choice.

Replacing the endpoint drops the file's TLS credentials with it. If the file
configures a TLS listener and you pass only `--grpc-listen-port`, the server
listens in plaintext on the new port. `resolve` warns when this happens. To
move the port and keep TLS, pass `--grpc-tls-certificate` and
`--grpc-tls-private-key` as well.

## Tracing

The node's tracing system owns the tracing configuration. That system is
hermod, built on `trace-dispatcher`. You give the configuration under one key,
`HermodTracing`, inside `Configuration`. Its value is a path to a file, or the
configuration object inline.

This library does not define the shape of that object, and does not read it.
The schema for it lives in
[`hermod-tracing`](https://github.com/IntersectMBO/hermod-tracing), so
`config.schema.json` describes `HermodTracing` as a path or an object and
stops there.

The parser hands the value to `trace-dispatcher`, which turns it into a
`TraceConfig`. A resolved configuration always carries one. A file with no
`HermodTracing` key gets `defaultCardanoTracingConfig` unchanged.
`cardano-config resolve` prints it back under `HermodTracing`, as an inline
object.

## Genesis initial data injection

A test network's genesis can hand the ledger its starting state. That state
covers initial funds, stake pools, stake credentials, delegations and DReps.
The genesis gives it inline, through the `initialFunds`, `staking`, `delegs`
and `initialDReps` fields. It can instead name a separate file under the
`extraConfig` key:

```json
"extraConfig": {
  "initialFunds": { "file": ["initial-funds.json"], "hash": "<blake2b-256 hex>" }
}
```

`cardano-ledger` streams that file while it builds the first ledger state,
rather than holding it in the genesis value. The `file` is not a filesystem
path. It is an `FsPath`, a list of path segments the ledger resolves against a
filesystem you supply.

This library fixes that filesystem to the directory of the Shelley genesis
file, which matches `cardano-node`. Note that this is the genesis directory.
It is not, in general, the directory of the configuration file. The parser
records it as `genesisInjectionRoot`. Build the filesystem with
`nodeConfigurationInjectionFS`, and hand the result to `protocolInfoCardano`.

The parser makes sure that three rules hold as it reads the configuration.
The ledger reports them much later otherwise, by throwing:

- a field takes its data from the inline form or from `extraConfig`, never both
- a mainnet genesis cannot use injection at all
- a file named under `extraConfig` must exist

The parser does not hash those files. The ledger makes sure that each hash
matches as it streams the file, and hashing here reads a large file twice. See
`Cardano.Configuration.Genesis.Injection`.

## Command-line options

`parseCliArgs` is an `optparse-applicative` parser. It produces a `CliArgs`
value. The flag names, metavars and help text match the ones `cardano-node`
accepted before, so your existing scripts keep working. Run
`cabal run cardano-config -- resolve --help` to read them.

## Seeing the result

Run `resolve` to see what a configuration comes to, defaults and all:

```console
$ cardano-config resolve --config <your-config.json> --<other node options>
Consensus:
  ConsensusMode: PraosMode
LocalConnections:
  EnableGrpc: false
Network:
  ...
```

Add `--with-geneses` to include every decoded era genesis. The output grows
large. Without the flag, each genesis appears as a path and a hash under
`Protocol`.

## Notes on networks

Each network enables different features:

|              | Mainnet | Preprod | Preview |
|--------------|---------|---------|---------|
| Checkpoints  | Yes     | No      | Yes     |
| Test*HardFork| No      | No      | Yes     |
