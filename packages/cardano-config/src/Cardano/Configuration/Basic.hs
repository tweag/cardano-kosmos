-- | Basic types for configuration
module Cardano.Configuration.Basic
  ( -- * Codecs
    diffTimeCodec

    -- * Strict optional fields
  , optionalFieldStrict
  , optionalFieldWithStrict

    -- * Resolution
  , ErrorMessage
  , requireField
  ) where

import Autodocodec
  ( HasCodec
  , JSONCodec
  , JSONObjectCodec
  , dimapCodec
  , optionalField
  , optionalFieldWith
  , scientificCodec
  )
import Cardano.Ledger.BaseTypes (StrictMaybe, maybeToStrictMaybe, strictMaybe, strictMaybeToMaybe)
import Data.Functor.Identity (Identity (..))
import Data.Text (Text)
import Data.Time.Clock (DiffTime)

type ErrorMessage = String

-- | Turn an @f@-parameter field into its resolved 'Identity' form. The value is
-- expected to have been supplied by the always-applied base defaults, so a
-- missing one is a configuration-packaging error and is reported by name.
requireField :: String -> StrictMaybe a -> Either ErrorMessage (Identity a)
requireField name = strictMaybe (Left ("missing default value for " <> name)) (Right . Identity)

-- | Like autodocodec's 'optionalField', but for a 'StrictMaybe' field. The
-- package uses @StrictData@, so a plain 'Maybe' field is forced only to WHNF and
-- its payload stays a thunk; 'StrictMaybe' keeps the payload strict too. Since
-- autodocodec's 'optionalField' is hardwired to 'Maybe', this adapts it with a
-- 'dimapCodec' (the JSON schema is unchanged: 'dimapCodec' is transparent to
-- schema generation).
optionalFieldStrict :: HasCodec a => Text -> Text -> JSONObjectCodec (StrictMaybe a)
optionalFieldStrict key doc =
  dimapCodec maybeToStrictMaybe strictMaybeToMaybe (optionalField key doc)

-- | Like 'optionalFieldStrict', but with an explicit value codec (mirrors
-- autodocodec's 'optionalFieldWith').
optionalFieldWithStrict :: Text -> JSONCodec a -> Text -> JSONObjectCodec (StrictMaybe a)
optionalFieldWithStrict key c doc =
  dimapCodec maybeToStrictMaybe strictMaybeToMaybe (optionalFieldWith key c doc)

-- | A codec for 'DiffTime', represented in JSON as a (possibly fractional)
-- number of seconds, matching the node.
diffTimeCodec :: JSONCodec DiffTime
diffTimeCodec = dimapCodec realToFrac realToFrac scientificCodec
