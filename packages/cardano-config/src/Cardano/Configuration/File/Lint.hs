-- | Linting of the top-level configuration keys: detecting unrecognised keys.
-- This is the only part of the configuration-file handling that depends on the
-- schema (for the set of recognised keys).
--
-- The checks are pure and return structured 'ConfigWarning's; how (or whether) to
-- surface them — print, log via a tracer, treat as fatal — is left to the caller.
module Cardano.Configuration.File.Lint
  ( ConfigWarning (..)
  , renderConfigWarning
  , configWarnings
  , checkUnknownKeys
  ) where

import Cardano.Configuration.Schema (recognisedKeys)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as T

-- | A non-fatal observation about a configuration. Returned by the parser so the
-- caller decides how to surface it (the @cardano-config@ executable prints them
-- to @stderr@; another consumer might log them through its own tracer, or treat
-- them as errors).
data ConfigWarning
  = -- | Keys at the @Configuration@ level that no parser recognises — typos,
    -- and keys of a component this library does not know. They are ignored. A
    -- key that is a component property is not one of these: migration groups it
    -- under the section that owns it before the check runs.
    UnrecognisedKeys [String]
  | -- | The document was not in the current canonical format, so migrating it (see
    -- @Cardano.Configuration.File.Migrate.migrate@) changed it before parsing —
    -- either it was not in the envelope, or it still used a pre-rename
    -- field name, or it carried an obsolete key. Run @cardano-config migrate@ to
    -- update the file on disk.
    MigratedToCurrentFormat
  | -- | The configuration is at an older format version (the first 'Int') than
    -- the one this library writes (the second). A document with no @Version@
    -- key is version 1. It was migrated to the current version in memory, so it
    -- still parses. Run @cardano-config migrate@ to update the file.
    OutdatedFormatVersion Int Int
  | -- | While migrating, both the old and the current name of a renamed field
    -- were present at the same level (@(old, new)@). The value under the current
    -- name is kept and the one under the old name is dropped. Reconcile the two by
    -- hand if the dropped value was the one you meant to keep.
    RenamedKeyCollision Text Text
  | -- | While migrating, a key appeared both as a top-level sibling of the
    -- @Configuration@ envelope and inside it. The value inside @Configuration@ (the
    -- canonical location) is kept and the top-level one is dropped.
    EnvelopeKeyCollision Text
  | -- | A consistency check of warning severity did not hold on the resolved
    -- configuration (e.g. the Mithril snapshot policy under the V2LSM backend
    -- without an @LSMExportPath@). The configuration is still accepted; the
    -- string is the check's description. See @Cardano.Configuration.ConfigCheck@.
    ConsistencyWarning String
  deriving (Eq, Show)

-- | A human-readable rendering of a 'ConfigWarning', matching the text the
-- library used to print itself.
renderConfigWarning :: ConfigWarning -> String
renderConfigWarning = \case
  UnrecognisedKeys ks ->
    "unrecognised configuration key(s): " <> intercalate ", " ks <> " (ignored)"
  MigratedToCurrentFormat ->
    "the configuration was not in the current canonical format; "
      <> "it was migrated before parsing "
      <> "(run `cardano-config migrate` to update the file)"
  OutdatedFormatVersion declared current ->
    "the configuration is format version "
      <> show declared
      <> ", and this cardano-config writes version "
      <> show current
      <> ". It was migrated in memory (run `cardano-config migrate` to update the file)"
  RenamedKeyCollision old new ->
    "both the old key \""
      <> T.unpack old
      <> "\" and its current name \""
      <> T.unpack new
      <> "\" are present; keeping \""
      <> T.unpack new
      <> "\" and dropping \""
      <> T.unpack old
      <> "\""
  EnvelopeKeyCollision key ->
    "the key \""
      <> T.unpack key
      <> "\" appears both at the top level and inside Configuration; "
      <> "keeping the value inside Configuration"
  ConsistencyWarning msg -> msg

-- | All warnings for an (unwrapped) configuration object.
--
-- With the parser accepting only the enveloped format (a document that is not is
-- migrated first, which groups every component under its section), the only key
-- warning left is for keys that none of the parsers recognise: typos, and keys
-- of a component this library does not know.
configWarnings :: Value -> [ConfigWarning]
configWarnings = checkUnknownKeys

-- | Top-level keys that none of the parsers recognise. Only the section keys, the
-- tracing keys and the envelope annotations are recognised at the @Configuration@
-- level. A component's own property names are recognised only under its section,
-- and migration has already moved any of them found here, so what is left is a
-- name no part of this library claims.
checkUnknownKeys :: Value -> [ConfigWarning]
checkUnknownKeys = \case
  Object o ->
    let unknown = [K.toString k | k <- KM.keys o, K.toText k `notElem` recognisedKeys]
     in [UnrecognisedKeys unknown | not (null unknown)]
  _ -> []
