-- | Options related to the Cardano protocol
module Cardano.Configuration.File.Protocol
  ( -- * Configuration
    ProtocolConfiguration (..)

    -- * Hashed files
  , Hashed (..)
  , MaybeHashed (..)
  , optionalHashedGenesisObjectCodec

    -- * Particular eras
  , ByronGenesisConfiguration (..)
  , RequiresNetworkMagic (..)
  ) where

import Autodocodec
import Cardano.Configuration.Basic (optionalFieldStrict)
import Cardano.Configuration.Common (filePathCodec)
import Cardano.Crypto.Hash (Blake2b_256, Hash, hashFromTextAsHex, hashToTextAsHex)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), maybeToStrictMaybe, strictMaybeToMaybe)
import Data.Aeson (FromJSON, ToJSON)
import Data.ByteString (ByteString)
import Data.Functor.Identity (Identity)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics

-- | A hashed entity, possibly a file.
data Hashed a = Hashed
  { hashed :: a
  , hash :: Hash Blake2b_256 ByteString
  }
  deriving (Generic, Show)

-- | A maybe hashed entity, possibly a file.
data MaybeHashed a = MaybeHashed
  { maybeHashed :: a
  , maybeHash :: StrictMaybe (Hash Blake2b_256 ByteString)
  }
  deriving (Generic, Show)

-- | A codec for a Blake2b-256 hash: a hex string. We bimap over the string codec
-- (rather than 'codecViaAeson') so the schema declares @"type": "string"@.
hashCodec :: JSONCodec (Hash Blake2b_256 ByteString)
hashCodec =
  bimapCodec
    (maybe (Left "invalid Blake2b_256 hash (expected a hex string)") Right . hashFromTextAsHex)
    hashToTextAsHex
    (codec @Text)
    <?> "Blake2b_256 hash"

-- | A required genesis file together with its (mandatory) hash: a genesis file
-- must always be pinned to a hash, so the hash key is required whenever the file
-- is present. The hash is stored as @'Just'@.
hashedGenesisObjectCodec :: Text -> Text -> JSONObjectCodec (Hashed FilePath)
hashedGenesisObjectCodec fileKey hashKey =
  Hashed
    <$> requiredFieldWith fileKey filePathCodec "Path to the genesis file" .= hashed
    <*> requiredFieldWith hashKey hashCodec "Hash of the genesis file" .= hash

-- | An optional genesis file whose hash is mandatory once the file is given:
-- 'Nothing' when the file key is absent, but if the file key is present the hash
-- key must be too (a genesis file without a pinned hash is rejected at parse
-- time). The resulting 'Hashed' therefore always carries a @'Just' hash@.
optionalHashedGenesisObjectCodec :: Text -> Text -> JSONObjectCodec (StrictMaybe (Hashed FilePath))
optionalHashedGenesisObjectCodec fileKey hashKey =
  bimapCodec toG fromG $
    (,)
      <$> optionalFieldWith fileKey filePathCodec "Path to the genesis file" .= fst
      <*> optionalFieldWith hashKey hashCodec "Hash of the genesis file" .= snd
 where
  toG (Nothing, Nothing) = Right SNothing
  toG (Just f, Just h) = Right (SJust (Hashed f h))
  toG (Just _, Nothing) =
    Left (T.unpack hashKey <> " is required when " <> T.unpack fileKey <> " is provided")
  toG (Nothing, Just _) =
    Left (T.unpack hashKey <> " was given without " <> T.unpack fileKey)
  fromG SNothing = (Nothing, Nothing)
  fromG (SJust (Hashed f mh)) = (Just f, Just mh)

-- | An optional (optionally hashed) file: 'SNothing' when the file key is absent.
optionalHashedFileObjectCodec ::
  Text -> Text -> JSONObjectCodec (StrictMaybe (MaybeHashed FilePath))
