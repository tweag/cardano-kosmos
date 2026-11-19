-- | Orchestration of configuration-file parsing: it ties together the JSON
-- layering engine ("Cardano.Configuration.File.Merge"), the key linting
-- ("Cardano.Configuration.File.Lint") and the per-component parsers and genesis
-- readers, and re-exports the public surface.
module Cardano.Configuration.File
  ( -- * Configuration file
    NodeConfigurationFromFile (..)
  , parseConfigurationFiles
  , migrateConfiguration

    -- * Warnings
  , ConfigWarning (..)
  , renderConfigWarning

    -- * Defaults
  , componentDefaults
  , defaultConfiguration
  , decodeSection
  , mergeValues

    -- * Errors
  , ConfigurationParsingError (..)

    -- * Specific components configurations
  , StorageConfiguration (..)
  , ConsensusConfiguration (..)
  , ProtocolConfiguration (..)
  , NetworkConfiguration (..)
  , DiffusionMode (..)
  , PeerSharing (..)
  , AcceptedConnectionsLimit (..)
  , AcceptedConnectionsLimitConfig (..)
  , acceptedConnectionsLimitOf
  , LocalConnectionsConfig (..)
  , GrpcEndpoint (..)
  , GrpcTlsFiles (..)
  , defaultGrpcListenAddress
  , TestingConfiguration (..)
  , MempoolConfiguration (..)
  , TracingConfiguration (..)
  , TracingConfigSource (..)
  , TraceConfig
  , resolveTracingConfiguration
  , mkConfiguration

    -- * Resolving components
  , finalizeNetwork
  , finalizeLocalConnections
  , finalizeMempool
  , finalizeTesting

    -- * Network role
  , BlockProducerOrRelay (..)
  ) where

import Cardano.Configuration.File.Consensus
import Cardano.Configuration.File.Error (ConfigurationParsingError (..))
import Cardano.Configuration.File.Lint
  ( ConfigWarning (..)
  , configWarnings
  , renderConfigWarning
  )
import Cardano.Configuration.File.Mempool
import Cardano.Configuration.File.Merge
  ( declaredFormatVersion
  , decodeSection
  , decodeValueFile
  , defaultConfiguration
  , mergeValues
  , parseSection
  , roleIndependentDefaults
  , runCodec
  , splitEnvelope
  )
import Cardano.Configuration.File.Migrate (migrate, renderMigrationError)
import Cardano.Configuration.File.Network
import Cardano.Configuration.File.Protocol
import Cardano.Configuration.File.Storage
import Cardano.Configuration.File.Testing
import Cardano.Configuration.File.Tracing
  ( TracingConfigSource (..)
  , TracingConfiguration (..)
  , mkConfiguration
  , resolveTracingConfiguration
  )
import Cardano.Configuration.Genesis
  ( GenesisReadError
  , genesisErrorFile
  , readGenesisFile
  , resolveExperimentalGenesis
  )
import Cardano.Configuration.Genesis.Byron (ByronGenesisConfig, readByronGenesisConfig)
import Cardano.Configuration.Genesis.Injection
  ( InjectionSlot (..)
  , injectionProblems
  , injectionSlots
  , missingInjectionFiles
  , renderInjectionSlot
  )
import Cardano.Configuration.Schema (componentPropertyNames, currentFormatVersion)
import qualified Cardano.Crypto.ProtocolMagic as Byron
import Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis)
import Cardano.Ledger.BaseTypes
  ( StrictMaybe (..)
  , fromSMaybe
  , maybeToStrictMaybe
  , strictMaybeToMaybe
  )
import Cardano.Ledger.Conway.Genesis (ConwayGenesis)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis)
import Cardano.Ledger.Shelley.Genesis (ShelleyGenesis)
import Cardano.Logging.Types (TraceConfig)
import Control.Exception (throwIO)
import Control.Monad (when)
import Data.Aeson (FromJSON, Value)
import qualified Data.Aeson.Key as K
import Data.Aeson.Types (JSONPathElement (..))
import qualified Data.Text as T
import GHC.Generics (Generic)
import GHC.Stack
import System.FilePath (takeDirectory, (</>))

