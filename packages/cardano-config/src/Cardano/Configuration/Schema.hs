-- | JSON Schemas for the configuration components, derived directly from the
-- autodocodec codecs (so they cannot drift from the parsers).
--
-- Each schema records which keys are required, which are optional, and the
-- defaults applied at parse time (e.g. the @Backend@ or @EnableCSJ@ defaults).
-- Keys that are merely left unset for the node to default appear as optional
-- without a value.
--
-- The raw codec schemas are post-processed (see 'publish') to be as useful as
-- possible to validators, editors and documentation generators:
--
--   * autodocodec's @$comment@ annotations become @description@s;
--   * file-path strings (tagged via 'filePathFormatMarker') gain a
--     @"format": "path"@ annotation, so a path is distinguishable from an
--     arbitrary string;
--   * string-enumeration @oneOf@\/@anyOf@s (of bare @const@s) collapse to a
--     @{ "type": "string", "enum": [..] }@, so every such field declares a type;
--   * every schema and property gains a @title@, and every document an @$id@, so
--     tools that key off them (e.g. @jsonschema2md@) render names rather than
--     @Untitled@\/@undefined@.
--
-- Tracing is not a component of its own: it is surfaced only as the single
-- top-level @HermodTracing@ key, which the node's tracing system
-- (hermod/@trace-dispatcher@) reads. Its contents are neither parsed nor
-- described here; the authoritative tracing schema lives in that package.
module Cardano.Configuration.Schema
  ( -- * Whole configuration
    configSchema
  , recognisedKeys
  , componentPropertyNames

    -- * Default values
  , configSchemaWithDefaults

    -- * Versioning
  , currentFormatVersion
  , packageFormatVersion
  , schemaTag
  , schemaId
  ) where

import Autodocodec.Schema (jsonSchemaViaCodec)
import Cardano.Configuration.Common (defaultGrpcListenAddress, filePathFormatMarker)
import Cardano.Configuration.File.Consensus (ConsensusConfiguration)
import Cardano.Configuration.File.Mempool (MempoolConfiguration)
import Cardano.Configuration.File.Network (LocalConnectionsConfig, NetworkConfiguration)
import Cardano.Configuration.File.Protocol (ProtocolConfiguration)
import Cardano.Configuration.File.Storage (StorageConfiguration)
import Cardano.Configuration.File.Testing (TestingConfiguration)
import Cardano.Configuration.File.Tracing (TracingConfiguration)
import Cardano.Ledger.BaseTypes (StrictMaybe)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Version (versionBranch)
import Paths_cardano_config (version)

-- The raw schemas as emitted by autodocodec-schema (descriptions in @$comment@,
-- no @$schema@). Used internally for merging; 'publish' makes them public.
rawStorageSchema, rawConsensusSchema, rawProtocolSchema, rawNetworkSchema :: Value
rawLocalConnectionsSchema, rawMempoolSchema, rawTestingSchema, rawTracingSchema :: Value
rawStorageSchema = toJSON (jsonSchemaViaCodec @(StorageConfiguration StrictMaybe))
rawConsensusSchema = toJSON (jsonSchemaViaCodec @(ConsensusConfiguration StrictMaybe))
rawProtocolSchema = toJSON (jsonSchemaViaCodec @(ProtocolConfiguration StrictMaybe))
rawNetworkSchema = toJSON (jsonSchemaViaCodec @(NetworkConfiguration StrictMaybe))
rawLocalConnectionsSchema = toJSON (jsonSchemaViaCodec @(LocalConnectionsConfig StrictMaybe))
rawMempoolSchema = toJSON (jsonSchemaViaCodec @(MempoolConfiguration StrictMaybe))
rawTestingSchema = toJSON (jsonSchemaViaCodec @(TestingConfiguration StrictMaybe))
rawTracingSchema = toJSON (jsonSchemaViaCodec @TracingConfiguration)

