{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Self-contained verification of Peras certificates.
--
-- This module bundles the wFA^LS voting committee, the BLS crypto scheme
-- 'PerasBLSCrypto' and the quorum rule into a single entry point,
-- 'verifyPerasCert', which yields the same verdicts as consensus's
-- @defaultVerifyPerasCert@ for the Dijkstra era (wFA^LS committee, BLS
-- crypto). It only depends on @cardano-base@ types, so that the ledger can call
-- it.
--
-- The caller is responsible for choosing the right epoch inputs (epoch nonce
-- and stake distribution) for the round of the certificate, as consensus does
-- when it resolves the Peras epoch context of a round.
module Cardano.Crypto.Peras.Validation
  ( -- * Quorum
    PerasQuorumThreshold (..)
  , perasWeightAboveThreshold

    -- * Validation context
  , PerasCertValidationContext
  , pcvcCommittee
  , pcvcQuorumThreshold
  , mkPerasCertValidationContext
  , PerasCertValidationContextError (..)

    -- * Verification
  , verifyPerasCert
  , PerasCertValidationError (..)

    -- * Public keys
  , PerasPublicKey (..)
  , perasLedgerKeyScope
  , perasPublicKeyFromBlsKey

    -- * Re-exports
  , Nonce (..)
  , BlsKey (..)
  , KeyHash (..)
  , PoolId (..)
  , LedgerStake (..)
  , TargetCommitteeSize (..)
  , VoteWeight (..)
  , PerasBLSCrypto
  , WFALS
  , VotingCommittee
  , VotingCommitteeError
  , WFAError (..)
  ) where

import Cardano.Crypto.Peras.Cert (PerasCert)
import Cardano.Crypto.Peras.Cert.WFALS (PerasConversionError, fromPerasCert)
import Cardano.Crypto.Peras.Committee.Base (BlsKey (..), KeyHash (..), Nonce (..))
import Cardano.Crypto.Peras.Committee.Class
  ( CryptoSupportsVotingCommittee (..)
  , VotingCommittee
  )
import qualified Cardano.Crypto.Peras.Committee.Crypto.BLS as BLS
import Cardano.Crypto.Peras.Committee.Types
  ( LedgerStake (..)
  , PoolId (..)
  , TargetCommitteeSize (..)
  , VoteWeight (..)
  )
import Cardano.Crypto.Peras.Committee.WFA
  ( WFAError (..)
  , mkExtWFAStakeDistr
  , wFATiebreakerWithEpochNonce
  )
import Cardano.Crypto.Peras.Committee.WFALS (VotingCommitteeInput (..), WFALS)
import Cardano.Crypto.Peras.Crypto.BLS (PerasBLSCrypto, PerasPublicKey (..))
import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import GHC.Generics (Generic)

{-------------------------------------------------------------------------------
  Quorum
-------------------------------------------------------------------------------}

-- | Quorum parameters, as in consensus's @PerasParams@
-- (@perasQuorumWeightThreshold@ and @perasQuorumWeightThresholdSafetyMargin@).
--
-- Both values are relative (normalized) vote weights. In consensus, the
-- threshold is the constant @3/4@ and the safety margin comes from the
-- @plvQuorumThresholdSafetyMargin@ protocol parameter.
data PerasQuorumThreshold = PerasQuorumThreshold
  { pqtQuorumWeightThreshold :: !Rational
  , pqtQuorumWeightThresholdSafetyMargin :: !Rational
  }
  deriving stock (Show, Eq, Generic)

-- | Check whether a given vote weight reaches the quorum.
--
-- Port of consensus's @weightAboveThreshold@: the weight must be at least the
-- threshold plus the safety margin.
perasWeightAboveThreshold :: PerasQuorumThreshold -> VoteWeight -> Bool
perasWeightAboveThreshold quorum (VoteWeight weight) =
  weight >= pqtQuorumWeightThreshold quorum + pqtQuorumWeightThresholdSafetyMargin quorum

{-------------------------------------------------------------------------------
  Public keys
-------------------------------------------------------------------------------}

-- | Key scope of the BLS public keys registered in the ledger.
--
-- Must match consensus's @Ouroboros.Consensus.Peras.Voting.V1.ledgerKeyScope@:
-- the scope prefixes every signed message (e.g. @VOTE:PERAS/LEDGER:V0@), so a
-- different scope makes every signature check fail.
perasLedgerKeyScope :: BLS.KeyScope
perasLedgerKeyScope = "PERAS/LEDGER"

-- | Build a committee public key from a pool's registered BLS key, with the
-- ledger key scope, as consensus does.
--
-- The proof of possession is not checked here; the ledger checks it at
-- registration.
perasPublicKeyFromBlsKey :: BlsKey -> PerasPublicKey
perasPublicKeyFromBlsKey =
  PerasPublicKey . BLS.coercePublicKey . BLS.publicKeyFromLedgerBlsKey perasLedgerKeyScope

{-------------------------------------------------------------------------------
  Validation context
-------------------------------------------------------------------------------}

-- | Everything needed to verify the certificates of an epoch: the wFA^LS
-- voting committee of the epoch and the quorum parameters.
data PerasCertValidationContext = PerasCertValidationContext
  { pcvcCommittee :: !(VotingCommittee PerasBLSCrypto WFALS)
  , pcvcQuorumThreshold :: !PerasQuorumThreshold
  }
  deriving stock (Show, Eq, Generic)

-- | Errors building a 'PerasCertValidationContext'.
data PerasCertValidationContextError
  = -- | The stake distribution could not be turned into a wFA^LS one (e.g. it
    -- is empty)
    PerasContextWFAError WFAError
  | -- | The committee could not be built (e.g. not enough pools with positive
    -- stake for the target committee size)
    PerasContextCommitteeError (VotingCommitteeError PerasBLSCrypto WFALS)
  deriving stock (Show, Eq, Generic)

-- | Build the validation context of an epoch.
--
-- This mirrors consensus's @mkPerasVotingCommitteeInput@ followed by
-- @mkVotingCommittee@:
--
-- * the stake distribution must contain exactly the pools that have a
--   registered BLS key (consensus drops the others), keyed by pool id, with
--   their ledger stake (consensus uses @individualPoolStake@, the pool's
--   relative stake) and their public key in the ledger key scope (see
--   'perasPublicKeyFromVerificationKey');
-- * the epoch nonce is the one consensus uses for that epoch
--   (@praosStateEpochNonce@);
-- * the target committee size is consensus's @perasTargetCommitteeSize@.
--
-- This is the expensive step (sorting the stake distribution); build it once
-- per epoch.
mkPerasCertValidationContext ::
  Nonce ->
  Map PoolId (LedgerStake, PerasPublicKey) ->
  TargetCommitteeSize ->
  PerasQuorumThreshold ->
  Either PerasCertValidationContextError PerasCertValidationContext
mkPerasCertValidationContext epochNonce stakeDistr targetCommitteeSize quorum = do
  extWFAStakeDistr <-
    first PerasContextWFAError $
      mkExtWFAStakeDistr
        (wFATiebreakerWithEpochNonce epochNonce)
        stakeDistr
  committee <-
    first PerasContextCommitteeError $
      mkVotingCommittee
        ( WFALSVotingCommitteeInput
            epochNonce
            targetCommitteeSize
            extWFAStakeDistr
        )
  pure
    PerasCertValidationContext
      { pcvcCommittee = committee
      , pcvcQuorumThreshold = quorum
      }

{-------------------------------------------------------------------------------
  Verification
-------------------------------------------------------------------------------}

-- | Reasons for rejecting a certificate.
--
-- These correspond to the errors consensus's @defaultVerifyPerasCert@ can
-- raise: @PerasVotingConversionError@, @PerasVotingCommitteeError@ and
-- @PerasQuorumNotReachedError@.
data PerasCertValidationError
  = PerasCertConversionError PerasConversionError
  | PerasCertCommitteeError (VotingCommitteeError PerasBLSCrypto WFALS)
  | -- | The certificate is valid but its total vote weight is below quorum
    PerasCertQuorumNotReached VoteWeight
  deriving stock (Show, Eq, Generic)

-- | Verify a Peras certificate and return its total (normalized) vote weight.
--
-- Port of consensus's @defaultVerifyPerasCert@: verify the certificate against
-- the committee (seats, aggregate vote signature, VRF eligibility proofs), sum
-- the vote weights of its voters and check that the sum reaches the quorum.
--
-- As in consensus, this does not check that the boosted block is not from the
-- future with respect to the round, nor the certificate size.
verifyPerasCert ::
  PerasCertValidationContext ->
  PerasCert ->
  Either PerasCertValidationError VoteWeight
verifyPerasCert ctx cert = do
  let committee = pcvcCommittee ctx
  abstractCert <-
    first PerasCertConversionError $
      fromPerasCert cert
  witnesses <-
    first PerasCertCommitteeError $
      verifyCert committee abstractCert
  let totalVoteWeight = sum (eligiblePartyVoteWeight committee <$> witnesses)
  if perasWeightAboveThreshold (pcvcQuorumThreshold ctx) totalVoteWeight
    then pure totalVoteWeight
    else Left (PerasCertQuorumNotReached totalVoteWeight)
