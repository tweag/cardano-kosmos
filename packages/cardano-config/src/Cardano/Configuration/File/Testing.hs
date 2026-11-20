-- | Values related to testing, which are unused by a real node
module Cardano.Configuration.File.Testing
  ( TestingConfiguration (..)
  , finalizeTesting
  ) where

import Autodocodec
import Cardano.Configuration.Basic (ErrorMessage, optionalFieldStrict, requireField)
import Cardano.Configuration.File.Protocol
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Functor.Identity (Identity (..))
import Data.Word
import GHC.Generics (Generic)

-- | The testing configuration: knobs for forcing era transitions at specific
-- epochs/versions and for enabling the experimental era. Only
-- @ExperimentalHardForksEnabled@ has a default; the rest are optional by nature.
data TestingConfiguration f = TestingConfiguration
  { experimentalHardForksEnabled :: f Bool
  , testShelleyHardForkAtEpoch :: StrictMaybe Word64
  , testShelleyHardForkAtVersion :: StrictMaybe Word
  , testAllegraHardForkAtEpoch :: StrictMaybe Word64
  , testAllegraHardForkAtVersion :: StrictMaybe Word
  , testMaryHardForkAtEpoch :: StrictMaybe Word64
  , testMaryHardForkAtVersion :: StrictMaybe Word
  , testAlonzoHardForkAtEpoch :: StrictMaybe Word64
  , testAlonzoHardForkAtVersion :: StrictMaybe Word
  , testBabbageHardForkAtEpoch :: StrictMaybe Word64
  , testBabbageHardForkAtVersion :: StrictMaybe Word
  , testConwayHardForkAtEpoch :: StrictMaybe Word64
  , testConwayHardForkAtVersion :: StrictMaybe Word
  , testDijkstraHardForkAtEpoch :: StrictMaybe Word64
  , testDijkstraHardForkAtVersion :: StrictMaybe Word
  , experimentalGenesis :: StrictMaybe (Hashed FilePath)
  }
  deriving Generic

deriving instance Show (TestingConfiguration StrictMaybe)
deriving instance Show (TestingConfiguration Identity)

deriving via
  (Autodocodec (TestingConfiguration StrictMaybe))
  instance
    FromJSON (TestingConfiguration StrictMaybe)

deriving via
  (Autodocodec (TestingConfiguration StrictMaybe))
  instance
    ToJSON (TestingConfiguration StrictMaybe)

