{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- | Golden-ish tests: every example configuration must parse through the
-- autodocodec-derived parsers (and the full file pipeline). This is the most
-- reliable validation we have, since the parser shares its codec with the
-- schema.
--
-- The @test/examples/@ and @schemas/@ fixtures are read from the source tree,
-- resolved against 'packageRoot' (the package directory, baked in at compile
-- time) when it still exists, and against the current working directory
-- otherwise (see 'getDataFileName'), so the tests work under @cabal test@, Nix
-- and a source distribution alike. Unlike the files the
-- library itself needs, which are compiled into it (see
-- "Cardano.Configuration.Embedded"), the fixtures are read as files: most of
-- them are fed to the file pipeline, which resolves the genesis paths they name
-- relative to the file's own directory.
--
-- The cases form a tasty 'TestTree' of @tasty-hunit@ assertions; 'defaultMain'
-- runs them and sets the process exit code.
module Main (main) where

import Cardano.Configuration (resolveConfiguration)
import qualified Cardano.Configuration as C
import Cardano.Configuration.CliArgs
  ( CliArgs
  , credentials
  , grpcEndpointCLI
  , parseCliArgs
  , shelleyBLSKey
  )
import Cardano.Configuration.Edit
  ( configurationDocumentFromValue
  , readConfigurationDocument
  , refreshGenesisHashes
  , writeConfigurationDocument
  )
import Cardano.Configuration.File
import Cardano.Configuration.File.Migrate (migrate, renderMigrationError)
import Cardano.Configuration.File.Storage
  ( LedgerDbBackendSelector (..)
  , LedgerDbConfiguration (..)
  , SnapshotOptions (..)
  , SnapshotPolicy (..)
  , resolveSnapshotPolicy
  )
import Cardano.Configuration.Genesis (GenesisReadError (..), readGenesisFile)
import Cardano.Configuration.Genesis.Byron (readByronGenesisConfig)
import Cardano.Configuration.Genesis.Injection
  ( InjectionSlot (..)
  , InjectionSource (..)
  , fileInjections
  , injectionSlots
  , missingInjectionFiles
  , renderInjectionSlot
  )
import Cardano.Configuration.Render (GenesisRendering (..), nodeConfigurationToJSON)
import Cardano.Configuration.Schema
  ( configSchemaWithDefaults
  , currentFormatVersion
  , packageFormatVersion
  , schemaId
  )
import Cardano.Crypto.Hash (Blake2b_256, Hash, hashFromTextAsHex, hashToTextAsHex)
import Cardano.Crypto.ProtocolMagic (RequiresNetworkMagic (RequiresNoMagic))
import Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), isSJust, strictMaybeToMaybe)
import Cardano.Ledger.Conway.Genesis (ConwayGenesis)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis)
import Cardano.Ledger.Shelley.Genesis (ShelleyGenesis)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (foldM)
import Data.Aeson
  ( FromJSON
  , Object
  , Result (..)
  , Value (..)
  , eitherDecodeFileStrict'
  , encodeFile
  , fromJSON
  , toJSON
  )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.FileEmbed (makeRelativeToProject)
import Data.Functor.Identity (runIdentity)
import Data.IP (IP)
import Data.List (isInfixOf, sort)
import Data.Maybe (fromJust)
import qualified Data.Text as T
import Data.Word (Word64)
import Language.Haskell.TH.Syntax (lift)
import Options.Applicative (defaultPrefs, execParserPure, getParseResult, info)
import System.Directory (copyFile, doesFileExist)
import System.FS.API (fsPathToList)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase)

-- | The package directory (the one holding the @.cabal@ file), resolved at
-- compile time by @file-embed@. The fixtures live under it.
packageRoot :: FilePath
packageRoot = $(makeRelativeToProject "." >>= lift)

-- | Resolve a fixture path relative to the package root. This replaces the
-- @Paths_cardano_config@ function of the same name, which resolved the same
-- files through the Cabal data directory the package no longer installs.
--
-- The baked-in root can be gone by the time the tests run: @haskell.nix@
-- builds the suite in one derivation and runs it in another, and on Darwin each
-- gets its own randomly named build directory. The run then happens in the
-- unpacked source tree, so the path is resolved against the working directory
-- instead.
getDataFileName :: FilePath -> IO FilePath
getDataFileName p = do
  baked <- doesFileExist (packageRoot </> "cardano-config.cabal")
  pure (if baked then packageRoot </> p else p)

main :: IO ()
main = defaultMain $ testGroup "cardano-config" (cases <> [schemaTests])

-- | The example/parser/resolver cases, in the order they used to be checked.
cases :: [TestTree]
cases =
  [ parseCase "test/examples/legacy-fullconfig.json"
  , parseCase "test/examples/all-sections.json"
  , tracingCase
  , tracingDefaultIllustrationCase
  , unrecognisedKeyCase
  , migrationWarningCase
  , migrationErrorCase
  , formatVersionCase
  , formatVersionCompatibilityCase
  , version1RenamesCase
  , migrateCase
  , migrateRenameCase
  , migrateNoOverrideCase
  , migrateSectionRenameCase
  , migrateTracingCase
  , migrateApplicationNameCase
  , migrateLedgerDbSnapshotsCase
  , migrateSnapshotRenameCase
  , migrateLedgerDbBackendCase
  , backendRoundTripCase
  , migrateSiblingCase
  , migrateEnvelopeCollisionCase
  , migrateEnvelopedRenameCase
  , migrateRenameCollisionCase
  , sectionNotInlineCase
  , minNodeVersionCase
  , resolveCase
  , genesisRenderCase
  , schemaConstraintsCase
  , snapshotIntervalCase
  , grpcEndpointCase
  , grpcEndpointRejectionCase
  , grpcEndpointCliCase
  , grpcTlsDowngradeCase
  , grpcEnabledEndpointCheckCase
  , boundedDecimalOnlyCase
  , roleSelectionCase
  , blsKeyRoleCase
  , rolePrecedenceCase
  , peerTargetsRejectedCase
  , sectionDecodeErrorCase
  , partialNestedObjectCase
  , softAboveHardLimitCase
  , defaultConfigParityCase
  , experimentalHardForksDefaultCase
  , mempoolAllUnsetCase
  , mempoolAllSetCase
  , mempoolMixedCase
  , mempoolMixedResolveCase
  , snapshotMithrilResolveCase
  , snapshotResolvePolicyCase
  , mithrilRequiresExportCase
  , lsmDatabasePathDefaultCase
  , injectionRootCase
  , injectionSlotsCase
  , injectionConflictCase
  , injectionMainnetCase
  , injectionMissingFileCase
  , dijkstraGenesisDecodeCase
  , dijkstraGenesisHashMismatchCase
  , genesisHashRequiredCase
  , genesisHashPresentCase
  , experimentalGenesisGateCase
  , experimentalGenesisRequiredCase
  , decodeCase
      "test/examples/mainnet-shelley-genesis.json (decodes via the ledger instances)"
      (decodeData "test/examples/mainnet-shelley-genesis.json" :: IO (Either String ShelleyGenesis))
  , decodeCase
      "test/examples/mainnet-alonzo-genesis.json (decodes via the ledger instances)"
      (decodeData "test/examples/mainnet-alonzo-genesis.json" :: IO (Either String AlonzoGenesis))
  , decodeCase
      "test/examples/mainnet-conway-genesis.json (decodes via the ledger instances)"
      (decodeData "test/examples/mainnet-conway-genesis.json" :: IO (Either String ConwayGenesis))
  , byronGenesisDecodeCase
  , refreshMissingHashesCase
  , refreshStaleHashesCase
  , documentRoundTripCase
  ]

-- | 'migrate' on a document that is expected to migrate cleanly. Every input
-- below is one, so a rejection is a test failure; 'sectionNotInlineCase' covers
-- the rejecting path.
migrated :: Value -> (Value, [ConfigWarning])
migrated = either (error . renderMigrationError) id . migrate

-- | Fail the assertion with the message when one is present, otherwise pass.
expectOk :: Maybe String -> Assertion
expectOk = maybe (pure ()) assertFailure

-- | Decode a packaged data file (resolved via 'getDataFileName') through its
-- 'FromJSON' instance.
decodeData :: FromJSON a => FilePath -> IO (Either String a)
decodeData p = getDataFileName p >>= eitherDecodeFileStrict'

-- | Build a JSON object from string-keyed pairs (test convenience, mirroring the
-- @KM.fromList . map (first K.fromString)@ used by the inline fixtures).
obj :: [(String, Value)] -> Value
obj = Object . KM.fromList . map (\(k, v) -> (K.fromString k, v))

-- | Decode a single example via its 'FromJSON' instance, forcing the result.
decodeCase :: Show a => String -> IO (Either String a) -> TestTree
decodeCase label act =
  testCase label $ do
    res <- act
    case res of
      Left err -> assertFailure err
      Right v -> () <$ evaluate (length (show v))

-- | Parse a full configuration file through the whole pipeline.
parseCase :: FilePath -> TestTree
parseCase fp =
  testCase fp $ do
    path <- getDataFileName fp
    res <- try (parseConfigurationFiles path >>= \c -> evaluate (length (show c)))
    expectOk $ case res of
      Left (e :: SomeException) -> Just (show e)
      Right _ -> Nothing

-- | A configuration is held in one file, so a section that names a separate
-- file instead of holding its configuration object is rejected, naming the
-- section and telling the user to copy the contents in.
sectionNotInlineCase :: TestTree
sectionNotInlineCase =
  testCase "a section naming a separate file is rejected" $ do
    path <- getDataFileName "test/examples/section-not-inline.json"
    res <- try (parseConfigurationFiles path)
    expectOk $ case res of
      Right _ -> Just "expected a section naming a separate file to be rejected"
      Left (e :: SomeException)
        | "Storage" `isInfixOf` show e
        , "one file" `isInfixOf` show e ->
            Nothing
        | otherwise -> Just ("unexpected rejection message: " <> show e)

-- | A key at the @Configuration@ level that no parser recognises (here the
-- typo @DijsktraGenesisFile@) belongs to no section, so migration leaves it
-- where it is. Parsing still succeeds and an 'UnrecognisedKeys' warning names
-- it. A key that /is/ a component property is a different matter: migration
-- groups it under the section that owns it (see 'migrateCase').
unrecognisedKeyCase :: TestTree
unrecognisedKeyCase =
  testCase "test/examples/unrecognised-key.json (an unknown key warns, still parses)" $ do
    path <- getDataFileName "test/examples/unrecognised-key.json"
    res <- try (parseConfigurationFiles path)
    expectOk $ case res of
      Left (e :: SomeException) -> Just (show e)
      Right (_, warnings)
        | any mentionsTypo warnings -> Nothing
        | otherwise ->
            Just ("expected an UnrecognisedKeys warning for DijsktraGenesisFile, got " <> show warnings)
 where
  mentionsTypo (UnrecognisedKeys ks) = "DijsktraGenesisFile" `elem` ks
  mentionsTypo _ = False

-- | Every document is migrated before parsing, and the two warnings that
-- reports split by cause. A document at an older format version yields
-- 'OutdatedFormatVersion' alone, since migration always rewrites it and the
-- generic warning would only repeat that. A document already at the current
-- version that migration still changes (here a legacy field name inside a
-- current envelope) yields 'MigratedToCurrentFormat'. A canonical document
-- migrates to itself and yields neither.
migrationWarningCase :: TestTree
migrationWarningCase =
  testCase "the migration warnings split by cause" $ do
    legacy <- warningsFor "test/examples/legacy-fullconfig.json"
    renamed <- warningsFor "test/examples/current-version-legacy-name.json"
    canonical <- warningsFor "test/examples/min-node-version.json"
    expectOk $
      firstProblem
        [ check
            "an older version"
            legacy
            [OutdatedFormatVersion 1 currentFormatVersion]
            [MigratedToCurrentFormat]
        , check
            "a current version still rewritten"
            renamed
            [MigratedToCurrentFormat]
            [OutdatedFormatVersion 1 currentFormatVersion]
        , check
            "a canonical document"
            canonical
            []
            [MigratedToCurrentFormat, OutdatedFormatVersion 1 currentFormatVersion]
        ]
 where
  warningsFor p = snd <$> (getDataFileName p >>= parseConfigurationFiles)
  check what warnings expected unexpected
    | not (all (`elem` warnings) expected) =
        Just (what <> ": expected " <> show expected <> ", got " <> show warnings)
    | any (`elem` warnings) unexpected =
        Just (what <> ": did not expect " <> show unexpected <> ", got " <> show warnings)
    | otherwise = Nothing

-- | A document that is not in the envelope /and/ whose migration still
-- does not yield a parseable configuration is rejected (the parse error
-- surfaces). Here a legacy document with an ill-typed @ConsensusMode@ migrates to
-- an envelope, but the component codec then rejects the value.
migrationErrorCase :: TestTree
migrationErrorCase =
  testCase "a non-enveloped document whose migration is still unparseable is rejected" $ do
    path <- getDataFileName "test/examples/migration-unparseable.json"
    res <- try (parseConfigurationFiles path >>= \c -> evaluate (length (show c)))
    expectOk $ case res of
      Left (_ :: SomeException) -> Nothing
      Right _ -> Just "expected a parse error for a document whose migration is unparseable"

-- | The newest configuration format version is the first component of the package
-- version: @cardano-config-X.y.z.v@ parses every version up to and including @X@,
-- so the schemas are not changed without bumping it. Bumping it therefore has to
-- be deliberate — a new parse path in 'parseConfigurationFiles', a new @schemas\/@
-- generation and a new @vX@ tag for the @$schema@ URLs — so this guards against
-- the package's first component moving on its own (or against the format version
-- moving without it). Pre-1.0 the package is @0.x.x.x@ while the format is already
-- 1, which 'packageFormatVersion' accounts for.
formatVersionCase :: TestTree
formatVersionCase =
  testCase "the format version matches the package version's first component" $
    expectOk $
      if currentFormatVersion == packageFormatVersion
        then Nothing
        else
          Just $
            "currentFormatVersion is "
              <> show currentFormatVersion
              <> " but the package version implies "
              <> show packageFormatVersion

