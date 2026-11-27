# Revision history for cardano-config

## 2.2.3.0 -- 26-10-2026

### `migrate` keeps the input format

`cardano-config migrate` used to print JSON whatever it read. It now prints a
JSON document as JSON and a YAML document as YAML, from a file or from
standard input. A document that is valid JSON counts as JSON. Comments in a
YAML document are not carried over, so `migrate` warns when it finds any. A
syntax error in a document read from standard input is now reported like one
in a file.

## 2.2.2.0 -- 16-10-2026

### Dependency versions

Version bounds on `cardano-ledger` were relaxed from `^>=` to `>=` to allow
for the next integration cycle.

### Editing a configuration

The new `Cardano.Configuration.Edit` module reads, changes and writes a
configuration file without the checks `parseConfigurationFiles` makes for a
node, which a tool that writes configurations needs before those checks can
pass. `readConfigurationDocument` (or `configurationDocumentFromValue`, for a
configuration held as JSON) brings a configuration in any format version to the
current one, without reading its genesis files and with its genesis hashes
missing or out of date. `refreshGenesisHashes` sets each genesis hash to the hash
of the file it names, and `writeConfigurationDocument` writes the result back.

### Credentials

The node command line now takes `--shelley-bls-key FILEPATH`, the BLS (Leios)
signing key, as cardano-node does on its `leios-prototype` branch. It is held in
the new `shelleyBLSKey` field of `Credentials` and rendered as `ShelleyBLSKey`.

Like every other credential, its presence makes the node a block producer. This
matches the node's `hasProtocolFile`, which counts the BLS key too.

`Credentials` gains a field, so code that builds it with the positional
constructor has to change. Code that starts from `emptyCredentials` does not.

## 2.2.1.0 -- 06-10-2026

### Exports

`Cardano.Configuration.CliArgs` now exports `parseNodeDatabasePaths` and
`parseStartAsNonProducingNode`, along with the `NodeDatabasePaths` type.

Both parsers live in `Cardano.Configuration.Common`, which is an internal
module, so they could not be reached from outside the package. Every other
option parser of the node command line was already exported, so a consumer that
wanted to build the node's command line from this package had to write its own
`--database-path`, `--volatile-database-path`, `--immutable-database-path` and
`--start-as-non-producing-node`, which is what the exports exist to avoid. The
type is re-exported for the same reason `GrpcEndpoint` is: a consumer building a
`CliArgs` directly has to name the type of `databasePathCLI`.


## 2.2.0.0 -- 06-10-2026

### Defaults

The default `DatabasePath` is now `mainnet/db/`. It used to be `db`.

`mainnet/db/` is what cardano-node's own parser resolves to when a
configuration leaves `DatabasePath` unset. The two defaults disagreed. An
operator who moved an existing deployment to cardano-config, and who never
wrote the key, got a node that ignored the database under `mainnet/db/`. The
node started a fresh sync in a new `db` directory instead. The node now finds
the database it already has.

The directory is named `mainnet` on every network. That is the node's existing
behavior, and it is now this package's behavior as well. A deployment that
sets `DatabasePath` explicitly is unaffected. Only a configuration without the
key changes where the node reads and writes.

