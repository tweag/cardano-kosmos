module Cardano.Testnet.Test.Ports
  ( hprop_unique_ports
  ) where

import           Cardano.Testnet (createTestnetEnv, mkConf)

import           Prelude

import           Control.Monad (forM)
import           Data.Default.Class (def)
import qualified Data.Set as Set
import           System.FilePath ((</>))
import           Text.Read (readMaybe)

import           Testnet.Property.Util (integrationWorkspace)
import           Testnet.Start.Cardano (liftToIntegration)
import           Testnet.Start.Types

import           Hedgehog (Property, assert, evalIO, evalMaybe, (===))
import qualified Hedgehog.Extras as H

-- Exercise environment creation without starting the cluster or retrying failures.
hprop_unique_ports :: Property
hprop_unique_ports = integrationWorkspace "unique-ports" $ \tmpDir -> H.runWithDefaultWatchdog_ $ do
  let nodeCount = 128
      nodes = cardanoDefaultTestnetNodesWithOptions
        { optRelayNodes = replicate (nodeCount - 1) (NodeWithOptions Nothing []) }
      creationOptions = def { creationNodes = nodes }

  conf <- mkConf tmpDir
  liftToIntegration $ createTestnetEnv creationOptions conf

  ports <- forM [1 .. nodeCount] $ \node -> do
    contents <- evalIO $ readFile $ tmpDir </> "node-data" </> ("node" <> show node) </> "port"
    evalMaybe (readMaybe contents :: Maybe Int)

  Set.size (Set.fromList ports) === nodeCount
  assert $ all (\port -> port > 0 && port <= 65535) ports