-- The components that are sections of their own. Tracing is deliberately
-- absent: it is not a section, only the single top-level @HermodTracing@ key
-- (see 'hermodTracingProps').
rawComponentSchemas :: [(Text, Value)]
rawComponentSchemas =
  [ (name, withConstraints name raw)
  | (name, raw) <-
      [ ("Storage", rawStorageSchema)
      , ("Consensus", rawConsensusSchema)
      , ("Protocol", rawProtocolSchema)
      , ("Network", rawNetworkSchema)
      , ("LocalConnections", rawLocalConnectionsSchema)
      , ("Mempool", rawMempoolSchema)
      , ("Testing", rawTestingSchema)
      ]
  ]

--------------------------------------------------------------------------------
-- Cross-field constraints

-- | The rules a component's parser enforces across /several/ of its keys, as the
-- JSON Schema keywords that say the same thing. autodocodec derives a schema key
-- by key, so a rule spanning two of them has to be attached here.
--
-- Only rules whose inputs are all read from the configuration file belong here.
-- \"Enabling gRPC needs somewhere to listen\" does not: a @--socket-path@ can
-- satisfy it, and a validator sees only the file.
--
-- Each entry holds at most a @dependencies@ object and an @allOf@ array (see
-- 'mergeConstraints').
--
-- These state /what validates/, so they are frozen with the format version (see
-- 'currentFormatVersion').
componentConstraints :: Text -> KM.KeyMap Value
componentConstraints = \case
  -- The gRPC server has exactly one listener, so a unix socket path excludes the
  -- TCP keys, an address or a TLS credential needs a port, and the certificate
  -- and its private key are given together. Mirrors
  -- 'Cardano.Configuration.Common.grpcEndpointObjectCodec'.
  "LocalConnections" ->
    dependencies
      [ ("GrpcSocketPath", excludes tcpEndpointKeys)
      , ("GrpcListenAddress", requires ["GrpcListenPort"])
      , ("GrpcTlsCertificateFile", requires ["GrpcTlsPrivateKeyFile", "GrpcListenPort"])
      , ("GrpcTlsPrivateKeyFile", requires ["GrpcTlsCertificateFile", "GrpcListenPort"])
      ,
        ( "GrpcTlsChainCertificateFiles"
        , requires ["GrpcTlsCertificateFile", "GrpcTlsPrivateKeyFile"]
        )
      ]
  -- The three mempool timeouts are one coupled default: all set, or all unset.
  -- Mirrors 'Cardano.Configuration.File.Mempool.finalizeMempool'.
  "Mempool" ->
    dependencies
      [ ("MempoolTimeoutSoft", requires ["MempoolTimeoutHard", "MempoolTimeoutCapacity"])
      , ("MempoolTimeoutHard", requires ["MempoolTimeoutSoft", "MempoolTimeoutCapacity"])
      , ("MempoolTimeoutCapacity", requires ["MempoolTimeoutSoft", "MempoolTimeoutHard"])
      ]
  -- A genesis file is never taken on trust, so its hash comes with it. Enabling
  -- the experimental eras requires the genesis to run them from.
  -- Mirrors 'Cardano.Configuration.File.Protocol.optionalHashedGenesisObjectCodec'
  -- and 'Cardano.Configuration.File.Testing.finalizeTesting'.
  "Testing" ->
    mergeConstraints
      ( dependencies
          [ ("DijkstraGenesisFile", requires ["DijkstraGenesisHash"])
          , ("DijkstraGenesisHash", requires ["DijkstraGenesisFile"])
          ]
      )
      (allOf [ifThen experimentalErasEnabled (requiredKeys dijkstraGenesisKeys)])
  _ -> KM.empty
 where
  tcpEndpointKeys =
    [ "GrpcListenAddress"
    , "GrpcListenPort"
    , "GrpcTlsCertificateFile"
    , "GrpcTlsPrivateKeyFile"
    , "GrpcTlsChainCertificateFiles"
    ]
  dijkstraGenesisKeys = ["DijkstraGenesisFile", "DijkstraGenesisHash"]
  experimentalErasEnabled =
    object
      [ "properties" .= object ["ExperimentalHardForksEnabled" .= object ["const" .= True]]
      , "required" .= (["ExperimentalHardForksEnabled"] :: [Text])
      ]