instance HasCodec (TestingConfiguration StrictMaybe) where
  codec =
    object "TestingConfiguration" $ do
      TestingConfiguration
        <$> optionalFieldStrict
          "ExperimentalHardForksEnabled"
          ( "Enable the experimental eras. When true, a DijkstraGenesisFile and its"
              <> " DijkstraGenesisHash must be given alongside it, or resolution rejects the"
              <> " configuration."
          )
          .= experimentalHardForksEnabled
        <*> optionalFieldStrict "TestShelleyHardForkAtEpoch" "Force the Shelley hard fork at this epoch"
          .= testShelleyHardForkAtEpoch
        <*> optionalFieldStrict
          "TestShelleyHardForkAtVersion"
          "Force the Shelley hard fork at this protocol version"
          .= testShelleyHardForkAtVersion
        <*> optionalFieldStrict "TestAllegraHardForkAtEpoch" "Force the Allegra hard fork at this epoch"
          .= testAllegraHardForkAtEpoch
        <*> optionalFieldStrict
          "TestAllegraHardForkAtVersion"
          "Force the Allegra hard fork at this protocol version"
          .= testAllegraHardForkAtVersion
        <*> optionalFieldStrict "TestMaryHardForkAtEpoch" "Force the Mary hard fork at this epoch"
          .= testMaryHardForkAtEpoch
        <*> optionalFieldStrict "TestMaryHardForkAtVersion" "Force the Mary hard fork at this protocol version"
          .= testMaryHardForkAtVersion
        <*> optionalFieldStrict "TestAlonzoHardForkAtEpoch" "Force the Alonzo hard fork at this epoch"
          .= testAlonzoHardForkAtEpoch
        <*> optionalFieldStrict
          "TestAlonzoHardForkAtVersion"
          "Force the Alonzo hard fork at this protocol version"
          .= testAlonzoHardForkAtVersion
        <*> optionalFieldStrict "TestBabbageHardForkAtEpoch" "Force the Babbage hard fork at this epoch"
          .= testBabbageHardForkAtEpoch
        <*> optionalFieldStrict
          "TestBabbageHardForkAtVersion"
          "Force the Babbage hard fork at this protocol version"
          .= testBabbageHardForkAtVersion
        <*> optionalFieldStrict "TestConwayHardForkAtEpoch" "Force the Conway hard fork at this epoch"
          .= testConwayHardForkAtEpoch
        <*> optionalFieldStrict
          "TestConwayHardForkAtVersion"
          "Force the Conway hard fork at this protocol version"
          .= testConwayHardForkAtVersion
        <*> optionalFieldStrict "TestDijkstraHardForkAtEpoch" "Force the Dijkstra hard fork at this epoch"
          .= testDijkstraHardForkAtEpoch
        <*> optionalFieldStrict
          "TestDijkstraHardForkAtVersion"
          "Force the Dijkstra hard fork at this protocol version"
          .= testDijkstraHardForkAtVersion
        <*> optionalHashedGenesisObjectCodec "DijkstraGenesisFile" "DijkstraGenesisHash" .= experimentalGenesis

-- | Resolve a partial testing configuration, taking @ExperimentalHardForksEnabled@
-- from the (always-applied) defaults.
--
-- The two experimental-era keys are coupled: enabling the experimental eras
-- without a genesis to run them from is not a configuration anyone meant to
-- write, so @ExperimentalHardForksEnabled: true@ without a @DijkstraGenesisFile@
-- is rejected here.
finalizeTesting ::
  TestingConfiguration StrictMaybe -> Either ErrorMessage (TestingConfiguration Identity)
finalizeTesting c = do
  enabled <- requireField "ExperimentalHardForksEnabled" (experimentalHardForksEnabled c)
  case (runIdentity enabled, experimentalGenesis c) of
    (True, SNothing) ->
      Left $
        "ExperimentalHardForksEnabled is true, so Testing must also give a "
          <> "DijkstraGenesisFile (with its DijkstraGenesisHash); "
          <> "add them, or set ExperimentalHardForksEnabled to false"
    _ -> Right ()
  pure $
    TestingConfiguration
      { experimentalHardForksEnabled = enabled
      , testShelleyHardForkAtEpoch = testShelleyHardForkAtEpoch c
      , testShelleyHardForkAtVersion = testShelleyHardForkAtVersion c
      , testAllegraHardForkAtEpoch = testAllegraHardForkAtEpoch c
      , testAllegraHardForkAtVersion = testAllegraHardForkAtVersion c
      , testMaryHardForkAtEpoch = testMaryHardForkAtEpoch c
      , testMaryHardForkAtVersion = testMaryHardForkAtVersion c
      , testAlonzoHardForkAtEpoch = testAlonzoHardForkAtEpoch c
      , testAlonzoHardForkAtVersion = testAlonzoHardForkAtVersion c
      , testBabbageHardForkAtEpoch = testBabbageHardForkAtEpoch c
      , testBabbageHardForkAtVersion = testBabbageHardForkAtVersion c
      , testConwayHardForkAtEpoch = testConwayHardForkAtEpoch c
      , testConwayHardForkAtVersion = testConwayHardForkAtVersion c
      , testDijkstraHardForkAtEpoch = testDijkstraHardForkAtEpoch c
      , testDijkstraHardForkAtVersion = testDijkstraHardForkAtVersion c
      , experimentalGenesis = experimentalGenesis c
      }