-- | 'migrate' reshapes a legacy flat config into the envelope: the
-- envelope keys appear at the top, each component's flat keys are grouped under
-- its section (e.g. ConsensusMode under Consensus), a removed key
-- (MaxKnownMajorProtocolVersion) is dropped, and the result is idempotent.
migrateCase :: TestTree
migrateCase =
  testCase "migrate test/examples/legacy-fullconfig.json (legacy flat -> envelope)" $ do
    res <- decodeData "test/examples/legacy-fullconfig.json" :: IO (Either String Value)
    expectOk $ case res of
      Left err -> Just ("could not read fixture: " <> err)
      Right raw -> case fst (migrated raw) of
        m@(Object top)
          | not (all (`KM.member` top) (map K.fromString envelopeKeys)) ->
              Just ("missing envelope keys; got " <> show (KM.keys top))
          | otherwise -> case KM.lookup (K.fromString "Configuration") top of
              Just (Object cfg)
                | not (nested cfg "Protocol" "ByronGenesisFile") ->
                    Just "Protocol.ByronGenesisFile not grouped"
                | not (nested cfg "Consensus" "ConsensusMode") ->
                    Just "Consensus.ConsensusMode not grouped"
                | not (nested cfg "Storage" "LedgerDB") ->
                    Just "Storage.LedgerDB not grouped"
                | KM.member (K.fromString "MaxKnownMajorProtocolVersion") cfg ->
                    Just "removed key MaxKnownMajorProtocolVersion survived (should be dropped)"
                | fst (migrated m) /= m -> Just "migrate is not idempotent"
                | otherwise -> Nothing
              _ -> Just "Configuration is not an object"
        _ -> Just "migrate did not produce an object"
 where
  envelopeKeys = ["$schema", "Version", "MinNodeVersion", "Configuration"]
  nested cfg section key = case KM.lookup (K.fromString section) cfg of
    Just (Object s) -> KM.member (K.fromString key) s
    _ -> False

-- | 'migrate' brings every document it accepts to the current format version,
-- which is why there is one parse path rather than one per version. A legacy
-- document and a version-1 document both come out at 'currentFormatVersion',
-- with the @$schema@ that goes with it. Reading a version-1 document still
-- works and reports 'OutdatedFormatVersion'. A version past the newest is
-- rejected, naming it, and so is one below the oldest: 1 is the lowest version
-- there has ever been, so 0 names no format, and without the check it would be
-- read as a legacy document and quietly migrated.
formatVersionCompatibilityCase :: TestTree
formatVersionCompatibilityCase =
  testCase "migrate upgrades an older version; a newer one is rejected" $ do
    olderPath <- getDataFileName "test/examples/version1.json"
    older <- decodeData "test/examples/version1.json" :: IO (Either String Value)
    legacy <- decodeData "test/examples/legacy-fullconfig.json" :: IO (Either String Value)
    (parsed, warnings) <- parseConfigurationFiles olderPath
    unsupportedPath <- getDataFileName "test/examples/version-unsupported.json"
    unsupported <- try (parseConfigurationFiles unsupportedPath)
    nonPositivePath <- getDataFileName "test/examples/version-nonpositive.json"
    nonPositive <- try (parseConfigurationFiles nonPositivePath)
    expectOk $ case (older, legacy) of
      (Left err, _) -> Just ("could not read the version-1 fixture: " <> err)
      (_, Left err) -> Just ("could not read the legacy fixture: " <> err)
      (Right olderValue, Right legacyValue)
        | not (upgraded olderValue) -> Just "a version-1 document was not upgraded"
        | not (upgraded legacyValue) -> Just "a legacy document was not upgraded"
        | OutdatedFormatVersion 1 currentFormatVersion `notElem` warnings ->
            Just ("reading a version-1 document did not report it: " <> show warnings)
        | otherwise -> case resolveConfiguration (C.defaultCliArgs olderPath) parsed of
            Left err -> Just ("the version-1 document did not resolve: " <> show err)
            Right _ -> case (unsupported, nonPositive) of
              (Right _, _) -> Just "a document past the newest format version was accepted"
              (_, Right _) -> Just "a document declaring version 0 was accepted"
              (Left (e :: SomeException), Left (e0 :: SomeException))
                | not ("99" `isInfixOf` show e) ->
                    Just ("rejected, but without naming the version: " <> show e)
                | not ("0" `isInfixOf` show e0 && "positive" `isInfixOf` show e0) ->
                    Just ("version 0 rejected, but not as a version: " <> show e0)
                | otherwise -> Nothing
 where
  upgraded v = case fst (migrated v) of
    Object o ->
      KM.lookup (K.fromString "Version") o == Just (Number (fromIntegral currentFormatVersion))
        && KM.lookup (K.fromString "$schema") o == Just (String (schemaId "config.schema.json"))
    _ -> False

-- | A version-1 envelope written with the version-1 spellings reaches version 2
-- with the renames applied: the snapshot options @SnapshotInterval@\/@SlotOffset@
-- become @Interval@\/@Offset@, the sections lose their @Config@ suffix, a
-- @"NoOverride"@ mempool capacity override is
-- dropped, and a numeric one is renamed to @CapacityBytesOverride@. The fixture is
-- read through the parser (which migrates it in memory) and resolved, so the
-- renamed options also fill in from the Mithril values.
version1RenamesCase :: TestTree
version1RenamesCase =
  testCase "a version-1 envelope is migrated with the snapshot and mempool renames" $ do
    path <- getDataFileName "test/examples/version1-renames.json"
    raw <- decodeData "test/examples/version1-renames.json" :: IO (Either String Value)
    (parsed, warnings) <- parseConfigurationFiles path
    expectOk $ case raw of
      Left err -> Just ("could not read the fixture: " <> err)
      Right v1
        | OutdatedFormatVersion 1 currentFormatVersion `notElem` warnings ->
            Just ("reading the version-1 document did not report it: " <> show warnings)
        | isSJust (mempoolCapacityOverride (mempoolConfiguration parsed)) ->
            Just "the \"NoOverride\" capacity override was not dropped"
        | Just problem <- migratedProblem v1 -> Just problem
        | otherwise -> case resolveConfiguration (C.defaultCliArgs path) parsed of
            Left err -> Just ("the version-1 document did not resolve: " <> show err)
            Right (nc, _) ->
              case snapshots (runIdentity (ledgerDbConfiguration (C.storageConfiguration nc))) of
                SJust (CustomSnapshotPolicy o)
                  | snapshotFields o == [Just 864, Just 10, Just 600, Just 300, Just 21600, Just 2] -> Nothing
                other -> Just ("unexpected resolved snapshot options: " <> show other)
 where
  -- The same document with a numeric override: after 'migrate' it sits at
  -- version 2 under the current names only.
  migratedProblem v1 = case fst (migrated (withNumericOverride v1)) of
    m@(Object top)
      | KM.lookup (K.fromString "Version") top /= Just (Number (fromIntegral currentFormatVersion)) ->
          Just "the version-1 document was not stamped with the current version"
      | any
          ( `elem`
              [ "SnapshotInterval"
              , "SlotOffset"
              , "MempoolCapacityBytesOverride"
              , "MempoolConfig"
              , "ProtocolConfig"
              , "StorageConfig"
              ]
          )
          (allKeys m) ->
          Just ("an old name survived migration; keys: " <> show (allKeys m))
      | navigate m ["Configuration", "Mempool", "CapacityBytesOverride"] /= Just (Number 2000000) ->
          Just "the numeric capacity override was not renamed to CapacityBytesOverride"
      | otherwise -> Nothing
    _ -> Just "migrate did not produce an object"
  withNumericOverride = setAt ["Configuration", "MempoolConfig", "MempoolCapacityBytesOverride"] (Number 2000000)
  setAt [k] x (Object o) = Object (KM.insert (K.fromString k) x o)
  setAt (k : ks) x (Object o) = case KM.lookup (K.fromString k) o of
    Just inner -> Object (KM.insert (K.fromString k) (setAt ks x inner) o)
    Nothing -> Object o
  setAt _ _ v = v
  navigate v [] = Just v
  navigate (Object o) (k : ks) = KM.lookup (K.fromString k) o >>= \v -> navigate v ks
  navigate _ _ = Nothing
  allKeys (Object o) = map K.toString (KM.keys o) <> concatMap allKeys (KM.elems o)
  allKeys (Array a) = concatMap allKeys a
  allKeys _ = []

-- | 'migrate' rewrites the renamed fields to their current names and drops the
-- removed ones. Renamed flat keys must end up grouped under their section using
-- the /new/ name (a peer target under Network, EnableGrpc under
-- LocalConnections); AcceptedConnectionsLimit's sub-keys are renamed in
-- place, but that rename is scoped — a stray @delay@ elsewhere is left alone;
-- no removed key survives anywhere (including @Protocol@ and
-- @MaxKnownMajorProtocolVersion@); a genuinely-unrecognised key is kept; and the
-- result is still idempotent.
migrateRenameCase :: TestTree
migrateRenameCase =
  testCase "migrate rewrites renamed fields and drops removed ones" $ do
    res <- decodeData "test/examples/legacy-renamed-fields.json" :: IO (Either String Value)
    expectOk $ case res of
      Left err -> Just ("could not read fixture: " <> err)
      Right raw -> case fst (migrated raw) of
        m@(Object top)
          | any (`elem` removed) (allKeys m) ->
              Just ("a removed key survived; keys: " <> show (allKeys m))
          | any (`elem` oldNames) (allKeys m) ->
              Just ("an old name survived; keys: " <> show (allKeys m))
          | otherwise -> case KM.lookup (K.fromString "Configuration") top of
              Just (Object cfg)
                | not (nested cfg "Network" "DeadlineTargetNumberOfRootPeers") ->
                    Just "renamed peer target not grouped under Network"
                | not (nested cfg "LocalConnections" "EnableGrpc") ->
                    Just "EnableGrpc not grouped under LocalConnections"
                | not (nested cfg "Mempool" "CapacityBytesOverride") ->
                    Just "renamed CapacityBytesOverride not grouped under Mempool"
                | not (deepNested cfg "Network" "AcceptedConnectionsLimit" "HardLimit") ->
                    Just "AcceptedConnectionsLimit.HardLimit not renamed in place"
                | deepNested cfg "Network" "AcceptedConnectionsLimit" "hardLimit" ->
                    Just "AcceptedConnectionsLimit.hardLimit not renamed"
                -- The rename is scoped: a stray top-level "delay" is not touched.
                | not (KM.member (K.fromString "delay") cfg) ->
                    Just "a stray 'delay' outside AcceptedConnectionsLimit was renamed (should be scoped)"
                -- A genuinely-unrecognised key (a typo) is kept, not dropped.
                | not (KM.member (K.fromString "SomeUnrecognisedKey") cfg) ->
                    Just "a genuinely-unrecognised key was dropped (should be kept)"
                | fst (migrated m) /= m -> Just "migrate is not idempotent"
                | otherwise -> Nothing
              _ -> Just "Configuration is not an object"
        _ -> Just "migrate did not produce an object"
 where
  removed =
    [ "PBftSignatureThreshold"
    , "LastKnownBlockVersion-Major"
    , "LastKnownBlockVersion-Minor"
    , "LastKnownBlockVersion-Alt"
    , "ApplicationVersion"
    , "EnableP2P"
    , "Protocol"
    , "MaxKnownMajorProtocolVersion"
    ]
  -- Globally-unique old names that must never survive (the generic
  -- AcceptedConnectionsLimit sub-keys are checked in place above, since a stray
  -- one is deliberately left unchanged).
  oldNames =
    [ "EnableRpc"
    , "RpcSocketPath"
    , "RpcListenAddress"
    , "RpcListenPort"
    , "RpcTlsCertificateFile"
    , "RpcTlsPrivateKeyFile"
    , "RpcTlsChainCertificateFiles"
    , "TargetNumberOfRootPeers"
    , "MempoolCapacityBytesOverride"
    ]
  nested cfg section key = case KM.lookup (K.fromString section) cfg of
    Just (Object s) -> KM.member (K.fromString key) s
    _ -> False
  deepNested cfg section sub key = case KM.lookup (K.fromString section) cfg of
    Just (Object s) -> nested s sub key
    _ -> False
  -- Every object key appearing anywhere in the document.
  allKeys (Object o) = map K.toString (KM.keys o) <> concatMap allKeys (KM.elems o)
  allKeys (Array a) = concatMap allKeys a
  allKeys _ = []

-- | 'migrate' renames the sections that carried a @Config@ suffix. Where both
-- spellings are present the current one wins, with a 'RenamedKeyCollision'
-- warning. A @Protocol@ section survives, although @Protocol@ is also the removed
-- legacy protocol selector, which is still dropped.
migrateSectionRenameCase :: TestTree
migrateSectionRenameCase =
  testCase "migrate drops the Config suffix from the sections" $
    expectOk $ case migrated input of
      (Object top, warnings)
        | RenamedKeyCollision (T.pack "NetworkConfig") (T.pack "Network") `notElem` warnings ->
            Just ("expected a RenamedKeyCollision for NetworkConfig, got " <> show warnings)
        | otherwise -> case KM.lookup (K.fromString "Configuration") top of
            Just (Object cfg)
              | any (\k -> KM.member (K.fromString k) cfg) ["NetworkConfig", "ProtocolConfig", "StorageConfig"] ->
                  Just ("an old section name survived; keys: " <> show (KM.keys cfg))
              | KM.lookup (K.fromString "Network") cfg
                  /= Just (obj [("DiffusionMode", String (T.pack "InitiatorOnly"))]) ->
                  Just ("the current-name Network should win, got " <> show (KM.lookup (K.fromString "Network") cfg))
              | KM.lookup (K.fromString "Protocol") cfg
                  /= Just (obj [("RequiresNetworkMagic", String (T.pack "RequiresNoMagic"))]) ->
                  Just
                    ( "the Protocol section was not kept as written, got "
                        <> show (KM.lookup (K.fromString "Protocol") cfg)
                    )
              | KM.lookup (K.fromString "Storage") cfg
                  /= Just (obj [("DatabasePath", String (T.pack "mainnet/db/"))]) ->
                  Just "StorageConfig was not renamed to Storage"
              | otherwise -> Nothing
            _ -> Just "Configuration is not an object"
      _ -> Just "migrate did not produce an object"
 where
  input =
    obj
      [ ("Protocol", String (T.pack "Cardano"))
      ,
        ( "Configuration"
        , obj
            [ ("NetworkConfig", obj [("DiffusionMode", String (T.pack "InitiatorAndResponder"))])
            , ("Network", obj [("DiffusionMode", String (T.pack "InitiatorOnly"))])
            , ("ProtocolConfig", obj [("RequiresNetworkMagic", String (T.pack "RequiresNoMagic"))])
            , ("StorageConfig", obj [("DatabasePath", String (T.pack "mainnet/db/"))])
            ]
        )
      ]

