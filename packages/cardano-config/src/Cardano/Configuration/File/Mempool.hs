-- | Options related to the mempool
module Cardano.Configuration.File.Mempool
  ( MempoolConfiguration (..)
  , finalizeMempool
  ) where

import Autodocodec
import Cardano.Configuration.Basic
  ( ErrorMessage
  , diffTimeCodec
  , optionalFieldStrict
  , optionalFieldWithStrict
  )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Functor.Identity (Identity (..))
import Data.Time.Clock (DiffTime)
import Data.Word
import GHC.Generics (Generic)

-- | The mempool configuration. @mempoolCapacityOverride@ is optional by nature
-- (leaving it unset means no override), so it stays @Maybe@ in both forms. The
-- three timeouts, however, are resolved /together/: they must be either all set
-- or all unset, and all-unset takes a coupled default (see 'finalizeMempool'),
-- so they carry the @f@ parameter — @Maybe@ in the partial form, @Identity@ in
-- the resolved form. See "Cardano.Configuration.File" for the @f@ convention.
data MempoolConfiguration f = MempoolConfiguration
  { mempoolCapacityOverride :: StrictMaybe Word64
  , mempoolTimeoutSoft :: f DiffTime
  , mempoolTimeoutHard :: f DiffTime
  , mempoolTimeoutCapacity :: f DiffTime
  }
  deriving Generic

deriving instance Show (MempoolConfiguration StrictMaybe)
deriving instance Show (MempoolConfiguration Identity)

deriving via
  (Autodocodec (MempoolConfiguration StrictMaybe))
  instance
    FromJSON (MempoolConfiguration StrictMaybe)

deriving via
  (Autodocodec (MempoolConfiguration StrictMaybe))
  instance
    ToJSON (MempoolConfiguration StrictMaybe)

instance HasCodec (MempoolConfiguration StrictMaybe) where
  codec =
    object "MempoolConfiguration" $
      MempoolConfiguration
        <$> optionalFieldStrict
          "CapacityBytesOverride"
          "Override for the maximum mempool size in bytes. Unset means no override"
          .= mempoolCapacityOverride
        <*> optionalFieldWithStrict
          "MempoolTimeoutSoft"
          diffTimeCodec
          "Soft mempool timeout, in seconds. Set all three or none. All unset takes the coupled default: Soft 1, Hard 1.5, Capacity 5"
          .= mempoolTimeoutSoft
        <*> optionalFieldWithStrict
          "MempoolTimeoutHard"
          diffTimeCodec
          "Hard mempool timeout, in seconds. Set all three or none. All unset takes the coupled default: Soft 1, Hard 1.5, Capacity 5"
          .= mempoolTimeoutHard
        <*> optionalFieldWithStrict
          "MempoolTimeoutCapacity"
          diffTimeCodec
          "Capacity mempool timeout, in seconds. Set all three or none. All unset takes the coupled default: Soft 1, Hard 1.5, Capacity 5"
          .= mempoolTimeoutCapacity

-- | Resolve a partial mempool configuration. The three timeouts are coupled:
-- they must be either all set or all unset. All-unset takes the node's coupled
-- default of @(1, 1.5, 5)@ seconds (soft, hard, capacity); a mix of set and
-- unset is rejected. @mempoolCapacityOverride@ is independent and passes through.
finalizeMempool ::
  MempoolConfiguration StrictMaybe -> Either ErrorMessage (MempoolConfiguration Identity)
finalizeMempool c =
  case (mempoolTimeoutSoft c, mempoolTimeoutHard c, mempoolTimeoutCapacity c) of
    (SJust s, SJust h, SJust cap) ->
      Right (MempoolConfiguration (mempoolCapacityOverride c) (Identity s) (Identity h) (Identity cap))
    (SNothing, SNothing, SNothing) ->
      Right (MempoolConfiguration (mempoolCapacityOverride c) (Identity 1) (Identity 1.5) (Identity 5))
    _ ->
      Left "mempool timeouts (Soft, Hard, Capacity) must be all set or all unset"
