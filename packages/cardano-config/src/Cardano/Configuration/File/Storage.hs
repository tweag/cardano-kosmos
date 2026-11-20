-- | Options related to storage
module Cardano.Configuration.File.Storage
  ( adjustDbPath
  , StorageConfiguration (..)

    -- * LedgerDB
  , LedgerDbConfiguration (..)

    -- ** Snapshots
  , SnapshotPolicy (..)
  , SnapshotOptions (..)
  , mithrilSnapshotOptions
  , resolveSnapshotPolicy
  , resolveSnapshotOptions

    -- ** Backend
  , LedgerDbBackendSelector (..)
  ) where

import Autodocodec
import Cardano.Configuration.Basic (optionalFieldStrict, optionalFieldWithStrict)
import Cardano.Configuration.Common
import Cardano.Ledger.BaseTypes
  ( StrictMaybe (..)
  , fromSMaybe
  )
import Control.Applicative ((<|>))
import Data.Aeson (FromJSON, ToJSON)
import Data.Default
import Data.Functor.Identity
import Data.Word
import GHC.Generics

-- | A non-zero snapshot interval, in slots: the node rejects 0.
snapshotIntervalCodec :: JSONCodec Word64
snapshotIntervalCodec = bimapCodec validate id codec
 where
  validate 0 = Left "Non-positive Interval: 0"
  validate w = Right w

-- | An explicit set of snapshot policy options. All fields are optional; when
-- unset the node applies its own defaults (which are the Mithril values in
-- @mithrilSnapshotOptions@).
data SnapshotOptions = SnapshotOptions
  { snapshotInterval :: StrictMaybe Word64
  -- ^ How many slots between attempts to write a snapshot to disk (non-zero).
  , slotOffset :: StrictMaybe Word64
  -- ^ The slot at which the snapshot schedule is anchored: snapshots are taken
  --     at @slotOffset + n * snapshotInterval@.
  , snapshotRateLimit :: StrictMaybe Word64
  -- ^ The minimum wall-clock time, in seconds, between two snapshots.
  , minDelay :: StrictMaybe Word64
  -- ^ Lower bound, in seconds, of the random delay before taking a snapshot.
  , maxDelay :: StrictMaybe Word64
  -- ^ Upper bound, in seconds, of the random delay before taking a snapshot.
  , numOfDiskSnapshots :: StrictMaybe Word64
  -- ^ How many snapshots the node should keep on disk.
  }
  deriving (Eq, Generic, Show)

instance HasCodec SnapshotOptions where
  codec =
    bimapCodec validateDelays id $
      object "SnapshotOptions" $
        SnapshotOptions
          <$> optionalFieldWithStrict
            "Interval"
            snapshotIntervalCodec
            "Slots between snapshots (non-zero)"
            .= snapshotInterval
          <*> optionalFieldStrict "Offset" "Slot at which the snapshot schedule is anchored" .= slotOffset
          <*> optionalFieldStrict "RateLimit" "Minimum seconds between snapshots" .= snapshotRateLimit
          <*> optionalFieldStrict "MinDelay" "Lower bound (seconds) of the random snapshot delay" .= minDelay
          <*> optionalFieldStrict "MaxDelay" "Upper bound (seconds) of the random snapshot delay" .= maxDelay
          <*> optionalFieldStrict "NumOfDiskSnapshots" "How many snapshots to keep on disk" .= numOfDiskSnapshots
   where
    validateDelays so@SnapshotOptions{minDelay = SJust lo, maxDelay = SJust hi}
      | lo > hi =
          Left $ "Invalid snapshot delay range, MinDelay > MaxDelay: " <> show lo <> " > " <> show hi
      | otherwise = Right so
    validateDelays so = Right so

-- | The snapshot policy: either the predefined @"Mithril"@ policy (the only
-- named policy currently accepted) or an explicit set of options.
data SnapshotPolicy
  = MithrilSnapshotPolicy
  | CustomSnapshotPolicy SnapshotOptions
  deriving (Generic, Show)

-- | The Mithril policy is the JSON string @"Mithril"@ (and nothing else); a
-- custom policy is a JSON object. We dispatch on that shape so that, when an
-- object is supplied, a validation failure inside 'SnapshotOptions' is reported
-- on its own rather than alongside the irrelevant other-branch failure. Using a
-- literal @"Mithril"@ codec (rather than an arbitrary string) means any other
-- string is rejected at parse time, and the schema lists @"Mithril"@ as the only
-- accepted value.
instance HasCodec SnapshotPolicy where
  codec =
    matchChoiceCodec
      (literalTextValueCodec MithrilSnapshotPolicy "Mithril")
      (dimapCodec CustomSnapshotPolicy id (codec @SnapshotOptions))
      selector
   where
    selector MithrilSnapshotPolicy = Left MithrilSnapshotPolicy
    selector (CustomSnapshotPolicy o) = Right o

