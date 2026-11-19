-- | Parse the configuration for a @cardano-node@, combining both the
-- t'Cardano.Configuration.CliArgs' and the
-- t'Cardano.Configuration.NodeConfigurationFromFile'
--
-- The configuration file can be either in JSON or in YAML format.
module Cardano.Configuration
  ( -- * Configuration
    NodeConfiguration (..)
  , resolveConfiguration
  , resolveConfigurationWith
  , resolveConfigurationFromFile

    -- ** Consistency checks
  , ConfigCheck (..)
  , CheckSeverity (..)
  , defaultConfigChecks
  , ConfigResolutionError (..)

    -- ** Storage
  , File.StorageConfiguration (..)
  , File.LedgerDbConfiguration (..)
  , File.SnapshotPolicy (..)
  , File.SnapshotOptions (..)
  , File.mithrilSnapshotOptions
  , File.resolveSnapshotPolicy
  , File.LedgerDbBackendSelector (..)
  , File.NodeDatabasePaths (..)

    -- ** Consensus
  , File.ConsensusConfiguration (..)
  , File.ConsensusMode (..)
  , File.GenesisConfigFlags (..)

    -- ** Protocol
  , File.ProtocolConfiguration (..)
  , File.ByronGenesisConfiguration (..)
  , File.RequiresNetworkMagic (..)
  , File.Hashed (..)
  , File.MaybeHashed (..)
  , CLI.Credentials (..)
  , CLI.emptyCredentials
  , CLI.KESSource (..)

    -- ** Network
  , File.NetworkConfiguration (..)
  , File.DiffusionMode (..)
  , File.PeerSharing (..)
  , File.AcceptedConnectionsLimit (..)
  , File.AcceptedConnectionsLimitConfig (..)
  , File.acceptedConnectionsLimitOf
  , File.LocalConnectionsConfig (..)
  , File.GrpcEndpoint (..)
  , File.GrpcTlsFiles (..)
  , File.defaultGrpcListenAddress
  , File.ResponderCoreAffinityPolicy (..)
  , File.TxSubmissionLogicVersion (..)

    -- ** Testing
  , File.TestingConfiguration (..)
  , CLI.TracerConnection (..)

    -- ** Mempool
  , File.MempoolConfiguration (..)

    -- ** Genesis

    -- | The era genesis types of the resolved 'NodeConfiguration' fields. The
    --     later eras come from @cardano-ledger@ (@ShelleyGenesis@, @AlonzoGenesis@,
    --     @ConwayGenesis@, @DijkstraGenesis@); only Byron's is defined here.
  , ByronGenesisConfig

    -- ** Genesis initial-data injection

    -- | A test network's genesis can hand the ledger its initial funds, stake
    --     pools, stake credentials, delegations and DReps out of separate JSON
    --     files, named under the genesis @extraConfig@ key and streamed by the
    --     ledger rather than decoded into the genesis value (see
    --     "Cardano.Configuration.Genesis.Injection"). Those file references are
    --     resolved against a filesystem the /consumer/ supplies, so
    --     'genesisInjectionRoot' records which directory that is and
    --     'nodeConfigurationInjectionFS' builds the @SomeHasFS@ to pass on to
    --     @protocolInfoCardano@.
  , nodeConfigurationInjectionFS
  , nodeConfigurationInjections
  , Injection.InjectionSlot (..)
  , Injection.InjectionSource (..)
  , Injection.injectionHasFS
  , Injection.injectionMountPoint

    -- ** Operational
  , CLI.ShutdownOn (..)

    -- * CLI

    -- | The 'CLI.CliArgs' type is exported here, but its constructor and field
    -- selectors are not (they would clash with the same-named 'NodeConfiguration'
    -- fields). Consumers that build or override a 'CLI.CliArgs' directly should
    -- import "Cardano.Configuration.CliArgs", which the public library also
    -- re-exposes; 'CLI.defaultCliArgs' is a convenient starting point.
  , CLI.CliArgs
  , CLI.parseCliArgs
  , CLI.defaultCliArgs

    -- ** Reusable option parsers
  , CLI.parseConfigFile
  , CLI.parseTopologyFile
  , CLI.parseSocketPath
  , CLI.parseValidateDB
  , CLI.parseEnableGrpc
  , CLI.parseGrpcEndpoint
  , CLI.parseGrpcSocketPath
  , CLI.parseGrpcListenAddress
  , CLI.parseGrpcListenPort
  , CLI.parseGrpcTlsFiles
  , CLI.parseCredentials
  , CLI.parseKESSource
  , CLI.parseHostIPv4Addr
  , CLI.parseHostIPv6Addr
  , CLI.parsePort
  , CLI.parseTracerSocketMode
  , CLI.parseShutdownIPC
  , CLI.parseShutdownOn
  , CLI.parseNodeAddress
  , CLI.parseHostPort

    -- * Configuration file
  , File.NodeConfigurationFromFile
  , File.TracingConfiguration (..)
  , File.TracingConfigSource (..)
  , File.TraceConfig
  , File.parseConfigurationFiles
  , File.ConfigWarning (..)
  , File.renderConfigWarning
  , File.ConfigurationParsingError (..)
  ) where

