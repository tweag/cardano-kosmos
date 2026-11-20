-- | The JSON layering engine: splitting the envelope, deep-merging the role's
-- default configuration with the user's and running a component's codec. The
-- configuration is one file, so the only files read here are the configuration
-- itself and the @defaults\/@ compiled into the binary. This module knows
-- nothing about which keys the parsers recognise (that is
-- "Cardano.Configuration.File.Lint") nor about the overall orchestration (that
-- is "Cardano.Configuration.File").
module Cardano.Configuration.File.Merge
  ( decodeValueFile
  , decodeValueBytes
  , runCodec
  , mergeValues
  , defaultConfiguration
  , roleIndependentDefaults
  , sectionUserLayer
  , parseSection
  , decodeSection
  , splitEnvelope
  , declaredFormatVersion
  ) where

import Cardano.Configuration.Embedded (embeddedBlockProducerDefaults, embeddedRelayDefaults)
import Cardano.Configuration.File.Error (ConfigurationParsingError (..))
import Cardano.Configuration.File.Network (BlockProducerOrRelay (..))
import Cardano.Ledger.BaseTypes (StrictMaybe (..), maybeToStrictMaybe)
import Control.Exception (throwIO)
import Data.Aeson (FromJSON, Value (..), parseJSON)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (JSONPathElement (..), formatError, iparseEither)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml

-- | Read and decode a YAML\/JSON file into a 'Value', reporting syntax errors as
-- a 'ConfigurationParsingError' that names the file. Only the configuration
-- file itself is read this way, so there is no section to name.
decodeValueFile :: FilePath -> IO Value
decodeValueFile fp = BS.readFile fp >>= decodeValueBytes Nothing fp

-- | Decode already-read YAML\/JSON bytes into a 'Value', reporting syntax errors
-- against the given name. Used for the files embedded into the binary (see
-- "Cardano.Configuration.Embedded"), which have no path on disk to read.
decodeValueBytes ::
  -- | The section being read, for error reporting.
  Maybe String ->
  -- | The name the bytes came from, for error reporting.
  FilePath ->
  -- | The bytes to decode.
  ByteString ->
  IO Value
decodeValueBytes section fp bytes =
  case Yaml.decodeEither' bytes of
    Left e ->
      throwIO $
        ConfigurationParsingError
          (SJust fp)
          (maybeToStrictMaybe section)
          []
          (Yaml.prettyPrintParseException e)
    Right v -> pure v

-- | Run a component parser on a 'Value', turning a failure into a structured
-- 'ConfigurationParsingError' carrying the section and JSON path. Every value
-- parsed here comes from the configuration file, so the error names no other
-- file.
runCodec ::
  FromJSON a =>
  -- | The section being parsed, for error reporting.
  String ->
  -- | The value to parse.
  Value ->
  IO a
runCodec section value =
  case iparseEither parseJSON value of
    Left (path, msg) -> throwIO $ ConfigurationParsingError SNothing (SJust section) path msg
    Right a -> pure a

-- | Deep, right-biased merge of two JSON values: two objects are merged key by
-- key (a key present in both is merged recursively), and for anything else the
-- second (later) value wins. Used to layer a section's user-supplied value on
-- top of its always-applied base default, so the user's value wins.
mergeValues :: Value -> Value -> Value
mergeValues (Object earlier) (Object later) = Object (KM.unionWith mergeValues earlier later)
mergeValues _ later = later

-- | The default configuration for a node in the given role: the @Configuration@
-- object of the matching @defaults\/config.\<role\>.json@ embedded into the
-- binary (see "Cardano.Configuration.Embedded"). It is the bottom layer of
-- resolution, with the user's configuration merged on top.
--
-- Decoded once, at first use. The files are compiled in and covered by the test
-- suite, so a failure here means the build itself is broken, which is why it is
-- an 'error' rather than a value the caller has to handle.
defaultConfiguration :: BlockProducerOrRelay -> Value
defaultConfiguration IsBlockProducer = blockProducerDefaults
defaultConfiguration IsRelay = relayDefaults

blockProducerDefaults, relayDefaults :: Value
blockProducerDefaults = embeddedConfiguration "config.blockproducer.json" embeddedBlockProducerDefaults
relayDefaults = embeddedConfiguration "config.relay.json" embeddedRelayDefaults

-- | The @Configuration@ object of an embedded default configuration.
embeddedConfiguration :: FilePath -> ByteString -> Value
embeddedConfiguration name bytes =
  case Yaml.decodeEither' bytes of
    Left e -> error ("defaults/" <> name <> " is not valid: " <> Yaml.prettyPrintParseException e)
    Right (Object o) -> fromMaybe (Object KM.empty) (KM.lookup "Configuration" o)
    Right _ -> error ("defaults/" <> name <> " is not an object")

-- | The defaults both roles agree on, keyed by section. A value the two role
-- files disagree on is left out, since it is not a default the configuration
-- has before a role is known. Used to document the defaults in the schema (see
-- 'Cardano.Configuration.Schema.configSchemaWithDefaults').
roleIndependentDefaults :: [(T.Text, Value)]
roleIndependentDefaults =
  case (blockProducerDefaults, relayDefaults) of
    (Object bp, Object relay) ->
      [ (K.toText k, agreed)
      | (k, bpV) <- KM.toList bp
      , Just relayV <- [KM.lookup k relay]
      , Just agreed <- [intersect bpV relayV]
      ]
    _ -> []
 where
  -- The values the two agree on, key by key; objects recurse so a section that
  -- differs in one field still contributes the rest.
  intersect (Object a) (Object b) =
    Just . Object . KM.fromList $
      [ (k, v)
      | (k, av) <- KM.toList a
      , Just bv <- [KM.lookup k b]
      , Just v <- [intersect av bv]
      ]
  intersect a b = if a == b then Just a else Nothing

