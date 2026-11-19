{-# LANGUAGE TemplateHaskell #-}

-- | The default configurations under @defaults\/@, embedded into the compiled
-- artefact.
--
-- These are the only JSON files the library itself reads (see
-- 'Cardano.Configuration.File.Merge.defaultConfiguration'). Embedding them
-- means a distributed executable does not have to locate a Cabal data
-- directory, and the defaults are compiled in, so they cannot go missing or
-- drift out of step with the binary.
--
-- There is one file per node role, each a complete default configuration. The
-- two differ only in the @Network@ deadline peer targets and
-- @PeerSharing@, which is what \"block producer\" and \"relay\" mean here; every
-- other section is identical. Resolution picks one by whether the operator
-- supplied block-forging credentials and merges the user's configuration on top
-- (see 'Cardano.Configuration.resolveConfiguration').
--
-- Neither file names a genesis, so neither is a configuration you can run: the
-- genesis keys are network-specific and deliberately absent from the defaults.
--
-- The other JSON the repository ships is not needed here: @schemas\/@ holds a
-- committed /output/, regenerated from the codecs by
-- "Cardano.Configuration.Schema" and only compared against by the test suite.
--
-- The files stay committed to the repository (and listed in
-- @extra-source-files@, so they reach a source distribution): they are the
-- source of truth, read by Template Haskell at build time. Editing one triggers
-- a rebuild of this module.
module Cardano.Configuration.Embedded
  ( embeddedBlockProducerDefaults
  , embeddedRelayDefaults
  ) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile, makeRelativeToProject)

-- | The contents of @defaults\/config.blockproducer.json@.
embeddedBlockProducerDefaults :: ByteString
embeddedBlockProducerDefaults =
  $(makeRelativeToProject "defaults/config.blockproducer.json" >>= embedFile)

-- | The contents of @defaults\/config.relay.json@.
embeddedRelayDefaults :: ByteString
embeddedRelayDefaults =
  $(makeRelativeToProject "defaults/config.relay.json" >>= embedFile)