-- | @{ "dependencies": { .. } }@: each key, when present, constrains the object.
dependencies :: [(Text, Value)] -> KM.KeyMap Value
dependencies ds =
  KM.singleton "dependencies" (Object (KM.fromList [(K.fromText k, v) | (k, v) <- ds]))

-- | @{ "allOf": [ .. ] }@.
allOf :: [Value] -> KM.KeyMap Value
allOf = KM.singleton "allOf" . toJSON

-- | A @dependencies@ entry in its key-list form: these keys must be present too.
requires :: [Text] -> Value
requires = toJSON

-- | A @dependencies@ entry in its schema form: none of these keys may be present.
excludes :: [Text] -> Value
excludes ks = object ["not" .= object ["anyOf" .= map (\k -> requiredKeys [k]) ks]]

-- | @{ "required": [ .. ] }@.
requiredKeys :: [Text] -> Value
requiredKeys ks = object ["required" .= ks]

-- | @{ "if": .., "then": .. }@.
ifThen :: Value -> Value -> Value
ifThen c t = object ["if" .= c, "then" .= t]

-- | Merge two constraint sets: @dependencies@ objects union key by key, @allOf@
-- arrays concatenate. Used to attach a component's rules to its schema.
mergeConstraints :: KM.KeyMap Value -> KM.KeyMap Value -> KM.KeyMap Value
mergeConstraints = KM.unionWith merge
 where
  merge (Object a) (Object b) = Object (KM.union a b)
  merge (Array a) (Array b) = Array (a <> b)
  merge a _ = a

-- | Attach a component's cross-field constraints to its schema, so the
-- component's section of the whole-configuration schema carries them.
withConstraints :: Text -> Value -> Value
withConstraints name (Object o) = Object (mergeConstraints (componentConstraints name) o)
withConstraints _ v = v

-- | Tracing is not a component/section of its own; it contributes exactly one
-- top-level key, @HermodTracing@, which the node's tracing system reads (and
-- which @cardano-config@ neither parses nor describes further). We take that
-- key's schema straight from the TracingConfiguration codec so it stays in step
-- with the parser.
hermodTracingProps :: KM.KeyMap Value
hermodTracingProps = properties rawTracingSchema

-- | The JSON Schema of the whole configuration — the current form, and the one
-- the @schema@ subcommand prints: the @{ $schema, Version, MinNodeVersion,
-- Configuration }@ envelope, with each component inline under its section key
-- inside @Configuration@, all in one document.
--
-- The sections sit inside @Configuration@ and nowhere else, so this schema
-- describes the current form and only that: a legacy document, whose component
-- keys sit at the top level, fails it, which is what @migrate@ is for. Tracing is not a section; it is the @HermodTracing@
-- key beside them, whose contents are neither parsed nor described here.
configSchema :: Value
configSchema = configSchemaFrom rawComponentSchemas

-- | 'configSchema', built from the given component schemas, so the defaulted
-- variant ('configSchemaWithDefaults') can feed in component schemas already
-- carrying their @default@s.
configSchemaFrom :: [(Text, Value)] -> Value
configSchemaFrom components =
  publish "Cardano node configuration" "config.schema.json" $
    object
      [ "$comment" .= configDescription
      , "type" .= ("object" :: Text)
      , -- The schema requires exactly what 'Cardano.Configuration.File.Migrate.migrate'
        -- always writes, which is what makes a document canonical: the
        -- @$schema@ it follows, the @Version@ it is at, and the
        -- @Configuration@ that is the configuration. A document missing any of
        -- them is one migration would change, so the parser raises
        -- @OutdatedFormatVersion@ or @MigratedToCurrentFormat@ on it, and this
        -- schema rejects it. @MinNodeVersion@ is not required, because
        -- migration never invents one: a document without it is canonical and
        -- parses silently.
        "required" .= (["$schema", "Version", "Configuration"] :: [Text])
      , "properties" .= Object envelopeProps
      ]
 where
  envelopeProps =
    KM.fromList
      [ ("$schema", schemaRef)
      , ("Version", versionRef)
      , ("MinNodeVersion", minNodeVersionRef)
      , ("Configuration", configurationBody)
      ]
  -- The configuration itself: every section, plus the lone HermodTracing key.
  -- 'publish' gives each one its title, as it does for every other property.
  configurationBody =
    object
      [ "$comment"
          .= ( "The configuration itself: each component given inline under its section key,"
                 <> " plus the HermodTracing key." ::
                 Text
             )
      , "type" .= ("object" :: Text)
      , "properties" .= Object (sectionProps <> hermodTracingProps)
      ]
  sectionProps = KM.fromList [(K.fromText name, raw) | (name, raw) <- components]