-- | A mempool capacity override of @"NoOverride"@ means the same as omitting the
-- key, which is now the only spelling, so 'migrate' drops the entry whole, under
-- the old name or the current one. It does not count as a rename collision.
migrateNoOverrideCase :: TestTree
migrateNoOverrideCase =
  testCase "migrate drops a \"NoOverride\" mempool capacity override" $
    expectOk $
      firstProblem
        [ check "old name, flat" (obj [("MempoolCapacityBytesOverride", noOverride)]) []
        , check
            "current name, in the envelope"
            (obj [("Configuration", obj [("Mempool", obj [("CapacityBytesOverride", noOverride)])])])
            []
        , check
            "old name beside the current one"
            ( obj
                [
                  ( "Configuration"
                  , obj
                      [
                        ( "Mempool"
                        , obj [("MempoolCapacityBytesOverride", noOverride), ("CapacityBytesOverride", Number 5)]
                        )
                      ]
                  )
                ]
            )
            [Number 5]
        ]
 where
  noOverride = String (T.pack "NoOverride")
  check label input expected = case migrated input of
    (Object top, warnings)
      | any isCollision warnings -> Just (label <> ": unexpected collision warning: " <> show warnings)
      | otherwise ->
          let found = case KM.lookup (K.fromString "Configuration") top of
                Just (Object cfg) -> case KM.lookup (K.fromString "Mempool") cfg of
                  Just (Object m) ->
                    [ v
                    | (k, v) <- KM.toList m
                    , K.toString k `elem` ["MempoolCapacityBytesOverride", "CapacityBytesOverride"]
                    ]
                  _ -> []
                _ -> []
           in if found == expected
                then Nothing
                else Just (label <> ": expected " <> show expected <> ", got " <> show found)
    _ -> Just (label <> ": migrate did not produce an object")
  isCollision RenamedKeyCollision{} = True
  isCollision _ = False

-- | 'migrate' gathers the flat trace-dispatcher keys /verbatim/ into an inline
-- @HermodTracing@ object under @Configuration@ (keeping the flat names — including
-- @TraceOptionResourceFrequency@, which has no inner form), and drops the obsolete
-- iohk-monitoring keys (@UseTraceDispatcher@, @minSeverity@, …). Idempotent.
migrateTracingCase :: TestTree
migrateTracingCase =
  testCase
    "migrate gathers trace-dispatcher keys verbatim under HermodTracing and drops obsolete logging keys"
    $ expectOk
    $ case fst (migrated legacyTracing) of
      m@(Object top)
        | any (`elem` obsolete) (allKeys m) ->
            Just ("an obsolete logging key survived; keys: " <> show (allKeys m))
        | otherwise -> case KM.lookup (K.fromString "Configuration") top of
            Just (Object cfg) -> case KM.lookup (K.fromString "HermodTracing") cfg of
              Just (Object h)
                | not (all (\k -> KM.member (K.fromString k) h) tracingKeys) ->
                    Just ("HermodTracing is missing a trace-dispatcher key; has: " <> show (KM.keys h))
                -- The trace-dispatcher keys moved into HermodTracing, not left flat.
                | any (\k -> KM.member (K.fromString k) cfg) tracingKeys ->
                    Just "a trace-dispatcher key was left flat under Configuration"
                | fst (migrated m) /= m -> Just "migrate is not idempotent"
                | otherwise -> Nothing
              _ -> Just "HermodTracing was not created as an object"
            _ -> Just "Configuration is not an object"
      _ -> Just "migrate did not produce an object"
 where
  -- The flat trace-dispatcher keys that must end up (verbatim) inside HermodTracing,
  -- including the no-inner frequency key which must be kept, not dropped.
  tracingKeys =
    [ "TraceOptions"
    , "TraceOptionForwarder"
    , "TraceOptionMetricsPrefix"
    , "TraceOptionResourceFrequency"
    ]
  -- The obsolete iohk-monitoring keys that must not survive anywhere.
  obsolete =
    [ "UseTraceDispatcher"
    , "TurnOnLogging"
    , "TurnOnLogMetrics"
    , "minSeverity"
    , "defaultScribes"
    , "options"
    ]
  -- A minimal legacy flat config carrying both tracing families.
  legacyTracing =
    Object $
      KM.fromList
        [ (K.fromString "TraceOptions", Object (KM.fromList [(K.fromString "", Object KM.empty)]))
        , (K.fromString "TraceOptionForwarder", Object KM.empty)
        , (K.fromString "TraceOptionMetricsPrefix", String (T.pack "cardano.node.metrics."))
        , (K.fromString "TraceOptionResourceFrequency", Number 1000)
        , (K.fromString "UseTraceDispatcher", Bool True)
        , (K.fromString "TurnOnLogging", Bool True)
        , (K.fromString "TurnOnLogMetrics", Bool True)
        , (K.fromString "minSeverity", String (T.pack "Critical"))
        , (K.fromString "defaultScribes", Array mempty)
        , (K.fromString "options", Object KM.empty)
        ]
  allKeys (Object o) = map K.toString (KM.keys o) <> concatMap allKeys (KM.elems o)
  allKeys (Array a) = concatMap allKeys a
  allKeys _ = []

-- | 'migrate' collapses a top-level @ApplicationName@ (the obsolete Byron
-- software-version name, now repurposed as the tracing node name) into
-- @HermodTracing.TraceOptionNodeName@, and drops the Byron @ApplicationVersion@.
-- The result is idempotent.
migrateApplicationNameCase :: TestTree
migrateApplicationNameCase =
  testCase
    "migrate collapses top-level ApplicationName to HermodTracing.TraceOptionNodeName, drops ApplicationVersion"
    $ expectOk
    $ case fst (migrated legacyByron) of
      m@(Object top)
        | "ApplicationVersion" `elem` allKeys m -> Just "ApplicationVersion survived"
        | "ApplicationName" `elem` allKeys m -> Just "top-level ApplicationName was not collapsed"
        | otherwise -> case KM.lookup (K.fromString "Configuration") top of
            Just (Object cfg) -> case KM.lookup (K.fromString "HermodTracing") cfg of
              Just (Object h) -> case KM.lookup (K.fromString "TraceOptionNodeName") h of
                Just (String n)
                  | n /= T.pack "cardano-sl" -> Just ("TraceOptionNodeName has wrong value: " <> show n)
                  | fst (migrated m) /= m -> Just "migrate is not idempotent"
                  | otherwise -> Nothing
                _ -> Just "HermodTracing.TraceOptionNodeName is missing"
              _ -> Just "HermodTracing was not created as an object"
            _ -> Just "Configuration is not an object"
      _ -> Just "migrate did not produce an object"
 where
  -- A legacy flat config with the Byron software version at the top level, plus
  -- TraceOptions so the resulting HermodTracing is a valid tracing object.
  legacyByron =
    Object $
      KM.fromList
        [ (K.fromString "ApplicationName", String (T.pack "cardano-sl"))
        , (K.fromString "ApplicationVersion", Number 0)
        , (K.fromString "TraceOptions", Object (KM.fromList [(K.fromString "", Object KM.empty)]))
        ]
  allKeys (Object o) = map K.toString (KM.keys o) <> concatMap allKeys (KM.elems o)
  allKeys (Array a) = concatMap allKeys a
  allKeys _ = []

-- | 'migrate' gathers the flat snapshot-option keys directly under @LedgerDB@
-- (which legacy configs and the node parser accept there) into a nested
-- @LedgerDB.Snapshots@ object — the form cardano-config's @LedgerDB@ codec reads —
-- renaming @SnapshotInterval@ to @Interval@ on the way.
-- @Backend@/@QueryBatchSize@ stay at the @LedgerDB@ level. Idempotent.
migrateLedgerDbSnapshotsCase :: TestTree
migrateLedgerDbSnapshotsCase =
  testCase "migrate gathers flat LedgerDB snapshot options into LedgerDB.Snapshots" $
    expectOk $ case fst (migrated legacyLedgerDB) of
      m@Object{} -> case navigate m ["Configuration", "Storage", "LedgerDB"] of
        Just (Object ldb)
          | any (\k -> KM.member (K.fromString k) ldb) flatOpts ->
              Just ("a flat snapshot key stayed at the LedgerDB level; keys: " <> show (KM.keys ldb))
          | not (KM.member (K.fromString "Backend") ldb && KM.member (K.fromString "QueryBatchSize") ldb) ->
              Just "Backend/QueryBatchSize were not kept at the LedgerDB level"
          | otherwise -> case KM.lookup (K.fromString "Snapshots") ldb of
              Just (Object snaps)
                | not (all (\k -> KM.member (K.fromString k) snaps) nestedOpts) ->
                    Just ("LedgerDB.Snapshots is missing a moved key; has: " <> show (KM.keys snaps))
                | fst (migrated m) /= m -> Just "migrate is not idempotent"
                | otherwise -> Nothing
              _ -> Just "LedgerDB.Snapshots was not created as an object"
        _ -> Just "Configuration.Storage.LedgerDB not found"
      _ -> Just "migrate did not produce an object"
 where
  flatOpts = ["SnapshotInterval", "NumOfDiskSnapshots"]
  nestedOpts = ["Interval", "NumOfDiskSnapshots"]
  legacyLedgerDB =
    Object $
      KM.fromList
        [
          ( K.fromString "LedgerDB"
          , Object $
              KM.fromList
                [ (K.fromString "Backend", String (T.pack "V2InMemory"))
                , (K.fromString "QueryBatchSize", Number 100000)
                , (K.fromString "SnapshotInterval", Number 864)
                , (K.fromString "NumOfDiskSnapshots", Number 2)
                ]
          )
        ]
  navigate v [] = Just v
  navigate (Object o) (k : ks) = KM.lookup (K.fromString k) o >>= \v -> navigate v ks
  navigate _ _ = Nothing

-- | Inside an existing @LedgerDB.Snapshots@ object 'migrate' renames
-- @SnapshotInterval@\/@SlotOffset@ to @Interval@\/@Offset@. Where both spellings
-- are present the current one wins, with a 'RenamedKeyCollision' warning.
migrateSnapshotRenameCase :: TestTree
migrateSnapshotRenameCase =
  testCase "migrate renames the snapshot options inside LedgerDB.Snapshots" $
    expectOk $ case migrated input of
      (m, warnings)
        | expectedWarning `notElem` warnings ->
            Just ("expected a RenamedKeyCollision warning, got " <> show warnings)
        | otherwise -> case navigate m ["Configuration", "Storage", "LedgerDB", "Snapshots"] of
            Just (Object snaps)
              | any (\k -> KM.member (K.fromString k) snaps) ["SnapshotInterval", "SlotOffset"] ->
                  Just ("an old snapshot option name survived; keys: " <> show (KM.keys snaps))
              | KM.lookup (K.fromString "Interval") snaps /= Just (Number 100) ->
                  Just
                    ( "the current-name Interval (100) should win, got "
                        <> show (KM.lookup (K.fromString "Interval") snaps)
                    )
              | KM.lookup (K.fromString "Offset") snaps /= Just (Number 7) ->
                  Just ("SlotOffset was not renamed to Offset; keys: " <> show (KM.keys snaps))
              | otherwise -> Nothing
            _ -> Just "LedgerDB.Snapshots is not an object"
 where
  expectedWarning = RenamedKeyCollision (T.pack "SnapshotInterval") (T.pack "Interval")
  input =
    obj
      [
        ( "LedgerDB"
        , obj
            [
              ( "Snapshots"
              , obj [("SnapshotInterval", Number 864), ("Interval", Number 100), ("SlotOffset", Number 7)]
              )
            ]
        )
      ]
  navigate v [] = Just v
  navigate (Object o) (k : ks) = KM.lookup (K.fromString k) o >>= \v -> navigate v ks
  navigate _ _ = Nothing

-- | 'migrate' folds the legacy flat @V2LSM@ backend keys under @LedgerDB@ into the
-- tagged @Backend: { "LSM": { "DatabasePath": …, "ExportPath": … } }@ form.
migrateLedgerDbBackendCase :: TestTree
migrateLedgerDbBackendCase =
  testCase "migrate folds the flat V2LSM backend into Backend.LSM" $
    expectOk $ case fst (migrated legacyLedgerDB) of
      m@Object{} -> case navigate m ["Configuration", "Storage", "LedgerDB"] of
        Just (Object ldb)
          | any (\k -> KM.member (K.fromString k) ldb) ["LSMDatabasePath", "LSMExportPath"] ->
              Just ("a flat LSM key stayed at the LedgerDB level; keys: " <> show (KM.keys ldb))
          | otherwise -> case KM.lookup (K.fromString "Backend") ldb of
              Just (Object be) -> case KM.lookup (K.fromString "LSM") be of
                Just (Object lsm)
                  | KM.lookup (K.fromString "DatabasePath") lsm == Just (String (T.pack "lsm"))
                      && KM.lookup (K.fromString "ExportPath") lsm == Just (String (T.pack "lsm-export")) ->
                      if fst (migrated m) == m then Nothing else Just "migrate is not idempotent"
                  | otherwise -> Just ("Backend.LSM has wrong contents: " <> show (KM.toList lsm))
                _ -> Just "Backend.LSM was not created as an object"
              other -> Just ("Backend was not folded into an object: " <> show other)
        _ -> Just "Configuration.Storage.LedgerDB not found"
      _ -> Just "migrate did not produce an object"
 where
  legacyLedgerDB =
    Object $
      KM.fromList
        [
          ( K.fromString "LedgerDB"
          , Object $
              KM.fromList
                [ (K.fromString "Backend", String (T.pack "V2LSM"))
                , (K.fromString "LSMDatabasePath", String (T.pack "lsm"))
                , (K.fromString "LSMExportPath", String (T.pack "lsm-export"))
                ]
          )
        ]
  navigate v [] = Just v
  navigate (Object o) (k : ks) = KM.lookup (K.fromString k) o >>= \v -> navigate v ks
  navigate _ _ = Nothing

