-- | Tracing configuration.
--
-- Tracing is owned by the node's tracing system (hermod / @trace-dispatcher@),
-- not by @cardano-config@. The configuration is given under a single top-level
-- @HermodTracing@ key, whose value is /either/ a path (a string) to a separate
-- file holding the tracing configuration, /or/ that configuration object inline.
--
-- We do not interpret the tracing configuration ourselves: its authoritative
-- schema lives in @trace-dispatcher@. What we do is hand the @HermodTracing@
-- value to @trace-dispatcher@'s own parser ('readConfiguration'), which turns it
-- into a 'TraceConfig' — a file reference via 'FromFile' (after resolving the
-- path to its canonical location), an inline object via 'FromJSONObject'.
--
-- We hand it no default of our own. Every other component of the configuration
-- takes its defaults from @defaults\/@, but tracing does not: @trace-dispatcher@
-- already falls back for whatever the configuration leaves unset, and a second
-- default here would only compete with it. The @HermodTracing@ block in
-- @defaults\/@ is there to show a reader what that fallback amounts to; it is
-- never applied.
--
-- Correspondingly, the configuration schema describes @HermodTracing@ only as
-- \"a path or a JSON object\"; the shape of that object is @trace-dispatcher@'s
-- responsibility to describe, not this library's.
module Cardano.Configuration.File.Tracing
  ( TracingConfiguration (..)
  , TracingConfigSource (..)
  , resolveTracingConfiguration
  , mkConfiguration
  ) where

import Autodocodec
import Cardano.Configuration.Basic (optionalFieldStrict)
import Cardano.Configuration.Common (filePathCodec)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Logging
import Data.Aeson (FromJSON, Object, ToJSON)
import qualified Data.Aeson.KeyMap as KM
import GHC.Generics (Generic)
import System.Directory (canonicalizePath)
import System.FilePath ((</>))

-- | Where the @HermodTracing@ configuration comes from: either a path to a
-- separate file holding it, or the configuration object given inline. Which one
-- was written is decided purely by the JSON shape (a string vs. an object); the
-- contents are captured opaquely and only interpreted by @trace-dispatcher@.
data TracingConfigSource
  = -- | @HermodTracing@ was a path (a string) to a separate file.
    TracingConfigFile FilePath
  | -- | @HermodTracing@ held the tracing configuration object inline.
    TracingConfigInline Object
  deriving (Generic, Show)

-- | A single JSON string is read as a file path; a single JSON object is read as
-- an inline configuration. We dispatch on that shape (as 'NodeDatabasePaths'
-- does) so the two never compete in error messages.
instance HasCodec TracingConfigSource where
  codec =
    matchChoiceCodec
      (dimapCodec TracingConfigFile id filePathCodec)
      (dimapCodec TracingConfigInline id inlineObjectCodec)
      selector
   where
    selector (TracingConfigFile fp) = Left fp
    selector (TracingConfigInline o) = Right o

-- | A codec for an arbitrary JSON object. Its schema is just @type: object@ with
-- no described properties — this library deliberately says nothing about what
-- the tracing configuration object holds (that is @trace-dispatcher@'s domain).
inlineObjectCodec :: JSONCodec Object
inlineObjectCodec = dimapCodec KM.fromMapText KM.toMapText (mapCodec valueCodec)

-- | The tracing configuration is given under a single @HermodTracing@ key. It is
-- captured (as a path or an inline object) but not interpreted here; see the
-- module documentation and 'resolveTracingConfiguration'.
newtype TracingConfiguration = TracingConfiguration
  { hermodTracing :: StrictMaybe TracingConfigSource
  -- ^ The @HermodTracing@ value: a path to a file, or an inline object.
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via (Autodocodec TracingConfiguration)

instance HasCodec TracingConfiguration where
  codec =
    object "TracingConfiguration" $
      TracingConfiguration
        <$> optionalFieldStrict
          "HermodTracing"
          ( "Tracing configuration, given as a path to a separate file holding it "
              <> "or as that configuration object inline. Consumed by the node tracing "
              <> "system (trace-dispatcher), which owns its schema; not described further "
              <> "by cardano-config."
          )
          .= hermodTracing

-- | Resolve the captured @HermodTracing@ value into a 'TraceConfig' by handing
-- it to @trace-dispatcher@'s own parser ('readConfiguration'):
--
--   * a file reference is resolved to its canonical location (relative paths are
--     taken against the configuration directory @root@) and read via 'FromFile';
--   * an inline object is read via 'FromJSONObject'.
--
-- No default of ours is passed: @trace-dispatcher@ applies its own fallback to
-- the namespace root (@Notice@ severity, @DNormal@ detail, @Stdout
-- MachineFormat@) for whatever the value leaves unset.
--
-- When there is no @HermodTracing@ key at all the tracing system still needs a
-- configuration, so we take @trace-dispatcher@'s minimal viable one
-- ('mkConfiguration') — that same fallback over an empty configuration — rather
-- than no configuration at all.
resolveTracingConfiguration ::
  -- | The directory a relative @HermodTracing@ file path is resolved against.
  FilePath ->
  TracingConfiguration ->
  IO TraceConfig
resolveTracingConfiguration root (TracingConfiguration mSource) =
  case mSource of
    SNothing -> pure mkConfiguration
    SJust (TracingConfigFile path) -> do
      canonPath <- canonicalizePath (root </> path)
      readConfiguration (FromFile canonPath)
    SJust (TracingConfigInline obj) ->
      readConfiguration (FromJSONObject obj)