-- | The concrete snapshot options the @"Mithril"@ policy stands for. Resolving
-- @"Mithril"@ to these values here means every consumer (not just consensus)
-- gets the same numbers without re-deriving them.
--
-- The interval of 86400 slots is @40 * k@ for the mainnet security parameter
-- @k = 2160@, which is one snapshot a day. That interval divides both the
-- 432000-slot Shelley epoch and the 4492800-slot start of Shelley, so with an
-- offset of 0 the schedule hits every epoch boundary, which is the state
-- Mithril signs, and four further slots inside each epoch. The node captures
-- the state at that slot but writes it between @MinDelay@ and @MaxDelay@
-- seconds later, so the write does not land on the epoch-boundary work.
--
-- The interval is the mainnet value. A network with a different security
-- parameter needs its own @Interval@.
--
-- These mirror the values consensus uses for the Mithril policy, in
-- @Ouroboros.Consensus.Storage.LedgerDB.Snapshots.mithrilSnapshotPolicyArgs@. A
-- test pins them here, so a change on this side is deliberate, but nothing
-- compares the two packages: keep them in step by hand.
mithrilSnapshotOptions :: SnapshotOptions
mithrilSnapshotOptions =
  SnapshotOptions
    { snapshotInterval = SJust 86400
    , slotOffset = SJust 0
    , snapshotRateLimit = SJust 600
    , minDelay = SJust 300
    , maxDelay = SJust 21600
    , numOfDiskSnapshots = SJust 2
    }

-- | Resolve a snapshot policy to a concrete, fully-populated set of options:
-- @"Mithril"@ becomes 'mithrilSnapshotOptions', and a custom (possibly partial)
-- policy keeps every value the user set while the Mithril values fill in any it
-- left unset. So a configuration that overrides only a couple of snapshot
-- options still ends up with all of them resolved.
resolveSnapshotPolicy :: SnapshotPolicy -> SnapshotOptions
resolveSnapshotPolicy MithrilSnapshotPolicy = mithrilSnapshotOptions
resolveSnapshotPolicy (CustomSnapshotPolicy user) =
  SnapshotOptions
    { snapshotInterval = snapshotInterval user <|> snapshotInterval mithrilSnapshotOptions
    , slotOffset = slotOffset user <|> slotOffset mithrilSnapshotOptions
    , snapshotRateLimit = snapshotRateLimit user <|> snapshotRateLimit mithrilSnapshotOptions
    , minDelay = minDelay user <|> minDelay mithrilSnapshotOptions
    , maxDelay = maxDelay user <|> maxDelay mithrilSnapshotOptions
    , numOfDiskSnapshots = numOfDiskSnapshots user <|> numOfDiskSnapshots mithrilSnapshotOptions
    }

-- | Selector for the backend that keeps track of differences in the UTxO set.
data LedgerDbBackendSelector
  = -- | The in-memory backend.
    V2InMemory
  | -- | The LSM-tree backend.
    V2LSM
      -- | An optional custom path to the
      -- database (the @LSMDatabasePath@ key). Relative to the volatile
      -- database directory, or used as is when absolute.
      (StrictMaybe FilePath)
      -- | An optional directory into which the backend
      -- exports snapshots as it takes them (the @LSMExportPath@ key).
      -- Resolved like the database path, and it must be on the same volume
      -- as the database.
      (StrictMaybe FilePath)
  deriving (Eq, Generic, Show)

