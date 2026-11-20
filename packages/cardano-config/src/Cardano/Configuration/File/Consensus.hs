-- | Options related to the Consensus layer
module Cardano.Configuration.File.Consensus
  ( ConsensusConfiguration (..)
  , ConsensusMode (..)
  , GenesisConfigFlags (..)
  ) where

import Autodocodec
import Cardano.Configuration.Basic (diffTimeCodec, optionalFieldStrict, optionalFieldWithStrict)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Default
import Data.Functor.Identity (Identity)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Time.Clock (DiffTime)
import Data.Word
import GHC.Generics (Generic)

data ConsensusMode
  = PraosMode
  | GenesisMode GenesisConfigFlags
  deriving (Generic, Show)

-- | In which mode should the node run.
newtype ConsensusConfiguration f = ConsensusConfiguration {getConsensusConfiguration :: f ConsensusMode}

deriving instance Show (ConsensusConfiguration StrictMaybe)
deriving instance Show (ConsensusConfiguration Identity)

deriving via
  (Autodocodec (ConsensusConfiguration StrictMaybe))
  instance
    FromJSON (ConsensusConfiguration StrictMaybe)

deriving via
  (Autodocodec (ConsensusConfiguration StrictMaybe))
  instance
    ToJSON (ConsensusConfiguration StrictMaybe)

-- | The @ConsensusMode@ discriminator. Kept separate from 'ConsensusMode'
-- (which also carries the Genesis flags) so that the codec can enumerate the
-- valid string values in the schema and reject typos at parse time.
data ConsensusModeName = PraosModeName | GenesisModeName
  deriving Eq

consensusModeNameCodec :: JSONCodec ConsensusModeName
consensusModeNameCodec =
  stringConstCodec ((PraosModeName, "PraosMode") :| [(GenesisModeName, "GenesisMode")])

-- | The consensus mode is selected by the @ConsensusMode@ key; the Genesis
-- flags (the @LowLevelGenesisOptions@ key) only apply in Genesis mode. Supplying
-- them in any other case is rejected rather than silently dropped.
instance HasCodec (ConsensusConfiguration StrictMaybe) where
  codec =
    bimapCodec toConfig fromConfig $
      object "ConsensusConfiguration" $
        (,)
          <$> optionalFieldWith
            "ConsensusMode"
            consensusModeNameCodec
            "Which consensus mode to run (PraosMode or GenesisMode)"
            .= fst
          <*> optionalField "LowLevelGenesisOptions" "Low-level Genesis tuning (GenesisMode only)" .= snd
   where
    toConfig ::
      (Maybe ConsensusModeName, Maybe GenesisConfigFlags) ->
      Either String (ConsensusConfiguration StrictMaybe)
    toConfig (Just GenesisModeName, mflags) =
      Right (ConsensusConfiguration (SJust (GenesisMode (fromMaybe def mflags))))
    toConfig (_, Just _) =
      Left "LowLevelGenesisOptions is only valid when ConsensusMode is GenesisMode"
    toConfig (Nothing, Nothing) = Right (ConsensusConfiguration SNothing)
    toConfig (Just PraosModeName, Nothing) = Right (ConsensusConfiguration (SJust PraosMode))
    fromConfig (ConsensusConfiguration SNothing) = (Nothing, Nothing)
    fromConfig (ConsensusConfiguration (SJust PraosMode)) = (Just PraosModeName, Nothing)
    fromConfig (ConsensusConfiguration (SJust (GenesisMode flags))) = (Just GenesisModeName, Just flags)

-- | Configuration options for Genesis parameters
data GenesisConfigFlags = GenesisConfigFlags
  { gcfEnableCSJ :: Bool
  , gcfEnableLoEAndGDD :: Bool
  , gcfEnableLoP :: Bool
  , gcfBlockFetchGracePeriod :: StrictMaybe DiffTime
  , gcfBucketCapacity :: StrictMaybe Integer
  , gcfBucketRate :: StrictMaybe Integer
  , gcfCSJJumpSize :: StrictMaybe Word64
  , gcfGDDRateLimit :: StrictMaybe DiffTime
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via (Autodocodec GenesisConfigFlags)

instance Default GenesisConfigFlags where
  def = GenesisConfigFlags True True True SNothing SNothing SNothing SNothing SNothing

instance HasCodec GenesisConfigFlags where
  codec =
    object "GenesisConfigFlags" $
      GenesisConfigFlags
        <$> optionalFieldWithDefault "EnableCSJ" True "Enable ChainSync Jumping" .= gcfEnableCSJ
        <*> optionalFieldWithDefault
          "EnableLoEAndGDD"
          True
          "Enable the Limit on Eagerness and the Genesis Density Disconnection"
          .= gcfEnableLoEAndGDD
        <*> optionalFieldWithDefault "EnableLoP" True "Enable the Limit on Patience" .= gcfEnableLoP
        <*> optionalFieldWithStrict
          "BlockFetchGracePeriod"
          diffTimeCodec
          "Grace period, in seconds, for BlockFetch"
          .= gcfBlockFetchGracePeriod
        <*> optionalFieldStrict "BucketCapacity" "Token bucket capacity for the LoP" .= gcfBucketCapacity
        <*> optionalFieldStrict "BucketRate" "Token bucket refill rate for the LoP" .= gcfBucketRate
        <*> optionalFieldStrict "CSJJumpSize" "Size, in slots, of ChainSync jumps" .= gcfCSJJumpSize
        <*> optionalFieldWithStrict "GDDRateLimit" diffTimeCodec "Rate limit, in seconds, for the GDD"
          .= gcfGDDRateLimit
