-- | Reading the Byron-era genesis. Byron genesis files are canonical JSON (not
-- the @aeson@ JSON used by the later eras) and the genesis hash is computed over
-- the canonical-JSON rendering, so we reuse the ledger's 'mkConfigFromFile',
-- which reads, hashes and checks the file and builds a 'Config'.
module Cardano.Configuration.Genesis.Byron
  ( ByronGenesisConfig
  , readByronGenesisConfig
  , byronGenesisFileHash
  , byronGenesisToJSON
  ) where

import Cardano.Chain.Genesis
  ( Config
  , GenesisHash (unGenesisHash)
  , configGenesisData
  , mkConfigFromFile
  , readGenesisData
  )
import Cardano.Crypto.Hash (Blake2b_256, Hash, hashFromBytes, hashToBytes)
import qualified Cardano.Crypto.Hashing as Byron
import Cardano.Crypto.ProtocolMagic (RequiresNetworkMagic)
import qualified Cardano.Crypto.Raw as Byron
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Functor.Identity (runIdentity)
import qualified Text.JSON.Canonical as Canonical

-- | The parsed Byron genesis (data, hash, network-magic requirement and UTxO
-- configuration), as the ledger represents it.
type ByronGenesisConfig = Config

-- | Read, hash-check and decode a Byron genesis file into a 'Config'.
--
-- The expected hash is the @Blake2b_256@ hash from the configuration; Byron
-- represents the same hash as a @'Byron.Hash' 'Byron.Raw'@, so we rebuild it
-- from the raw bytes.
readByronGenesisConfig ::
  -- | Whether the Byron network magic is required.
  RequiresNetworkMagic ->
  -- | The expected genesis hash.
  Hash Blake2b_256 ByteString ->
  -- | The genesis file.
  FilePath ->
  IO (Either String ByronGenesisConfig)
readByronGenesisConfig rnm expected fp = do
  let expectedRaw :: Byron.Hash Byron.Raw
      expectedRaw = Byron.unsafeAbstractHashFromBytes (hashToBytes expected)
  first show <$> runExceptT (mkConfigFromFile rnm fp expectedRaw)

-- | The hash a configuration pins a Byron genesis file to: the @Blake2b_256@
-- hash of its canonical-JSON rendering, as 'readByronGenesisConfig' checks it.
byronGenesisFileHash :: FilePath -> IO (Either String (Hash Blake2b_256 ByteString))
byronGenesisFileHash fp = do
  result <- runExceptT (readGenesisData fp)
  pure $ case result of
    Left err -> Left (show err)
    Right (_, genesisHash) ->
      case hashFromBytes (Byron.abstractHashToBytes (unGenesisHash genesisHash)) of
        Just h -> Right h
        Nothing -> Left "the Byron genesis hash is not a Blake2b_256 hash"

-- | Render a parsed Byron genesis as an (aeson) JSON 'Value'. Byron genesis is
-- /canonical/ JSON (not the @aeson@ JSON of the later eras), so we re-encode the
-- genesis data through the ledger's canonical-JSON instance and reparse it as
-- aeson — reproducing the on-disk genesis (the bytes the genesis hash is
-- computed over). Used to render the resolved configuration; there is no
-- matching parser.
byronGenesisToJSON :: ByronGenesisConfig -> Value
byronGenesisToJSON cfg =
  case Aeson.eitherDecode (Canonical.renderCanonicalJSON canonical) of
    Right v -> v
    Left err -> object ["error" .= ("could not render the Byron genesis as JSON: " <> err)]
 where
  canonical = runIdentity (Canonical.toJSON (configGenesisData cfg))