configDescription :: Text
configDescription =
  T.unwords
    [ "The cardano-node configuration, held in one file."
    , "The document is the { $schema, Version, MinNodeVersion, Configuration } envelope,"
    , "and Configuration gives each component inline under its section key (e.g. Storage)."
    , "The mandatory genesis files are supplied through the Protocol section."
    ]

versionRef :: Value
versionRef =
  object
    [ "type" .= ("integer" :: Text)
    , "minimum" .= (1 :: Int)
    , "$comment"
        .= ( "The configuration format version (currently "
               <> T.pack (show currentFormatVersion)
               <> "). It is the first component of the cardano-config version, which states how far"
               <> " the parser goes: cardano-config-"
               <> T.pack (show currentFormatVersion)
               <> ".y.z.v parses every version up to and including "
               <> T.pack (show currentFormatVersion)
               <> ", and writes "
               <> T.pack (show currentFormatVersion)
               <> "." ::
               Text
           )
    ]

minNodeVersionRef :: Value
minNodeVersionRef =
  object
    [ "type" .= ("string" :: Text)
    , "$comment"
        .= ( "The minimum cardano-node version expected to run this configuration."
               <> " A top-level annotation (a sibling of Version), recorded for a consumer to check." ::
               Text
           )
    ]

-- | The @$schema@ annotation: the URL of the schema this configuration follows,
-- a sibling of @Version@. Lets editors and validators pick up the schema, and
-- lets a file declare which schema it conforms to. Defaults to this schema's own
-- published URL, pinned to the tag of the format version it describes (see
-- 'schemaTag').
schemaRef :: Value
schemaRef =
  object
    [ "type" .= ("string" :: Text)
    , "default" .= schemaId "config.schema.json"
    , "$comment"
        .= ( "URL of the JSON Schema this configuration follows (the standard $schema annotation),"
               <> " a sibling of Version, for editors and validators."
               <> " Pinned to the vN tag of the format version it describes, so it identifies one"
               <> " exact schema; point it at a later vN to validate against that version." ::
               Text
           )
    ]

-- | Every key the parsers recognise at the @Configuration@ level: the section
-- keys, the tracing keys and the envelope keys. Used to detect unrecognised
-- keys (a typo, or a key of some component this library does not know). A
-- component's own property names are recognised only inside its section, so
-- they are deliberately /not/ listed here; migration has already moved any of
-- them found at this level.
recognisedKeys :: [Text]
recognisedKeys =
  nub $
    envelopeKeys <> sectionKeys <> tracingKeys
 where
  envelopeKeys = ["$schema", "Version", "MinNodeVersion", "Configuration"]
  sectionKeys = map fst componentPropertyNames
  tracingKeys = map K.toText (KM.keys hermodTracingProps)

-- | The property names of each component (the keys it reads at the top level in
-- the legacy flat form), keyed by the component's section name. Used by
-- migration to group a flat key under the section that owns it. Every property
-- name belongs to exactly one component.
componentPropertyNames :: [(Text, [Text])]
componentPropertyNames =
  [(name, map K.toText (KM.keys (properties s))) | (name, s) <- rawComponentSchemas]

--------------------------------------------------------------------------------
-- Post-processing

-- | The JSON Schema draft these schemas target. autodocodec-schema emits
-- draft-07-compatible schemas, and the keywords we add here (@enum@, @format@,
-- @title@, @$id@) are likewise draft-07 core, so validators such as ajv accept
-- them by default.
draftURI :: Text
draftURI = "http://json-schema.org/draft-07/schema#"