import qualified Cardano.Configuration.CliArgs as CLI
import qualified Cardano.Configuration.Common as File
import qualified Cardano.Configuration.File as File
import Cardano.Configuration.File.Consensus
import qualified Cardano.Configuration.File.Consensus as File
import qualified Cardano.Configuration.File.Network as File
import qualified Cardano.Configuration.File.Protocol as File
import qualified Cardano.Configuration.File.Storage as File
import Cardano.Configuration.Genesis.Byron (ByronGenesisConfig)
import Cardano.Configuration.Genesis.Injection (injectionHasFS, injectionSlots)
import qualified Cardano.Configuration.Genesis.Injection as Injection
import Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), isSJust, strictMaybe)
import Cardano.Ledger.Conway.Genesis (ConwayGenesis)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis)
import Cardano.Ledger.Shelley.Genesis (ShelleyGenesis)
import Control.Applicative ((<|>))
import Control.Exception (Exception (..))
import Data.Aeson (FromJSON)
import Data.Functor.Identity
import Data.IP
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import GHC.Stack (HasCallStack)
import Network.Socket
import Ouroboros.Network.PeerSelection.Governor.Types
  ( PeerSelectionTargets
  , sanePeerSelectionTargets
  )
import System.FS.API (SomeHasFS)
import System.Posix.Types

-- | The complete configuration for a cardano-node, combining the configuration
-- file and the cli arguments
data NodeConfiguration = NodeConfiguration
  { storageConfiguration :: File.StorageConfiguration Identity
  , consensusConfiguration :: File.ConsensusConfiguration Identity
  , protocolConfiguration :: File.ProtocolConfiguration Identity
  , networkConfiguration :: File.NetworkConfiguration Identity
  , localConnectionsConfig :: File.LocalConnectionsConfig Identity
  , testingConfiguration :: File.TestingConfiguration Identity
  , mempoolConfiguration :: File.MempoolConfiguration Identity
  , tracingConfiguration :: File.TraceConfig
  -- ^ The tracing configuration resolved from the top-level @HermodTracing@ key
  -- by @trace-dispatcher@'s parser (see 'File.resolveTracingConfiguration'),
  -- with the @HermodTracing@ defaults from @defaults\/@ layered underneath it.
  -- Unlike every other component it is resolved while parsing, not here: it is
  -- read from files, and the two roles' tracing defaults are identical, so
  -- nothing about it waits on the role.
  -- Carried through unchanged from the file-parse result so consumers get the
  -- parsed 'File.TraceConfig'.
  , byronGenesisConfig :: ByronGenesisConfig
  -- ^ The parsed Byron genesis.
  , shelleyGenesisConfig :: ShelleyGenesis
  -- ^ The parsed Shelley genesis.
  , alonzoGenesisConfig :: AlonzoGenesis
  -- ^ The parsed Alonzo genesis.
  , conwayGenesisConfig :: ConwayGenesis
  -- ^ The parsed Conway genesis.
  , experimentalGenesisConfig :: StrictMaybe DijkstraGenesis
  -- ^ The parsed experimental (Dijkstra) genesis, when there is one in play.
  , genesisInjectionRoot :: FilePath
  -- ^ The directory the ledger resolves genesis initial-data injection files
  --     against: the directory holding the Shelley genesis file. Pass it to
  --     'Injection.injectionHasFS' to build the filesystem @protocolInfoCardano@
  --     wants; see "Cardano.Configuration.Genesis.Injection".
  , configFilePath :: FilePath
  , topologyFile :: FilePath
  , validateDatabase :: Bool
  , credentials :: CLI.Credentials
  , hostAddr :: StrictMaybe IPv4
  , hostIPv6Addr :: StrictMaybe IPv6
  , port :: StrictMaybe PortNumber
  , tracerSocket :: StrictMaybe CLI.TracerConnection
  , shutdownIPC :: StrictMaybe Fd
  , shutdownOnTarget :: StrictMaybe CLI.ShutdownOn
  }
  deriving Show

