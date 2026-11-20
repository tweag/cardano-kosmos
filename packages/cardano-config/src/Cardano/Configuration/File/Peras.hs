module Cardano.Configuration.File.Peras
  ( PerasConfiguration (..)
  , finalizePeras
  ) where

import Autodocodec
import Cardano.Configuration.Basic (ErrorMessage, optionalFieldStrict, requireField)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Functor.Identity (Identity (..))
import GHC.Generics (Generic)

newtype PerasConfiguration f = PerasConfiguration
  { perasEnabled :: f Bool
  }
  deriving Generic

deriving instance Show (PerasConfiguration StrictMaybe)
deriving instance Show (PerasConfiguration Identity)

deriving via
  (Autodocodec (PerasConfiguration StrictMaybe))
  instance
    FromJSON (PerasConfiguration StrictMaybe)

deriving via
  (Autodocodec (PerasConfiguration StrictMaybe))
  instance
    ToJSON (PerasConfiguration StrictMaybe)

instance HasCodec (PerasConfiguration StrictMaybe) where
  codec =
    object "PerasConfiguration" $
      PerasConfiguration
        <$> optionalFieldStrict
          "PerasEnabled"
          "Enable Peras: the node diffuses Peras votes and certificates"
          .= perasEnabled

finalizePeras ::
  PerasConfiguration StrictMaybe -> Either ErrorMessage (PerasConfiguration Identity)
finalizePeras c = PerasConfiguration <$> requireField "PerasEnabled" (perasEnabled c)