-- | The configuration file, read: what it said, plus everything reading it
-- required the library to fetch.
--
-- The sections are /not/ here as parsed components. Which defaults apply
-- depends on the node's role, which comes from the command line, so the
-- sections stay as the user wrote them ('userConfiguration') and are read once
-- the defaults are layered under them, at resolution (see
-- 'Cardano.Configuration.resolveConfiguration'). What is here is what could not
-- wait: the genesis files, which the configuration names and this library
-- reads and hash-checks, and the tracing configuration.
data NodeConfigurationFromFile = NodeConfigurationFromFile
  { minNodeVersion :: StrictMaybe T.Text
  -- ^ The minimum @cardano-node@ version expected to run this configuration,
  -- taken from the optional top-level @MinNodeVersion@ key (a sibling of
  -- @Version@, present in both the enveloped and legacy forms). Purely
  -- informational here — it is recorded for a consumer to check.
  --
  -- Caveat: this is /not/ carried into the resolved
  -- t'Cardano.Configuration.NodeConfiguration'; 'resolveConfiguration' drops it.
  -- It lives only on this file-parse result, so a consumer that wants to act on
  -- it must read it here, before resolving.
  , storageConfiguration :: StorageConfiguration StrictMaybe
  , consensusConfiguration :: ConsensusConfiguration StrictMaybe
  , protocolConfiguration :: ProtocolConfiguration StrictMaybe
  , networkConfiguration :: NetworkConfiguration StrictMaybe
  , localConnectionsConfig :: LocalConnectionsConfig StrictMaybe
  , testingConfiguration :: TestingConfiguration StrictMaybe
  , mempoolConfiguration :: MempoolConfiguration StrictMaybe
  -- ^ Each component as the configuration file wrote it, with no defaults
  -- filled in. A field the file leaves unset is @SNothing@ here.
  --
  -- Which defaults apply depends on the node's role, which comes from the
  -- command line, so these cannot carry them. 'resolveConfiguration' layers
  -- the role's default configuration under the file and reads each component
  -- again from the result. Read these to see what the file itself said.
  , userConfiguration :: Value
  -- ^ The same @Configuration@ object, as JSON, brought to the current format
  -- by @migrate@. Resolution merges the role's default configuration under it
  -- and reads the components from the merge.
  --
  -- The merge is by key and recurses into nested objects, so a file that sets
  -- one field of @LedgerDB@ keeps the defaults of the others. Merging the
  -- typed components field by field would replace whole nested objects
  -- instead, which is why the JSON is kept.
  , tracingConfiguration :: TraceConfig
  -- ^ The tracing configuration referenced by the top-level @HermodTracing@ key,
  -- resolved by @trace-dispatcher@'s own parser ('resolveTracingConfiguration'):
  -- a @HermodTracing@ file path is read from that file, an inline object is read
  -- directly. The value is passed on as the configuration wrote it, with no
  -- default of ours under it: what it leaves unset, @trace-dispatcher@ fills
  -- from its own fallback, so a tracing configuration is always present. Its
  -- schema is owned by @trace-dispatcher@, not described here (see
  -- 'TracingConfiguration').
  , byronGenesisConfig :: ByronGenesisConfig
  -- ^ The parsed Byron genesis (read from the @ByronGenesisFile@).
  , shelleyGenesisConfig :: ShelleyGenesis
  -- ^ The parsed Shelley genesis (read from the @ShelleyGenesisFile@).
  , alonzoGenesisConfig :: AlonzoGenesis
  -- ^ The parsed Alonzo genesis (read from the @AlonzoGenesisFile@).
  , conwayGenesisConfig :: ConwayGenesis
  -- ^ The parsed Conway genesis (read from the @ConwayGenesisFile@).
  , experimentalGenesisConfig :: StrictMaybe DijkstraGenesis
  -- ^ The experimental (Dijkstra) genesis, when there is one in play.
  , genesisInjectionRoot :: FilePath
  -- ^ The directory the ledger resolves genesis initial-data injection files
  -- against: the directory holding the Shelley genesis file (which is /not/ in
  -- general the directory holding the configuration file).
  --
  -- A genesis @extraConfig@ names its injection files by @FsPath@ — a list of
  -- path segments resolved against a @HasFS@ the consumer supplies — so the
  -- mount point is the configuration's to decide. Recording it here means a
  -- consumer building the node's @SomeHasFS@ does not have to re-derive it; see
  -- "Cardano.Configuration.Genesis.Injection".
  }
  deriving (Generic, Show)