-- | How a failed 'ConfigCheck' is treated: 'CheckError' aborts resolution with
-- a 'ConfigResolutionError'; 'CheckWarning' lets resolution succeed but surfaces
-- a 'File.ConsistencyWarning' alongside the resolved configuration.
data CheckSeverity
  = CheckError
  | CheckWarning
  deriving (Eq, Show)

-- | A single consistency check over a resolved 'NodeConfiguration': an
-- invariant that must hold, together with a description used when it fails and
-- a severity deciding whether a failure is fatal or merely a warning.
-- Consumers can define their own and pass them to 'resolveConfigurationWith'.
data ConfigCheck = ConfigCheck
  { checkSeverity :: CheckSeverity
  -- ^ Whether a failure aborts resolution ('CheckError') or is surfaced as a
  --     non-fatal warning ('CheckWarning').
  , checkDescription :: String
  -- ^ A description of the invariant, phrased as what must hold (used in the
  --     error or warning message when it does not).
  , checkHolds :: NodeConfiguration -> Bool
  -- ^ The invariant. 'True' means the configuration satisfies it.
  }

-- | A failure while resolving the configuration.
data ConfigResolutionError
  = -- | One or more consistency checks failed on a configuration whose
    -- individual values were each well-formed. Carries the descriptions of the
    -- violated checks.
    ViolatedChecks (NonEmpty String)
  | -- | A section could not be decoded from the merge of the shipped defaults
    -- with the configuration. Carries the section and the decode error.
    --
    -- This is a decode failure, not an inconsistency, and it is separate
    -- because it says something different about who is at fault. Every section
    -- is decoded from the configuration's own text at parse time, with the same
    -- codec resolution uses, so by the time resolution decodes the merge the
    -- configuration's own sections have already decoded. What is left to fail
    -- is the shipped defaults or the merge itself, which is to say a fault in
    -- this library rather than in the file.
    SectionDecodeError String String
  deriving (Eq, Show)

instance Exception ConfigResolutionError where
  displayException = \case
    ViolatedChecks violations ->
      intercalate
        "\n"
        ("The configuration is inconsistent:" : ["  - " <> v | v <- NE.toList violations])
    SectionDecodeError section msg ->
      "Could not decode the "
        <> section
        <> " section of the resolved configuration: "
        <> msg
        <> "\nThe configuration parsed on its own, so this is a fault in cardano-config"
        <> " rather than in the file."

