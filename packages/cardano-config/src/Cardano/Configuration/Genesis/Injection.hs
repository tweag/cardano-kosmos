-- | The genesis initial-data injection mechanism (the @extraConfig@ key of the
-- Shelley and Conway genesis).
--
-- A test network's genesis can carry the data the ledger seeds the initial
-- ledger state with — initial funds, stake pools, stake credentials,
-- delegations and DReps — in two ways:
--
-- * inline, in the legacy top-level genesis fields (@initialFunds@, @staking@,
--   @delegs@, @initialDReps@), which are decoded into memory along with the rest
--   of the genesis; or
--
-- * under the genesis @extraConfig@ key, either embedded (@data@) or, and this
--   is the point of the mechanism, as a reference to a separate JSON file
--   (@file@ plus @hash@) that @cardano-ledger@ /streams/ and hashes while
--   building the initial ledger state, so a large initial UTxO never has to be
--   held in memory as a decoded genesis field.
--
-- Only one of the two may be given per field: @cardano-ledger@'s
-- @resolveInjectionSource@ throws @InjectionConflictingSources@ when a field is
-- set both legacy-style and under @extraConfig@, and none of it is allowed on
-- mainnet. Both invariants are checked while the configuration is read (see
-- 'injectionProblems'), together with the existence of the referenced files
-- ('missingInjectionFiles'), so a bad genesis is reported against the genesis
-- key that named it rather than as an exception thrown from deep inside the
-- initial-ledger-state construction.
--
-- The file reference is /not/ a filesystem path: it is an @FsPath@, a list of
-- path segments that the ledger resolves against a @HasFS@ that the /consumer/
-- supplies. So the mount point is a configuration decision, not a ledger one,
-- and this module is where @cardano-config@ makes it: the filesystem is rooted
-- at the directory holding the Shelley genesis file (which is what
-- @cardano-node@ passes to @protocolInfoCardano@), and 'injectionHasFS' builds
-- it from the 'genesisInjectionRoot' recorded while parsing the configuration.
module Cardano.Configuration.Genesis.Injection
  ( -- * The filesystem the ledger resolves injection files against
    injectionMountPoint
  , injectionHasFS
  , injectionFilePath

    -- * The configured injections
  , InjectionSlot (..)
  , InjectionSource (..)
  , injectionSlots
  , renderInjectionSlot

    -- ** Queries over the slots
  , conflictingInjections
  , fileInjections
  , hasInjectedData

    -- * Validation
  , injectionProblems
  , missingInjectionFiles
  ) where

import Cardano.Crypto.Hash (Blake2b_256, Hash)
import Cardano.Ledger.BaseTypes (Network (Mainnet), StrictMaybe (..))
import Cardano.Ledger.Conway.Genesis (ConwayExtraConfig (..), ConwayGenesis (..))
import Cardano.Ledger.Shelley.Genesis
  ( InjectionData (..)
  , ShelleyExtraConfig (..)
  , ShelleyGenesis (..)
  , ShelleyGenesisStaking (..)
  )
import Data.ByteString (ByteString)
import Data.Maybe (mapMaybe)
import System.Directory (doesFileExist)
import System.FS.API (FsPath, MountPoint (..), SomeHasFS (..), fsToFilePath)
import System.FS.IO (ioHasFS)

-- | The mount point the ledger resolves genesis injection @FsPath@s against:
-- the directory holding the Shelley genesis file. This matches what
-- @cardano-node@ hands to @protocolInfoCardano@, so a @file@ reference in an
-- @extraConfig@ names a file sitting next to (or under the directory of) the
-- Shelley genesis, /not/ next to the node configuration file — the two differ
-- whenever the genesis files live in a subdirectory of the configuration.
--
-- The argument is the 'Cardano.Configuration.genesisInjectionRoot' recorded
-- while parsing the configuration, which is exactly that directory.
injectionMountPoint :: FilePath -> MountPoint
injectionMountPoint = MountPoint

