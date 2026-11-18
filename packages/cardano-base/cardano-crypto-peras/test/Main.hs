module Main (main) where

import qualified Test.Cardano.Crypto.Peras
import qualified Test.Cardano.Crypto.Peras.Validation
import Test.Hspec (hspec)
import Prelude

main :: IO ()
main = hspec $ do
  Test.Cardano.Crypto.Peras.spec
  Test.Cardano.Crypto.Peras.Validation.spec