-- | The newest configuration format version: the @Version@ that
-- 'Cardano.Configuration.File.Migrate.migrate' stamps on a document, and the
-- version of the schemas under @schemas\/@.
--
-- It is the /first component/ of the package version, and that component states
-- how far the parser goes: @cardano-config-X.y.z.v@ parses every format version up
-- to and including @X@, and writes @X@. The other three components carry changes
-- to the Haskell code alone, so the schemas are not changed without bumping the
-- first. 'packageFormatVersion' and the test suite keep the two from drifting.
--
-- Note this is the /newest/ version, not the whole accepted set. Versions @1@
-- through @X@ all stay readable, because @parseConfigurationFiles@ migrates a
-- document to @X@ before parsing it. Each new version therefore costs one
-- migration step, not one parse path.
currentFormatVersion :: Int
currentFormatVersion = 2

-- | The newest format version implied by the package version: its first
-- component, with the pre-1.0 series (@0.x.x.x@) counting as heading for version
-- 1. Should equal 'currentFormatVersion'; the test suite asserts it, so bumping
-- the package's first component fails the build until the format version and its
-- parse path follow.
packageFormatVersion :: Int
packageFormatVersion = case versionBranch version of
  major : _ -> max 1 major
  [] -> 1

-- | The git tag the published schema URLs point at: @v\<n\>@ for format version
-- @n@, so version 1's schemas are served from the @v1@ tag.
--
-- These tags are their own family, one per format version, cut alongside the
-- major release that introduces the version (@v2@ with @cardano-config-2.0.0.0@).
-- Keying the URL on the format version rather than on a release version is what
-- gives a schema one canonical address: every @cardano-config-1.x.x.x@ release
-- serves the same version-1 document, so it should not have a different URL per
-- release. The tag makes it immutable, so a configuration's @$schema@ identifies
-- exactly one schema, for good.
--
-- /Immutable/ means the constraints are immutable: what a document must satisfy
-- in order to be valid cannot change under a tag. Annotations may be corrected —
-- @default@, @description@, @title@ — because they do not affect validation, so a
-- wrong default is fixed in a @1.x.x.x@ release rather than held back for a new
-- format version. A change to /what validates/ is the one that needs a new format
-- version, and gets its own tag.
--
-- This leaves the schema stricter than the parser, deliberately:
-- 'Cardano.Configuration.File.Migrate.migrate' runs on every document, so a
-- configuration written in a superseded spelling still loads (raising
-- @MigratedToCurrentFormat@) while failing validation against the schema, which
-- documents the canonical form alone.
--
-- The tag must exist for the URL to resolve. @v1@ was cut alongside
-- @cardano-config-1.1.0.0@. @v2@ is cut alongside @cardano-config-2.0.0.0@, so
-- the URLs the schemas carry today resolve only once that tag exists.
schemaTag :: Text
schemaTag = "v" <> T.pack (show currentFormatVersion)

-- | The @$id@ for a committed schema file: where it is published in the repo, at
-- the tag of the format version it describes (see 'schemaTag').
schemaId :: FilePath -> Text
schemaId file =
  "https://raw.githubusercontent.com/IntersectMBO/cardano-config/"
    <> schemaTag
    <> "/schemas/"
    <> T.pack file

-- | Make a raw codec schema friendly to validators, editors and documentation
-- generators. See the module header for the full list of transformations.
publish :: Text -> FilePath -> Value -> Value
publish title idFile raw =
  case transform raw of
    Object o ->
      Object $
        KM.insert "$schema" (String draftURI) $
          KM.insert "$id" (String (schemaId idFile)) $
            KM.insertWith keepExisting "title" (String title) o
    other -> other
 where
  keepExisting _new old = old

-- | The recursive transformation applied throughout a schema tree.
transform :: Value -> Value
transform = \case
  Object o ->
    Object
      . titleBranches
      . collapseStringEnum
      . typeConst
      . extractPathFormat
      . constrainProperties
      . defaultProperties
      . titleProperties
      $ KM.fromList [(rename k, transform v) | (k, v) <- KM.toList o]
  Array a -> Array (transform <$> a)
  other -> other
 where
  rename k = if k == "$comment" then "description" else k