The two default configurations carry the new value. `schemas/config.schema.json`
carries it as the documented `default`. A default is an annotation and not a
constraint, so the format version stays at 2 and the `v2` tag moves (#28).


## 2.1.0.0 -- 02-10-2026

### Snapshots

The Mithril `Interval` is now 86400 slots and the Mithril `Offset` is now 0.
They used to be 432000 and 388800.

86400 slots is `40 * k` for the mainnet security parameter `k = 2160`, which is
one snapshot a day. That interval divides both the 432000-slot Shelley epoch
and the 4492800-slot start of Shelley, so an offset of 0 puts a snapshot on
every epoch boundary, which is the state Mithril signs, and four more inside
each epoch. The node captures the state at that slot and writes it between
`MinDelay` and `MaxDelay` seconds later, so the write does not land on the
epoch-boundary work. The previous offset put the one snapshot of each epoch at
mid-epoch instead, which kept the write off the boundary but signed a state
that was not on one.

The interval is the mainnet value. A network with a different security
parameter needs its own `Interval`.

`mithrilSnapshotOptions`, the two default configurations and the example
configurations carry the new values.

## 2.0.0.0 -- 02-10-2026

The configuration format moves to version 2, so the package version is
`2.0.0.0`. A `cardano-config-2.x.x.x` reads every format version up to and
including 2, and writes 2.

Three changes shape the release. The configuration lives in one file. The
package ships one complete default configuration per node role. The gRPC
server can listen on a TCP port, with or without TLS.

### Upgrading

Run `cardano-config migrate <file>`. The command rewrites the file to version
2, renames the keys that changed name, and groups loose keys under the section
that owns them. It prints a line to stderr pointing you at `resolve`.

Migration is a structural rewrite. It does not parse the result, so run
`cardano-config resolve --config <file>` afterward to make sure that the file
still loads.

You do not have to migrate on disk. The parser migrates a version 1 document
in memory before it reads it, and reports the migration as a warning.

Three configurations that worked with 1.1.0.0 now fail:

- One whose sections name separate files. Copy each sub-file's contents in
  under its section key. `migrate` cannot do this for you, because reading
  those files is what this release removes.
- One that sets `EnableGrpc` without a `SocketPath`. The gRPC server serves
  every request over the node-to-client socket, so it needs one whichever
  endpoint it listens on.
- One that sets `ExperimentalHardForksEnabled` without a
  `DijkstraGenesisFile`. An experimental era needs a genesis to run from.

The last two are consistency checks added after `v1`. `resolve` reports both,
and each message names what is missing.

### One file

A section key such as `Storage` or `Protocol` used to take either
an inline object or a path to a separate file. It now takes the inline object
alone. A section that holds anything else is rejected, and the error names the
section. The genesis files and the `HermodTracing` file are unaffected,
because those keys name files by design.

A configuration is one envelope: `$schema`, `Version` and `Configuration`. The
schema requires all three, because `migrate` writes all three.
`MinNodeVersion` stays optional.

`migrate` now writes the current format version rather than carrying an older
one through. Because every document reaches the parser at version 2, there is
one parse path instead of one per version.

### The shipped defaults

The package ships `defaults/config.blockproducer.json` and
`defaults/config.relay.json`. Each is a complete configuration in the
envelope. They replace the seven `defaults/<Component>.json` files,
`defaults/HermodTracing.json` and the two `defaults/NetworkConfig/` files.

Resolution picks one file by whether the operator supplied block-forging
credentials, then merges your configuration on top. The two differ only in the
deadline peer targets and `PeerSharing`, which is what block producer and
relay mean here. Neither names a genesis, so neither is a configuration you
can run.

The defaults now apply at resolution rather than while the file is read.
`parseConfigurationFiles` returns what the file states, with nothing filled
in.

The `variants/` directory is gone. Its files held per-network sections to copy
by hand, and nothing read them. Copy the genesis names for your network out of
a working configuration instead.

### The schema

There is one schema, `schemas/config.schema.json`. The seven
`schemas/<Component>.schema.json` files and the legacy single-file schema are
gone, along with the Haskell values that built them. `cardano-config schema`
takes no options now.

The schema describes the envelope and the sections inside `Configuration`. It
used to put the section keys at the top level and declare `Configuration` as a
bare object. That schema accepted documents the parser rejects, and rejected
the canonical form.

The schema states the cross-field rules this library enforces, so a validator
now rejects documents `v1` accepted:

- `GrpcSocketPath` excludes the TCP and TLS keys.
- A TLS certificate and its private key go together, and both need a port.
- The three mempool timeouts are all set or all unset.
- A genesis file comes with its hash.
- `ExperimentalHardForksEnabled` requires a Dijkstra genesis.

Only the last rejects a configuration 1.1.0.0 accepted. The others state what
the parser already rejected, or govern keys that version 2 adds.

The schema also states every default the library applies. Most come from the
two default configurations. `GrpcListenAddress` carries
`default: "127.0.0.1"`, taken from the Haskell value so the two cannot drift.
Two defaults stay in a description, because JSON Schema cannot express either:
the three coupled mempool timeouts, and the LSM `DatabasePath` default of
`"lsm"`.

### The gRPC endpoint

The gRPC server used to listen only on a unix socket. It can now listen over
HTTP/2 on a TCP port, with or without TLS. `LocalConnections` gains five
keys:

- `GrpcListenAddress`
- `GrpcListenPort`
- `GrpcTlsCertificateFile`
- `GrpcTlsPrivateKeyFile`
- `GrpcTlsChainCertificateFiles`

The three listeners are one choice, so the keys exclude each other.
`GrpcSocketPath` excludes the other five. An address or a TLS credential needs
a port beside it. `GrpcListenAddress` defaults to `127.0.0.1`, which keeps a
plaintext listener on the loopback interface.

The command line gains `--grpc-listen-address`, `--grpc-listen-port`,
`--grpc-tls-certificate`, `--grpc-tls-private-key` and
`--grpc-tls-chain-certificate`. A command-line endpoint replaces the endpoint
in the file whole, because the two describe one choice.

Replacing the endpoint drops the file's TLS credentials with it. If the file
configures a TLS listener and you pass only `--grpc-listen-port`, the server
listens in plaintext on the new port. `resolve` warns when this happens. To
move the port and keep TLS, pass the two TLS flags as well.

`migrate` renames the older `Rpc*` spelling of all five keys to the `Grpc*`
form.

### Tracing

`cardano-config` no longer supplies tracing defaults. Tracing belongs to
`trace-dispatcher`, which falls back on its own for whatever a configuration
leaves unset. The `HermodTracing` value reaches that library as written, with
no default underneath it.

The old default set more than that fallback does. It added the `EKGBackend`
backend and the `cardano.node.metrics.` metrics prefix, set per-tracer
severities for `ChainDB`, `Mempool`, `Forge` and others, and added five rate
limiters. None of them apply now. A node that wants them must state them under
`HermodTracing`.

What remains is `trace-dispatcher`'s own fallback: `Notice` severity, `DNormal`
detail and `Stdout MachineFormat` at the namespace root. The `HermodTracing`
block in both default configurations states that fallback for a reader.
Nothing applies it.

### Stricter and looser parsing

`AcceptedConnectionsLimit` accepts a partial object. A configuration that sets
`HardLimit` alone takes `SoftLimit` and `Delay` from the defaults. All three
used to be required together.

An `AcceptedConnectionsLimit` whose `SoftLimit` exceeds its `HardLimit` is
rejected at resolution. The check applies after the defaults, so setting
`HardLimit` below the default `SoftLimit` of 384 without also lowering
`SoftLimit` fails.

A `Version` below 1 is rejected, naming it. Version 1 is the lowest that has
ever existed, so `0` and a negative number name no format. Both used to be
read as version 1 documents and migrated.

The peer selection targets are checked with `ouroboros-network`'s own
`sanePeerSelectionTargets`, one check for the `Deadline` group and one for the
`Sync` group. The node does not reject a bad set itself, because it states the
rule as an assertion that `-O` compiles out.

The numeric command-line options take plain decimal only. `--grpc-listen-port
0x1F1` used to bind port 497, and `0o17` used to bind port 15. This affects
`--port`, `--grpc-listen-port`, `--shutdown-on-slot-synced` and
`--shutdown-on-block-synced`.

An `UnrecognisedKeys` warning reports only a name no parser claims, such as a
typo. `migrate` groups a component property under the section that owns it in
every case, so such a property is no longer reported.

`ConfigWarning` gains `OutdatedFormatVersion declared current`, raised when a
document is at an older format version. `MigratedToCurrentFormat` now reports
only a document already at the current version that migration still changed.

The `migrate` command used to print `ExitFailure 1` under a message it had
already written. It no longer does.

### Section names

The sections under `Configuration` lose their `Config` suffix:
`ConsensusConfig` is now `Consensus`, and likewise `LocalConnections`,
`Mempool`, `Network`, `Protocol`, `Storage` and `Testing`. `HermodTracing`
keeps its name.

`migrate` renames the sections. The legacy `Protocol` selector is still
dropped, but only when it is not an object, so the new `Protocol` section
survives.

### The mempool capacity override

`MempoolCapacityBytesOverride` is now `CapacityBytesOverride`, and it takes a
byte count only. Leaving it out means no override. The `"NoOverride"` string
is gone, and the default configurations no longer set the key.

`migrate` renames the key. Where its value is `"NoOverride"`, under either
name, `migrate` drops the key instead.

### Snapshots

Two snapshot options are renamed inside `LedgerDB.Snapshots`:
`SnapshotInterval` is now `Interval`, and `SlotOffset` is now `Offset`.
`migrate` rewrites both, whether they sit flat under `LedgerDB` or already
inside `Snapshots`. The parser rejects the old names.

The Mithril `MaxDelay` is now 21600 seconds, which is `10 * k` on mainnet. It
used to be 600. `mithrilSnapshotOptions` carries the new value.

The default configurations spell the Mithril values out rather than naming the
`"Mithril"` policy. The warning for a Mithril policy under `V2LSM` with no
`LSMExportPath` now matches the policy by its values, so it still fires for the
default and for a partial policy that fills in to the Mithril values.

### The Haskell API

The networking types come from `ouroboros-network` instead of being declared
here. `DiffusionMode`, `AcceptedConnectionsLimit` and
`TxSubmissionLogicVersion` are that library's types, re-exported under the
same names, and `peerSharing` holds its `PeerSharing` rather than a `Bool`.
Configuration files are unaffected, because the codecs keep the spellings they
had. Code that matches on the old constructors must change:

- `InitiatorOnly` and `InitiatorAndResponder` become
  `InitiatorOnlyDiffusionMode` and `InitiatorAndResponderDiffusionMode`.
- `hardLimit`, `softLimit` and `delayOnSoftLimit` become
  `acceptedConnectionsHardLimit`, `acceptedConnectionsSoftLimit` and
  `acceptedConnectionsDelay`.
- `True` and `False` for peer sharing become `PeerSharingEnabled` and
  `PeerSharingDisabled`.

`ConfigResolutionError` has two constructors. `ViolatedChecks` carries the
descriptions of the consistency checks that failed. `SectionDecodeError`
carries a section and a decode error. The type is no longer a newtype, and the
`violatedChecks` field accessor is gone. The type gains a `displayException`,
so `resolve` prints failed checks as a list.

`NodeConfigurationFromFile` is a plain record. `NodeConfigurationFromFileF`
and its `Identity` synonym are gone. It loses `networkUserLayer` and gains
`userConfiguration :: Value`, the `Configuration` object as JSON. Its
component fields hold the file's own values, so a field the file leaves unset
is `SNothing`.

`LocalConnectionsConfig` replaces `grpcSocketPath :: StrictMaybe FilePath`
with `grpcEndpoint :: StrictMaybe GrpcEndpoint`, the choice among the three
listeners. `CliArgs` replaces `grpcSocketPathCLI` with `grpcEndpointCLI` in
the same way.

`experimentalGenesisConfig` is `SJust` only when
`ExperimentalHardForksEnabled` is on and a `DijkstraGenesisFile` is named.
With the flag off the file is not opened, not read and not hash-checked. A
consumer that used to handle four combinations of flag and genesis now handles
two. The price is that a stale `DijkstraGenesisHash` goes unreported while the
flag is off.

Smaller changes:

- `Cardano.Configuration.Commands` drops `SchemaOptions` and `ConfigForm`.
  `runSchemaCommand` takes `()`, and `schemaOptionsParser` has type
  `Parser ()`.
- `Cardano.Configuration.CliArgs` exports `parseNodeHostIPAddress` and the
  gRPC endpoint parsers.
- `Cardano.Configuration.File.Merge.runCodec` loses its `Maybe FilePath`
  argument, and `decodeValueFile` loses its `Maybe String` section argument.
  Both only ever named a sub-file.
- `AcceptedConnectionsLimitConfig f` holds the three limits, one per field.
  `acceptedConnectionsLimitOf` reads them as `ouroboros-network`'s
  `AcceptedConnectionsLimit`.
- `deadlinePeerSelectionTargets` and `syncPeerSelectionTargets` build a
  `PeerSelectionTargets` from a resolved configuration.

### Dependencies

The lower bounds on the boot libraries `bytestring`, `directory`, `filepath`,
`text` and `time` now allow the versions GHC 9.6.7 ships.

## 1.1.0.0 -- 2026-09-08

Schema format version stays at `1`: the `v1` tag had not been cut when
`1.0.0.0` was released, so the constraint changes below are absorbed into it.
This is the last release that can do that — once `v1` is tagged, a change to
what validates needs a new format version.

### Breaking changes

* `NodeConfiguration` gains a `genesisInjectionRoot` field (the directory the
  ledger resolves genesis injection files against). The constructor is exported,
  so code building the record has to account for it (#17).
* The `LedgerDB` `Backend` key is now either the string `"V2InMemory"` or the
  tagged object `{ "LSM": { "DatabasePath": …, "ExportPath": … } }`. The flat
  spelling — `Backend: "V2LSM"` alongside `LSMDatabasePath`/`LSMExportPath` — is
  still accepted by the parser (`migrate` folds it into the tagged form, raising
  `MigratedToCurrentFormat`), but no longer validates against the schema (#14).
* `LedgerDbBackendSelector` now has its own `HasCodec` instance, and derives
  `Eq` (#14).
* The JSON under `defaults/` is compiled into the library with `file-embed`
  rather than installed as `data-files`. The `data-files` stanza is gone, so the
  defaults are no longer reachable through the Cabal data directory at run time;
  a distributed binary no longer needs one (#15).

### Added

* Genesis initial-data injection: a test network's genesis can name its initial
  funds, stake pools, stake credentials, delegations and DReps under the genesis
  `extraConfig` key, for `cardano-ledger` to stream from separate JSON files.
  New module `Cardano.Configuration.Genesis.Injection`, and from
  `Cardano.Configuration`: `nodeConfigurationInjectionFS`,
  `nodeConfigurationInjections`, `InjectionSlot (..)`, `InjectionSource (..)`,
  `injectionHasFS` and `injectionMountPoint`.

  Three conditions the ledger would otherwise report much later, while building
  the initial ledger state, are now checked as the configuration is read: a
  field takes its data from the legacy form or from `extraConfig`, never both;
  injection is rejected on a mainnet genesis; and a referenced injection file
  must exist. File hashes are left to the ledger, which verifies them as it
  streams (#17).
* `MaybeHashed (..)` is re-exported from `Cardano.Configuration` (#14).
* `Cardano.Configuration.Embedded`, exposing the embedded `defaults/`, and
  `decodeValueBytes` in `Cardano.Configuration.File.Merge` for decoding them
  (#15).
* `migrate` handles more legacy spellings: the flat `LedgerDB` snapshot options
  (`SnapshotInterval`, `NumOfDiskSnapshots`, …) are nested under
  `LedgerDB.Snapshots`, the flat `V2LSM` backend keys are folded into the tagged
  `Backend` form, and a top-level `ApplicationName` is collapsed into
  `HermodTracing.TraceOptionNodeName`. The obsolete `ApplicationVersion` and
  `EnableP2P` keys are now dropped rather than carried forward as
  unrecognised-key warnings (#14).

### Changed

* The `TxSubmissionInitDelay` default is now 60 seconds, was 0 (#14).

## 1.0.0.0 -- 2026-07-31

First release
