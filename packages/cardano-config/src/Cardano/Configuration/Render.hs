-- | Render a resolved 'NodeConfiguration' as a JSON 'Value' that uses the
-- documented configuration keys (the same ones accepted on input), rather than
-- the Haskell record/constructor names. Intended for human-facing output (e.g.
-- dumping the resolved configuration as YAML); it is not a canonical encoding and
-- there is no matching parser.
--
-- Each component is rendered by lifting its resolved (@Identity@) form back into
-- the @Maybe@-parameterised form and reusing that form's 'ToJSON' instance, so
-- the keys stay in sync with the parsers. The operational arguments that come
-- only from the CLI (credentials, host\/port, shutdown, …) are grouped under a
-- @Runtime@ key.
--
-- The decoded era genesis values are large, so they are included only when
-- 'IncludeGeneses' is passed (the @--with-geneses@ flag of @cardano-config
-- resolve@); otherwise only their file reference and hash appear, under
-- @Protocol@.
module Cardano.Configuration.Render
  ( nodeConfigurationToJSON
  , GenesisRendering (..)
  ) where

import Cardano.Configuration (NodeConfiguration (..))
import qualified Cardano.Configuration.CliArgs as CLI
import qualified Cardano.Configuration.File as File
import Cardano.Configuration.Genesis.Byron (byronGenesisToJSON)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), strictMaybeToMaybe)
import Cardano.Logging.ConfigurationParser ()
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Functor.Identity (Identity, runIdentity)
import Data.Maybe (mapMaybe)

-- | Whether the rendered configuration includes the (large) decoded era genesis
-- values.
data GenesisRendering
  = -- | Omit the genesis values; only their file reference\/hash appears (under
    --       @Protocol@). The default for @cardano-config resolve@.
    OmitGeneses
  | -- | Include the decoded genesis value of every era (the @--with-geneses@ flag).
    IncludeGeneses
  deriving (Eq, Show)