-- | The configuration layer the user supplied for a section: the inline object
-- given under the section key. A component is read only from its own section
-- key; a section that is absent contributes an empty layer, so every field of
-- the component is unset (the defaults come in at resolution, not here).
-- Component keys placed flat under @Configuration@ are
-- /not/ resolved into their section — they are left unrecognised (see
-- 'Cardano.Configuration.File.Lint.checkUnknownKeys'). Non-enveloped documents,
-- where the keys are flat, are migrated (grouped into sections) before reaching
-- here.
--
-- The whole configuration lives in one file. A section whose value is anything
-- other than an object — a path to a separate file, as older configurations
-- wrote it — is rejected here.
sectionUserLayer :: Value -> String -> IO Value
sectionUserLayer configValue section =
  case configValue of
    Object o ->
      case KM.lookup (K.fromString section) o of
        Nothing -> pure (Object KM.empty)
        Just (Object user) -> pure (Object user)
        Just _ ->
          throwIO $
            ConfigurationParsingError
              SNothing
              (SJust section)
              [Key (K.fromString section)]
              ( "expected an inline configuration object. A path to a separate file is no "
                  <> "longer accepted: copy that file's contents in here."
              )
    _ ->
      throwIO $
        ConfigurationParsingError SNothing SNothing [] "expected the configuration to be a JSON/YAML object"

-- | Parse a single component from a configuration object, as written — no
-- defaults are applied, so a field the configuration leaves unset is unset
-- here. The defaults come in at resolution, once the node's role is known (see
-- 'defaultConfiguration').
parseSection ::
  FromJSON a =>
  -- | The (unwrapped) configuration object.
  Value ->
  -- | The section name.
  String ->
  IO a
parseSection configValue section =
  sectionUserLayer configValue section >>= runCodec section

-- | The pure counterpart of 'parseSection', for resolution, which merges the
-- role's defaults with the user's configuration and reads each section from the
-- result. A failure is returned rather than thrown, and rendered against the
-- JSON path within the section. Naming the section is the caller's, which has
-- it to hand and carries it separately (see
-- @Cardano.Configuration.SectionDecodeError@).
decodeSection :: FromJSON a => Value -> String -> Either String a
decodeSection configValue section =
  case iparseEither parseJSON sectionValue of
    Left (path, msg) -> Left (formatError path msg)
    Right a -> Right a
 where
  sectionValue = case configValue of
    Object o -> fromMaybe (Object KM.empty) (KM.lookup (K.fromString section) o)
    _ -> Object KM.empty

-- | Split the optional configuration envelope @{ \"Version\": N,
-- \"MinNodeVersion\": \"x.y.z\", \"Configuration\": {..} }@ into the version, the
-- optional minimum node version and the configuration object. A document with
-- no @Configuration@ key falls back to taking the whole value as the
-- configuration, reading the optional flat @Version@ and @MinNodeVersion@ from
-- it. Reading a configuration never takes that path, because @migrate@
-- envelopes the document first; it is there for a caller that splits a document
-- of its own.
--
-- @MinNodeVersion@ is a top-level annotation (sibling of @Version@), not a
-- configuration component: it records the lowest @cardano-node@ version expected
-- to run this configuration, for a consumer to check.
splitEnvelope :: Value -> IO (Int, Maybe T.Text, Value)
splitEnvelope value =
  case value of
    Object o -> do
      version <- declaredFormatVersion value
      minNodeVersion <- lookupMinNodeVersion o
      pure (version, minNodeVersion, fromMaybe value (KM.lookup "Configuration" o))
    _ ->
      throwIO $
        ConfigurationParsingError SNothing SNothing [] "expected the configuration to be a JSON/YAML object"
 where
  -- @MinNodeVersion@ is optional and, when present, must be a string.
  lookupMinNodeVersion o = case KM.lookup "MinNodeVersion" o of
    Nothing -> pure Nothing
    Just (String t) -> pure (Just t)
    Just _ ->
      throwIO $
        ConfigurationParsingError
          SNothing
          SNothing
          [Key "MinNodeVersion"]
          "invalid MinNodeVersion: expected a string"

-- | The format version a document declares, read before any migration, so the
-- caller can reject a version this library does not write and warn about one it
-- migrates.
--
-- A missing @Version@ is the legacy version 1: a fixed historical fact about
-- unversioned documents, not 'Cardano.Configuration.Schema.currentFormatVersion'.
-- A present one must be an integer of at least 1, which is what the schema
-- declares: 1 is the lowest version there has ever been, so 0 or a negative
-- number names no format. Rejecting them here keeps a document the schema
-- refuses from being read as a legacy one and quietly migrated. A value that is
-- not an object reports 1 and fails later, where the error names the real
-- problem.
declaredFormatVersion :: Value -> IO Int
declaredFormatVersion (Object o) = case KM.lookup "Version" o of
  Nothing -> pure 1
  Just (Number n) -> case toBoundedInteger n of
    Just v | v >= 1 -> pure v
    Just v -> throwIO (badVersion ("expected a positive integer, got " <> show v))
    Nothing -> throwIO (badVersion ("expected an integer, got " <> show n))
  Just _ -> throwIO (badVersion "expected an integer")
 where
  badVersion msg = ConfigurationParsingError SNothing SNothing [Key "Version"] ("invalid Version: " <> msg)
declaredFormatVersion _ = pure 1