-- | The built-in consistency checks applied by 'resolveConfiguration'. Exported
-- so consumers can extend them, e.g.
-- @'resolveConfigurationWith' (defaultConfigChecks <> myChecks)@.
defaultConfigChecks :: [ConfigCheck]
defaultConfigChecks =
  [ ConfigCheck
      CheckError
      ( "Enabling the gRPC endpoint requires a node socket path: the gRPC server serves every "
          <> "request over the node-to-client socket, so it needs one whichever endpoint it listens on"
      )
      ( \nc ->
          let lcc = localConnectionsConfig nc
           in not (runIdentity (File.enableGrpc lcc))
                || isSJust (File.socketPath lcc)
      )
  , ConfigCheck
      CheckWarning
      ( "the Mithril snapshot policy under the V2LSM backend has no LSMExportPath, so the LSM backend "
          <> "cannot export snapshots; set an LSMExportPath, or use the V2InMemory backend"
      )
      -- Mithril is matched by value, not by the "Mithril" name: the defaults
      -- spell the Mithril values out, and a partial policy may fill in to them.
      ( \nc ->
          let ldb = runIdentity (File.ledgerDbConfiguration (storageConfiguration nc))
           in case File.snapshots ldb of
                SJust policy
                  | File.resolveSnapshotPolicy policy == File.mithrilSnapshotOptions ->
                      case File.backendSelector ldb of
                        SNothing -> True -- defaults to V2InMemory, which satisfies Mithril
                        SJust File.V2InMemory -> True
                        SJust (File.V2LSM _ exportPath) -> isSJust exportPath
                _ -> True
      )
  , ConfigCheck
      CheckError
      ( "AcceptedConnectionsLimit's SoftLimit must be no greater than its HardLimit: the node "
          <> "starts delaying new connections at the soft limit and refuses them at the hard one"
      )
      ( \nc ->
          let l = File.acceptedConnectionsLimitOf (networkConfiguration nc)
           in File.acceptedConnectionsSoftLimit l <= File.acceptedConnectionsHardLimit l
      )
  , peerSelectionTargetsCheck
      "Deadline"
      (File.deadlinePeerSelectionTargets . networkConfiguration)
  , peerSelectionTargetsCheck
      "Sync"
      (Just . File.syncPeerSelectionTargets . networkConfiguration)
  ]

-- | A peer selection target set must be one @ouroboros-network@ will accept.
-- Its governor states 'sanePeerSelectionTargets' over the targets it is handed,
-- but as a 'Control.Exception.assert', which @-O@ compiles out: a release node
-- does not reject such a set, it runs peer selection on targets the governor's
-- own logic assumes cannot occur. We reject it here instead, where the
-- configuration is still in front of the operator.
--
-- The predicate is @ouroboros-network@'s own, so the two cannot disagree about
-- what is acceptable. It answers only yes or no, so the description states the
-- whole invariant rather than the clause that failed. The group name
-- (@Deadline@ or @Sync@) prefixes the field names, so it says which seven
-- fields are meant.
--
-- A group the configuration does not fully state is not checked: there is no
-- target set to judge. That can only be the deadline group, whose targets have
-- no always-applied default.
peerSelectionTargetsCheck ::
  -- | The prefix the group's field names carry: @Deadline@ or @Sync@.
  String ->
  -- | The group's targets, if the configuration states them all.
  (NodeConfiguration -> Maybe PeerSelectionTargets) ->
  ConfigCheck
peerSelectionTargetsCheck group targets =
  ConfigCheck CheckError description (maybe True sanePeerSelectionTargets . targets)
 where
  field name = group <> "TargetNumberOf" <> name
  description =
    "the "
      <> group
      <> " peer targets must be ones ouroboros-network accepts: each of "
      <> field "ActivePeers"
      <> ", "
      <> field "EstablishedPeers"
      <> " and "
      <> field "KnownPeers"
      <> " no greater than the next, "
      <> field "RootPeers"
      <> " no greater than "
      <> field "KnownPeers"
      <> ", the same order among "
      <> field "ActiveBigLedgerPeers"
      <> ", "
      <> field "EstablishedBigLedgerPeers"
      <> " and "
      <> field "KnownBigLedgerPeers"
      <> ", none of them negative, and the active, established and known "
      <> "targets no greater than 100, 1000 and 10000 respectively (both the "
      <> "peer and the big ledger peer group). The node does not reject these "
      <> "itself: it runs peer selection on them, and its governor is written "
      <> "assuming they hold"