optionalHashedFileObjectCodec fileKey hashKey =
  dimapCodec toG fromG $
    (,)
      <$> optionalFieldWith fileKey filePathCodec "Path to the file" .= fst
      <*> optionalFieldWith hashKey hashCodec "Hash of the file" .= snd
 where
  toG (Nothing, _) = SNothing
  toG (Just f, mh) = SJust (MaybeHashed f (maybeToStrictMaybe mh))
  fromG SNothing = (Nothing, Nothing)
  fromG (SJust (MaybeHashed f mh)) = (Just f, strictMaybeToMaybe mh)

-- | Whether the Byron network magic is required. Enumerated so the schema lists
-- the valid values and typos are caught at parse time.
data RequiresNetworkMagic
  = RequiresNoMagic
  | RequiresMagic
  deriving (Generic, Show, Eq, Enum, Bounded)
  deriving (FromJSON, ToJSON) via (Autodocodec RequiresNetworkMagic)

instance HasCodec RequiresNetworkMagic where
  codec = shownBoundedEnumCodec

-- | Configuration for byron era
data ByronGenesisConfiguration = ByronGenesisConfiguration
  { byronGenesisFile :: !(Hashed FilePath)
  , byronReqNetworkMagic :: !(StrictMaybe RequiresNetworkMagic)
  }
  deriving (Generic, Show)

byronGenesisObjectCodec :: JSONObjectCodec ByronGenesisConfiguration
byronGenesisObjectCodec =
  ByronGenesisConfiguration
    <$> hashedGenesisObjectCodec "ByronGenesisFile" "ByronGenesisHash" .= byronGenesisFile
    <*> optionalFieldStrict "RequiresNetworkMagic" "Whether network magic is required"
      .= byronReqNetworkMagic

-- | The genesis file (and optional hash) for the checkpoints.
checkpointsObjectCodec :: JSONObjectCodec (StrictMaybe (MaybeHashed FilePath))
checkpointsObjectCodec = optionalHashedFileObjectCodec "CheckpointsFile" "CheckpointsFileHash"

-- | Configuration for the protocol
data ProtocolConfiguration f = ProtocolConfiguration
  { byronGenesis :: !ByronGenesisConfiguration
  , shelleyGenesis :: !(Hashed FilePath)
  , alonzoGenesis :: !(Hashed FilePath)
  , conwayGenesis :: !(Hashed FilePath)
  , startAsNonProducingNode :: !(f Bool)
  , checkpointsFile :: !(StrictMaybe (MaybeHashed FilePath))
  }
  deriving Generic

deriving instance Show (ProtocolConfiguration StrictMaybe)
deriving instance Show (ProtocolConfiguration Identity)

deriving via
  (Autodocodec (ProtocolConfiguration StrictMaybe))
  instance
    FromJSON (ProtocolConfiguration StrictMaybe)

deriving via
  (Autodocodec (ProtocolConfiguration StrictMaybe))
  instance
    ToJSON (ProtocolConfiguration StrictMaybe)

instance HasCodec (ProtocolConfiguration StrictMaybe) where
  codec =
    object "ProtocolConfiguration" $
      ProtocolConfiguration
        <$> byronGenesisObjectCodec .= byronGenesis
        <*> hashedGenesisObjectCodec "ShelleyGenesisFile" "ShelleyGenesisHash" .= shelleyGenesis
        <*> hashedGenesisObjectCodec "AlonzoGenesisFile" "AlonzoGenesisHash" .= alonzoGenesis
        <*> hashedGenesisObjectCodec "ConwayGenesisFile" "ConwayGenesisHash" .= conwayGenesis
        <*> optionalFieldStrict
          "StartAsNonProducingNode"
          ( "Start the node without block production even when block-forging credentials are supplied. "
              <> "false (the default) behaves normally — producing blocks if credentials were supplied, "
              <> "otherwise just running as a relay; true suppresses block production even with credentials present."
          )
          .= startAsNonProducingNode
        <*> checkpointsObjectCodec .= checkpointsFile
