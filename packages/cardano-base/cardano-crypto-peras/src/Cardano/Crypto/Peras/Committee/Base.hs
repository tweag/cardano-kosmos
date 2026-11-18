{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeData #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Small ledger-independent types used by the voting committee code.
--
-- These mirror their @cardano-ledger-core@ counterparts, under the same names
-- ('Nonce', 'NonZero', 'HasZero', 'FixedPoint', 'KeyHash', 'BlsKey', ...), so
-- that the committee code moved from @ouroboros-consensus@ can live in
-- @cardano-base@, below the ledger, unchanged. The ledger and consensus convert
-- at the boundary.
module Cardano.Crypto.Peras.Committee.Base (
  HASH,
  Hash,
  Nonce (..),
  NonZero (unNonZero),
  HasZero (..),
  nonZero,
  unsafeNonZero,
  FixedPoint,
  runByteBuilder,
  KeyRole (..),
  KeyHash (..),
  BlsKey (..),
  SlotNo (..),
) where

import Cardano.Binary (
  FromCBOR (..),
  ToCBOR (..),
  decodeListLen,
  decodeWord8,
  encodeListLen,
  encodeWord8,
 )
import Cardano.Crypto.DSIGN (
  BLS12381MinSigDSIGN,
  DSIGNAggregatable (PossessionProofDSIGN),
  DSIGNAlgorithm (..),
  Ed25519DSIGN,
 )
import Cardano.Crypto.Hash (Blake2b_224, Blake2b_256, Hash)
import Cardano.Slotting.Slot (SlotNo (..))
import Control.DeepSeq (NFData)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder)
import Data.ByteString.Builder.Extra (safeStrategy, toLazyByteStringWith)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Fixed as FP
import Data.Word (Word64)
import GHC.Generics (Generic)
import NoThunks.Class (NoThunks)

-- | The hash algorithm the ledger uses for most hashes (its @HASH@).
type HASH = Blake2b_256

-- | Evolving nonce, as in @Cardano.Ledger.BaseTypes@.
data Nonce
  = Nonce !(Hash Blake2b_256 Nonce)
  | -- | Identity element
    NeutralNonce
  deriving (Eq, Generic, Ord, Show, NFData, NoThunks)

-- | Same encoding as the ledger's: @[0]@ for 'NeutralNonce', @[1, hash]@ for
-- 'Nonce'.
instance ToCBOR Nonce where
  toCBOR NeutralNonce = encodeListLen 1 <> encodeWord8 0
  toCBOR (Nonce h) = encodeListLen 2 <> encodeWord8 1 <> toCBOR h

instance FromCBOR Nonce where
  fromCBOR = do
    len <- decodeListLen
    tag <- decodeWord8
    case (len, tag) of
      (1, 0) -> pure NeutralNonce
      (2, 1) -> Nonce <$> fromCBOR
      _ -> fail ("Nonce: unexpected list length " <> show len <> " and tag " <> show tag)

-- | A value known to be non-zero, as in @Cardano.Ledger.BaseTypes.NonZero@.
newtype NonZero a = NonZero {unNonZero :: a}
  deriving stock (Show)
  deriving newtype (Eq, Ord, NoThunks, NFData)

class HasZero a where
  isZero :: a -> Bool
  default isZero :: (Eq a, Num a) => a -> Bool
  isZero = (== 0)

instance HasZero Integer

instance HasZero Word64

instance HasZero Rational

unsafeNonZero :: a -> NonZero a
unsafeNonZero = NonZero

nonZero :: HasZero a => a -> Maybe (NonZero a)
nonZero x
  | isZero x = Nothing
  | otherwise = Just (NonZero x)

data E34

instance FP.HasResolution E34 where
  resolution _ = (10 :: Integer) ^ (34 :: Integer)

-- | Fixed-point numbers with 34 decimal digits, as in @Cardano.Ledger.BaseTypes@.
type FixedPoint = FP.Fixed E34

instance HasZero FixedPoint

-- | Run a builder into a strict bytestring, with a size hint, as in
-- @Cardano.Ledger.Binary@.
runByteBuilder :: Int -> Builder -> BS.ByteString
runByteBuilder !sizeHint =
  BSL.toStrict . toLazyByteStringWith (safeStrategy sizeHint (2 * sizeHint)) mempty
{-# NOINLINE runByteBuilder #-}

-- | Roles of the keys whose hashes the committee code uses, as in
-- @Cardano.Ledger.Keys@.
type data KeyRole = StakePool

-- | Hash of a key, as in @Cardano.Ledger.Keys@ (@ADDRHASH@ is 'Blake2b_224' and
-- @DSIGN@ is 'Ed25519DSIGN').
newtype KeyHash (r :: KeyRole) = KeyHash
  {unKeyHash :: Hash Blake2b_224 (VerKeyDSIGN Ed25519DSIGN)}
  deriving (Show, Eq, Ord, Generic)
  deriving newtype (NFData, NoThunks, ToCBOR, FromCBOR)

-- | BLS key of a stake pool, as in @Cardano.Ledger.State@.
data BlsKey = BlsKey
  { blsPubKey :: !(VerKeyDSIGN BLS12381MinSigDSIGN)
  , blsPossessionProof :: !(PossessionProofDSIGN BLS12381MinSigDSIGN)
  }
  deriving (Show, Generic, Eq, NoThunks, NFData)