-- | Give each member of a @properties@ map a @title@ equal to its key (unless it
-- already has one), so documentation tools name it rather than show "Untitled".
titleProperties :: KM.KeyMap Value -> KM.KeyMap Value
titleProperties o =
  case KM.lookup "properties" o of
    Just (Object props) -> KM.insert "properties" (Object (KM.mapWithKey addTitle props)) o
    _ -> o
 where
  addTitle k (Object c) | not (KM.member "title" c) = Object (KM.insert "title" (String (K.toText k)) c)
  addTitle _ v = v

-- | Narrow a property whose codec derives a wider schema than the parser
-- accepts. Keyed by the property name, which is unique across the
-- configuration, so it is matched at any depth.
--
-- @Interval@ (the snapshot interval) is a 'Data.Word.Word64', so its derived schema admits 0,
-- which @snapshotIntervalCodec@ rejects. Like 'componentConstraints' this
-- states what validates, so it is frozen with the format version.
constrainProperties :: KM.KeyMap Value -> KM.KeyMap Value
constrainProperties o =
  case KM.lookup "properties" o of
    Just (Object props) -> KM.insert "properties" (Object (KM.mapWithKey narrow props)) o
    _ -> o
 where
  narrow k (Object c)
    | Just extra <- lookup (K.toText k) propertyConstraints = Object (KM.union extra c)
  narrow _ v = v

-- | The property-level narrowings applied by 'constrainProperties'.
propertyConstraints :: [(Text, KM.KeyMap Value)]
propertyConstraints =
  [ ("Interval", KM.singleton "minimum" (Number 1))
  ]

-- | Attach the 'propertyDefaults' to the properties they name. A @default@
-- already taken from the defaults files wins, since those state what the
-- bottom layer supplies.
defaultProperties :: KM.KeyMap Value -> KM.KeyMap Value
defaultProperties o =
  case KM.lookup "properties" o of
    Just (Object props) -> KM.insert "properties" (Object (KM.mapWithKey annotate props)) o
    _ -> o
 where
  annotate k (Object c)
    | Just d <- lookup (K.toText k) propertyDefaults =
        Object (KM.insertWith keepExisting "default" d c)
  annotate _ v = v
  keepExisting _new old = old

-- | A @default@ the library applies that neither the codec nor the defaults
-- files can state. Keyed by the property name, which is unique across the
-- configuration, so it is matched at any depth.
--
-- Unlike 'propertyConstraints' these are annotations rather than constraints.
-- They say what a consumer gets when the key is absent, not what validates,
-- so correcting one does not need a new format version.
propertyDefaults :: [(Text, Value)]
propertyDefaults =
  [ -- The gRPC listener binds to loopback when a port is given without an
    -- address. This cannot live in the defaults files: a value there reaches
    -- every configuration, and an address without a port is rejected, so
    -- every configuration that sets no port would stop parsing. It is applied
    -- by 'Cardano.Configuration.Common.defaultGrpcListenAddress', which is
    -- also where this value comes from, so the two cannot drift.
    ("GrpcListenAddress", String (T.pack (show defaultGrpcListenAddress)))
  ]

-- | Lift the file-path sentinel ('filePathFormatMarker') carried in a
-- @description@ into a @"format": "path"@ annotation, stripping the sentinel.
extractPathFormat :: KM.KeyMap Value -> KM.KeyMap Value
extractPathFormat o =
  case KM.lookup "description" o of
    Just (String d)
      | let ls = T.splitOn "\n" d
      , filePathFormatMarker `elem` ls ->
          let kept = filter (/= filePathFormatMarker) ls
              withFormat = KM.insert "format" (String "path") o
           in if null kept
                then KM.delete "description" withFormat
                else KM.insert "description" (String (T.intercalate "\n" kept)) withFormat
    _ -> o

