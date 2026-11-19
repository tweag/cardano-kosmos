-- | Reshape an existing configuration into the recommended envelope:
-- @{ $schema, Version, MinNodeVersion, Configuration }@, with every component
-- grouped under its section key inside @Configuration@.
--
-- It also rewrites the field names that changed, and drops the fields that were
-- removed, in the rename series that this library no longer parses (see
-- 'renamedFields'\/'removedFields'). This is deliberate: the parser rejects the
-- old names outright, and @migrate@ is the supported way to bring an older
-- configuration up to the current names.
--
-- Apart from those renames\/removals this is a purely structural migration: it
-- preserves the values as written and does /not/ fill in defaults or read
-- genesis files. It is meant to port a legacy flat or otherwise non-enveloped
-- configuration to the new layout; resolution and validation are left to a
-- subsequent @resolve@.
--
-- A configuration is one file, so a section that names a separate file instead
-- of holding an object cannot be migrated: reading that file is exactly what
-- @migrate@ does not do. Such a document is rejected with a
-- 'MigrationError' naming every section at fault (see 'renderMigrationError').
--
-- The reshaping (see 'migrate'):
--
--   * renamed keys are rewritten to their current names and removed keys are
--     dropped, at every depth (so the grouping below, which keys off the current
--     names, places them correctly). A mempool capacity override of
--     @"NoOverride"@ is dropped whole, since omitting the key means the same;
--   * @Version@ and @$schema@ are set to the current format version (see
--     'Cardano.Configuration.Schema.currentFormatVersion' and
--     'Cardano.Configuration.Schema.schemaTag'), so an older document comes out
--     at the current version. A document already at that version keeps a
--     @$schema@ it pins. A document declaring a /newer/ version keeps it, since
--     migration never goes backwards, and the reader rejects it. An existing
--     @MinNodeVersion@ is carried through;
--   * a section still carrying its old @Config@ suffix (@StorageConfig@,
--     @NetworkConfig@, …) is renamed to its current name (@Storage@,
--     @Network@, …) at the @Configuration@ level (see 'sectionRenames');
--   * a flat top-level property key is nested under the component section that
--     owns it (e.g. @ConsensusMode@ under @Consensus@, @LedgerDB@ under
--     @Storage@);
--   * the flat snapshot-option keys directly under @LedgerDB@ (@SnapshotInterval@,
--     @NumOfDiskSnapshots@, …) are gathered into a nested @LedgerDB.Snapshots@
--     object, where @SnapshotInterval@\/@SlotOffset@ are renamed to
--     @Interval@\/@Offset@, and the flat @V2LSM@ backend keys are folded into the
--     tagged @Backend: { "LSM": … }@ form the @LedgerDB@ codec reads (see
--     'nestSnapshotOptions'\/'renameSnapshotOptions'\/'nestBackend');
--   * the flat tracing keys that @trace-dispatcher@'s own parser reads (its
--     legacy format: @TraceOptions@, @TraceOptionForwarder@, …) are gathered
--     verbatim into an inline @HermodTracing@ object, a top-level @ApplicationName@
--     is collapsed into @HermodTracing.TraceOptionNodeName@ (the tracing node
--     name), and the obsolete keys of the old iohk-monitoring logging system
--     (@setupScribes@, @minSeverity@, … — no longer read by anything) are dropped
--     (see 'tracingLegacyKeys'\/'tracingObsoleteKeys');
--   * a section key, an existing @HermodTracing@ key, and any unrecognised key
--     are kept at the @Configuration@ level as-is (so nothing is silently
--     dropped);
--   * a top-level sibling of an existing @Configuration@ envelope (e.g. a stray
--     @ByronGenesisFile@) is merged into the body and regrouped, not dropped; if it
--     collides with a key already inside @Configuration@ the enveloped value wins
--     and an 'EnvelopeKeyCollision' warning is raised;
--   * where both the old and the current name of a renamed field are present the
--     current name wins, with a 'RenamedKeyCollision' warning;
--   * a document already in the envelope is reshaped idempotently.
module Cardano.Configuration.File.Migrate
  ( migrate
  , MigrationError (..)
  , renderMigrationError
  ) where