-- | The defaults to document in the schema: those the two role configurations
-- agree on, keyed by section. A value that depends on the role (the deadline
-- peer targets, @PeerSharing@) is not a default a configuration has before its
-- role is known, so it is left out. These come from the same files resolution
-- merges, so the documented defaults are the applied ones.
componentDefaults :: [(T.Text, Value)]
componentDefaults =
  [ (name, defaults)
  | (name, _) <- componentPropertyNames
  , Just defaults <- [lookup name roleIndependentDefaults]
  ]

-- | Parse the configuration file, together with any non-fatal
-- 'ConfigWarning's (unrecognised keys, or a document that had to be migrated).
--
-- The whole configuration is held in that one file, apart from the genesis
-- files and the optional @HermodTracing@ file, which are read from the paths it
-- gives.
--
-- The configuration may be given in JSON or YAML. Failures are thrown as a
-- 'ConfigurationParsingError', identifying the offending file, section and
-- location. The warnings are /returned/, not emitted: the caller decides whether
-- to print them, log them, or treat them as fatal (see 'renderConfigWarning').
parseConfigurationFiles ::
  HasCallStack => FilePath -> IO (NodeConfigurationFromFile, [ConfigWarning])
parseConfigurationFiles cfgFile = do
  rawValue <- decodeValueFile cfgFile
  (mainValue, migrationWarnings) <- migrateConfiguration (Just cfgFile) rawValue
  -- migrate has brought the document to the current version, so there is one
  -- body parser rather than one per version.
  (_version, minNodeVer, configValue) <- splitEnvelope mainValue
  let warnings = migrationWarnings <> configWarnings configValue
      root = takeDirectory cfgFile
  config <- parseConfigurationBody root minNodeVer configValue
  pure (config, warnings)

-- | Bring a configuration document to the current format version, together
-- with the warnings doing so raised. Failures are thrown as a
-- 'ConfigurationParsingError', naming the file when one is given.
migrateConfiguration ::
  -- | The file the document was read from, for error reporting.
  Maybe FilePath ->
  -- | The document, as decoded from the file.
  Value ->
  IO (Value, [ConfigWarning])
migrateConfiguration cfgFile rawValue = do
  -- Every document is run through 'migrate' before parsing, so an already-enveloped
  -- configuration that still uses a pre-rename field name (or carries a stray
  -- top-level sibling) is brought up to the current shape too — not only a
  -- non-enveloped one. Migration is idempotent, so a configuration already in the
  -- canonical form is left untouched; a 'MigratedToCurrentFormat' warning is raised
  -- only when migration actually changed the document (@migrated /= rawValue@, an
  -- order-independent comparison). 'migrate' also returns its own warnings for the
  -- fields it had to reconcile. If the migrated document still cannot be parsed, the
  -- parse error surfaces as usual.
  -- The declared version is read before migrating, because migrating rewrites
  -- it. A version this library does not write is rejected here rather than
  -- misread as the current one.
  declared <- declaredFormatVersion rawValue
  when (declared > currentFormatVersion) $
    throwIO $
      ConfigurationParsingError
        (maybeToStrictMaybe cfgFile)
        SNothing
        [Key "Version"]
        ( "unsupported configuration version: "
            <> show declared
            <> ". This cardano-config writes version "
            <> show currentFormatVersion
            <> ", so upgrade cardano-config to read it."
        )
  -- A document migrate cannot reshape — one whose sections name separate files
  -- rather than holding their configuration — is rejected here, naming them.
  (mainValue, migrateWarnings) <- case migrate rawValue of
    Left err ->
      throwIO $
        ConfigurationParsingError
          (maybeToStrictMaybe cfgFile)
          SNothing
          []
          (renderMigrationError err)
    Right ok -> pure ok
  let migrationWarnings =
        -- An outdated version is reported on its own. migrate always rewrites
        -- such a document, so the generic warning would only repeat it.
        [ MigratedToCurrentFormat
        | mainValue /= rawValue
        , declared == currentFormatVersion
        ]
          <> [OutdatedFormatVersion declared currentFormatVersion | declared < currentFormatVersion]
          <> migrateWarnings
  pure (mainValue, migrationWarnings)

-- | Read a configuration object at the current format version: check that
-- every section parses, and read the genesis files and tracing configuration
-- it names.
parseConfigurationBody ::
  -- | The directory the genesis and tracing paths are resolved against.
  FilePath ->
  -- | The optional top-level @MinNodeVersion@ annotation.
  Maybe T.Text ->
  -- | The configuration object.
  Value ->
  IO NodeConfigurationFromFile