-- | Render the complete resolved configuration: each component under its name,
-- plus the operational CLI-only arguments under @Runtime@. With 'IncludeGeneses'
-- the decoded era genesis values are added too.
nodeConfigurationToJSON :: GenesisRendering -> NodeConfiguration -> Value
nodeConfigurationToJSON geneses nc =
  object $
    [ "Storage" .= toJSON (weakenStorage (storageConfiguration nc))
    , "Consensus" .= toJSON (weakenConsensus (consensusConfiguration nc))
    , "Protocol" .= toJSON (weakenProtocol (protocolConfiguration nc))
    , "Network" .= toJSON (weakenNetwork (networkConfiguration nc))
    , "LocalConnections" .= toJSON (weakenLocalConnections (localConnectionsConfig nc))
    , "Mempool" .= toJSON (weakenMempool (mempoolConfiguration nc))
    , "Testing" .= toJSON (weakenTesting (testingConfiguration nc))
    , "Runtime" .= runtimeValue nc
    ]
      <> tracingFields
      <> genesisFields
 where
  -- The tracing configuration resolved by trace-dispatcher, rendered under the
  -- same @HermodTracing@ key it is read from (as an inline object, via
  -- trace-dispatcher's own 'ToJSON'). Always present: absent a @HermodTracing@
  -- key it holds the tracing defaults from @defaults\/@.
  tracingFields =
    ["HermodTracing" .= tracingConfiguration nc]
  -- The resolved (parsed) era geneses, rendered through the ledger's @aeson@
  -- 'toJSON' instances (and, for Byron, its canonical-JSON form), so the dump
  -- shows the decoded genesis content rather than just the file reference and
  -- hash (which always appear under @Protocol@). These are exactly the
  -- files read and hash-checked while parsing the configuration. Included only
  -- under 'IncludeGeneses', as they are large.
  genesisFields = case geneses of
    OmitGeneses -> []
    IncludeGeneses ->
      [ "ByronGenesis" .= byronGenesisToJSON (byronGenesisConfig nc)
      , "ShelleyGenesis" .= toJSON (shelleyGenesisConfig nc)
      , "AlonzoGenesis" .= toJSON (alonzoGenesisConfig nc)
      , "ConwayGenesis" .= toJSON (conwayGenesisConfig nc)
      ]
        -- The experimental (Dijkstra) genesis is optional: only when referenced.
        <> mapMaybe
          strictMaybeToMaybe
          [ ("ExperimentalGenesis" .=) . toJSON
              <$> experimentalGenesisConfig nc
          ]

-- | Lift a resolved (@Identity@) field back into the @StrictMaybe@-parameterised
-- form the component's 'ToJSON' instance expects.
j :: Identity a -> StrictMaybe a
j = SJust . runIdentity

-- | The same, for the accepted-connection limits, which carry the @f@ parameter
-- on each of their three fields rather than on the object.
weakenAcceptedConnectionsLimit ::
  File.AcceptedConnectionsLimitConfig Identity -> File.AcceptedConnectionsLimitConfig StrictMaybe
weakenAcceptedConnectionsLimit l =
  File.AcceptedConnectionsLimitConfig
    { File.hardLimit = j (File.hardLimit l)
    , File.softLimit = j (File.softLimit l)
    , File.delayOnSoftLimit = j (File.delayOnSoftLimit l)
    }

weakenStorage :: File.StorageConfiguration Identity -> File.StorageConfiguration StrictMaybe
weakenStorage s =
  File.StorageConfiguration
    { File.databasePath = j (File.databasePath s)
    , File.ledgerDbConfiguration = j (File.ledgerDbConfiguration s)
    }

weakenConsensus :: File.ConsensusConfiguration Identity -> File.ConsensusConfiguration StrictMaybe
weakenConsensus c =
  File.ConsensusConfiguration{File.getConsensusConfiguration = j (File.getConsensusConfiguration c)}

weakenProtocol :: File.ProtocolConfiguration Identity -> File.ProtocolConfiguration StrictMaybe
weakenProtocol p =
  File.ProtocolConfiguration
    { File.byronGenesis = File.byronGenesis p
    , File.shelleyGenesis = File.shelleyGenesis p
    , File.alonzoGenesis = File.alonzoGenesis p
    , File.conwayGenesis = File.conwayGenesis p
    , File.startAsNonProducingNode = j (File.startAsNonProducingNode p)
    , File.checkpointsFile = File.checkpointsFile p
    }

weakenNetwork :: File.NetworkConfiguration Identity -> File.NetworkConfiguration StrictMaybe
weakenNetwork n =
  File.NetworkConfiguration
    { File.diffusionMode = j (File.diffusionMode n)
    , File.maxConcurrencyBulkSync = j (File.maxConcurrencyBulkSync n)
    , File.maxConcurrencyDeadline = j (File.maxConcurrencyDeadline n)
    , File.protocolIdleTimeout = j (File.protocolIdleTimeout n)
    , File.timeWaitTimeout = j (File.timeWaitTimeout n)
    , File.egressPollInterval = j (File.egressPollInterval n)
    , File.chainSyncIdleTimeout = j (File.chainSyncIdleTimeout n)
    , File.acceptedConnectionsLimit = weakenAcceptedConnectionsLimit (File.acceptedConnectionsLimit n)
    , File.deadlineTargetOfRootPeers = File.deadlineTargetOfRootPeers n
    , File.deadlineTargetOfKnownPeers = File.deadlineTargetOfKnownPeers n
    , File.deadlineTargetOfEstablishedPeers = File.deadlineTargetOfEstablishedPeers n
    , File.deadlineTargetOfActivePeers = File.deadlineTargetOfActivePeers n
    , File.deadlineTargetOfKnownBigLedgerPeers = File.deadlineTargetOfKnownBigLedgerPeers n
    , File.deadlineTargetOfEstablishedBigLedgerPeers = File.deadlineTargetOfEstablishedBigLedgerPeers n
    , File.deadlineTargetOfActiveBigLedgerPeers = File.deadlineTargetOfActiveBigLedgerPeers n
    , File.syncTargetOfRootPeers = j (File.syncTargetOfRootPeers n)
    , File.syncTargetOfKnownPeers = j (File.syncTargetOfKnownPeers n)
    , File.syncTargetOfEstablishedPeers = j (File.syncTargetOfEstablishedPeers n)
    , File.syncTargetOfActivePeers = j (File.syncTargetOfActivePeers n)
    , File.syncTargetOfKnownBigLedgerPeers = j (File.syncTargetOfKnownBigLedgerPeers n)
    , File.syncTargetOfEstablishedBigLedgerPeers = j (File.syncTargetOfEstablishedBigLedgerPeers n)
    , File.syncTargetOfActiveBigLedgerPeers = j (File.syncTargetOfActiveBigLedgerPeers n)
    , File.minBigLedgerPeersForTrustedState = j (File.minBigLedgerPeersForTrustedState n)
    , File.peerSharing = File.peerSharing n
    , File.responderCoreAffinityPolicy = j (File.responderCoreAffinityPolicy n)
    , File.experimentalProtocolsEnabled = j (File.experimentalProtocolsEnabled n)
    , File.txSubmissionLogicVersion = j (File.txSubmissionLogicVersion n)
    , File.txSubmissionInitDelay = j (File.txSubmissionInitDelay n)
    }

weakenLocalConnections ::
  File.LocalConnectionsConfig Identity -> File.LocalConnectionsConfig StrictMaybe
weakenLocalConnections l =
  File.LocalConnectionsConfig
    { File.socketPath = File.socketPath l
    , File.enableGrpc = j (File.enableGrpc l)
    , File.grpcEndpoint = File.grpcEndpoint l
    }

weakenTesting :: File.TestingConfiguration Identity -> File.TestingConfiguration StrictMaybe
weakenTesting t =
  File.TestingConfiguration
    { File.experimentalHardForksEnabled = j (File.experimentalHardForksEnabled t)
    , File.testShelleyHardForkAtEpoch = File.testShelleyHardForkAtEpoch t
    , File.testShelleyHardForkAtVersion = File.testShelleyHardForkAtVersion t
    , File.testAllegraHardForkAtEpoch = File.testAllegraHardForkAtEpoch t
    , File.testAllegraHardForkAtVersion = File.testAllegraHardForkAtVersion t
    , File.testMaryHardForkAtEpoch = File.testMaryHardForkAtEpoch t
    , File.testMaryHardForkAtVersion = File.testMaryHardForkAtVersion t
    , File.testAlonzoHardForkAtEpoch = File.testAlonzoHardForkAtEpoch t
    , File.testAlonzoHardForkAtVersion = File.testAlonzoHardForkAtVersion t
    , File.testBabbageHardForkAtEpoch = File.testBabbageHardForkAtEpoch t
    , File.testBabbageHardForkAtVersion = File.testBabbageHardForkAtVersion t
    , File.testConwayHardForkAtEpoch = File.testConwayHardForkAtEpoch t
    , File.testConwayHardForkAtVersion = File.testConwayHardForkAtVersion t
    , File.testDijkstraHardForkAtEpoch = File.testDijkstraHardForkAtEpoch t
    , File.testDijkstraHardForkAtVersion = File.testDijkstraHardForkAtVersion t
    , File.experimentalGenesis = File.experimentalGenesis t
    }

weakenMempool :: File.MempoolConfiguration Identity -> File.MempoolConfiguration StrictMaybe
weakenMempool m =
  File.MempoolConfiguration
    { File.mempoolCapacityOverride = File.mempoolCapacityOverride m
    , File.mempoolTimeoutSoft = j (File.mempoolTimeoutSoft m)
    , File.mempoolTimeoutHard = j (File.mempoolTimeoutHard m)
    , File.mempoolTimeoutCapacity = j (File.mempoolTimeoutCapacity m)
    }

-- | The operational arguments that come only from the CLI. Unset optional values
-- are omitted.
runtimeValue :: NodeConfiguration -> Value
runtimeValue nc =
  object $
    [ "ConfigFile" .= configFilePath nc
    , "TopologyFile" .= topologyFile nc
    , "ValidateDatabase" .= validateDatabase nc
    , "Credentials" .= credentialsValue (credentials nc)
    ]
      <> mapMaybe
        strictMaybeToMaybe
        [ ("HostAddr" .=) . show <$> hostAddr nc
        , ("HostIPv6Addr" .=) . show <$> hostIPv6Addr nc
        , ("Port" .=) . portNumber <$> port nc
        , ("TracerSocket" .=) . tracerConnectionValue <$> tracerSocket nc
        , ("ShutdownIPC" .=) . fdNumber <$> shutdownIPC nc
        , ("ShutdownOn" .=) . shutdownOnValue <$> shutdownOnTarget nc
        ]
 where
  portNumber p = toJSON (toInteger p)
  fdNumber fd = toJSON (toInteger fd)

credentialsValue :: CLI.Credentials -> Value
credentialsValue c =
  object $
    mapMaybe
      strictMaybeToMaybe
      [ ("ByronDelegationCertificate" .=) <$> CLI.byronDelegationCertificate c
      , ("ByronSigningKey" .=) <$> CLI.byronSigningKey c
      , ("ShelleyKES" .=) . kesSourceValue <$> CLI.shelleyKES c
      , ("ShelleyVRFKey" .=) <$> CLI.shelleyVRFKey c
      , ("ShelleyOperationalCertificate" .=) <$> CLI.shelleyOperationalCertificate c
      , ("ShelleyBLSKey" .=) <$> CLI.shelleyBLSKey c
      , ("BulkCredentialsFile" .=) <$> CLI.bulkCredentialsFile c
      ]

kesSourceValue :: CLI.KESSource -> Value
kesSourceValue = \case
  CLI.KESKeyFilePath p -> object ["KeyFile" .= p]
  CLI.KESAgentSocketPath p -> object ["AgentSocket" .= p]

tracerConnectionValue :: CLI.TracerConnection -> Value
tracerConnectionValue (CLI.TracerConnection name method) =
  object ["Name" .= name, "Method" .= methodValue method]
 where
  methodValue :: CLI.TracerConnectionMethod -> Value
  methodValue = \case
    CLI.TracerConnectViaPipe p -> object ["Pipe" .= p]
    CLI.TracerConnectViaRemote host p ->
      object ["Host" .= host, "Port" .= toInteger p]

shutdownOnValue :: CLI.ShutdownOn -> Value
shutdownOnValue = \case
  CLI.ShutdownAtSlot n -> object ["AtSlot" .= n]
  CLI.ShutdownAtBlock n -> object ["AtBlock" .= n]