import Cardano.Configuration.File.Lint (ConfigWarning (..))
import Cardano.Configuration.File.Merge (mergeValues)
import Cardano.Configuration.Schema (componentPropertyNames, currentFormatVersion, schemaId)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import qualified Data.Text as T

-- | Migrate a raw configuration value to the envelope, together with the
-- non-fatal 'ConfigWarning's raised while doing so (a renamed field colliding with
-- its current name, or a top-level sibling colliding with a key inside the
-- envelope). A value that is not a JSON\/YAML object is returned unchanged, with no
-- warnings.
--
-- Renames and removals are applied first (recursively, over the whole document)
-- so that the subsequent structural grouping sees only current names.
--
-- A document whose sections do not all hold an object is rejected with a
-- 'MigrationError': see the module header.
migrate :: Value -> Either MigrationError (Value, [ConfigWarning])
migrate value = do
  let (renamed, renameWarnings) = renameLegacy value
  (reshaped, reshapeWarnings) <- reshape renamed
  pure (reshaped, renameWarnings <> reshapeWarnings)

-- | Why a document cannot be migrated.
newtype MigrationError
  = -- | These sections (the section name and the value found) hold something
    -- other than a configuration object. Older configurations split a section
    -- out into a separate file and named that file here.
    SectionsNotInline [(Text, Value)]
  deriving (Eq, Show)

-- | A human-readable rendering of a 'MigrationError'.
renderMigrationError :: MigrationError -> String
renderMigrationError (SectionsNotInline sections) =
  "the configuration is not held in one file: "
    <> intercalate ", " (map describe sections)
    <> ". A section holds its configuration object directly, so copy each of "
    <> "those files' contents in under its section key and migrate again."
 where
  describe (name, String path) = T.unpack name <> " names the file " <> show (T.unpack path)
  describe (name, _) = T.unpack name <> " is not an object"

-- | The field renames introduced in the current key-naming series, as
-- @(old, new)@. The parser only accepts the new names; @migrate@ rewrites the
-- old ones so a configuration written before the rename can be brought forward.
-- Matching is on the whole key (not a substring), so e.g.
-- @SyncTargetNumberOfRootPeers@ is left untouched by the @TargetNumberOf*@
-- entries. These names are globally unique, so they are rewritten at any depth;
-- the lower-cased 'acceptedConnectionsLimitFields' are handled separately
-- because those names are too generic to rewrite unconditionally.
renamedFields :: [(Text, Text)]
renamedFields =
  [ -- gRPC local-connection keys (were named Rpc)
    ("EnableRpc", "EnableGrpc")
  , ("RpcSocketPath", "GrpcSocketPath")
  , ("RpcListenAddress", "GrpcListenAddress")
  , ("RpcListenPort", "GrpcListenPort")
  , ("RpcTlsCertificateFile", "GrpcTlsCertificateFile")
  , ("RpcTlsPrivateKeyFile", "GrpcTlsPrivateKeyFile")
  , ("RpcTlsChainCertificateFiles", "GrpcTlsChainCertificateFiles")
  , -- Deadline peer targets (gained the Deadline prefix)
    ("TargetNumberOfRootPeers", "DeadlineTargetNumberOfRootPeers")
  , ("TargetNumberOfKnownPeers", "DeadlineTargetNumberOfKnownPeers")
  , ("TargetNumberOfEstablishedPeers", "DeadlineTargetNumberOfEstablishedPeers")
  , ("TargetNumberOfActivePeers", "DeadlineTargetNumberOfActivePeers")
  , ("TargetNumberOfKnownBigLedgerPeers", "DeadlineTargetNumberOfKnownBigLedgerPeers")
  , ("TargetNumberOfEstablishedBigLedgerPeers", "DeadlineTargetNumberOfEstablishedBigLedgerPeers")
  , ("TargetNumberOfActiveBigLedgerPeers", "DeadlineTargetNumberOfActiveBigLedgerPeers")
  , -- Mempool capacity override (lost the Mempool prefix)
    ("MempoolCapacityBytesOverride", "CapacityBytesOverride")
  ]