-- | The injectable genesis fields of a resolved configuration, with the source
-- each one takes its data from. See "Cardano.Configuration.Genesis.Injection".
nodeConfigurationInjections :: NodeConfiguration -> [Injection.InjectionSlot]
nodeConfigurationInjections nc =
  injectionSlots (shelleyGenesisConfig nc) (conwayGenesisConfig nc)

-- | The filesystem @cardano-ledger@ resolves this configuration's genesis
-- injection files against, ready to hand to @protocolInfoCardano@. Rooted at
-- 'genesisInjectionRoot', the directory holding the Shelley genesis file.
nodeConfigurationInjectionFS :: NodeConfiguration -> SomeHasFS IO
nodeConfigurationInjectionFS = injectionHasFS . genesisInjectionRoot

-- | Run a set of consistency checks over a resolved configuration. Any failed
-- 'CheckError' aborts with a 'ConfigResolutionError' listing their descriptions;
-- otherwise resolution succeeds and every failed 'CheckWarning' is returned as a
-- 'File.ConsistencyWarning' for the caller to surface.
runConfigChecks ::
  [ConfigCheck] ->
  NodeConfiguration ->
  Either ConfigResolutionError (NodeConfiguration, [File.ConfigWarning])
runConfigChecks checks nc =
  case [checkDescription c | c <- checks, checkSeverity c == CheckError, not (checkHolds c nc)] of
    (violation : violations) -> Left (ViolatedChecks (violation :| violations))
    [] ->
      Right
        ( nc
        , [ File.ConsistencyWarning (checkDescription c)
          | c <- checks
          , checkSeverity c == CheckWarning
          , not (checkHolds c nc)
          ]
        )

-- | Combine the cli arguments and configuration file values into a full
-- configuration, then check it with 'defaultConfigChecks'. CLI values take
-- precedence over file values.
resolveConfiguration ::
  CLI.CliArgs ->
  File.NodeConfigurationFromFile ->
  Either ConfigResolutionError (NodeConfiguration, [File.ConfigWarning])
resolveConfiguration = resolveConfigurationWith defaultConfigChecks

-- | Resolve a full 'NodeConfiguration' from a configuration file alone, with no
-- command-line overrides. This is the common case for tools that consume a node
-- configuration file but have no node command line of their own (eg db-analyser,
-- db-immutaliser): the file is parsed with 'File.parseConfigurationFiles' and
-- resolved against 'CLI.defaultCliArgs', so every value comes from the file (and
-- the always-applied defaults layer). The returned warnings combine those raised
-- while parsing the files with those from the consistency checks.
--
-- File-level parse failures are thrown as a 'File.ConfigurationParsingError' (as
-- in 'File.parseConfigurationFiles'); a well-formed file that fails a consistency
-- check is returned as a 'Left'. Consumers that need to supply command-line
-- overrides should instead build a 'CLI.CliArgs' (starting, if convenient, from
-- 'CLI.defaultCliArgs') and call 'resolveConfiguration' directly.
resolveConfigurationFromFile ::
  HasCallStack =>
  FilePath ->
  IO (Either ConfigResolutionError (NodeConfiguration, [File.ConfigWarning]))
resolveConfigurationFromFile configFile = do
  (fileCfg, fileWarnings) <- File.parseConfigurationFiles configFile
  pure $ case resolveConfiguration (CLI.defaultCliArgs configFile) fileCfg of
    Left err -> Left err
    Right (nc, checkWarnings) -> Right (nc, fileWarnings <> checkWarnings)

