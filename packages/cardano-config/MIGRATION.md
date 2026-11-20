# Migrating a configuration

`cardano-config migrate` brings an older `cardano-node` configuration up to
the current format. It reads `-` as standard input, so you can fetch and
convert in one step:

```console
$ cardano-config migrate old-config.json > config.json
$ cardano-config migrate old-config.yaml > config.yaml
$ curl -sL <url-of-old-config> | cardano-config migrate - > config.json
```

It prints the result in the format it read: a document that is valid JSON
comes out as JSON, and anything else comes out as YAML. YAML comments and
anchors do not survive, and keys come out sorted. `migrate` warns when the
input has comments, so that you can copy across the ones you want to keep.

The parser runs the same steps in memory on every file it reads, so an older
file still loads. It warns you when it has to. Run `migrate` to make the file
on disk match what the parser sees, and to stop the warnings.

This page lists every change `migrate` makes, so that you can audit the result
key by key. The lists come from
[`Cardano.Configuration.File.Migrate`](src/Cardano/Configuration/File/Migrate.hs).

## What it does not do

`migrate` changes the shape of the document and the spelling of its keys.
It keeps the values as you wrote them. It does not:

- fill in any default
- read, hash or validate a genesis file
- read any other file the configuration names
- reject a value that the parser will later reject

Run `cardano-config resolve --config <file>` afterwards to make sure that the
result parses.

## When it refuses

`migrate` refuses two documents outright:

| Document | Reason |
|----------|--------|
| One at a format version newer than this program writes | Migration never goes backwards. Upgrade `cardano-config` instead. |
| One whose sections name other files | Reading those files is what `migrate` does not do. Copy each file's contents in under its section key first. |

## The envelope

`migrate` puts the document in the envelope, and writes these top-level keys:

| Key | What it writes |
|-----|----------------|
| `$schema` | The URL of the current schema. It keeps the one you pinned when your document is already at the current version. |
| `Version` | The current format version. It keeps a version newer than that one. |
| `MinNodeVersion` | Yours, carried through. It never invents one. |
| `Configuration` | The configuration itself, with every component under its section key. |

A key that sits next to `Configuration` rather than inside it moves inside. If
the same key sits in both places, the one inside `Configuration` wins, and
`migrate` raises an `EnvelopeKeyCollision` warning.

## Renamed keys

`migrate` rewrites these names. The parser rejects the old ones.

| Old name | Current name |
|----------|--------------|
| `EnableRpc` | `EnableGrpc` |
| `RpcSocketPath` | `GrpcSocketPath` |
| `RpcListenAddress` | `GrpcListenAddress` |
| `RpcListenPort` | `GrpcListenPort` |
| `RpcTlsCertificateFile` | `GrpcTlsCertificateFile` |
| `RpcTlsPrivateKeyFile` | `GrpcTlsPrivateKeyFile` |
| `RpcTlsChainCertificateFiles` | `GrpcTlsChainCertificateFiles` |
| `TargetNumberOfRootPeers` | `DeadlineTargetNumberOfRootPeers` |
| `TargetNumberOfKnownPeers` | `DeadlineTargetNumberOfKnownPeers` |
| `TargetNumberOfEstablishedPeers` | `DeadlineTargetNumberOfEstablishedPeers` |
| `TargetNumberOfActivePeers` | `DeadlineTargetNumberOfActivePeers` |
| `TargetNumberOfKnownBigLedgerPeers` | `DeadlineTargetNumberOfKnownBigLedgerPeers` |
| `TargetNumberOfEstablishedBigLedgerPeers` | `DeadlineTargetNumberOfEstablishedBigLedgerPeers` |
| `TargetNumberOfActiveBigLedgerPeers` | `DeadlineTargetNumberOfActiveBigLedgerPeers` |
| `MempoolCapacityBytesOverride` | `CapacityBytesOverride` |

The sections lose their `Config` suffix. They are renamed only directly under
`Configuration`, where sections live:

| Old name | Current name |
|----------|--------------|
| `ConsensusConfig` | `Consensus` |
| `LocalConnectionsConfig` | `LocalConnections` |
| `MempoolConfig` | `Mempool` |
| `NetworkConfig` | `Network` |
| `ProtocolConfig` | `Protocol` |
| `StorageConfig` | `Storage` |
| `TestingConfig` | `Testing` |

