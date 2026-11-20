-- | The error type reported when reading or parsing the configuration files.
module Cardano.Configuration.File.Error
  ( ConfigurationParsingError (..)
  ) where

import Cardano.Ledger.BaseTypes (StrictMaybe, strictMaybe)
import Control.Exception (Exception)
import Data.Aeson.Types (JSONPath, formatError)

-- | An error encountered while reading or parsing the configuration. It records
-- enough context to point the user at the offending file, section and location.
data ConfigurationParsingError = ConfigurationParsingError
  { errFile :: StrictMaybe FilePath
  -- ^ The file the failure is about, when it is about a file as a whole. That
  -- is the configuration file when it does not decode, declares a format
  -- version this library cannot read, or cannot be migrated. It is a genesis
  -- file when that file cannot be read, hash-checked or decoded.
  --
  -- Absent when the failure is at a path /inside/ the configuration, which
  -- 'errSection' and 'errPath' locate instead.
  --
  -- The tracing file never appears here. @trace-dispatcher@ reads it and
  -- reports its own errors.
  , errSection :: StrictMaybe String
  -- ^ The top-level configuration section being parsed (e.g. @"Storage"@).
  , errPath :: JSONPath
  -- ^ The path to the offending value within the JSON\/YAML document.
  , errMessage :: String
  -- ^ The underlying error message.
  }
  deriving Eq

instance Exception ConfigurationParsingError

instance Show ConfigurationParsingError where
  show ConfigurationParsingError{errFile, errSection, errPath, errMessage} =
    mconcat
      [ "Error parsing the cardano-node configuration"
      , strictMaybe "" (\s -> " (section " <> show s <> ")") errSection
      , strictMaybe " in the main configuration file" (\f -> " in " <> f) errFile
      , ":\n  "
      , formatError errPath errMessage
      ]