-- | The @Backend@ codec round-trips both forms: the @"V2InMemory"@ string and the
-- tagged @{ "LSM": { … } }@ object.
backendRoundTripCase :: TestTree
backendRoundTripCase =
  testCase "LedgerDB Backend round-trips (V2InMemory string, tagged LSM object)" $ do
    check V2InMemory
    check (V2LSM (SJust "db") (SJust "exp"))
    check (V2LSM SNothing SNothing)
 where
  check sel =
    let ldb = LedgerDbConfiguration SNothing SNothing (SJust sel)
     in case fromJSON (toJSON ldb) of
          Success ldb' ->
            assertBool
              ("round-trip changed the backend: " <> show (backendSelector ldb'))
              (backendSelector ldb' == SJust sel)
          Error e -> assertFailure ("round-trip failed to decode: " <> e)

-- | 'migrate' does not drop a top-level sibling of an existing @Configuration@
-- envelope: a stray @ByronGenesisFile@ next to the envelope is folded into the
-- body and regrouped under its owning section (@Protocol@), and the pre-existing
-- @Storage@ section is preserved. (Regression test for the reviewer's
-- "enveloped file drops its siblings" concern.)
migrateSiblingCase :: TestTree
migrateSiblingCase =
  testCase "migrate keeps a top-level sibling of the Configuration envelope (regroups, not drops)" $
    expectOk $ case migrated input of
      (Object top, warnings)
        | not (null warnings) -> Just ("expected no warnings, got " <> show warnings)
        | otherwise -> case KM.lookup (K.fromString "Configuration") top of
            Just (Object cfg)
              | not (nested cfg "Protocol" "ByronGenesisFile") ->
                  Just "the sibling ByronGenesisFile was dropped, not regrouped under Protocol"
              | not (KM.member (K.fromString "Storage") cfg) ->
                  Just "the pre-existing Storage section was lost"
              | otherwise -> Nothing
            _ -> Just "Configuration is not an object"
      _ -> Just "migrate did not produce an object"
 where
  input =
    obj
      [ ("Version", Number 1)
      , ("Configuration", obj [("Storage", obj [("DatabasePath", String (T.pack "mainnet/db/"))])])
      , ("ByronGenesisFile", String (T.pack "byron.json"))
      ]
  nested cfg section key = case KM.lookup (K.fromString section) cfg of
    Just (Object s) -> KM.member (K.fromString key) s
    _ -> False

-- | When a key appears both as a top-level sibling and inside the @Configuration@
-- envelope, 'migrate' keeps the value inside @Configuration@ (the canonical
-- location) and raises an 'EnvelopeKeyCollision' warning naming the key.
migrateEnvelopeCollisionCase :: TestTree
migrateEnvelopeCollisionCase =
  testCase
    "migrate resolves a sibling/Configuration collision in favour of Configuration (with a warning)"
    $ expectOk
    $ case migrated input of
      (Object top, warnings)
        | EnvelopeKeyCollision (T.pack "Mempool") `notElem` warnings ->
            Just ("expected an EnvelopeKeyCollision for Mempool, got " <> show warnings)
        | otherwise -> case KM.lookup (K.fromString "Configuration") top of
            Just (Object cfg) -> case KM.lookup (K.fromString "Mempool") cfg of
              Just (Object m)
                | KM.lookup (K.fromString "MempoolCapacityOverride") m /= Just (Number 100) ->
                    Just
                      ( "the Configuration value (100) should win, got "
                          <> show (KM.lookup (K.fromString "MempoolCapacityOverride") m)
                      )
                | otherwise -> Nothing
              _ -> Just "Mempool is not an object"
            _ -> Just "Configuration is not an object"
      _ -> Just "migrate did not produce an object"
 where
  input =
    obj
      [ ("Configuration", obj [("Mempool", obj [("MempoolCapacityOverride", Number 100)])])
      , ("Mempool", obj [("MempoolCapacityOverride", Number 999)])
      ]

-- | 'migrate' rewrites a pre-rename field name even when the document is
-- /already/ enveloped (the parser used to skip migration for enveloped
-- documents, so an enveloped @EnableRpc@ silently reverted to its default).
--
-- A pinned @$schema@ survives only while the version does not move. Upgrading a
-- version-1 document replaces it, because the pinned URL describes a version
-- the document no longer is; a document already at the current version keeps
-- whatever URL it pins.
migrateEnvelopedRenameCase :: TestTree
migrateEnvelopedRenameCase =
  testCase "migrate renames inside an envelope, and repins $schema only on an upgrade" $
    expectOk (firstProblem [renamed, upgradedRepins, currentKeepsPin])
 where
  renamed = case migrated (envelope 1) of
    (m@(Object top), _)
      | "EnableRpc" `elem` allKeys m -> Just "the old name EnableRpc survived the rename"
      | otherwise -> case KM.lookup (K.fromString "Configuration") top of
          Just (Object cfg)
            | not (nested cfg "LocalConnections" "EnableGrpc") ->
                Just "EnableRpc was not renamed to EnableGrpc under LocalConnections"
            | otherwise -> Nothing
          _ -> Just "Configuration is not an object"
    (m, _) -> Just ("migrate did not produce an object: " <> show m)
  upgradedRepins
    | schemaOf (envelope 1) == Just (String (schemaId "config.schema.json")) = Nothing
    | otherwise = Just ("an upgraded document kept its old $schema: " <> show (schemaOf (envelope 1)))
  currentKeepsPin
    | schemaOf (envelope currentFormatVersion) == Just pinnedSchema = Nothing
    | otherwise =
        Just
          ( "a document already at the current version lost its pinned $schema: "
              <> show (schemaOf (envelope currentFormatVersion))
          )
  schemaOf v = case fst (migrated v) of
    Object top -> KM.lookup (K.fromString "$schema") top
    _ -> Nothing
  pinnedSchema = String (T.pack "https://example.com/pinned/config.schema.json")
  envelope :: Int -> Value
  envelope version =
    obj
      [ ("$schema", pinnedSchema)
      , ("Version", Number (fromIntegral version))
      , ("Configuration", obj [("LocalConnections", obj [("EnableRpc", Bool True)])])
      ]
  nested cfg section key = case KM.lookup (K.fromString section) cfg of
    Just (Object s) -> KM.member (K.fromString key) s
    _ -> False
  allKeys (Object o) = map K.toString (KM.keys o) <> concatMap allKeys (KM.elems o)
  allKeys (Array a) = concatMap allKeys a
  allKeys _ = []

-- | When both the old and the current name of a renamed field sit in the same
-- object, 'migrate' keeps the current-name value (deterministically, not by
-- iteration order), drops the old-name one, and raises a 'RenamedKeyCollision'
-- warning. (Regression test for the reviewer's "key collision during renames"
-- concern.)
migrateRenameCollisionCase :: TestTree
migrateRenameCollisionCase =
  testCase "migrate keeps the current name on an old/new rename collision (with a warning)" $
    expectOk $ case migrated input of
      (Object top, warnings)
        | expectedWarning `notElem` warnings ->
            Just ("expected a RenamedKeyCollision warning, got " <> show warnings)
        | otherwise -> case KM.lookup (K.fromString "Configuration") top of
            Just (Object cfg) -> case KM.lookup (K.fromString "Network") cfg of
              Just (Object n)
                | KM.member (K.fromString "TargetNumberOfRootPeers") n ->
                    Just "the old name TargetNumberOfRootPeers survived (should be dropped)"
                | KM.lookup (K.fromString "DeadlineTargetNumberOfRootPeers") n /= Just (Number 2) ->
                    Just
                      ( "the current-name value (2) should win, got "
                          <> show (KM.lookup (K.fromString "DeadlineTargetNumberOfRootPeers") n)
                      )
                | otherwise -> Nothing
              _ -> Just "Network is not an object"
            _ -> Just "Configuration is not an object"
      _ -> Just "migrate did not produce an object"
 where
  expectedWarning =
    RenamedKeyCollision (T.pack "TargetNumberOfRootPeers") (T.pack "DeadlineTargetNumberOfRootPeers")
  input =
    obj
      [
        ( "Configuration"
        , obj
            [
              ( "Network"
              , obj
                  [ ("TargetNumberOfRootPeers", Number 1)
                  , ("DeadlineTargetNumberOfRootPeers", Number 2)
                  ]
              )
            ]
        )
      ]

-- | The optional top-level @MinNodeVersion@ annotation is read from the same
-- level as @Version@: from inside the @{ Version, Configuration }@ envelope, and
-- — when the document is not enveloped — from the top level alongside the
-- (section or flat) configuration keys. A document that omits it parses to
-- 'Nothing'.
minNodeVersionCase :: TestTree
minNodeVersionCase =
  testCase "MinNodeVersion is read at the top level (enveloped and legacy), or absent" $ do
    enveloped <- parsedMinNodeVersion "test/examples/min-node-version.json"
    legacy <- parsedMinNodeVersion "test/examples/min-node-version-legacy.json"
    absent <- parsedMinNodeVersion "test/examples/all-sections.json"
    expectOk $
      if enveloped == SJust (T.pack "10.5.0")
        && legacy == SJust (T.pack "9.1.0")
        && absent == SNothing
        then Nothing
        else
          Just $
            "unexpected MinNodeVersion: enveloped="
              <> show enveloped
              <> " legacy="
              <> show legacy
              <> " absent="
              <> show absent
 where
  parsedMinNodeVersion fp = do
    path <- getDataFileName fp
    (cfg, _) <- parseConfigurationFiles path
    pure (minNodeVersion cfg)

-- | Resolving a parsed configuration with default CLI arguments must succeed and
-- produce a complete (@Identity@) configuration, which exercises that the base
-- defaults populate every resolved field.
resolveCase :: TestTree
resolveCase =
  testCase "resolveConfiguration examples/legacy-fullconfig.json" $ do
    path <- getDataFileName "test/examples/legacy-fullconfig.json"
    (cfg, _) <- parseConfigurationFiles path
    case cliArgs [] of
      Nothing -> assertFailure "could not build default CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left err -> assertFailure (show err)
        Right (nc, _) -> () <$ evaluate (length (show nc))

-- | The top-level @HermodTracing@ key is resolved by trace-dispatcher's parser
-- into a 'TraceConfig' — whether given inline (an object) or as a path to a
-- separate file — and surfaced both on the parse result and, when the resolved
-- configuration is dumped, back under a @HermodTracing@ key. A configuration
-- without the key gets trace-dispatcher's minimal viable configuration, which is
-- likewise surfaced and rendered (so the @HermodTracing@ key always appears).
tracingCase :: TestTree
tracingCase =
  testCase "HermodTracing resolves to a TraceConfig (inline, file, default) and is always rendered" $ do
    inline <- parsed "test/examples/tracing-inline.json"
    fromFile <- parsed "test/examples/tracing-file.json"
    absent <- parsed "test/examples/legacy-fullconfig.json"
    renderedInline <- rendersTracing "test/examples/tracing-inline.json"
    renderedAbsent <- rendersTracing "test/examples/legacy-fullconfig.json"
    let asJSON = toJSON . tracingConfiguration
        deflt = toJSON mkConfiguration
    expectOk $
      if asJSON inline /= deflt -- the inline object was applied
        && asJSON fromFile /= deflt -- the referenced file was applied
        && asJSON absent == deflt -- no key falls back to trace-dispatcher's
        && renderedInline == Right True
        && renderedAbsent == Right True -- rendered even without a key
        then Nothing
        else
          Just $
            "unexpected tracing resolution: inlineIsDefault="
              <> show (asJSON inline == deflt)
              <> " fileIsDefault="
              <> show (asJSON fromFile == deflt)
              <> " absentIsDefault="
              <> show (asJSON absent == deflt)
              <> " renderedInline="
              <> show renderedInline
              <> " renderedAbsent="
              <> show renderedAbsent
 where
  parsed fp = getDataFileName fp >>= fmap fst . parseConfigurationFiles
  -- Whether the resolved configuration renders a HermodTracing key.
  rendersTracing fp = do
    path <- getDataFileName fp
    (cfg, _) <- parseConfigurationFiles path
    pure $ case cliArgs [] of
      Nothing -> Left "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Left ("resolve failed: " <> show e)
        Right (nc, _) -> case nodeConfigurationToJSON OmitGeneses nc of
          Object o -> Right (KM.member (K.fromString "HermodTracing") o)
          _ -> Left "rendered configuration was not an object"

-- | The @HermodTracing@ block in the shipped default configurations is not
-- applied to anything: tracing is the one part of the configuration
-- @cardano-config@ supplies no default for, because @trace-dispatcher@ falls
-- back on its own. The block is there to show a reader what that fallback is.
--
-- An illustration that is wrong is worse than none, so this pins it: each
-- file's block must be written exactly as @trace-dispatcher@ writes the
-- configuration it falls back to ('mkConfiguration'), minus the top-level keys
-- that fallback leaves empty.
--
-- It compares the block as written, not the 'TraceConfig' it resolves to,
-- because the two are not the same check. A key the parser does not know is
-- ignored, and the fallback then supplies the value the key was trying to give,
-- so a misspelling resolves correctly and only shows up here. If this fails,
-- copy the expected value the failure prints into both files.
tracingDefaultIllustrationCase :: TestTree
tracingDefaultIllustrationCase =
  testCase "the HermodTracing block in defaults/ is trace-dispatcher's fallback, as written" $
    mapM_ check ["defaults/config.blockproducer.json", "defaults/config.relay.json"]
 where
  check fp = do
    path <- getDataFileName fp
    committed <- eitherDecodeFileStrict' path
    case committed >>= tracingSectionOf of
      Left e -> assertFailure ("could not read " <> fp <> ": " <> e)
      Right tracing ->
        expectOk $
          if Object tracing == expected
            then Nothing
            else
              Just $
                fp
                  <> " does not show trace-dispatcher's fallback: "
                  <> show (Object tracing)
                  <> " /= "
                  <> show expected
  -- trace-dispatcher renders every top-level field, including the ones its
  -- fallback does not set. Those say nothing, so the files leave them out.
  expected = case toJSON mkConfiguration of
    Object o -> Object (KM.filter (/= Null) o)
    v -> v

-- | The @HermodTracing@ object inside a default configuration's envelope.
tracingSectionOf :: Value -> Either String Object
tracingSectionOf v = case v of
  Object top
    | Just (Object cfg) <- KM.lookup (K.fromString "Configuration") top ->
        case KM.lookup (K.fromString "HermodTracing") cfg of
          Just (Object tracing) -> Right tracing
          Just _ -> Left "Configuration.HermodTracing is not an object"
          Nothing -> Left "the default configuration has no Configuration.HermodTracing"
  _ -> Left "the default configuration has no Configuration object"

-- | With 'IncludeGeneses' the resolved configuration renders the decoded value
-- of every era genesis (Byron via its canonical-JSON form, the rest via the
-- ledger's aeson instances), not just the file references; with 'OmitGeneses'
-- none appear. These are the files read and hash-checked at parse time.
genesisRenderCase :: TestTree
genesisRenderCase =
  testCase "resolve renders era geneses only with IncludeGeneses" $ do
    path <- getDataFileName "test/examples/legacy-fullconfig.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Just ("resolve failed: " <> show e)
        Right (nc, _) ->
          let keysOf r = case nodeConfigurationToJSON r nc of
                Object o -> [k | k <- eras, maybe False nonEmpty (KM.lookup (K.fromString k) o)]
                _ -> []
              nonEmpty (Object m) = not (KM.null m)
              nonEmpty _ = False
           in if keysOf IncludeGeneses == eras && null (keysOf OmitGeneses)
                then Nothing
                else Just "geneses not gated correctly by IncludeGeneses/OmitGeneses"
 where
  eras = ["ByronGenesis", "ShelleyGenesis", "AlonzoGenesis", "ConwayGenesis"]

-- | The networking role defaults are chosen by credential presence: a credential
-- (here a VRF key) yields the block-producer targets (root 100, known 100,
-- PeerSharing disabled); no credential yields the relay targets (root 60, known
-- 150, PeerSharing enabled). These values are the node's
-- @defaultDeadlineTargets@ oracle.
roleSelectionCase :: TestTree
roleSelectionCase =
  testCase "network role defaults selected from credential presence" $ do
    path <- getDataFileName "test/examples/legacy-fullconfig.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case (cliArgs ["--shelley-vrf-key", "vrf.skey"], cliArgs []) of
      (Just bpCli, Just relayCli) ->
        case (resolveConfiguration bpCli cfg, resolveConfiguration relayCli cfg) of
          (Left e, _) -> Just ("block-producer resolve failed: " <> show e)
          (_, Left e) -> Just ("relay resolve failed: " <> show e)
          (Right (bpNc, _), Right (relayNc, _)) ->
            let bn = C.networkConfiguration bpNc
                rn = C.networkConfiguration relayNc
                ok =
                  deadlineTargetOfRootPeers bn == SJust 100
                    && deadlineTargetOfKnownPeers bn == SJust 100
                    && peerSharing bn == SJust PeerSharingDisabled
                    && deadlineTargetOfRootPeers rn == SJust 60
                    && deadlineTargetOfKnownPeers rn == SJust 150
                    && peerSharing rn == SJust PeerSharingEnabled
             in if ok
                  then Nothing
                  else Just "resolved role targets do not match the expected block-producer/relay values"
      _ -> Just "could not build CLI arguments"

-- | @--shelley-bls-key@ is parsed into 'shelleyBLSKey' and, alone, is enough to
-- make the node a block producer, as in @cardano-node@'s @hasProtocolFile@: it
-- yields the block-producer targets of 'roleSelectionCase'.
blsKeyRoleCase :: TestTree
blsKeyRoleCase =
  testCase "a BLS key alone selects the block-producer role" $ do
    path <- getDataFileName "test/examples/legacy-fullconfig.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs ["--shelley-bls-key", "bls.skey"] of
      Nothing -> Just "could not build CLI arguments"
      Just cli
        | shelleyBLSKey (credentials cli) /= SJust "bls.skey" ->
            Just ("BLS key not parsed: " <> show (shelleyBLSKey (credentials cli)))
        | otherwise -> case resolveConfiguration cli cfg of
            Left e -> Just ("resolve failed: " <> show e)
            Right (nc, _) ->
              let n = C.networkConfiguration nc
               in if deadlineTargetOfRootPeers n == SJust 100
                    && deadlineTargetOfKnownPeers n == SJust 100
                    && peerSharing n == SJust PeerSharingDisabled
                    then Nothing
                    else Just "a BLS key did not select the block-producer targets"

-- | An explicit file value for a role field wins over the role default, even
-- when credentials are present (block producer). Here PeerSharing and
-- TargetNumberOfRootPeers are set in the file; the remaining role fields still
-- come from the (block-producer) role default.
--
-- The root target is 99 rather than some larger round number because the peer
-- targets are checked against ouroboros-network's own predicate at resolution:
-- root peers may not exceed known peers, which the block-producer default puts
-- at 100 (see 'peerTargetsRejectedCase').
rolePrecedenceCase :: TestTree
rolePrecedenceCase =
  testCase "explicit file value overrides the role default" $ do
    path <- getDataFileName "test/examples/role-precedence.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs ["--shelley-vrf-key", "vrf.skey"] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Just ("resolve failed: " <> show e)
        Right (nc, _) ->
          let n = C.networkConfiguration nc
           in if peerSharing n == SJust PeerSharingEnabled -- file wins over the producer's Disabled
                && deadlineTargetOfRootPeers n == SJust 99 -- file wins over 100
                && deadlineTargetOfKnownPeers n == SJust 100 -- unset in file, block-producer default
                then Nothing
                else Just "explicit file values did not take precedence over the role default"

-- | A section that cannot be decoded from the merge is reported as a
-- 'C.SectionDecodeError' naming the section, not as 'C.ViolatedChecks'. The two
-- say different things about who is at fault, which is why they are separate.
--
-- A configuration file cannot reach this: every section is decoded from the
-- file's own text at parse time with the same codec resolution uses, so a file
-- that parses has sections that decode, and the shipped defaults add no key
-- that any cross-field rule reads. It is reached here the way the only caller
-- that can would, by resolving a 'NodeConfigurationFromFile' whose
-- 'userConfiguration' has been replaced.
sectionDecodeErrorCase :: TestTree
sectionDecodeErrorCase =
  testCase "a section that cannot be decoded is a decode error, not a violated check" $ do
    path <- getDataFileName "test/examples/all-sections.json"
    (cfg, _) <- parseConfigurationFiles path
    let broken = cfg{userConfiguration = section "Network" "DiffusionMode" (str "Nonsense")}
        section outer inner v =
          Object (KM.singleton (K.fromString outer) (Object (KM.singleton (K.fromString inner) v)))
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli broken of
        Right _ -> Just "a section that cannot be decoded resolved"
        Left (C.SectionDecodeError sec msg)
          | sec /= "Network" -> Just ("the wrong section was named: " <> sec)
          | not ("DiffusionMode" `isInfixOf` msg) ->
              Just ("the decode error does not name the field: " <> msg)
          | otherwise -> Nothing
        Left e -> Just ("not reported as a decode error: " <> show e)

-- | A configuration that states part of a nested object takes the rest of that
-- object's fields from the defaults, because the merge recurses rather than
-- replacing the object whole. Here only @HardLimit@ is set, so @SoftLimit@ and
-- @Delay@ stay at the shipped 384 and 5.
--
-- @AcceptedConnectionsLimit@ is the one place this can be observed: it is the
-- only defaulted nested object whose sub-keys are values in their own right.
-- @LedgerDB@ is the other nested object default and already reads every
-- sub-key optionally; the remaining nested objects sit under a default that is
-- a string (@DatabasePath@, @Backend@), which an object replaces whole, so
-- there is nothing there to inherit.
partialNestedObjectCase :: TestTree
partialNestedObjectCase =
  testCase "a partly stated AcceptedConnectionsLimit keeps the defaults for the rest" $ do
    path <- getDataFileName "test/examples/partial-accepted-connections-limit.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Just ("resolve failed: " <> show e)
        Right (nc, _) ->
          let limits = acceptedConnectionsLimitOf (C.networkConfiguration nc)
              expected = AcceptedConnectionsLimit 1000 384 5
           in if limits == expected
                then Nothing
                else Just ("unexpected limits: " <> show limits <> " /= " <> show expected)

-- | A @SoftLimit@ above the @HardLimit@ is rejected at resolution. The fixture
-- sets only @HardLimit@, at 100, so the rejection is of the shipped @SoftLimit@
-- of 384: lowering the hard limit alone is the way an operator reaches this.
-- The partial configuration that raises @HardLimit@ to 1000 resolves, so what
-- is being rejected is the ordering and not the fixture.
softAboveHardLimitCase :: TestTree
softAboveHardLimitCase =
  testCase "a SoftLimit above the HardLimit fails resolution" $ do
    above <- resolveExample "test/examples/accepted-connections-soft-above-hard.json"
    below <- resolveExample "test/examples/partial-accepted-connections-limit.json"
    expectOk $ case (above, below) of
      (Left msg, Right ())
        | "SoftLimit must be no greater than its HardLimit" `isInfixOf` msg -> Nothing
        | otherwise -> Just ("rejected, but not for the limits: " <> msg)
      (Right (), _) -> Just "a SoftLimit above the HardLimit resolved"
      (_, Left e) -> Just ("a SoftLimit below the HardLimit was rejected: " <> e)
 where
  resolveExample fp = do
    path <- getDataFileName fp
    (cfg, _) <- parseConfigurationFiles path
    pure $ case cliArgs [] of
      Nothing -> Left "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Left (show e)
        Right _ -> Right ()

-- | A peer target set ouroboros-network will not accept is rejected at
-- resolution, naming the group it is in. Its governor only asserts
-- 'sanePeerSelectionTargets', and @-O@ compiles assertions out, so without this
-- check a release node starts on such a set and runs peer selection on it.
--
-- One fixture per group, each breaking the ordering the predicate requires: the
-- deadline group asks for more active peers than established ones, the sync
-- group for more established peers than known ones. Both also exceed the
-- predicate's absolute caps, so neither depends on the role's other defaults.
-- The same configuration without the offending field resolves, so what is being
-- rejected is the target and not the fixture.
peerTargetsRejectedCase :: TestTree
peerTargetsRejectedCase =
  testCase "a peer target set ouroboros-network rejects fails resolution" $ do
    deadline <- resolveExample "test/examples/peer-targets-deadline-insane.json"
    sync <- resolveExample "test/examples/peer-targets-sync-insane.json"
    sane <- resolveExample "test/examples/role-precedence.json"
    expectOk $ case (deadline, sync, sane) of
      (Left dMsg, Left sMsg, Right ())
        | "Deadline peer targets" `isInfixOf` dMsg
        , "Sync peer targets" `isInfixOf` sMsg ->
            Nothing
        | otherwise ->
            Just ("rejected, but not for the peer targets: " <> dMsg <> " / " <> sMsg)
      (Right (), _, _) -> Just "an insane deadline target set resolved"
      (_, Right (), _) -> Just "an insane sync target set resolved"
      (_, _, Left e) -> Just ("the sane configuration was rejected too: " <> e)
 where
  resolveExample fp = do
    path <- getDataFileName fp
    (cfg, _) <- parseConfigurationFiles path
    pure $ case cliArgs [] of
      Nothing -> Left "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Left (show e)
        Right _ -> Right ()

-- | The two default configurations are one configuration in two roles: they
-- must differ only in the @Network@ fields that the role decides (the
-- deadline peer targets and @PeerSharing@). Anything else differing means one
-- file was edited and the other was not.
defaultConfigParityCase :: TestTree
defaultConfigParityCase =
  testCase "the two default configurations differ only in the role fields" $ do
    bp <- getDataFileName "defaults/config.blockproducer.json" >>= decodeFile
    relay <- getDataFileName "defaults/config.relay.json" >>= decodeFile
    expectOk $ case (bp >>= body, relay >>= body) of
      (Left e, _) -> Just e
      (_, Left e) -> Just e
      (Right b, Right r)
        | differing /= ["Network"] ->
            Just ("sections other than Network differ: " <> show differing)
        | not (null badKeys) ->
            Just ("Network differs outside the role fields: " <> show badKeys)
        | roleKeys /= sort roleFields ->
            Just ("the role fields that differ are " <> show roleKeys)
        | otherwise -> Nothing
       where
        differing = sort [K.toString k | (k, v) <- KM.toList b, KM.lookup k r /= Just v]
        net (Object o) = case KM.lookup (K.fromString "Network") o of
          Just (Object n) -> n
          _ -> KM.empty
        net _ = KM.empty
        roleKeys =
          sort [K.toString k | (k, v) <- KM.toList (net (Object b)), KM.lookup k (net (Object r)) /= Just v]
        badKeys = [k | k <- roleKeys, k `notElem` roleFields]
 where
  decodeFile fp = eitherDecodeFileStrict' fp :: IO (Either String Value)
  -- Only these three actually hold different values; the rest of the role
  -- overlay agrees between the two.
  roleFields =
    [ "DeadlineTargetNumberOfKnownPeers"
    , "DeadlineTargetNumberOfRootPeers"
    , "PeerSharing"
    ]
  body (Object top) = case KM.lookup (K.fromString "Configuration") top of
    Just (Object cfg) -> Right cfg
    _ -> Left "a default configuration has no Configuration object"
  body _ = Left "a default configuration is not an object"

-- | Neither shipped default enables the experimental hard forks. The flag gates
-- eras a network is not ready to run, and it is the bottom layer of every
-- resolution, so a default that turned it on would turn them on for every node
-- that does not say otherwise.
experimentalHardForksDefaultCase :: TestTree
experimentalHardForksDefaultCase =
  testCase "the default configurations leave ExperimentalHardForksEnabled off" $
    mapM_ check ["defaults/config.blockproducer.json", "defaults/config.relay.json"]
 where
  check fp = do
    path <- getDataFileName fp
    committed <- eitherDecodeFileStrict' path :: IO (Either String Value)
    expectOk $ case committed of
      Left e -> Just ("could not read " <> fp <> ": " <> e)
      Right v -> case lookupPath ["Configuration", "Testing", "ExperimentalHardForksEnabled"] v of
        Just (Bool False) -> Nothing
        other -> Just (fp <> " sets ExperimentalHardForksEnabled to " <> show other)
  lookupPath keys v = foldM step v keys
   where
    step (Object o) k = KM.lookup (K.fromString k) o
    step _ _ = Nothing

-- | All three mempool timeouts unset resolves to the coupled default (1, 1.5, 5).
mempoolAllUnsetCase :: TestTree
mempoolAllUnsetCase =
  testCase "mempool timeouts: all-unset takes the coupled (1, 1.5, 5) default" $
    expectOk
      ( case finalizeMempool (MempoolConfiguration SNothing SNothing SNothing SNothing) of
          Left e -> Just ("unexpected rejection: " <> e)
          Right c
            | runIdentity (mempoolTimeoutSoft c) == 1
            , runIdentity (mempoolTimeoutHard c) == 1.5
            , runIdentity (mempoolTimeoutCapacity c) == 5 ->
                Nothing
            | otherwise -> Just "wrong coupled-default timeout values"
      )

-- | All three mempool timeouts set are preserved unchanged.
mempoolAllSetCase :: TestTree
mempoolAllSetCase =
  testCase "mempool timeouts: all-set are preserved" $
    expectOk
      ( case finalizeMempool (MempoolConfiguration SNothing (SJust 2) (SJust 3) (SJust 4)) of
          Left e -> Just ("unexpected rejection: " <> e)
          Right c
            | runIdentity (mempoolTimeoutSoft c) == 2
            , runIdentity (mempoolTimeoutHard c) == 3
            , runIdentity (mempoolTimeoutCapacity c) == 4 ->
                Nothing
            | otherwise -> Just "set timeout values were not preserved"
      )

-- | A mix of set and unset mempool timeouts is rejected by 'finalizeMempool'.
mempoolMixedCase :: TestTree
mempoolMixedCase =
  testCase "mempool timeouts: a partial set is rejected" $
    expectOk
      ( case finalizeMempool (MempoolConfiguration SNothing (SJust 1) SNothing SNothing) of
          Left _ -> Nothing
          Right _ -> Just "expected a partial set of timeouts to be rejected"
      )

-- | The all-or-nothing rule surfaces end-to-end: a configuration that sets only
-- one timeout makes 'resolveConfiguration' fail with a 'ConfigResolutionError'.
mempoolMixedResolveCase :: TestTree
mempoolMixedResolveCase =
  testCase "test/examples/mempool-mixed.json (partial mempool timeouts rejected on resolve)" $ do
    path <- getDataFileName "test/examples/mempool-mixed.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left _ -> Nothing
        Right _ -> Just "expected resolution to reject a partial set of mempool timeouts"

-- | Parse @cardano-node@-style CLI arguments for a test (no defaults file is
-- needed; the parser supplies its own).
-- | The flat @Grpc*@ keys of @LocalConnections@ fold into the single
-- 'GrpcEndpoint' they describe: a unix socket, a plaintext (h2c) TCP listener
-- or a TLS one. The listen address defaults to loopback. Each endpoint also
-- survives a round trip through 'toJSON'.
grpcEndpointCase :: TestTree
grpcEndpointCase =
  testCase "the flat Grpc* keys fold into a GrpcEndpoint (and unfold again)" $
    expectOk (firstProblem (map check endpoints))
 where
  endpoints =
    [ ("a unix socket", [socketPathKey], GrpcEndpointUnixSocket "rpc.sock")
    , ("a plaintext listener", [portKey], GrpcEndpointHttp defaultGrpcListenAddress 3001)
    ,
      ( "a plaintext listener on a given address"
      , [addressKey, portKey]
      , GrpcEndpointHttp (ip "0.0.0.0") 3001
      )
    ,
      ( "a plaintext listener on IPv6"
      , [("GrpcListenAddress", str "::1"), portKey]
      , GrpcEndpointHttp (ip "::1") 3001
      )
    ,
      ( "a TLS listener"
      , [portKey, certificateKey, privateKeyKey]
      , GrpcEndpointHttps defaultGrpcListenAddress 3001 (GrpcTlsFiles "tls/server.pem" "tls/server.key" [])
      )
    ,
      ( "a TLS listener with a chain"
      , [addressKey, portKey, certificateKey, privateKeyKey, chainKey]
      , GrpcEndpointHttps
          (ip "0.0.0.0")
          3001
          (GrpcTlsFiles "tls/server.pem" "tls/server.key" ["tls/intermediate.pem"])
      )
    ]
  check (label, fields, expected) = case decodeLocalConnections fields of
    Left err -> Just (label <> ": did not decode: " <> err)
    Right cfg
      | grpcEndpoint cfg /= SJust expected ->
          Just (label <> ": decoded to " <> show (grpcEndpoint cfg) <> ", expected " <> show expected)
      | otherwise -> case fromJSON (toJSON cfg) :: Result (LocalConnectionsConfig StrictMaybe) of
          Error err -> Just (label <> ": did not re-decode what it rendered: " <> err)
          Success cfg'
            | grpcEndpoint cfg' /= grpcEndpoint cfg ->
                Just (label <> ": did not survive a round trip: " <> show (grpcEndpoint cfg'))
            | otherwise -> Nothing

-- | The @Grpc*@ key combinations that describe no single listener are rejected
-- as the section is parsed, naming the keys at fault.
grpcEndpointRejectionCase :: TestTree
grpcEndpointRejectionCase =
  testCase "a Grpc* key combination that describes no single listener is rejected" $
    expectOk (firstProblem (map check rejected))
 where
  rejected =
    [ ("a socket path and a listen port", [socketPathKey, portKey], "mutually exclusive")
    , ("a socket path and a listen address", [socketPathKey, addressKey], "mutually exclusive")
    , ("a socket path and TLS", [socketPathKey, certificateKey, privateKeyKey], "mutually exclusive")
    , ("a listen address with no port", [addressKey], "GrpcListenAddress requires GrpcListenPort")
    , ("TLS with no port", [certificateKey, privateKeyKey], "require GrpcListenPort")
    , ("a certificate with no private key", [portKey, certificateKey], "must be set together")
    , ("a private key with no certificate", [portKey, privateKeyKey], "must be set together")
    , ("a TLS chain with no credentials", [portKey, chainKey], "requires GrpcTlsCertificateFile")
    ]
  check (label, fields, expectedMessage) = case decodeLocalConnections fields of
    Right cfg -> Just (label <> ": was accepted, as " <> show (grpcEndpoint cfg))
    Left err
      | expectedMessage `isInfixOf` err -> Nothing
      | otherwise ->
          Just (label <> ": rejected, but not for " <> show expectedMessage <> ": " <> err)

-- | A command-line endpoint replaces the configuration file's whole, so a flag
-- meaning only to move the port also drops the file's TLS credentials. That is
-- reported as a 'ConsistencyWarning' rather than silently accepted.
--
-- The resolution still succeeds: replacing the endpoint is what the flags are
-- for, and the warning says what was lost. Passing the TLS flags alongside
-- keeps TLS and raises nothing, and so does passing no endpoint flag at all.
grpcTlsDowngradeCase :: TestTree
grpcTlsDowngradeCase =
  testCase "replacing a TLS gRPC endpoint from the command line warns" $ do
    path <- getDataFileName "test/examples/grpc-tls-listener.json"
    (cfg, _) <- parseConfigurationFiles path
    let resolveWith args = case cliArgs args of
          Nothing -> Left "could not build CLI arguments"
          Just cli -> case resolveConfiguration cli cfg of
            Left e -> Left ("resolve failed: " <> show e)
            Right (_, ws) -> Right [w | w <- map renderConfigWarning ws, "plaintext" `isInfixOf` w]
        movedPort = resolveWith ["--grpc-listen-port", "4001"]
        keptTls =
          resolveWith
            [ "--grpc-listen-port"
            , "4001"
            , "--grpc-tls-certificate"
            , "tls/server.pem"
            , "--grpc-tls-private-key"
            , "tls/server.key"
            ]
        untouched = resolveWith []
    expectOk $ case (movedPort, keptTls, untouched) of
      (Left e, _, _) -> Just e
      (_, Left e, _) -> Just e
      (_, _, Left e) -> Just e
      (Right dropped, Right kept, Right none)
        | length dropped /= 1 -> Just ("moving the port did not warn once: " <> show dropped)
        | not (null kept) -> Just ("keeping TLS still warned: " <> show kept)
        | not (null none) -> Just ("no endpoint flag still warned: " <> show none)
        | otherwise -> Nothing

-- | The same endpoint, from the command line: the unix-socket flag and the TCP
-- ones are alternatives, so giving both fails the parse, as does an address or
-- a TLS credential with no port to listen on.
grpcEndpointCliCase :: TestTree
grpcEndpointCliCase =
  testCase "the gRPC endpoint flags build the endpoint, and exclude each other" $
    expectOk (firstProblem (map accepts accepted <> map rejects rejected))
 where
  accepted =
    [ (["--grpc-socket-path", "rpc.sock"], GrpcEndpointUnixSocket "rpc.sock")
    , (["--grpc-listen-port", "3001"], GrpcEndpointHttp defaultGrpcListenAddress 3001)
    ,
      ( ["--grpc-listen-address", "0.0.0.0", "--grpc-listen-port", "3001"]
      , GrpcEndpointHttp (ip "0.0.0.0") 3001
      )
    ,
      (
        [ "--grpc-listen-port"
        , "3001"
        , "--grpc-tls-certificate"
        , "tls/server.pem"
        , "--grpc-tls-private-key"
        , "tls/server.key"
        , "--grpc-tls-chain-certificate"
        , "tls/intermediate.pem"
        ]
      , GrpcEndpointHttps
          defaultGrpcListenAddress
          3001
          (GrpcTlsFiles "tls/server.pem" "tls/server.key" ["tls/intermediate.pem"])
      )
    ]
  rejected =
    [
      ( "a socket path and a listen port"
      , ["--grpc-socket-path", "rpc.sock", "--grpc-listen-port", "3001"]
      )
    , ("a listen address with no port", ["--grpc-listen-address", "0.0.0.0"])
    ,
      ( "TLS with no port"
      , ["--grpc-tls-certificate", "tls/server.pem", "--grpc-tls-private-key", "tls/server.key"]
      )
    ,
      ( "a certificate with no private key"
      , ["--grpc-listen-port", "3001", "--grpc-tls-certificate", "tls/server.pem"]
      )
    , ("a port out of range", ["--grpc-listen-port", "65536"])
    ]
  accepts (args, expected) = case cliArgs args of
    Nothing -> Just (show args <> ": did not parse")
    Just cli
      | grpcEndpointCLI cli /= SJust expected ->
          Just (show args <> ": parsed to " <> show (grpcEndpointCLI cli) <> ", expected " <> show expected)
      | otherwise -> Nothing
  rejects (label, args) = case cliArgs args of
    Nothing -> Nothing
    Just cli -> Just (label <> ": was accepted, as " <> show (grpcEndpointCLI cli))

-- | Enabling the gRPC server requires a node socket path, whichever endpoint it
-- listens on. The server serves every request over the node-to-client socket,
-- so a TCP listener changes where it listens, not whether it needs that
-- socket: @cardano-node@\'s @makeRpcConfig@ refuses @EnableGrpc@ without
-- @SocketPath@ in every case, and this check has to agree or the configuration
-- resolves here and dies at startup.
--
-- So @--grpc-enable@ alone is a resolution error, and so is
-- @--grpc-enable --grpc-listen-port 3001@. With a node socket path both are
-- accepted, and the endpoint itself stays unset when none was asked for, so
-- the consumer derives @rpc.sock@ beside the node socket.
grpcEnabledEndpointCheckCase :: TestTree
grpcEnabledEndpointCheckCase =
  testCase "enabling gRPC requires a node socket path, whatever it listens on" $ do
    path <- getDataFileName "test/examples/legacy-fullconfig.json"
    (cfg, _) <- parseConfigurationFiles path
    let resolveWith args = case cliArgs ("--config" : path : args) of
          Nothing -> Left ("could not build CLI arguments: " <> show args)
          Just cli -> either (Left . show) (Right . fst) (resolveConfiguration cli cfg)
        socket = ["--socket-path", "node.socket"]
    expectOk $ case ( resolveWith ["--grpc-enable"]
                    , resolveWith ["--grpc-enable", "--grpc-listen-port", "3001"]
                    , resolveWith (["--grpc-enable", "--grpc-listen-port", "3001"] <> socket)
                    , resolveWith (["--grpc-enable"] <> socket)
                    ) of
      (Right _, _, _, _) -> Just "gRPC enabled with no node socket path was accepted"
      (_, Right _, _, _) ->
        Just "gRPC enabled on a listen port with no node socket path was accepted"
      (_, _, Left err, _) -> Just ("gRPC on a listen port with a node socket was rejected: " <> err)
      (_, _, _, Left err) -> Just ("gRPC with a node socket path was rejected: " <> err)
      (Left _, Left _, Right onPort, Right onSocket)
        | grpcEndpoint (C.localConnectionsConfig onPort)
            /= SJust (GrpcEndpointHttp defaultGrpcListenAddress 3001) ->
            Just
              ("the listen port did not resolve to a TCP endpoint: " <> show (C.localConnectionsConfig onPort))
        -- Left unset, so that the consumer derives rpc.sock beside the node socket.
        | isSJust (grpcEndpoint (C.localConnectionsConfig onSocket)) ->
            Just ("a node socket path invented an endpoint: " <> show (C.localConnectionsConfig onSocket))
        | otherwise -> Nothing

-- | The numeric options take plain decimal only. @readEither@ on its own also
-- accepts Haskell\'s hexadecimal and octal literals and surrounding whitespace,
-- so @--grpc-listen-port 0x1F1@ used to bind port 497 quietly, and @0o17@ port
-- 15. @cardano-node@ rejects both, and so does every use of @bounded@ now.
boundedDecimalOnlyCase :: TestTree
boundedDecimalOnlyCase =
  testCase "numeric options take decimal only (no hex, octal or padding)" $
    expectOk (firstProblem (map check inputs))
 where
  -- (argument, the port it must resolve to, or Nothing if it must be refused)
  inputs =
    [ ("3001", Just 3001)
    , ("0x1F1", Nothing)
    , ("0o17", Nothing)
    , (" 12 ", Nothing)
    , ("12x", Nothing)
    , ("", Nothing)
    , ("-1", Nothing) -- read, then refused by the lower bound
    , ("99999", Nothing) -- refused by the upper bound, as before
    ]
  check (arg, expected) =
    case (grpcEndpointCLI <$> cliArgs ["--config", "c.json", "--grpc-listen-port", arg], expected) of
      (Nothing, Nothing) -> Nothing
      (Nothing, Just p) -> Just (show arg <> ": was refused, expected port " <> show p)
      (Just got, Nothing) -> Just (show arg <> ": was accepted as " <> show got)
      (Just got, Just p)
        | got == SJust (GrpcEndpointHttp defaultGrpcListenAddress p) -> Nothing
        | otherwise -> Just (show arg <> ": parsed to " <> show got <> ", expected port " <> show p)

-- | The cross-field rules the parser enforces are stated in the schemas too, so
-- a validator rejects the documents the parser rejects. This pins that they are
-- stated at all, and on the section a configuration actually writes them
-- under, which the drift test would not catch, because it compares the
-- committed files against the generator.
schemaConstraintsCase :: TestTree
schemaConstraintsCase =
  testCase "the schemas state the parser's cross-field rules" $ do
    results <- mapM check checks
    expectOk (firstProblem results)
 where
  checks =
    [ ("LocalConnections", "the gRPC endpoint exclusions", hasDependencies grpcKeys)
    , ("Mempool", "the coupled mempool timeouts", hasDependencies mempoolTimeoutKeys)
    , ("Testing", "the Dijkstra genesis file/hash pair", hasDependencies dijkstraKeys)
    , ("Testing", "the experimental-eras requirement", hasIfThen)
    , ("Storage", "the non-zero snapshot Interval", hasMinimum "Interval" 1)
    ]
  grpcKeys =
    [ "GrpcSocketPath"
    , "GrpcListenAddress"
    , "GrpcTlsCertificateFile"
    , "GrpcTlsPrivateKeyFile"
    , "GrpcTlsChainCertificateFiles"
    ]
  mempoolTimeoutKeys = ["MempoolTimeoutSoft", "MempoolTimeoutHard", "MempoolTimeoutCapacity"]
  dijkstraKeys = ["DijkstraGenesisFile", "DijkstraGenesisHash"]
  -- A component's rules are stated on its section of the configuration schema.
  check (name, what, holds) = do
    res <- fmap (>>= sectionOf name) (decodeData "schemas/config.schema.json")
    pure $ case res :: Either String Value of
      Left err -> Just (name <> ": " <> err)
      Right v
        | holds v -> Nothing
        | otherwise -> Just (name <> " does not state " <> what)
  -- The named section of config.schema.json: root.Configuration.<name>.
  sectionOf name v = case propertyOf name =<< propertyOf "Configuration" v of
    Just section -> Right section
    Nothing -> Left ("config.schema.json has no " <> name <> " section")
  propertyOf name (Object o)
    | Just (Object props) <- KM.lookup (K.fromString "properties") o =
        KM.lookup (K.fromString name) props
  propertyOf _ _ = Nothing
  hasDependencies ks v = all (\k -> KM.member (K.fromString k) (dependenciesOf v)) ks
  dependenciesOf (Object o) | Just (Object d) <- KM.lookup (K.fromString "dependencies") o = d
  dependenciesOf _ = KM.empty
  hasIfThen (Object o)
    | Just (Array branches) <- KM.lookup (K.fromString "allOf") o = any isIfThen branches
  hasIfThen _ = False
  isIfThen (Object b) = KM.member (K.fromString "if") b && KM.member (K.fromString "then") b
  isIfThen _ = False
  -- The minimum stated for a property of this name, wherever it appears.
  hasMinimum name n v = minimaFor name v == [Number n]
  minimaFor name = go
   where
    go (Object o) =
      [ m
      | Just (Object props) <- [KM.lookup (K.fromString "properties") o]
      , Just (Object c) <- [KM.lookup (K.fromString name) props]
      , Just m <- [KM.lookup (K.fromString "minimum") c]
      ]
        <> concatMap go (KM.elems o)
    go (Array a) = concatMap go a
    go _ = []

-- | The node rejects a zero snapshot interval, so the parser does too (and the
-- schema says @minimum: 1@ rather than the 0 a 'Data.Word.Word64' would allow).
snapshotIntervalCase :: TestTree
snapshotIntervalCase =
  testCase "a zero snapshot Interval is rejected" $
    expectOk $ case (decodeInterval 0, decodeInterval 1) of
      (Right _, _) -> Just "Interval 0 was accepted"
      (_, Left err) -> Just ("Interval 1 was rejected: " <> err)
      (Left _, Right _) -> Nothing
 where
  decodeInterval n =
    case fromJSON (obj [("LedgerDB", obj [("Snapshots", obj [("Interval", Number n)])])]) ::
           Result (StorageConfiguration StrictMaybe) of
      Error err -> Left err
      Success cfg -> Right cfg

-- | The first problem reported by a list of checks, if any.
firstProblem :: [Maybe String] -> Maybe String
firstProblem problems = case [p | Just p <- problems] of
  (p : _) -> Just p
  [] -> Nothing

-- | An IP address written the way the configuration and the command line write
-- it (the test module does not enable @OverloadedStrings@).
ip :: String -> IP
ip = read

-- | Decode a @LocalConnectionsConfig@ from the given keys alone.
decodeLocalConnections :: [(String, Value)] -> Either String (LocalConnectionsConfig StrictMaybe)
decodeLocalConnections fields = case fromJSON (obj fields) of
  Error err -> Left err
  Success cfg -> Right cfg

-- The individual Grpc* keys the cases above combine.
socketPathKey, addressKey, portKey, certificateKey, privateKeyKey, chainKey :: (String, Value)
socketPathKey = ("GrpcSocketPath", str "rpc.sock")
addressKey = ("GrpcListenAddress", str "0.0.0.0")
portKey = ("GrpcListenPort", Number 3001)
certificateKey = ("GrpcTlsCertificateFile", str "tls/server.pem")
privateKeyKey = ("GrpcTlsPrivateKeyFile", str "tls/server.key")
chainKey = ("GrpcTlsChainCertificateFiles", Array (pure (str "tls/intermediate.pem")))

-- | A JSON string (the test module does not enable @OverloadedStrings@).
str :: String -> Value
str = String . T.pack

cliArgs :: [String] -> Maybe CliArgs
cliArgs = getParseResult . execParserPure defaultPrefs (info parseCliArgs mempty)

-- | The snapshot fields, in a fixed order, for comparison.
snapshotFields :: SnapshotOptions -> [Maybe Word64]
snapshotFields o =
  map
    strictMaybeToMaybe
    [ snapshotInterval o
    , slotOffset o
    , snapshotRateLimit o
    , minDelay o
    , maxDelay o
    , numOfDiskSnapshots o
    ]

-- | The concrete values the @"Mithril"@ policy resolves to.
mithrilFields :: [Maybe Word64]
mithrilFields = [Just 86400, Just 0, Just 600, Just 300, Just 21600, Just 2]

-- | End-to-end: a configuration that uses the base @"Mithril"@ default and one
-- that sets only a couple of snapshot options both resolve to the full concrete
-- Mithril option set (the partial one inheriting the rest).
snapshotMithrilResolveCase :: TestTree
snapshotMithrilResolveCase =
  testCase "Mithril snapshot policy resolves to concrete values (filling partial overrides)" $ do
    fromMithril <- resolvedOptions "test/examples/role-precedence.json" -- no Snapshots ⇒ base (Mithril values)
    fromPartial <- resolvedOptions "test/examples/legacy-fullconfig.json" -- sets 3 of 6 (= Mithril)
    expectOk $ case (fromMithril, fromPartial) of
      (Right a, Right b)
        | a == mithrilFields && b == mithrilFields -> Nothing
        | otherwise -> Just ("unexpected resolved options: " <> show a <> " / " <> show b)
      (Left e, _) -> Just e
      (_, Left e) -> Just e
 where
  resolvedOptions cfgFile = do
    path <- getDataFileName cfgFile
    (cfg, _) <- parseConfigurationFiles path
    pure $ case cliArgs [] of
      Nothing -> Left "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Left (show e)
        Right (nc, _) -> case snapshots (runIdentity (ledgerDbConfiguration (C.storageConfiguration nc))) of
          SJust (CustomSnapshotPolicy o) -> Right (snapshotFields o)
          other -> Left ("expected resolved custom snapshot options, got " <> show other)

-- | 'resolveSnapshotPolicy': @"Mithril"@ yields its values, and a partial custom
-- policy keeps the value it set (here a distinct @Interval@) while the
-- rest are inherited from Mithril.
snapshotResolvePolicyCase :: TestTree
snapshotResolvePolicyCase =
  testCase "resolveSnapshotPolicy fills a partial custom policy from Mithril" $
    expectOk
      ( let mithril = snapshotFields (resolveSnapshotPolicy MithrilSnapshotPolicy)
            partial = SnapshotOptions (SJust 7777) SNothing SNothing SNothing SNothing SNothing
            filled = snapshotFields (resolveSnapshotPolicy (CustomSnapshotPolicy partial))
         in if mithril == mithrilFields
              && filled == [Just 7777, Just 0, Just 600, Just 300, Just 21600, Just 2]
              then Nothing
              else Just ("unexpected: mithril=" <> show mithril <> " filled=" <> show filled)
      )

-- | The Mithril policy under the V2LSM backend without an @LSMExportPath@ is
-- accepted, but resolution surfaces a non-fatal 'ConsistencyWarning'. The fixture
-- sets no @Snapshots@, so it inherits the defaults, which spell the Mithril values
-- out rather than name the @"Mithril"@ policy: the check matches them by value.
mithrilRequiresExportCase :: TestTree
mithrilRequiresExportCase =
  testCase "Mithril + V2LSM without LSMExportPath resolves with a warning" $ do
    path <- getDataFileName "test/examples/lsm-mithril-no-export.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Just ("expected acceptance with a warning, got rejection: " <> show e)
        Right (_, warnings)
          | any isConsistencyWarning warnings -> Nothing
          | otherwise -> Just ("expected a ConsistencyWarning, got: " <> show warnings)
 where
  isConsistencyWarning ConsistencyWarning{} = True
  isConsistencyWarning _ = False

-- | The V2LSM backend defaults its database path to @"lsm"@ when the
-- configuration leaves @LSMDatabasePath@ unset.
lsmDatabasePathDefaultCase :: TestTree
lsmDatabasePathDefaultCase =
  testCase "V2LSM defaults LSMDatabasePath to \"lsm\" when unset" $ do
    path <- getDataFileName "test/examples/lsm-mithril-export.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Just ("resolve failed: " <> show e)
        Right (nc, _) -> case backendSelector (runIdentity (ledgerDbConfiguration (C.storageConfiguration nc))) of
          SJust (V2LSM (SJust "lsm") (SJust "export-dir")) -> Nothing
          other -> Just ("unexpected backend: " <> show other)

-- | The Dijkstra genesis example decodes through the ledger's aeson instance
-- (the pinned hash is checked, so the read verifies the file too).
--
-- Genesis initial-data injection files are resolved against the directory
-- holding the /Shelley genesis/, not the one holding the configuration file.
-- The fixture keeps its geneses (and the files they inject) in a subdirectory,
-- so the two differ and a consumer that guessed the configuration directory
-- would look in the wrong place.
injectionRootCase :: TestTree
injectionRootCase =
  testCase "the genesis injection root is the Shelley genesis directory" $ do
    path <- getDataFileName "test/examples/injection.json"
    (cfg, _) <- parseConfigurationFiles path
    let root = genesisInjectionRoot cfg
    missing <-
      missingInjectionFiles
        root
        (injectionSlots (shelleyGenesisConfig cfg) (conwayGenesisConfig cfg))
    expectOk $
      if takeFileName root /= "injection-genesis"
        then Just ("unexpected injection root: " <> root)
        else
          if root == takeDirectory path
            then Just "the injection root must not be the configuration directory"
            else case missing of
              [] -> Nothing
              ms -> Just ("injection files not found under the root: " <> show (map snd ms))

-- | Every injectable field is reported with the source it actually takes its
-- data from: the three the fixture fills come from files (with the @FsPath@ the
-- genesis named), the rest from nowhere. The configuration resolves cleanly.
injectionSlotsCase :: TestTree
injectionSlotsCase =
  testCase "injection slots report their file sources, and the config resolves" $ do
    path <- getDataFileName "test/examples/injection.json"
    (cfg, _) <- parseConfigurationFiles path
    let slots = injectionSlots (shelleyGenesisConfig cfg) (conwayGenesisConfig cfg)
        files =
          [ (slotExtraField s, map T.unpack (fsPathToList fp))
          | (s, fp) <- fileInjections slots
          ]
        expected =
          [ ("extraConfig.initialFunds", ["initial-funds.json"])
          , ("extraConfig.stakePools", ["stake-pools.json"])
          , ("extraConfig.delegs", ["delegs.json"])
          ]
        inline = [renderInjectionSlot s | s <- slots, slotSource s == InjectedInline]
    expectOk $
      if files /= expected
        then Just ("unexpected file injections: " <> show files)
        else
          if not (null inline)
            then Just ("unexpected inline injections: " <> show inline)
            else case cliArgs [] of
              Nothing -> Just "could not build CLI arguments"
              Just cli -> case resolveConfiguration cli cfg of
                Left e -> Just ("resolve failed: " <> show e)
                Right _ -> Nothing

-- | Setting both a legacy genesis field and its @extraConfig@ counterpart is
-- what @cardano-ledger@'s @resolveInjectionSource@ rejects; the parser catches
-- it first, naming the field.
injectionConflictCase :: TestTree
injectionConflictCase =
  testCase "a legacy genesis field and its extraConfig counterpart conflict" $
    expectInjectionRejection
      "test/examples/injection-conflict.json"
      "extraConfig.initialFunds (legacy initialFunds) takes its initial data from both"

-- | Injection is a test-network facility: a mainnet genesis that asks for it is
-- rejected, as the ledger would.
injectionMainnetCase :: TestTree
injectionMainnetCase =
  testCase "genesis injection is rejected on a mainnet genesis" $
    expectInjectionRejection
      "test/examples/injection-mainnet.json"
      "only allowed on a test network"

-- | A referenced injection file that does not exist is reported while the
-- configuration is read, rather than as a filesystem error thrown much later,
-- when the node builds its initial ledger state.
injectionMissingFileCase :: TestTree
injectionMissingFileCase =
  testCase "a missing genesis injection file is rejected at parse time" $
    expectInjectionRejection
      "test/examples/injection-missing.json"
      "no-such-initial-funds.json, which does not exist"

-- | Parsing the configuration must fail, with an error mentioning the given
-- text. Used for the genesis-injection problems the parser reports: they are all
-- thrown as a 'ConfigurationParsingError' attributed to the genesis key at
-- fault.
expectInjectionRejection :: FilePath -> String -> Assertion
expectInjectionRejection fixture expected = do
  path <- getDataFileName fixture
  res <- try (parseConfigurationFiles path >>= \c -> evaluate (length (show c)))
  expectOk $ case res of
    Left (e :: SomeException)
      | expected `isInfixOf` show e -> Nothing
      | otherwise -> Just ("rejected, but with an unexpected error: " <> show e)
    Right _ -> Just ("expected rejection mentioning " <> show expected)

dijkstraGenesisDecodeCase :: TestTree
dijkstraGenesisDecodeCase =
  testCase "test/examples/dijkstra-genesis.json (decodes via the ledger instance)" $ do
    path <- getDataFileName "test/examples/dijkstra-genesis.json"
    res <-
      readGenesisFile @DijkstraGenesis
        ( fromJust $
            hashFromTextAsHex (T.pack "d939e640f5aece1b33b15345b7ae095aa2d8f93f703292e8ec1564c6b02d5f30")
        )
        path
    case res of
      Left err -> assertFailure (show err)
      Right g -> () <$ evaluate (length (show g))

-- | Reading a genesis file with a wrong expected hash is rejected.
dijkstraGenesisHashMismatchCase :: TestTree
dijkstraGenesisHashMismatchCase =
  testCase "test/examples/dijkstra-genesis.json (wrong hash is rejected)" $ do
    path <- getDataFileName "test/examples/dijkstra-genesis.json"
    let wrongHash :: Hash Blake2b_256 a
        wrongHash = fromJust $ hashFromTextAsHex (T.pack (replicate 64 '0'))
    res <- readGenesisFile @DijkstraGenesis wrongHash path
    expectOk $ case res of
      Left (GenesisHashMismatch{}) -> Nothing
      Left err -> Just ("expected a hash mismatch, got: " <> show err)
      Right _ -> Just "expected a hash mismatch, but the read succeeded"

-- | A @DijkstraGenesisFile@ without a @DijkstraGenesisHash@ is rejected at parse
-- time: a genesis file must come with a pinned hash.
genesisHashRequiredCase :: TestTree
genesisHashRequiredCase =
  testCase "test/examples/testing-dijkstra-nohash.json (genesis file requires a hash)" $ do
    res <-
      decodeData "test/examples/testing-dijkstra-nohash.json" ::
        IO (Either String (TestingConfiguration StrictMaybe))
    expectOk $ case res of
      Left err
        | "DijkstraGenesisHash" `isInfixOf` err -> Nothing
        | otherwise -> Just ("rejected, but with an unexpected error: " <> err)
      Right _ -> Just "expected rejection (missing DijkstraGenesisHash), but decoding succeeded"

-- | A @DijkstraGenesisFile@ accompanied by a @DijkstraGenesisHash@ decodes.
genesisHashPresentCase :: TestTree
genesisHashPresentCase =
  decodeCase
    "test/examples/testing-dijkstra.json (genesis file + hash decodes)"
    ( decodeData "test/examples/testing-dijkstra.json" ::
        IO (Either String (TestingConfiguration StrictMaybe))
    )

-- | The experimental (Dijkstra) genesis is gated on the
-- @ExperimentalHardForksEnabled@ testing flag, as it is in @cardano-node@: with
-- the flag off the named @DijkstraGenesisFile@ is ignored outright and
-- 'experimentalGenesisConfig' is 'SNothing' on both the parse result and the
-- resolved configuration; with the flag on it is read, hash-checked and decoded
-- into an 'SJust'.
--
-- The gated-off fixture pins a deliberately wrong @DijkstraGenesisHash@, so
-- parsing it at all proves the file is not merely dropped after being read: it
-- is never opened.
--
-- Neither case says anything about it. A @DijkstraGenesisFile@ named while the
-- flag is off is passed over in silence, deliberately: turning the flag on
-- hard-forks the node onto an experimental era, which is coordinated across a
-- network, so no warning should read as a nudge towards it. This pins that
-- parsing is silent in both cases.
experimentalGenesisGateCase :: TestTree
experimentalGenesisGateCase =
  testCase "the Dijkstra genesis is gated on ExperimentalHardForksEnabled" $ do
    (off, offWarnings) <- getDataFileName gatedOff >>= parseConfigurationFiles
    (on, onWarnings) <- getDataFileName gatedOn >>= parseConfigurationFiles
    -- Nothing may mention the ignored file, by name or otherwise.
    let mentions ws = [w | w <- map renderConfigWarning ws, "ijkstra" `isInfixOf` w]
    case cliArgs [] of
      Nothing -> assertFailure "could not build default CLI arguments"
      Just cli -> do
        offResolved <- resolved cli off
        onResolved <- resolved cli on
        expectOk $
          case (experimentalGenesisConfig off, experimentalGenesisConfig on) of
            (SNothing, SJust _)
              | SNothing <- C.experimentalGenesisConfig offResolved
              , SJust _ <- C.experimentalGenesisConfig onResolved
              , null (mentions offWarnings)
              , null (mentions onWarnings) ->
                  Nothing
            _ ->
              Just $
                "unexpected gating: off="
                  <> show (isSJust (experimentalGenesisConfig off))
                  <> " offResolved="
                  <> show (isSJust (C.experimentalGenesisConfig offResolved))
                  <> " on="
                  <> show (isSJust (experimentalGenesisConfig on))
                  <> " onResolved="
                  <> show (isSJust (C.experimentalGenesisConfig onResolved))
                  <> " offMentions="
                  <> show (mentions offWarnings)
                  <> " onMentions="
                  <> show (mentions onWarnings)
 where
  gatedOff = "test/examples/dijkstra-gated-off.json"
  gatedOn = "test/examples/dijkstra-gated-on.json"
  resolved cli cfg =
    either (assertFailure . show) (pure . fst) (resolveConfiguration cli cfg)

-- | The other half of the gating: @ExperimentalHardForksEnabled: true@ without a
-- @DijkstraGenesisFile@ is rejected outright, as it is by @cardano-node@ (which
-- makes the genesis file a mandatory key of the block it parses only when the
-- flag is on). Enabling an era with no genesis to run it from is not a
-- configuration anyone meant to write.
--
-- The rejection is a resolution error, not a parse error, because
-- 'finalizeTesting' is where both keys are in hand; parsing the file on its own
-- still succeeds. The message is asserted on, not merely the failure: someone who
-- turned the flag on has to be able to fix their file from it, so it names both
-- keys.
experimentalGenesisRequiredCase :: TestTree
experimentalGenesisRequiredCase =
  testCase "ExperimentalHardForksEnabled without a DijkstraGenesisFile is rejected" $ do
    (cfg, _) <- getDataFileName fixture >>= parseConfigurationFiles
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build default CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Right _ -> Just "expected the configuration to be rejected, but it resolved"
        Left err
          | all (`isInfixOf` show err) named -> Nothing
          | otherwise -> Just ("rejected, but with an unexpected message: " <> show err)
 where
  fixture = "test/examples/dijkstra-gated-on-nofile.json"
  -- The message has to name the flag, the key to add and its hash key.
  named = ["ExperimentalHardForksEnabled", "DijkstraGenesisFile", "DijkstraGenesisHash"]

-- | The Byron genesis decodes (canonical JSON) and its hash checks out via the
-- ledger's reader. The expected hash is the real mainnet Byron genesis hash.
byronGenesisDecodeCase :: TestTree
byronGenesisDecodeCase =
  testCase "test/examples/mainnet-byron-genesis.json (decodes + hash-checks via the ledger)" $ do
    path <- getDataFileName "test/examples/mainnet-byron-genesis.json"
    case hashFromTextAsHex (T.pack "5f20df933584822601f9e3f8c024eb5eb252fe8cefb24d1317dc3d432e940ebb") of
      Nothing -> assertFailure "could not parse the expected Byron genesis hash"
      Just expected -> do
        res <- readByronGenesisConfig RequiresNoMagic expected path
        expectOk (either (Just . ("Byron read failed: " <>)) (const Nothing) res)

-- | A configuration written without genesis hashes reads as a document, and
-- once its hashes are filled in it parses with every genesis file checked.
refreshMissingHashesCase :: TestTree
refreshMissingHashesCase =
  testCase "refreshGenesisHashes fills in the genesis hashes a configuration leaves out" $
    withEditFixtures $ \dir -> do
      (document, _) <- configurationDocumentFromValue (editConfiguration [])
      refreshed <- refreshGenesisHashes dir document
      writeConfigurationDocument (dir </> "config.json") refreshed
      expectEditHashes (dir </> "config.json")

-- | A configuration whose genesis hashes are out of date is rejected when
-- parsed, still reads as a document, and parses once its hashes are refreshed.
refreshStaleHashesCase :: TestTree
refreshStaleHashesCase =
  testCase "refreshGenesisHashes replaces genesis hashes that are out of date" $
    withEditFixtures $ \dir -> do
      let file = dir </> "config.json"
          stale = replicate 64 '0'
      encodeFile file . editConfiguration $
        [ (key, stale)
        | key <-
            [ "ByronGenesisHash"
            , "ShelleyGenesisHash"
            , "AlonzoGenesisHash"
            , "ConwayGenesisHash"
            , "DijkstraGenesisHash"
            ]
        ]
      rejected <- try @SomeException (parseConfigurationFiles file)
      assertBool "the out-of-date hashes are rejected" (either (const True) (const False) rejected)
      (document, _) <- readConfigurationDocument file
      refreshGenesisHashes dir document >>= writeConfigurationDocument file
      expectEditHashes file

-- | Writing a document and reading it back gives the same document.
documentRoundTripCase :: TestTree
documentRoundTripCase =
  testCase "readConfigurationDocument reads back what writeConfigurationDocument wrote" $
    withSystemTempDirectory "cardano-config-edit" $ \dir -> do
      (document, _) <- getDataFileName "test/examples/all-sections.json" >>= readConfigurationDocument
      writeConfigurationDocument (dir </> "config.json") document
      (document', _) <- readConfigurationDocument (dir </> "config.json")
      assertBool "the document changed on the way" (document == document')

-- | Run an edit case in a fresh directory holding the genesis files
-- 'editConfiguration' names.
withEditFixtures :: (FilePath -> IO a) -> IO a
withEditFixtures k =
  withSystemTempDirectory "cardano-config-edit" $ \dir -> do
    mapM_
      ( \file -> do
          source <- getDataFileName ("test/examples" </> file)
          copyFile source (dir </> file)
      )
      [ "mainnet-byron-genesis.json"
      , "mainnet-shelley-genesis.json"
      , "mainnet-alonzo-genesis.json"
      , "mainnet-conway-genesis.json"
      , "dijkstra-genesis.json"
      ]
    k dir

-- | A flat configuration naming the mainnet genesis files and the Dijkstra one,
-- with the given extra keys (hashes).
editConfiguration :: [(String, String)] -> Value
editConfiguration extra =
  Object . KM.fromList $
    [ (K.fromString k, String (T.pack v))
    | (k, v) <-
        [ ("ByronGenesisFile", "mainnet-byron-genesis.json")
        , ("ShelleyGenesisFile", "mainnet-shelley-genesis.json")
        , ("AlonzoGenesisFile", "mainnet-alonzo-genesis.json")
        , ("ConwayGenesisFile", "mainnet-conway-genesis.json")
        , ("DijkstraGenesisFile", "dijkstra-genesis.json")
        ]
          <> extra
    ]
      <> [(K.fromString "ExperimentalHardForksEnabled", Bool True)]

-- | The configuration parses, with every genesis file read and checked, and its
-- genesis hashes are the mainnet ones.
expectEditHashes :: FilePath -> Assertion
expectEditHashes file = do
  (config, _) <- parseConfigurationFiles file
  let protocol = protocolConfiguration config
      hashText = T.unpack . hashToTextAsHex
  assertBool "the Dijkstra genesis is read" (isSJust (experimentalGenesisConfig config))
  mapM_
    ( \(era, actual, expected) ->
        assertBool (era <> " genesis hash: " <> actual) (actual == expected)
    )
    [
      ( "Byron"
      , hashText (C.hash (C.byronGenesisFile (byronGenesis protocol)))
      , "5f20df933584822601f9e3f8c024eb5eb252fe8cefb24d1317dc3d432e940ebb"
      )
    ,
      ( "Shelley"
      , hashText (C.hash (shelleyGenesis protocol))
      , "1a3be38bcbb7911969283716ad7aa550250226b76a61fc51cc9a9a35d9276d81"
      )
    ,
      ( "Alonzo"
      , hashText (C.hash (alonzoGenesis protocol))
      , "7e94a15f55d1e82d10f09203fa1d40f8eede58fd8066542cf6566008068ed874"
      )
    ,
      ( "Conway"
      , hashText (C.hash (conwayGenesis protocol))
      , "15a199f895e461ec0ffc6dd4e4028af28a492ab4e806d39cb674c88f7643ef62"
      )
    ]

-- | The committed schemas under @schemas/@ (the whole configuration and one per
-- component) must match the schema derived from the codecs, so the documented
-- schema cannot drift from the parsers. Regenerate them with @scripts/gen-schemas.sh@.
schemaTests :: TestTree
schemaTests =
  testGroup
    "schemas"
    [schemaTest "schemas/config.schema.json" (configSchemaWithDefaults componentDefaults)]

-- | Assert that a committed schema file equals the given derived schema.
schemaTest :: FilePath -> Value -> TestTree
schemaTest path expected =
  testCase path $ do
    full <- getDataFileName path
    res <- eitherDecodeFileStrict' full :: IO (Either String Value)
    case res of
      Left err -> assertFailure ("could not read " <> path <> ": " <> err)
      Right committed ->
        assertBool
          (path <> " is out of date; regenerate with scripts/gen-schemas.sh")
          (committed == expected)
