-- | Reading, changing and writing a configuration file without the checks a
-- node makes when it starts.
--
-- 'Cardano.Configuration.File.parseConfigurationFiles' is what a node uses: it
-- reads every genesis file the configuration names, and rejects a genesis hash
-- that is missing or does not match the file. A tool that writes
-- configurations needs to read them before that holds: a testnet generator
-- rewrites its genesis files (their start times, say) and then has to bring
-- the hashes in line, and a configuration written by hand may have no hashes
-- yet. This module reads such a file as a 'ConfigurationDocument', in the
-- current format but otherwise unchecked, fills in or refreshes its genesis
-- hashes from the files, and writes it back.
module Cardano.Configuration.Edit
  ( -- * Documents
    ConfigurationDocument
  , configurationDocumentValue
  , readConfigurationDocument
  , configurationDocumentFromValue
  , writeConfigurationDocument

    -- * Genesis hashes
  , refreshGenesisHashes
  ) where

import Cardano.Configuration.File (migrateConfiguration)
import Cardano.Configuration.File.Error (ConfigurationParsingError (..))
import Cardano.Configuration.File.Lint (ConfigWarning, configWarnings)
import Cardano.Configuration.File.Merge (decodeValueFile, splitEnvelope)
import Cardano.Configuration.Genesis (genesisFileHash)
import Cardano.Configuration.Genesis.Byron (byronGenesisFileHash)
import Cardano.Crypto.Hash (hashToTextAsHex)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Control.Exception (throwIO)
import Data.Aeson (Value (..))
import Data.Aeson.Encode.Pretty (Config (..), defConfig, encodePretty')
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (JSONPathElement (..))
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (foldlM)
import qualified Data.Text as T
import System.FilePath ((</>))

-- | A configuration file as a JSON document, brought to the current format
-- version (see @MIGRATION.md@) but otherwise unchecked: the genesis files it
-- names have not been read, and their hashes may be missing or out of date.
newtype ConfigurationDocument = ConfigurationDocument Value
  deriving (Eq, Show)

-- | The document as JSON: the @{ $schema, Version, MinNodeVersion,
-- Configuration }@ envelope.
configurationDocumentValue :: ConfigurationDocument -> Value
configurationDocumentValue (ConfigurationDocument value) = value

-- | Read a configuration file (JSON or YAML, in any format version this library
-- reads) as a 'ConfigurationDocument', together with the warnings reading it
-- raised, as 'Cardano.Configuration.File.parseConfigurationFiles' returns them.
-- Failures are thrown as a 'ConfigurationParsingError'.
readConfigurationDocument :: FilePath -> IO (ConfigurationDocument, [ConfigWarning])
readConfigurationDocument file = decodeValueFile file >>= toDocument (Just file)

-- | Make a 'ConfigurationDocument' out of a configuration held as JSON, in any
-- format version this library reads: a flat configuration is moved under the
-- sections its keys belong to, as @cardano-config migrate@ does. Failures are
-- thrown as a 'ConfigurationParsingError'.
configurationDocumentFromValue :: Value -> IO (ConfigurationDocument, [ConfigWarning])
configurationDocumentFromValue = toDocument Nothing

toDocument :: Maybe FilePath -> Value -> IO (ConfigurationDocument, [ConfigWarning])
toDocument file rawValue = do
  (value, migrationWarnings) <- migrateConfiguration file rawValue
  (_version, _minNodeVersion, configValue) <- splitEnvelope value
  pure (ConfigurationDocument value, migrationWarnings <> configWarnings configValue)

-- | Write a 'ConfigurationDocument' as JSON (which is also YAML), with its keys
-- sorted.
writeConfigurationDocument :: FilePath -> ConfigurationDocument -> IO ()
writeConfigurationDocument file (ConfigurationDocument value) =
  LBS.writeFile file (encodePretty' defConfig{confCompare = compare} value <> "\n")

-- | Set the hash of every genesis file the document names to the hash of that
-- file, adding the hashes that are missing and replacing the ones that are out
-- of date. That is the four era genesis files under @Protocol@, and the
-- experimental (Dijkstra) genesis file under @Testing@. Each is hashed the way
-- 'Cardano.Configuration.File.parseConfigurationFiles' checks it.
--
-- A genesis file that cannot be read (or, for Byron, decoded) is reported as a
-- thrown 'ConfigurationParsingError'.
refreshGenesisHashes ::
  -- | The directory the genesis paths are resolved against: the one the
  -- configuration file is in.
  FilePath ->
  ConfigurationDocument ->
  IO ConfigurationDocument
refreshGenesisHashes root (ConfigurationDocument value) =
  case value of
    Object envelope
      | Just (Object configuration) <- KM.lookup "Configuration" envelope -> do
          configuration' <- foldlM (refreshGenesisHash root) configuration genesisReferences
          pure . ConfigurationDocument . Object $
            KM.insert "Configuration" (Object configuration') envelope
    _ -> pure (ConfigurationDocument value)

-- | How a genesis file is hashed.
data GenesisHashing
  = -- | The hash of its canonical-JSON rendering (Byron).
    CanonicalJsonHash
  | -- | The hash of its raw bytes (every later era).
    RawBytesHash

-- | Where each genesis file and its hash are in the configuration: the section,
-- the file key, the hash key, and how the file is hashed.
genesisReferences :: [(K.Key, K.Key, K.Key, GenesisHashing)]
genesisReferences =
  [ ("Protocol", "ByronGenesisFile", "ByronGenesisHash", CanonicalJsonHash)
  , ("Protocol", "ShelleyGenesisFile", "ShelleyGenesisHash", RawBytesHash)
  , ("Protocol", "AlonzoGenesisFile", "AlonzoGenesisHash", RawBytesHash)
  , ("Protocol", "ConwayGenesisFile", "ConwayGenesisHash", RawBytesHash)
  , ("Testing", "DijkstraGenesisFile", "DijkstraGenesisHash", RawBytesHash)
  ]

refreshGenesisHash ::
  FilePath ->
  KM.KeyMap Value ->
  (K.Key, K.Key, K.Key, GenesisHashing) ->
  IO (KM.KeyMap Value)
refreshGenesisHash root configuration (section, fileKey, hashKey, hashing) =
  case KM.lookup section configuration of
    Just (Object sectionObject)
      | Just (String file) <- KM.lookup fileKey sectionObject -> do
          let path = root </> T.unpack file
          result <- case hashing of
            CanonicalJsonHash -> byronGenesisFileHash path
            RawBytesHash -> first show <$> genesisFileHash path
          case result of
            Left err ->
              throwIO $
                ConfigurationParsingError (SJust path) (SJust (K.toString section)) [Key fileKey] err
            Right hash ->
              pure $
                KM.insert
                  section
                  (Object (KM.insert hashKey (String (hashToTextAsHex hash)) sectionObject))
                  configuration
    _ -> pure configuration
