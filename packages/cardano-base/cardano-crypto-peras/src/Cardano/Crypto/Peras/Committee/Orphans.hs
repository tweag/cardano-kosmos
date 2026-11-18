{-# OPTIONS_GHC -Wno-orphans #-}

-- | Orphan instances needed by the voting committee code, moved from
-- @Ouroboros.Consensus.Util.Orphans@.
module Cardano.Crypto.Peras.Committee.Orphans () where

import Data.Array (Array)
import qualified Data.Array as Array
import NoThunks.Class (NoThunks (..))

instance NoThunks a => NoThunks (Array i a) where
  showTypeOf _ = "Array"
  wNoThunks ctxt = wNoThunks ctxt . Array.elems