parseConfigurationBody root minNodeVer configValue = do
  -- Every section is read here, as the file wrote it, so a section the
  -- parsers cannot read is reported against the file while it is in hand.
  -- Resolution reads them again from the merge of the role defaults with this
  -- configuration, because only then is the role known.
  storage <- parseSection @(StorageConfiguration StrictMaybe) configValue "Storage"
  consensus <- parseSection @(ConsensusConfiguration StrictMaybe) configValue "Consensus"
  protocol <- parseSection @(ProtocolConfiguration StrictMaybe) configValue "Protocol"
  network <- parseSection @(NetworkConfiguration StrictMaybe) configValue "Network"
  localConnections <-
    parseSection @(LocalConnectionsConfig StrictMaybe) configValue "LocalConnections"
  mempool <- parseSection @(MempoolConfiguration StrictMaybe) configValue "Mempool"
  testing <- parseSection @(TestingConfiguration StrictMaybe) configValue "Testing"
  -- The @HermodTracing@ value is captured (as a file path or an inline object)
  -- and then handed to trace-dispatcher's own parser, which resolves it to a
  -- 'TraceConfig' — reading the referenced file, or the inline object directly.
  -- Unlike every other component this one takes no default from @defaults\/@:
  -- tracing belongs to @trace-dispatcher@, which has a fallback of its own, and
  -- layering ours under it would only be a second opinion on the same question.
  -- The @HermodTracing@ block in @defaults\/@ is there to show a reader what
  -- that fallback amounts to, not to be applied.
  tracing <- runCodec "Tracing" configValue
  traceConfig <- resolveTracingConfiguration root tracing
  -- The genesis files referenced by the configuration are read and decoded
  -- here, so that JSON resolution happens entirely within this library.
  let byronCfg = byronGenesis protocol
  byronGenesisData <-
    readByronGenesisOrThrow
      root
      (toByronReqNetworkMagic (byronReqNetworkMagic byronCfg))
      (byronGenesisFile byronCfg)
  shelleyGenesisData <-
    readEraGenesisOrThrow root "ShelleyGenesisFile" (shelleyGenesis protocol)
  -- The injection files a genesis @extraConfig@ references are resolved by the
  -- ledger against the Shelley genesis directory, so that is the root recorded
  -- (and checked) here — see "Cardano.Configuration.Genesis.Injection".
  let injectionRoot = takeDirectory (root </> hashed (shelleyGenesis protocol))
  alonzoGenesisData <-
    readEraGenesisOrThrow root "AlonzoGenesisFile" (alonzoGenesis protocol)
  conwayGenesisData <-
    readEraGenesisOrThrow root "ConwayGenesisFile" (conwayGenesis protocol)
  -- The experimental (Dijkstra) genesis is gated on the
  -- @ExperimentalHardForksEnabled@ testing flag. The flag is off unless the
  -- configuration turns it on, here and in the defaults alike, so reading it
  -- before the defaults are merged gives the same answer.
  --
  -- A @DijkstraGenesisFile@ named while the flag is off is passed over in
  -- silence: the file is not opened, and nothing is said about it. Turning the
  -- flag on hard-forks the node onto an experimental era, which is a decision
  -- coordinated across a network, never one taken because a tool suggested it.
  -- A warning here would read as that suggestion.
  let experimentalRef = strictMaybeToMaybe (experimentalGenesis testing)
      experimentalEnabled = fromSMaybe False (experimentalHardForksEnabled testing)
  experimentalGenesisData <-
    if experimentalEnabled
      then readExperimentalGenesisOrThrow root experimentalRef
      else pure Nothing
  checkInjectionOrThrow injectionRoot shelleyGenesisData conwayGenesisData
  pure $
    NodeConfigurationFromFile
      { minNodeVersion = maybeToStrictMaybe minNodeVer
      , storageConfiguration = storage
      , consensusConfiguration = consensus
      , protocolConfiguration = protocol
      , networkConfiguration = network
      , localConnectionsConfig = localConnections
      , testingConfiguration = testing
      , mempoolConfiguration = mempool
      , userConfiguration = configValue
      , tracingConfiguration = traceConfig
      , byronGenesisConfig = byronGenesisData
      , shelleyGenesisConfig = shelleyGenesisData
      , alonzoGenesisConfig = alonzoGenesisData
      , conwayGenesisConfig = conwayGenesisData
      , experimentalGenesisConfig = maybeToStrictMaybe experimentalGenesisData
      , genesisInjectionRoot = injectionRoot
      }