-- | As 'resolveConfiguration', but with an explicit set of consistency checks,
-- so consumers can add their own (typically @'defaultConfigChecks' <> myChecks@).
-- On success returns the resolved configuration together with any non-fatal
-- warnings raised by 'CheckWarning'-severity checks.
resolveConfigurationWith ::
  [ConfigCheck] ->
  CLI.CliArgs ->
  File.NodeConfigurationFromFile ->
  Either ConfigResolutionError (NodeConfiguration, [File.ConfigWarning])
resolveConfigurationWith checks cli file = do
  -- The defaults are the bottom layer, and which ones apply is decided here:
  -- the node is a block producer or a relay according to its credentials, and
  -- the two default configurations differ in exactly the fields that means
  -- (the deadline peer targets and PeerSharing). The user's configuration is
  -- merged on top, so anything it states wins, and the CLI wins over both.
  --
  -- Components are then finalized to their complete 'Identity' form; a field
  -- with neither a default nor a value surfaces as a resolution error.
  let role = roleFromCredentials (CLI.credentials cli)
      merged =
        File.mergeValues (File.defaultConfiguration role) (File.userConfiguration file)
      section :: FromJSON a => String -> Either ConfigResolutionError a
      section name = either (Left . SectionDecodeError name) Right (File.decodeSection merged name)
  network <- section "Network" >>= finalize . File.finalizeNetwork
  testing <- section "Testing" >>= finalize . File.finalizeTesting
  mempool <- section "Mempool" >>= finalize . File.finalizeMempool
  -- Local connections additionally take CLI overrides before being finalized.
  lcc <- section "LocalConnections"
  let cliGrpcEndpoint = CLI.grpcEndpointCLI cli
      lccWithCli =
        lcc
          { File.socketPath = CLI.socketPath cli <|> File.socketPath lcc
          , File.enableGrpc = CLI.enableGrpcCLI cli <|> File.enableGrpc lcc
          , -- The endpoint is one choice, so a command-line endpoint replaces the
            -- file's endpoint whole rather than merging into it.
            File.grpcEndpoint = cliGrpcEndpoint <|> File.grpcEndpoint lcc
          }
  localConnections <- finalize $ File.finalizeLocalConnections lccWithCli
  -- Storage, consensus and the non-producing flag take their value from the CLI
  -- or from the merge above (whose bottom layer supplies the default). For
  -- these a missing value is a resolution error rather than a hard-coded
  -- fallback, so what they default to is in defaults/ and nowhere else.
  --
  -- Three fields elsewhere do fall back in code, because their default cannot
  -- be written in defaults/: the LSM database path (the Backend default is a
  -- string, which an LSM object replaces whole), the coupled mempool timeouts
  -- (supplying them would stop "all set or all unset" ever firing) and the gRPC
  -- listen address (it needs a port beside it, and it also applies to an
  -- endpoint built from the command line alone). The schema still states each:
  -- the listen address as a @default@ taken from 'File.defaultGrpcListenAddress'
  -- itself, the other two in their descriptions, JSON Schema having no way to
  -- write a default of three coupled values or one that applies under a single
  -- backend.
  sc <- section "Storage"
  pc <- section "Protocol"
  consensus <- section "Consensus"
  dbPath <- finalize $ require "DatabasePath" (CLI.databasePathCLI cli <|> File.databasePath sc)
  consensusMode <- finalize $ require "ConsensusMode" (getConsensusConfiguration consensus)
  startNonProducing <-
    finalize $
      require
        "StartAsNonProducingNode"
        (CLI.startAsNonProducingNode cli <|> File.startAsNonProducingNode pc)
  -- Run the consistency checks on the snapshot policy as requested, then resolve
  -- it to concrete options so the result carries no bare "Mithril" policy.
  (resolved, warnings) <-
    runConfigChecks checks $
      NodeConfiguration
        { storageConfiguration = File.adjustDbPath sc dbPath
        , consensusConfiguration = ConsensusConfiguration (Identity consensusMode)
        , protocolConfiguration = pc{File.startAsNonProducingNode = Identity startNonProducing}
        , networkConfiguration = network
        , localConnectionsConfig = localConnections
        , testingConfiguration = testing
        , mempoolConfiguration = mempool
        , tracingConfiguration = File.tracingConfiguration file
        , byronGenesisConfig = File.byronGenesisConfig file
        , shelleyGenesisConfig = File.shelleyGenesisConfig file
        , alonzoGenesisConfig = File.alonzoGenesisConfig file
        , conwayGenesisConfig = File.conwayGenesisConfig file
        , experimentalGenesisConfig = File.experimentalGenesisConfig file
        , genesisInjectionRoot = File.genesisInjectionRoot file
        , configFilePath = CLI.configFilePath cli
        , topologyFile = CLI.topologyFile cli
        , validateDatabase = CLI.validateDatabase cli
        , credentials = CLI.credentials cli
        , hostAddr = CLI.hostAddr cli
        , hostIPv6Addr = CLI.hostIPv6Addr cli
        , port = CLI.port cli
        , tracerSocket = CLI.tracerSocket cli
        , shutdownIPC = CLI.shutdownIPC cli
        , shutdownOnTarget = CLI.shutdownOnTarget cli
        }
  pure
    ( resolved{storageConfiguration = File.resolveSnapshotOptions (storageConfiguration resolved)}
    , grpcTlsDowngradeWarning (File.grpcEndpoint lcc) cliGrpcEndpoint <> warnings
    )
 where
  finalize = either (\m -> Left (ViolatedChecks (m :| []))) Right
  require name = strictMaybe (Left (name <> " has no value and no base default")) Right