-- | The @Backend@ value: the string @"V2InMemory"@, or the LSM backend tagged as
-- an object @{ "LSM": { "DatabasePath": …, "ExportPath": … } }@ (both keys
-- optional). Dispatching on shape (string vs object) mirrors 'SnapshotPolicy'.
instance HasCodec LedgerDbBackendSelector where
  codec =
    matchChoiceCodec
      (literalTextValueCodec V2InMemory "V2InMemory")
      (dimapCodec (uncurry V2LSM) id lsmObjectCodec)
      selector
   where
    selector V2InMemory = Left V2InMemory
    selector (V2LSM p e) = Right (p, e)

    lsmObjectCodec :: JSONCodec (StrictMaybe FilePath, StrictMaybe FilePath)
    lsmObjectCodec =
      object "V2LSM" $
        requiredFieldWith
          "LSM"
          ( object "LSMOptions" $
              (,)
                <$> optionalFieldWithStrict
                  "DatabasePath"
                  filePathCodec
                  ( "Custom path to the LSM database. A relative path is resolved against the "
                      <> "volatile database directory (the DatabasePath itself when it is a single "
                      <> "path); an absolute path is used as is. Defaults to \"lsm\""
                  )
                  .= fst
                <*> optionalFieldWithStrict
                  "ExportPath"
                  filePathCodec
                  ( "Directory into which the LSM backend exports snapshots. Resolved like "
                      <> "DatabasePath: relative to the volatile database directory, or as is when "
                      <> "absolute. It must be on the same volume (filesystem or drive) as the LSM "
                      <> "database, otherwise exporting a snapshot fails"
                  )
                  .= snd
          )
          "LSM-tree backend options"

-- | The Ledger DB configuration
data LedgerDbConfiguration = LedgerDbConfiguration
  { snapshots :: StrictMaybe SnapshotPolicy
  , queryBatchSize :: StrictMaybe Word64
  , backendSelector :: StrictMaybe LedgerDbBackendSelector
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via (Autodocodec LedgerDbConfiguration)

instance HasCodec LedgerDbConfiguration where
  codec =
    object "LedgerDB" $
      LedgerDbConfiguration
        <$> optionalFieldStrict "Snapshots" "Snapshot policy: \"Mithril\" or an object of snapshot options"
          .= snapshots
        <*> optionalFieldStrict "QueryBatchSize" "Chunk size for large backend reads" .= queryBatchSize
        <*> optionalFieldStrict "Backend" "LedgerDB backend: \"V2InMemory\" or an LSM object" .= backendSelector

instance Default LedgerDbConfiguration where
  def = LedgerDbConfiguration SNothing SNothing SNothing

-- | Finally resolve the storage configuration with a final 'NodeDatabasePaths'.
-- The V2LSM backend's database path defaults to @"lsm"@ when unset (the export
-- path stays optional). The snapshot policy is /not/ resolved here — that happens
-- in 'resolveSnapshotOptions', after the consistency checks.
adjustDbPath ::
  StorageConfiguration StrictMaybe -> NodeDatabasePaths -> StorageConfiguration Identity
adjustDbPath sc db =
  sc
    { databasePath = Identity db
    , ledgerDbConfiguration =
        Identity $ defaultLsmDatabasePath $ fromSMaybe def $ ledgerDbConfiguration sc
    }
 where
  defaultLsmDatabasePath ldb = ldb{backendSelector = withLsmDefault <$> backendSelector ldb}
  withLsmDefault (V2LSM dbPath exportPath) = V2LSM (dbPath <|> SJust "lsm") exportPath
  withLsmDefault other = other

-- | Resolve the snapshot policy to a concrete set of options (see
-- 'resolveSnapshotPolicy'), so the resolved configuration never carries the bare
-- @"Mithril"@ policy or a partially-specified options object. Run /after/ the
-- consistency checks, so they see the policy as requested.
resolveSnapshotOptions :: StorageConfiguration Identity -> StorageConfiguration Identity
resolveSnapshotOptions sc =
  sc{ledgerDbConfiguration = fmap normalize (ledgerDbConfiguration sc)}
 where
  normalize ldb = ldb{snapshots = CustomSnapshotPolicy . resolveSnapshotPolicy <$> snapshots ldb}

-- | The storage configuration
data StorageConfiguration f = StorageConfiguration
  { databasePath :: f NodeDatabasePaths
  , ledgerDbConfiguration :: f LedgerDbConfiguration
  }
  deriving Generic

deriving instance Show (StorageConfiguration StrictMaybe)
deriving instance Show (StorageConfiguration Identity)

deriving via
  (Autodocodec (StorageConfiguration StrictMaybe))
  instance
    FromJSON (StorageConfiguration StrictMaybe)

deriving via
  (Autodocodec (StorageConfiguration StrictMaybe))
  instance
    ToJSON (StorageConfiguration StrictMaybe)

instance HasCodec (StorageConfiguration StrictMaybe) where
  codec =
    object "StorageConfiguration" $
      StorageConfiguration
        <$> optionalFieldStrict "DatabasePath" "Directory (or split directories) where the state is stored"
          .= databasePath
        <*> optionalFieldStrict "LedgerDB" "The LedgerDB configuration" .= ledgerDbConfiguration
