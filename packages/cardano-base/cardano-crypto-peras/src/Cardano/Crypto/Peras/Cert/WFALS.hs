{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}

-- | Conversion between the wire Peras certificate ('Base.PerasCert') and the
-- abstract wFA^LS certificate of the voting committee, for the BLS crypto
-- scheme 'PerasBLSCrypto'.
--
-- This is a port of the wFA^LS parts of @Ouroboros.Consensus.Peras.Cert.V1@
-- and @Ouroboros.Consensus.Peras.Voting.Adapter@. Consensus's @V1.PerasCert@
-- is a newtype over 'Base.PerasCert', so the conversions are the same.
module Cardano.Crypto.Peras.Cert.WFALS
  ( -- * Certificate conversion
    fromPerasCert
  , toPerasCert
  , fromPerasCertVoters
  , toPerasCertVoters

    -- * Conversion errors
  , PerasConversionError (..)

    -- * Seat indices
  , fromPerasSeatIndex
  , toPerasSeatIndex
  ) where

import Cardano.Crypto.Peras (PerasSeatIndex (..))
import qualified Cardano.Crypto.Peras.Cert as Base
import Cardano.Crypto.Peras.Committee.Crypto (CryptoSupportsAggregateVoteSigning (..), CryptoSupportsVRF (..))
import qualified Cardano.Crypto.Peras.Committee.Crypto.BLS as BLS
import Cardano.Crypto.Peras.Committee.WFA (SeatIndex (..))
import Cardano.Crypto.Peras.Committee.WFALS (Cert (..), WFALS)
import Cardano.Crypto.Peras.Crypto.BLS
  ( PerasBLSCrypto
  , PerasBLSCryptoAggregateVoteSignature (..)
  , VRFOutput (..)
  )
import Data.Containers.NonEmpty (HasNonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.NonEmpty as NEMap
import Data.Map.Strict (Map)
import Data.Word (Word16, Word64)
import GHC.Generics (Generic)
import NoThunks.Class (NoThunks)

-- | Errors that can occur when converting between Peras and committee types.
--
-- NOTE: consensus's version also has constructors for the @EveryoneVotes@
-- scheme and a 'CryptoError' that the wFA^LS conversions never produce; they
-- are omitted here.
data PerasConversionError
  = SeatIndexOverflowError Word64
  | PerasCertVotersError String
  deriving stock (Eq, Show, Generic)
  deriving anyclass NoThunks

-- | Convert a Peras seat index to a committee seat index.
fromPerasSeatIndex ::
  PerasSeatIndex ->
  SeatIndex
fromPerasSeatIndex (PerasSeatIndex seatIndex) =
  SeatIndex (fromIntegral @Word16 @Word64 seatIndex)

-- | Convert a committee seat index to a Peras seat index
--
-- NOTE: this can fail if the seat index in the committee vote or certificate
-- overflows the smaller 'Word16' type used by Peras votes and certificates.
-- In practice, this should never happen unless there is a bug in the voting
-- committee logic.
toPerasSeatIndex ::
  SeatIndex ->
  Either PerasConversionError PerasSeatIndex
toPerasSeatIndex (SeatIndex seatIndex)
  | seatIndex <= fromIntegral @Word16 @Word64 maxBound =
      Right (PerasSeatIndex (fromIntegral @Word64 @Word16 seatIndex))
  | otherwise =
      Left (SeatIndexOverflowError seatIndex)

toVRFOutput :: Base.PerasVRFOutput -> VRFOutput PerasBLSCrypto
toVRFOutput = PerasBLSCryptoVRFOutput . BLS.mkSignature . Base.unPerasVRFOutput

fromVRFOutput :: VRFOutput PerasBLSCrypto -> Base.PerasVRFOutput
fromVRFOutput = Base.PerasVRFOutput . BLS.rawSignature . unPerasBLSCryptoVRFOutput

toAggregateSignature :: Base.PerasSignature -> AggregateVoteSignature PerasBLSCrypto
toAggregateSignature =
  PerasBLSCryptoAggregateVoteSignature . BLS.mkSignature . Base.unPerasSignature

fromAggregateSignature :: AggregateVoteSignature PerasBLSCrypto -> Base.PerasSignature
fromAggregateSignature =
  Base.PerasSignature . BLS.rawSignature . unPerasBLSCryptoAggregateVoteSignature

-- | Seats (ascending) and optional non-persistent eligibility proofs of the
-- voters in a certificate.
fromPerasCertVoters ::
  Base.PerasCertVoters ->
  NE (Map SeatIndex (Maybe (VRFOutput PerasBLSCrypto)))
fromPerasCertVoters =
  NEMap.fromAscList
    . NonEmpty.map (\(seat, proof) -> (fromPerasSeatIndex seat, toVRFOutput <$> proof))
    . Base.perasCertVotersToSeats

toPerasCertVoters ::
  NE (Map SeatIndex (Maybe (VRFOutput PerasBLSCrypto))) ->
  Either PerasConversionError Base.PerasCertVoters
toPerasCertVoters voters = do
  seats <-
    traverse
      ( \(seat, proof) -> do
          seat' <- toPerasSeatIndex seat
          pure (seat', fromVRFOutput <$> proof)
      )
      (NEMap.toAscList voters)
  either (Left . PerasCertVotersError) pure (Base.perasCertVotersFromSeats seats)

-- | Turn an abstract wFA^LS certificate into a wire certificate.
toPerasCert ::
  Cert PerasBLSCrypto WFALS ->
  Either PerasConversionError Base.PerasCert
toPerasCert (WFALSCert electionId candidate voters sig) = do
  voters' <- toPerasCertVoters voters
  pure
    Base.PerasCert
      { Base.pcRoundNo = electionId
      , Base.pcBoostedBlock = candidate
      , Base.pcVoters = voters'
      , Base.pcSignature = fromAggregateSignature sig
      }

-- | Turn a wire certificate into an abstract wFA^LS certificate.
--
-- This conversion cannot fail, but returns 'Either' to match consensus's
-- @PerasCertCompatibleWithVotingCommittee@ interface.
fromPerasCert ::
  Base.PerasCert ->
  Either PerasConversionError (Cert PerasBLSCrypto WFALS)
fromPerasCert Base.PerasCert{Base.pcRoundNo, Base.pcBoostedBlock, Base.pcVoters, Base.pcSignature} =
  pure $
    WFALSCert
      pcRoundNo
      pcBoostedBlock
      (fromPerasCertVoters pcVoters)
      (toAggregateSignature pcSignature)