-- | Give each branch of a @oneOf@\/@anyOf@ union a @title@ (unless it already has
-- one) derived from its @const@ value or its @type@, so documentation tools name
-- the alternatives rather than show "Untitled".
titleBranches :: KM.KeyMap Value -> KM.KeyMap Value
titleBranches o = foldr titleUnion o ["anyOf", "oneOf"]
 where
  titleUnion key m = case KM.lookup key m of
    Just (Array bs) -> KM.insert key (Array (fmap addTitle bs)) m
    _ -> m
  addTitle (Object b)
    | not (KM.member "title" b)
    , Just t <- branchTitle b =
        Object (KM.insert "title" (String t) b)
  addTitle v = v
  -- Name a branch by its const value or its type; leave structural branches
  -- (e.g. a bare @{ required: [..] }@ constraint) untitled.
  branchTitle b = case KM.lookup "const" b of
    Just (String s) -> Just s
    _ -> case KM.lookup "type" b of
      Just (String t) -> Just (T.toTitle t)
      _ -> Nothing

-- | Give a bare @const@ schema the @type@ implied by its value, so even a single
-- enumerated alternative (e.g. the @"Mithril"@ branch of @Snapshots@) declares a
-- type rather than leaving it undefined.
typeConst :: KM.KeyMap Value -> KM.KeyMap Value
typeConst o =
  case KM.lookup "const" o of
    Just v | not (KM.member "type" o), Just t <- constType v -> KM.insert "type" (String t) o
    _ -> o
 where
  constType (String _) = Just "string"
  constType (Bool _) = Just "boolean"
  constType (Number _) = Just "number"
  constType _ = Nothing

-- | Collapse a @oneOf@\/@anyOf@ whose branches are all bare string @const@s into
-- @{ "type": "string", "enum": [..] }@, so the field declares a single type.
collapseStringEnum :: KM.KeyMap Value -> KM.KeyMap Value
collapseStringEnum o =
  case branches >>= traverse stringConst of
    Just consts@(_ : _) ->
      KM.insert "type" (String "string") $
        KM.insert "enum" (toJSON consts) $
          KM.delete "oneOf" (KM.delete "anyOf" o)
    _ -> o
 where
  branches = case (KM.lookup "oneOf" o, KM.lookup "anyOf" o) of
    (Just (Array a), _) -> Just (toList a)
    (_, Just (Array a)) -> Just (toList a)
    _ -> Nothing
  stringConst (Object b)
    | Just (String s) <- KM.lookup "const" b
    , all (\k -> k == "const" || k == "type") (KM.keys b) =
        Just s
  stringConst _ = Nothing

-- | The @properties@ map of a schema object, if any.
properties :: Value -> KM.KeyMap Value
properties (Object o) | Just (Object p) <- KM.lookup "properties" o = p
properties _ = KM.empty

--------------------------------------------------------------------------------
-- Default values
--
-- Defaults are not part of the codecs; they live entirely in the @defaults\/@
-- data files (the base layer the resolver merges). The schema therefore takes
-- them as input — the caller loads the per-component @defaults\/<Component>.json@
-- and passes them in — so the documented defaults are exactly the ones the
-- library applies, with a single source of truth.

-- | 'configSchema' with the @default@ of every key filled in from the
-- per-component defaults (keyed by component name), matching the per-component
-- schemas.
configSchemaWithDefaults :: [(Text, Value)] -> Value
configSchemaWithDefaults defs =
  let defsMap = Map.fromList defs
   in configSchemaFrom
        [ (name, maybe raw (`withDefaults` raw) (Map.lookup name defsMap))
        | (name, raw) <- rawComponentSchemas
        ]

-- | Fill in the @default@ keywords of a schema from a defaults object (a config
-- object keyed by the configuration keys). Each value is placed at
-- @properties.<key>.default@, recursing into a nested object only where the
-- schema itself has @properties@ there, so leaf defaults land on leaf
-- properties. An object default for a property without @properties@ (e.g. one
-- that is an @anyOf@ of a string and an object, like @Snapshots@) is kept whole as
-- that property's @default@, rather than inventing @properties@ next to the
-- @anyOf@.
withDefaults :: Value -> Value -> Value
withDefaults (Object defs) (Object schema)
  | Just (Object props) <- KM.lookup "properties" schema =
      Object (KM.insert "properties" (Object (KM.foldrWithKey place props defs)) schema)
 where
  place k v acc = KM.insert k (withDefaults v (fromMaybe (Object KM.empty) (KM.lookup k acc))) acc
withDefaults v (Object schema) = Object (KM.insert "default" v schema)
withDefaults v _ = object ["default" .= v]