-- | Convert this library's 'RequiresNetworkMagic' to the Byron ledger's, used
-- when reading the Byron genesis. Absent in the configuration defaults to
-- requiring no magic.
toByronReqNetworkMagic :: StrictMaybe RequiresNetworkMagic -> Byron.RequiresNetworkMagic
toByronReqNetworkMagic = \case
  SJust RequiresMagic -> Byron.RequiresMagic
  SJust RequiresNoMagic -> Byron.RequiresNoMagic
  SNothing -> Byron.RequiresNoMagic

-- | Read, hash-check and decode an (aeson) era genesis file referenced by the
-- protocol configuration, throwing a 'ConfigurationParsingError' on failure.
readEraGenesisOrThrow ::
  FromJSON a => FilePath -> String -> Hashed FilePath -> IO a
readEraGenesisOrThrow root fileKey (Hashed file mHash) = do
  result <- readGenesisFile mHash (root </> file)
  case result of
    Left err -> throwIO (genesisReadErrorAt "Protocol" fileKey err)
    Right genesis -> pure genesis

-- | Read, hash-check and decode the Byron genesis (canonical JSON), throwing a
-- 'ConfigurationParsingError' on failure.
readByronGenesisOrThrow ::
  FilePath -> Byron.RequiresNetworkMagic -> Hashed FilePath -> IO ByronGenesisConfig
readByronGenesisOrThrow root rnm (Hashed file expected) = do
  result <- readByronGenesisConfig rnm expected (root </> file)
  case result of
    Left err ->
      throwIO $
        ConfigurationParsingError
          (SJust (root </> file))
          (SJust "Protocol")
          [Key "ByronGenesisFile"]
          err
    Right cfg -> pure cfg

-- | Read and decode the experimental (Dijkstra) genesis referenced by the
-- testing configuration, turning a read\/hash\/decode failure into a
-- 'ConfigurationParsingError' under the @Testing@ section.
--
-- Whether to read it at all is the caller's decision: it is called only when
-- @ExperimentalHardForksEnabled@ is on (see 'experimentalGenesisConfig').
readExperimentalGenesisOrThrow ::
  FilePath -> Maybe (Hashed FilePath) -> IO (Maybe DijkstraGenesis)
readExperimentalGenesisOrThrow root mRef = do
  result <- resolveExperimentalGenesis root mRef
  case result of
    Left err -> throwIO (genesisReadErrorAt "Testing" "DijkstraGenesisFile" err)
    Right genesis -> pure genesis

-- | Check the genesis initial-data injection the geneses ask for, throwing a
-- 'ConfigurationParsingError' attributed to the genesis key at fault: a field
-- must name one source, not both the legacy field and its @extraConfig@
-- counterpart; injection is for test networks only; and a referenced injection
-- file must exist.
--
-- The files' hashes are /not/ checked: the ledger verifies them as it streams
-- each file, and re-hashing here would mean reading a potentially very large
-- file twice. Everything checked here is something @cardano-ledger@ would
-- otherwise throw much later, while the node builds its initial ledger state.
checkInjectionOrThrow :: FilePath -> ShelleyGenesis -> ConwayGenesis -> IO ()
checkInjectionOrThrow injectionRoot sg cg = do
  missing <- missingInjectionFiles injectionRoot (injectionSlots sg cg)
  let problems =
        injectionProblems sg cg
          <> [ (s, "references the injection file " <> path <> ", which does not exist")
             | (s, path) <- missing
             ]
  case problems of
    [] -> pure ()
    (slot, why) : _ ->
      throwIO $
        ConfigurationParsingError
          SNothing
          (SJust "Protocol")
          [Key (K.fromString (slotGenesisFile slot))]
          (renderInjectionSlot slot <> " " <> why)

-- | Render a 'GenesisReadError' as a 'ConfigurationParsingError' attributed to
-- the given section and file key.
genesisReadErrorAt :: String -> String -> GenesisReadError -> ConfigurationParsingError
genesisReadErrorAt section fileKey err =
  ConfigurationParsingError
    (maybeToStrictMaybe (genesisErrorFile err))
    (SJust section)
    [Key (K.fromString fileKey)]
    (show err)