These three are renamed only inside an `AcceptedConnectionsLimit` object,
because the names are too common to rewrite anywhere else:

| Old name | Current name |
|----------|--------------|
| `hardLimit` | `HardLimit` |
| `softLimit` | `SoftLimit` |
| `delay` | `Delay` |

If both the old and the current name are present at the same level, the
current name wins, and `migrate` raises a `RenamedKeyCollision` warning.
Reconcile the two by hand when the dropped value was the one you wanted.

## Dropped keys

A `MempoolCapacityBytesOverride` or `CapacityBytesOverride` whose value is the
string `"NoOverride"` is removed whole. Leaving the key out now means no
override, and `"NoOverride"` is no longer a valid value.

`migrate` also removes these keys. Nothing reads them now.

| Key | Why |
|-----|-----|
| `PBftSignatureThreshold` | Comes from consensus defaults. |
| `LastKnownBlockVersion-Major` | Comes from consensus defaults. |
| `LastKnownBlockVersion-Minor` | Comes from consensus defaults. |
| `LastKnownBlockVersion-Alt` | Comes from consensus defaults. |
| `ApplicationVersion` | The Byron software version number, now fixed in code. |
| `EnableP2P` | P2P is the only mode. |
| `Protocol` | The protocol selector no longer selects anything. Only a non-object value is dropped, because `Protocol` is also a section. |
| `MaxKnownMajorProtocolVersion` | The node never read it. |

These belonged to the old logging system, which `trace-dispatcher` replaced.
`migrate` drops them from the top level only, because the names are too common
to remove at any depth:

`UseTraceDispatcher`, `TurnOnLogging`, `TurnOnLogMetrics`, `defaultBackends`,
`defaultScribes`, `setupBackends`, `setupScribes`, `minSeverity`, `options`.

## Regrouped keys

Older files wrote many keys flat, at the top level. `migrate` moves each one
under the section that owns it. For example `ConsensusMode` moves under
`Consensus`, and `LedgerDB` moves under `Storage`.

Three groups change shape as well as place.

### Snapshot options

These keys sat directly under `LedgerDB`. They move into a nested `Snapshots`
object:

`SnapshotInterval`, `SlotOffset`, `RateLimit`, `MinDelay`, `MaxDelay`,
`NumOfDiskSnapshots`.

Inside `Snapshots`, two of them are renamed:

| Old name | Current name |
|----------|--------------|
| `SnapshotInterval` | `Interval` |
| `SlotOffset` | `Offset` |

The rename applies to the moved keys and to a `Snapshots` object already in
place. The names are too common to rewrite anywhere else. If both spellings
are present, the current name wins, with a `RenamedKeyCollision` warning.

If a `Snapshots` key is already present, it wins, and the flat keys are
dropped. `Snapshots` can be the string `"Mithril"`, which is a policy rather
than a set of values, so merging the two makes no sense.

### The LSM backend

`Backend: "V2LSM"`, with its optional `LSMDatabasePath` and `LSMExportPath`,
becomes the tagged form:

```json
"Backend": { "LSM": { "DatabasePath": "lsm", "ExportPath": "lsm-export" } }
```

`Backend: "V2InMemory"` stays as it is.

### Tracing

These keys move, unchanged, into an inline `HermodTracing` object:

`TraceOptions`, `TraceOptionForwarder`, `TraceOptionNodeName`,
`TraceOptionMetricsPrefix`, `TraceOptionResourceFrequency`,
`TraceOptionLedgerMetricsFrequency`, `TracePrometheusSimpleRun`.

`migrate` keeps their flat spelling rather than the inner one.
`TraceOptionResourceFrequency` and `TraceOptionLedgerMetricsFrequency` have no
inner counterpart, so a rename loses them.

A top-level `ApplicationName` becomes `HermodTracing.TraceOptionNodeName`. It
named the Byron software version, which nothing reads now, so the tracing node
name takes it over.

## Keys it does not recognize

`migrate` keeps a key that no parser claims, such as a typo, so that you lose
nothing. That key stays unrecognized, so the parser raises an
`UnrecognisedKeys` warning on the next read. Remove it by hand for a
configuration that reads without warnings.