-- | The old and current names of the mempool capacity override. Under either one
-- @migrate@ drops a @"NoOverride"@ value: omitting the key is now the only way to
-- ask for no override (see 'renameLegacy').
mempoolCapacityOverrideKeys :: [Text]
mempoolCapacityOverrideKeys = ["MempoolCapacityBytesOverride", "CapacityBytesOverride"]

-- | The @AcceptedConnectionsLimit@ sub-keys that were lower-cased before the
-- rename. Their names (@delay@ especially) are too generic to rewrite wherever
-- they appear, so they are only rewritten inside an @AcceptedConnectionsLimit@
-- object (see 'renameLegacy').
acceptedConnectionsLimitFields :: [(Text, Text)]
acceptedConnectionsLimitFields =
  [ ("hardLimit", "HardLimit")
  , ("softLimit", "SoftLimit")
  , ("delay", "Delay")
  ]

-- | The fields removed in the current series. @migrate@ drops them (they are no
-- longer parsed): the Byron @LastKnownBlockVersion-*@ trio and
-- @PBftSignatureThreshold@ now come from consensus defaults rather than config;
-- @ApplicationVersion@ is the (now hard-coded) Byron software-version number;
-- @EnableP2P@ is the vestigial P2P switch (P2P is now the only mode);
-- @Protocol@ is the vestigial protocol selector (dropped only when it is not an
-- object, since @Protocol@ is also the name of a section); and @MaxKnownMajorProtocolVersion@
-- is a dead key the node never read at all. Unlike a genuine typo (which is kept,
-- so nothing is lost) these are known-obsolete keys, so @migrate@ removes them
-- rather than carry them forward as perpetual unrecognised-key warnings.
--
-- The software-version /name/ (@ApplicationName@) is handled separately (see
-- 'reshape'): a top-level @ApplicationName@ is collapsed into
-- @HermodTracing.TraceOptionNodeName@ rather than dropped here, since it must be
-- treated top-level only (the same name is a live trace-dispatcher field inside a
-- @HermodTracing@ object, which must survive at depth).
removedFields :: [Text]
removedFields =
  [ "PBftSignatureThreshold"
  , "LastKnownBlockVersion-Major"
  , "LastKnownBlockVersion-Minor"
  , "LastKnownBlockVersion-Alt"
  , "ApplicationVersion"
  , "EnableP2P"
  , "Protocol"
  , "MaxKnownMajorProtocolVersion"
  ]