-- | The filesystem to hand to @protocolInfoCardano@ (or, more directly, to
-- @cardano-ledger@'s @injectIntoTestState@), rooted at 'injectionMountPoint'.
--
-- This is the whole point of recording the injection root: a consumer that
-- builds the mount point itself has to know that it is the Shelley genesis
-- directory rather than the configuration directory, and gets silently wrong
-- lookups if it guesses.
injectionHasFS :: FilePath -> SomeHasFS IO
injectionHasFS = SomeHasFS . ioHasFS . injectionMountPoint

-- | Where an injection @FsPath@ ends up on the real filesystem, given the
-- injection root. Used for the existence check below, and useful for reporting.
injectionFilePath :: FilePath -> FsPath -> FilePath
injectionFilePath root = fsToFilePath (injectionMountPoint root)

-- | Where one injectable genesis field takes its data from, resolved the way
-- @cardano-ledger@'s @resolveInjectionSource@ resolves it.
data InjectionSource
  = -- | Neither the legacy field nor an @extraConfig@ entry carries anything.
    NotInjected
  | -- | The data is in the genesis itself: either the legacy field, or an
    -- @extraConfig@ entry with an embedded @data@ object.
    InjectedInline
  | -- | The data is in a separate file, named by an @FsPath@ relative to the
    -- injection root and pinned to a hash the ledger checks while streaming it.
    InjectedFromFile FsPath (Hash Blake2b_256 ByteString)
  | -- | Both the legacy field and its @extraConfig@ counterpart are set. The
    -- ledger rejects this (@InjectionConflictingSources@); only one source may
    -- be given.
    ConflictingSources
  deriving (Eq, Show)

-- | One injectable genesis field: which genesis it lives in, what it is called,
-- and where its data comes from.
data InjectionSlot = InjectionSlot
  { slotGenesisFile :: String
  -- ^ The configuration key naming the genesis file this field lives in:
  -- @ShelleyGenesisFile@ or @ConwayGenesisFile@.
  , slotExtraField :: String
  -- ^ The field's name under the genesis @extraConfig@ key.
  , slotLegacyField :: String
  -- ^ The field's name in the legacy (inline) form, at the genesis top level.
  , slotSource :: InjectionSource
  -- ^ Where this field's data actually comes from.
  }
  deriving (Eq, Show)

-- | A one-line description of a slot, naming both spellings of the field, for
-- error and warning messages. The genesis file it belongs to is
-- 'slotGenesisFile'.
renderInjectionSlot :: InjectionSlot -> String
renderInjectionSlot slot =
  slotExtraField slot <> " (legacy " <> slotLegacyField slot <> ")"

-- | Every injectable field of the Shelley and Conway genesis, with its resolved
-- source. This is the single place that mirrors @cardano-ledger@'s list of
-- injectable fields; everything else here is a query over the result.
injectionSlots :: ShelleyGenesis -> ConwayGenesis -> [InjectionSlot]
injectionSlots sg cg =
  [ mkSlot
      "ShelleyGenesisFile"
      "extraConfig.initialFunds"
      "initialFunds"
      (sgExtraConfig sg)
      secInitialFunds
      (sgInitialFunds sg)
  , mkSlot
      "ShelleyGenesisFile"
      "extraConfig.stakePools"
      "staking.pools"
      (sgExtraConfig sg)
      secStakePools
      (sgsPools (sgStaking sg))
  , mkSlot
      "ShelleyGenesisFile"
      "extraConfig.stakeCredentials"
      "staking.stake"
      (sgExtraConfig sg)
      secStakeCredentials
      (sgsStake (sgStaking sg))
  , mkSlot
      "ConwayGenesisFile"
      "extraConfig.delegs"
      "delegs"
      (cgExtraConfig cg)
      cecDelegs
      (cgDelegs cg)
  , mkSlot
      "ConwayGenesisFile"
      "extraConfig.initialDReps"
      "initialDReps"
      (cgExtraConfig cg)
      cecInitialDReps
      (cgInitialDReps cg)
  ]

-- | Resolve one field's source, following @resolveInjectionSource@: an
-- @extraConfig@ entry and a non-empty legacy field conflict; an absent (or
-- @NoInjection@) @extraConfig@ entry falls back to the legacy field.
mkSlot ::
  Foldable f =>
  -- | The genesis file key.
  String ->
  -- | The field name under @extraConfig@.
  String ->
  -- | The legacy field name.
  String ->
  -- | The genesis's @extraConfig@, if it has one.
  StrictMaybe ec ->
  -- | This field's entry within the @extraConfig@.
  (ec -> InjectionData k v) ->
  -- | The legacy field's contents.
  f a ->
  InjectionSlot
mkSlot genesisFile extraField legacyField mExtraConfig getEntry legacy =
  InjectionSlot genesisFile extraField legacyField source
 where
  source = case mExtraConfig of
    SNothing -> fromLegacy
    SJust extraConfig -> case getEntry extraConfig of
      NoInjection -> fromLegacy
      entry
        | null legacy -> fromEntry entry
        | otherwise -> ConflictingSources
  fromLegacy
    | null legacy = NotInjected
    | otherwise = InjectedInline
  fromEntry = \case
    NoInjection -> NotInjected
    EmbeddedInjection _ -> InjectedInline
    InjectionFromFile fp h -> InjectedFromFile fp h

-- | The fields that set both the legacy form and the @extraConfig@ one, which
-- the ledger rejects.
conflictingInjections :: [InjectionSlot] -> [InjectionSlot]
conflictingInjections = filter ((== ConflictingSources) . slotSource)

-- | The fields whose data lives in a separate file, with that file's @FsPath@.
fileInjections :: [InjectionSlot] -> [(InjectionSlot, FsPath)]
fileInjections =
  mapMaybe
    ( \s -> case slotSource s of
        InjectedFromFile fp _ -> Just (s, fp)
        _ -> Nothing
    )

-- | Whether any initial data is injected at all, in either form. Injection is
-- for test networks only: the ledger refuses it on mainnet.
hasInjectedData :: [InjectionSlot] -> Bool
hasInjectedData = any ((/= NotInjected) . slotSource)

-- | What is wrong with a configuration's genesis injection, as far as can be
-- told without touching the filesystem, each problem paired with the field it
-- concerns (so the caller can attribute it to the genesis file it came from):
--
-- * a field that names two sources at once, which @cardano-ledger@ rejects with
--   @InjectionConflictingSources@; and
--
-- * any injection at all on a mainnet genesis, which the ledger refuses with
--   @InjectionNotAllowedOnMainnet@ — this is a facility for test networks.
injectionProblems :: ShelleyGenesis -> ConwayGenesis -> [(InjectionSlot, String)]
injectionProblems sg cg =
  [ (s, "takes its initial data from both the legacy genesis field and extraConfig; give only one")
  | s <- conflictingInjections slots
  ]
    <> [ (s, "injects initial data, which is only allowed on a test network")
       | sgNetworkId sg == Mainnet
       , s <- slots
       , slotSource s /= NotInjected
       ]
 where
  slots = injectionSlots sg cg

-- | The referenced injection files that do not exist under the injection root,
-- as @(slot, resolved path)@ pairs.
--
-- Only existence is checked: the file's hash is verified by the ledger as it
-- streams the file, and re-hashing it here would mean reading a potentially very
-- large file twice. A missing file, though, is worth catching while the
-- configuration is being read — otherwise it surfaces much later as an
-- @FsError@ from the initial-ledger-state construction.
missingInjectionFiles :: FilePath -> [InjectionSlot] -> IO [(InjectionSlot, FilePath)]
missingInjectionFiles root slots =
  fmap concat . mapM check $ fileInjections slots
 where
  check (s, fp) = do
    let path = injectionFilePath root fp
    exists <- doesFileExist path
    pure [(s, path) | not exists]