-- | The gRPC endpoint is one choice, so a command-line endpoint replaces the
-- configuration file's whole rather than merging into it. A flag that means
-- only to move the port therefore also drops the file's TLS credentials, and
-- the server listens in plaintext instead. The operator did not ask for that in
-- so many words, so it is reported.
--
-- This cannot be a 'ConfigCheck': by the time there is a 'NodeConfiguration' to
-- check, the file's endpoint has been replaced and the downgrade is no longer
-- visible. It is raised where both endpoints are still in hand.
grpcTlsDowngradeWarning ::
  -- | The endpoint the configuration file states.
  StrictMaybe File.GrpcEndpoint ->
  -- | The endpoint the command line states, which replaces it.
  StrictMaybe File.GrpcEndpoint ->
  [File.ConfigWarning]
grpcTlsDowngradeWarning fileEndpoint cliEndpoint = case (fileEndpoint, cliEndpoint) of
  (SJust File.GrpcEndpointHttps{}, SJust replacement)
    | not (servesTls replacement) ->
        [ File.ConsistencyWarning $
            "the command line replaces the gRPC endpoint the configuration file sets, and the "
              <> "file's endpoint served TLS while the command line's does not, so the certificate "
              <> "and private key are dropped and the server listens in plaintext. Pass "
              <> "--grpc-tls-certificate and --grpc-tls-private-key alongside the endpoint flags "
              <> "to keep TLS"
        ]
  _ -> []
 where
  servesTls File.GrpcEndpointHttps{} = True
  servesTls _ = False

-- | Derive the node's role from its credentials: it is a block producer iff
-- /any/ block-forging credential was supplied, otherwise a relay. This matches
-- @cardano-node@'s @hasProtocolFile@ semantics and selects which of the two
-- default configurations resolution starts from (see
-- 'File.defaultConfiguration').
roleFromCredentials :: CLI.Credentials -> File.BlockProducerOrRelay
roleFromCredentials c
  | any
      isSJust
      [ () <$ CLI.byronDelegationCertificate c
      , () <$ CLI.byronSigningKey c
      , () <$ CLI.shelleyKES c
      , () <$ CLI.shelleyVRFKey c
      , () <$ CLI.shelleyOperationalCertificate c
      , () <$ CLI.shelleyBLSKey c
      , () <$ CLI.bulkCredentialsFile c
      ] =
      File.IsBlockProducer
  | otherwise = File.IsRelay