-- | Rewrite renamed keys and drop removed keys, everywhere in the document,
-- accumulating a 'RenamedKeyCollision' warning wherever both the old and the
-- current name of a renamed field sit in the same object. Recurses through objects
-- and arrays; leaves scalars unchanged. The generic
-- 'acceptedConnectionsLimitFields' are rewritten only within an
-- @AcceptedConnectionsLimit@ object, and the flat snapshot options only within a
-- @LedgerDB@ object (see 'nestSnapshotOptions'), not wherever those names happen
-- to appear.
renameLegacy :: Value -> (Value, [ConfigWarning])
renameLegacy (Object o0) =
  (Object (KM.fromList pairs), collisionWarnings <> concatMap snd rekeyed)
 where
  -- A mempool capacity override of "NoOverride" means the same as leaving the key
  -- out, which is now the only way to say it, so the whole entry is dropped (under
  -- either name) before the renames below can see it.
  o = KM.filterWithKey (\k v -> not (isNoOverride k v)) o0
  isNoOverride k v = K.toText k `elem` mempoolCapacityOverrideKeys && v == String "NoOverride"
  present = [K.toText k | (k, _) <- KM.toList o]
  -- A rename whose target already exists here: keep the (current-name) value that
  -- is already present, drop the old-name one, and warn. Without this, KM.fromList
  -- below would keep whichever the list order happened to put last.
  collisions = [(old, new) | (old, new) <- renamedFields, old `elem` present, new `elem` present]
  collidingOld = map fst collisions
  collisionWarnings = [RenamedKeyCollision old new | (old, new) <- collisions]

  -- The surviving entries (old names that collide are dropped, removed keys too),
  -- each recursed into and rekeyed.
  rekeyed =
    [ rekey (k, v)
    | (k, v) <- KM.toList o
    , not (isRemoved k v)
    , K.toText k `notElem` collidingOld
    ]
  -- @Protocol@ is both a removed key (the legacy protocol selector, a string) and
  -- the current name of a section (an object), so only the former is dropped.
  isRemoved k v = K.toText k `elem` removedFields && not (K.toText k == "Protocol" && isObject v)
  pairs = map fst rekeyed
  rekey (k, v) =
    let (v', w) = renameLegacy v
        (v'', w') = scoped k v'
     in ((rename renamedFields k, v''), w <> w')
  -- Inside an AcceptedConnectionsLimit object, also rewrite its (generic) direct
  -- sub-keys; the recursion above has already handled any deeper nesting. Inside a
  -- LedgerDB object, gather the flat snapshot-option keys into a nested Snapshots
  -- object, rename the options inside it, and fold the flat V2LSM backend keys
  -- into the tagged Backend form (see 'nestSnapshotOptions'\/'renameSnapshotOptions'\/'nestBackend').
  scoped k v
    | K.toText k == "AcceptedConnectionsLimit" = (renameTopKeys acceptedConnectionsLimitFields v, [])
    | K.toText k == "LedgerDB" =
        let (v', w) = renameSnapshotOptions (nestSnapshotOptions v) in (nestBackend v', w)
    | otherwise = (v, [])
renameLegacy (Array a) =
  let results = fmap renameLegacy a
   in (Array (fmap fst results), foldMap snd results)
renameLegacy v = (v, [])

-- | Apply a rename table to the direct keys of an object (only), leaving
-- non-objects and unlisted keys unchanged.
renameTopKeys :: [(Text, Text)] -> Value -> Value
renameTopKeys table (Object o) =
  Object (KM.fromList [(rename table k, v) | (k, v) <- KM.toList o])
renameTopKeys _ v = v

-- | The snapshot options that were renamed when they moved into
-- @LedgerDB.Snapshots@, as @(old, new)@. The names are too generic to rewrite
-- anywhere else, so they are only rewritten inside a @LedgerDB.Snapshots@ object
-- (see 'renameSnapshotOptions').
snapshotOptionFields :: [(Text, Text)]
snapshotOptionFields =
  [ ("SnapshotInterval", "Interval")
  , ("SlotOffset", "Offset")
  ]

-- | The snapshot-option keys that legacy configs (and the node's own parser)
-- accept /flat/ directly under @LedgerDB@, but which cardano-config only reads
-- from a nested @LedgerDB.Snapshots@ object. These are the legacy spellings:
-- 'renameSnapshotOptions' then rewrites them to the current ones.
snapshotOptionKeys :: [Text]
snapshotOptionKeys =
  [ "SnapshotInterval"
  , "SlotOffset"
  , "RateLimit"
  , "MinDelay"
  , "MaxDelay"
  , "NumOfDiskSnapshots"
  ]

-- | Within a @LedgerDB@ object, move the flat snapshot-option keys
-- ('snapshotOptionKeys') into a nested @Snapshots@ object — the form
-- cardano-config's @LedgerDB@ codec reads. The other @LedgerDB@ keys (@Backend@,
-- @QueryBatchSize@, @LSMDatabasePath@, …) stay at the @LedgerDB@ level. If a
-- @Snapshots@ key is already present it wins (it is an explicit policy, possibly
-- the string @"Mithril"@), so the flat legacy keys are dropped rather than merged.
nestSnapshotOptions :: Value -> Value
nestSnapshotOptions (Object o)
  | KM.null flat = Object o
  | KM.member (K.fromText "Snapshots") rest = Object rest
  | otherwise = Object (KM.insert (K.fromText "Snapshots") (Object flat) rest)
 where
  flat = KM.filterWithKey (\k _ -> K.toText k `elem` snapshotOptionKeys) o
  rest = KM.filterWithKey (\k _ -> K.toText k `notElem` snapshotOptionKeys) o
nestSnapshotOptions v = v

-- | Within a @LedgerDB@ object whose @Snapshots@ is an options object, rewrite
-- the renamed options ('snapshotOptionFields') to their current names. Where both
-- the old and the current name are present the current one wins, with a
-- 'RenamedKeyCollision' warning. A @"Mithril"@ policy is left unchanged.
renameSnapshotOptions :: Value -> (Value, [ConfigWarning])
renameSnapshotOptions (Object ldb)
  | Just (Object snaps) <- KM.lookup "Snapshots" ldb =
      let present = [K.toText k | k <- KM.keys snaps]
          collisions = [(old, new) | (old, new) <- snapshotOptionFields, old `elem` present, new `elem` present]
          kept = KM.filterWithKey (\k _ -> K.toText k `notElem` map fst collisions) snaps
          renamed = KM.fromList [(rename snapshotOptionFields k, v) | (k, v) <- KM.toList kept]
       in ( Object (KM.insert "Snapshots" (Object renamed) ldb)
          , [RenamedKeyCollision old new | (old, new) <- collisions]
          )
renameSnapshotOptions v = (v, [])

-- | Within a @LedgerDB@ object, fold the legacy flat @V2LSM@ backend into the
-- tagged form: @Backend: "V2LSM"@ (+ optional @LSMDatabasePath@\/@LSMExportPath@)
-- becomes @Backend: { "LSM": { "DatabasePath": …, "ExportPath": … } }@. The
-- @V2InMemory@ string is left unchanged.
nestBackend :: Value -> Value
nestBackend (Object o)
  | KM.lookup "Backend" o == Just (String "V2LSM") =
      Object
        . KM.insert "Backend" (Object (KM.singleton "LSM" (Object lsm)))
        . KM.delete "LSMDatabasePath"
        . KM.delete "LSMExportPath"
        $ o
  | otherwise = Object o
 where
  lsm =
    KM.fromList $
      [("DatabasePath", v) | Just v <- [KM.lookup "LSMDatabasePath" o]]
        <> [("ExportPath", v) | Just v <- [KM.lookup "LSMExportPath" o]]
nestBackend v = v

-- | Look a key up in a rename table, returning it unchanged if absent.
rename :: [(Text, Text)] -> K.Key -> K.Key
rename table k = maybe k K.fromText (lookup (K.toText k) table)

-- | The flat top-level tracing keys that @trace-dispatcher@'s own parser reads
-- directly (its \"legacy\" configuration format — see @parseAsLegacy@ in
-- @Cardano.Logging.ConfigurationParser@). These belong inside @HermodTracing@:
-- @migrate@ gathers them into an inline @HermodTracing@ object /verbatim/, which
-- @resolve@ then hands to @trace-dispatcher@. We keep the flat names rather than
-- rewrite them to the inner (@Options@, @Forwarder@, …) spelling because two of
-- them — @TraceOptionResourceFrequency@ and @TraceOptionLedgerMetricsFrequency@ —
-- have no inner counterpart, so a full rename would silently drop them.
-- @TraceOptions@ is the only one the parser requires; the rest are optional, but
-- all are grouped when present.
tracingLegacyKeys :: [Text]
tracingLegacyKeys =
  [ "TraceOptions"
  , "TraceOptionForwarder"
  , "TraceOptionNodeName"
  , "TraceOptionMetricsPrefix"
  , "TraceOptionResourceFrequency"
  , "TraceOptionLedgerMetricsFrequency"
  , "TracePrometheusSimpleRun"
  ]

-- | The obsolete keys of the old iohk-monitoring\/katip logging system, fully
-- superseded by @trace-dispatcher@. Nothing reads them any more (not even the
-- @UseTraceDispatcher@ switch that once selected between the two systems), so
-- @migrate@ drops them. Unlike 'removedFields' these are dropped only at the top
-- level: their names (@options@, @minSeverity@) are too generic to remove
-- wherever they might appear at depth.
tracingObsoleteKeys :: [Text]
tracingObsoleteKeys =
  [ "UseTraceDispatcher"
  , "TurnOnLogging"
  , "TurnOnLogMetrics"
  , "defaultBackends"
  , "defaultScribes"
  , "setupBackends"
  , "setupScribes"
  , "minSeverity"
  , "options"
  ]

-- | The structural reshape into the envelope. A value that is not a
-- JSON\/YAML object is returned unchanged (with no warnings).
reshape :: Value -> Either MigrationError (Value, [ConfigWarning])
reshape (Object top)
  | not (null notInline) = Left (SectionsNotInline notInline)
  | otherwise =
      Right
        ( Object $
            KM.insert "$schema" schemaValue $
              KM.insert "Version" version $
                withMinNodeVersion $
                  KM.singleton "Configuration" (Object configuration)
        , collisionWarnings
        )
 where
  declared = KM.lookup "Version" top
  -- Write the current format version. A document declaring a newer one is left
  -- alone: migrate never downgrades, and the reader rejects it before getting
  -- here (see 'Cardano.Configuration.File.parseConfigurationFiles').
  version
    | Just v <- declared, isNewer v = v
    | otherwise = Number (fromIntegral currentFormatVersion)
  isNewer (Number n) = maybe False (> currentFormatVersion) (toBoundedInteger n)
  isNewer _ = False
  -- Keep a pinned $schema only when the version is unchanged. Once the version
  -- moves, the pinned URL describes a version the document no longer is.
  schemaValue
    | declared == Just version = fromMaybe currentSchema (KM.lookup "$schema" top)
    | otherwise = currentSchema
  currentSchema = String (schemaId "config.schema.json")
  -- Carry MinNodeVersion through if present; never invent one (it has no
  -- default, and its absence is itself a useful warning on the next parse).
  withMinNodeVersion = maybe id (KM.insert "MinNodeVersion") (KM.lookup "MinNodeVersion" top)

  -- The configuration body is the union of an already-enveloped document's
  -- Configuration object with the top-level keys that are not envelope
  -- annotations (a legacy\/non-enveloped document has no Configuration object, so
  -- the body is just those top-level keys). Nothing at the top level is dropped:
  -- a stray sibling such as @ByronGenesisFile@ is folded into the body and then
  -- regrouped under its section, rather than discarded.
  envelopeBody = case KM.lookup "Configuration" top of
    Just (Object c) -> c
    _ -> KM.empty
  siblings = KM.filterWithKey (\k _ -> K.toText k `notElem` envelopeAnnotations) top
  -- On a key present both as a sibling and inside Configuration, the value inside
  -- Configuration (the right\/\"later\" argument) wins; warn about the drop.
  body = KM.unionWith mergeValues siblings envelopeBody
  collisionWarnings =
    [EnvelopeKeyCollision (K.toText k) | k <- KM.keys siblings, k `KM.member` envelopeBody]
      <> [RenamedKeyCollision old new | (old, new) <- sectionCollisions]

  -- Rename the sections that carried a @Config@ suffix ('sectionRenames'). This
  -- happens only at this level, where sections live. Where both the old and the
  -- current name are present the current one wins, with a 'RenamedKeyCollision'
  -- warning, as for the other renames.
  sectionCollisions =
    [ (old, new)
    | (old, new) <- sectionRenames
    , K.fromText old `KM.member` body
    , K.fromText new `KM.member` body
    ]
  renamedBody =
    KM.fromList
      [ (rename sectionRenames k, v)
      | (k, v) <- KM.toList body
      , K.toText k `notElem` map fst sectionCollisions
      ]

  -- A section that does not hold an object cannot be migrated: the values it
  -- stands for are in another file, which migrate does not read. It is reported
  -- under the name the document used, old or current.
  notInline =
    [ (K.toText k, v)
    | (k, v) <- KM.toList body
    , K.toText k `elem` sectionNames <> map fst sectionRenames
    , not (isObject v)
    ]

  -- Group each body key under its component section. A flat property key nests
  -- under the section that owns it; a flat trace-dispatcher key nests (verbatim)
  -- under HermodTracing; a top-level @ApplicationName@ is collapsed into
  -- @HermodTracing.TraceOptionNodeName@ (the tracing node name — the obsolete
  -- Byron software-version name is repurposed as it, since nothing else reads it);
  -- an obsolete iohk-monitoring key is dropped; a section key, an existing
  -- HermodTracing or any unrecognised key stays at the Configuration level as-is.
  -- A mixed input (a section object plus some of its flat keys, or HermodTracing
  -- alongside flat tracing keys) is deep-merged. Every section present holds an
  -- object (checked above), so nesting never has to merge into a non-object.
  configuration = KM.foldrWithKey place KM.empty renamedBody
  place k v
    | key `elem` tracingObsoleteKeys = id
    | key `elem` tracingLegacyKeys = nestUnderAs "HermodTracing" k
    | key == "ApplicationName" = nestUnderAs "HermodTracing" (K.fromText "TraceOptionNodeName")
    | Just section <- lookup key propertyToSection = nestUnderAs section k
    | otherwise = keepFlat
   where
    key = K.toText k
    keepFlat = KM.insertWith mergeValues k v
    -- Nest @v@ under @section@ using @targetKey@ (the original key, except a
    -- top-level @ApplicationName@ is nested as @TraceOptionNodeName@).
    nestUnderAs section targetKey =
      KM.insertWith mergeValues (K.fromText section) (Object (KM.singleton targetKey v))
reshape v = Right (v, [])

-- | Whether a value is a JSON object.
isObject :: Value -> Bool
isObject Object{} = True
isObject _ = False

-- | Top-level keys that belong to the envelope, not to the configuration body.
envelopeAnnotations :: [Text]
envelopeAnnotations = ["$schema", "Version", "MinNodeVersion", "Configuration"]

-- | The sections renamed when they lost their @Config@ suffix, as @(old, new)@.
-- They are renamed only at the @Configuration@ level (see 'reshape'); the
-- current names are too generic to rewrite anywhere else.
sectionRenames :: [(Text, Text)]
sectionRenames =
  [ ("ConsensusConfig", "Consensus")
  , ("LocalConnectionsConfig", "LocalConnections")
  , ("MempoolConfig", "Mempool")
  , ("NetworkConfig", "Network")
  , ("ProtocolConfig", "Protocol")
  , ("StorageConfig", "Storage")
  , ("TestingConfig", "Testing")
  ]

-- | The name of every component section, so a section holding something other
-- than its configuration object can be reported.
sectionNames :: [Text]
sectionNames = map fst componentPropertyNames

-- | Each component property name mapped to the section that owns it. Every
-- property belongs to exactly one component (see 'componentPropertyNames').
propertyToSection :: [(Text, Text)]
propertyToSection =
  [(prop, section) | (section, props) <- componentPropertyNames, prop <- props]
