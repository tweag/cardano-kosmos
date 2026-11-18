{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Test.Cardano.Crypto.Peras.Validation (spec) where

import Cardano.Binary.FixedSizeCodec (rawEncodeFixedSized)
import Cardano.Crypto.DSIGN (DSIGNAggregatable (..), DSIGNAlgorithm (..))
import Cardano.Crypto.Hash (Blake2b_224, Blake2b_256)
import qualified Cardano.Crypto.Hash as Hash
import Cardano.Crypto.Peras (
  PerasBlockRef (..),
  PerasBoostedBlock (..),
  PerasRoundNo (..),
  PerasSeatIndex,
  PerasSigningKey,
  PerasVRFOutput (..),
 )
import Cardano.Crypto.Peras.Cert (
  PerasCert (..),
  PerasCertVoters,
  perasCertNumberOfNonPersistentVoters,
  perasCertVotersFromSeats,
  perasCertVotersToSeats,
 )
import Cardano.Crypto.Peras.Cert.WFALS (fromPerasCert, toPerasCert, toPerasSeatIndex)
import Cardano.Crypto.Peras.Committee.Class (
  CryptoSupportsVotingCommittee (..),
  ensureUniqueVotesWithSameTarget,
 )
import Cardano.Crypto.Peras.Committee.Crypto (
  CryptoSupportsVRF (..),
  VRFPoolContext (..),
 )
import qualified Cardano.Crypto.Peras.Committee.Crypto.BLS as BLS
import Cardano.Crypto.Peras.Committee.WFALS (Vote (..))
import Cardano.Crypto.Peras.Crypto.BLS (
  PerasPrivateKey (..),
  VRFOutput (..),
  VoteSignature (..),
 )
import Cardano.Crypto.Peras.Validation
import Cardano.Slotting.Slot (SlotNo (..), WithOrigin (..))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BSB
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Short as SBS
import Data.Either (isLeft)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Proxy (Proxy (..))
import Data.Word (Word8)
import GHC.Base (Any)
import Test.Cardano.Crypto.Peras.Gen (perasSigningKeyFromSeedByte)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

{-------------------------------------------------------------------------------
  Fixture
-------------------------------------------------------------------------------}

data TestPool = TestPool
  { tpPoolId :: PoolId
  , tpSigningKey :: PerasSigningKey
  , tpPrivateKey :: PerasPrivateKey
  , tpStake :: LedgerStake
  }

mkTestPool :: Word8 -> Rational -> TestPool
mkTestPool seedByte stake =
  TestPool
    { tpPoolId = PoolId (KeyHash (Hash.castHash (Hash.hashWith @Blake2b_224 id (BS.pack [seedByte]))))
    , tpSigningKey = sk
    , tpPrivateKey =
        PerasPrivateKey
          . fromMaybe (error "mkTestPool: invalid private key")
          . BLS.rawDeserialisePrivateKey @Any perasLedgerKeyScope
          $ rawEncodeFixedSized sk
    , tpStake = LedgerStake stake
    }
 where
  sk = perasSigningKeyFromSeedByte seedByte

-- | Ten pools with a long-tailed stake distribution, so that a committee of
-- target size 6 has both persistent and non-persistent seats.
testPools :: [TestPool]
testPools =
  zipWith
    mkTestPool
    [1 ..]
    ((/ 100) <$> [25, 20, 15, 10, 8, 7, 5, 4, 3, 3])

testNonce :: Nonce
testNonce = Nonce (Hash.castHash (Hash.hashWith @Blake2b_256 id "peras-validation-test-nonce"))

testStakeDistr :: Map.Map PoolId (LedgerStake, PerasPublicKey)
testStakeDistr =
  Map.fromList
    [ (tpPoolId p, (tpStake p, perasPublicKeyFromBlsKey (BlsKey (deriveVerKeyDSIGN (tpSigningKey p)) (createPossessionProofDSIGN (tpSigningKey p)))))
    | p <- testPools
    ]

testTargetCommitteeSize :: TargetCommitteeSize
testTargetCommitteeSize = TargetCommitteeSize 6

consensusQuorum :: PerasQuorumThreshold
consensusQuorum = PerasQuorumThreshold (3 / 4) 0

mkContext :: PerasQuorumThreshold -> PerasCertValidationContext
mkContext quorum =
  either (error . show) id $
    mkPerasCertValidationContext testNonce testStakeDistr testTargetCommitteeSize quorum

testContext :: PerasCertValidationContext
testContext = mkContext consensusQuorum

testCommittee :: VotingCommittee PerasBLSCrypto WFALS
testCommittee = pcvcCommittee testContext

mkBlock :: Word8 -> PerasBoostedBlock
mkBlock b =
  PerasBoostedBlock . At $
    PerasBlockRef
      { pbrSlot = SlotNo (1000 + fromIntegral b)
      , pbrHash = SBS.toShort (BS.replicate 32 b)
      }

testBlock :: PerasBoostedBlock
testBlock = mkBlock 0xaa

-- | All the votes of the eligible pools (among the given ones) for a round.
forgeVotes :: [TestPool] -> PerasRoundNo -> PerasBoostedBlock -> [Vote PerasBLSCrypto WFALS]
forgeVotes pools roundNo block =
  [ forgeVote witness (tpPrivateKey p) roundNo block
  | p <- pools
  , Right (Just witness) <- [checkShouldVote testCommittee (tpPoolId p) (tpPrivateKey p) roundNo]
  ]

-- | Forge a certificate from the votes of the eligible pools (among the given
-- ones), with the ported committee code.
forgeTestCert :: [TestPool] -> PerasRoundNo -> PerasBoostedBlock -> PerasCert
forgeTestCert pools roundNo block =
  case forgeVotes pools roundNo block of
    [] -> error "forgeTestCert: no eligible voter"
    v : vs ->
      either (error . show) id $ do
        uniqueVotes <-
          either (Left . const "duplicate votes") Right $
            ensureUniqueVotesWithSameTarget voteTarget compareVotesById (v :| vs)
        abstractCert <- either (Left . show) Right (forgeCert uniqueVotes)
        either (Left . show) Right (toPerasCert abstractCert)

-- | The first round (from 0) whose certificate, with every pool voting, has at
-- least one non-persistent voter and reaches the consensus quorum.
goodRound :: PerasRoundNo
goodRound =
  fromMaybe (error "no suitable round") $
    find suitable [0 .. 200]
 where
  suitable r =
    let cert = forgeTestCert testPools r testBlock
     in perasCertNumberOfNonPersistentVoters (pcVoters cert) > 0
          && either (const False) (const True) (verifyPerasCert testContext cert)

goodCert :: PerasCert
goodCert = forgeTestCert testPools goodRound testBlock

modifyVoters :: ([(PerasSeatIndex, Maybe PerasVRFOutput)] -> [(PerasSeatIndex, Maybe PerasVRFOutput)]) -> PerasCert -> PerasCert
modifyVoters f cert =
  cert{pcVoters = rebuild (f (NonEmpty.toList (perasCertVotersToSeats (pcVoters cert))))}
 where
  rebuild :: [(PerasSeatIndex, Maybe PerasVRFOutput)] -> PerasCertVoters
  rebuild seats =
    case seats of
      [] -> error "modifyVoters: no voters left"
      s : ss -> either error id (perasCertVotersFromSeats (s :| ss))

-- | The pool sitting in each seat that votes in 'goodRound'.
seatPools :: Map.Map PerasSeatIndex TestPool
seatPools =
  Map.fromList
    [ (either (error . show) id (toPerasSeatIndex (voteSeat vote)), p)
    | p <- testPools
    , vote <- forgeVotes [p] goodRound testBlock
    ]
 where
  voteSeat (WFALSPersistentVote seat _ _ _) = seat
  voteSeat (WFALSNonPersistentVote seat _ _ _ _) = seat

shouldBeCommitteeError :: Either PerasCertValidationError VoteWeight -> Expectation
shouldBeCommitteeError r =
  case r of
    Left (PerasCertCommitteeError _) -> pure ()
    other -> expectationFailure ("expected a committee error, got: " <> show other)

{-------------------------------------------------------------------------------
  Byte-exactness pins (independent of the committee code)
-------------------------------------------------------------------------------}

word64BE :: Integral a => a -> BSB.Builder
word64BE = BSB.word64BE . fromIntegral

blake2b256 :: BS.ByteString -> BS.ByteString
blake2b256 = Hash.hashToBytes . Hash.hashWith @Blake2b_256 id

buildStrict :: BSB.Builder -> BS.ByteString
buildStrict = BSL.toStrict . BSB.toLazyByteString

-- | The message consensus signs for a vote/certificate: Blake2b-256 of the
-- big-endian round number, slot and block hash (nothing for 'Origin').
expectedVoteMessage :: PerasRoundNo -> PerasBoostedBlock -> BS.ByteString
expectedVoteMessage (PerasRoundNo r) (PerasBoostedBlock wo) =
  blake2b256 . buildStrict $
    word64BE r <> case wo of
      Origin -> mempty
      At (PerasBlockRef (SlotNo s) h) -> word64BE s <> BSB.shortByteString h

-- | The VRF input consensus uses: Blake2b-256 of the big-endian round number
-- and the epoch nonce bytes (nothing for 'NeutralNonce').
expectedVRFInput :: PerasRoundNo -> Nonce -> BS.ByteString
expectedVRFInput (PerasRoundNo r) nonce =
  blake2b256 . buildStrict $
    word64BE r <> case nonce of
      NeutralNonce -> mempty
      Nonce h -> BSB.byteString (Hash.hashToBytes h)

{-------------------------------------------------------------------------------
  Spec
-------------------------------------------------------------------------------}

spec :: Spec
spec = describe "Validation" $ do
  describe "fixture" $ do
    it "the good certificate has persistent and non-persistent voters" $ do
      let seats = NonEmpty.toList (perasCertVotersToSeats (pcVoters goodCert))
      any (isNothing . snd) seats `shouldBe` True
      any (isJust . snd) seats `shouldBe` True
    it "fromPerasCert . toPerasCert round-trips the wire certificate" $
      (fromPerasCert goodCert >>= toPerasCert) `shouldBe` Right goodCert

  describe "byte-exactness of the signed messages" $ do
    let pool = head testPools
        vk = deriveVerKeyDSIGN (tpSigningKey pool)
    it "vote signatures are BLS signatures over the consensus message prefixed with the VOTE scope" $ do
      let witness =
            either (error . show) (fromMaybe (error "not eligible")) $
              checkShouldVote testCommittee (tpPoolId pool) (tpPrivateKey pool) goodRound
          sig = case forgeVote witness (tpPrivateKey pool) goodRound testBlock of
            WFALSPersistentVote _ _ _ s -> s
            WFALSNonPersistentVote _ _ _ _ s -> s
      verifyDSIGN
        ()
        vk
        ("VOTE:PERAS/LEDGER:V0" <> expectedVoteMessage goodRound testBlock)
        (BLS.rawSignature (unPerasBLSCryptoVoteSignature sig))
        `shouldBe` Right ()
    it "VRF outputs are BLS signatures over the consensus VRF input prefixed with the VRF scope" $ do
      let vrfOutput =
            either error id $
              evalVRF
                (VRFSignContext (getVRFSigningKey (Proxy @PerasBLSCrypto) (tpPrivateKey pool)))
                (mkVRFElectionInput @PerasBLSCrypto testNonce goodRound)
      verifyDSIGN
        ()
        vk
        ("VRF:PERAS/LEDGER:V0" <> expectedVRFInput goodRound testNonce)
        (BLS.rawSignature (unPerasBLSCryptoVRFOutput vrfOutput))
        `shouldBe` Right ()

  describe "verifyPerasCert" $ do
    it "accepts a certificate forged by the committee" $
      verifyPerasCert testContext goodCert `shouldSatisfy` either (const False) (>= VoteWeight (3 / 4))
    it "uses >= on threshold + safety margin" $ do
      let weight = either (error . show) id (verifyPerasCert testContext goodCert)
      verifyPerasCert (mkContext (PerasQuorumThreshold (unVoteWeight weight) 0)) goodCert
        `shouldBe` Right weight
      verifyPerasCert (mkContext (PerasQuorumThreshold (unVoteWeight weight - 1 / 100) (1 / 100))) goodCert
        `shouldBe` Right weight
      verifyPerasCert (mkContext (PerasQuorumThreshold (unVoteWeight weight) (1 / 1000))) goodCert
        `shouldBe` Left (PerasCertQuorumNotReached weight)
    it "rejects a certificate below quorum" $ do
      let cert = forgeTestCert (take 1 testPools) goodRound testBlock
      case verifyPerasCert testContext cert of
        Left (PerasCertQuorumNotReached w) -> w `shouldSatisfy` (< VoteWeight (3 / 4))
        other -> expectationFailure ("expected quorum not reached, got: " <> show other)
    it "rejects a certificate with a wrong round" $
      shouldBeCommitteeError $
        verifyPerasCert testContext goodCert{pcRoundNo = goodRound + 1}
    it "rejects a certificate with a wrong boosted block" $
      shouldBeCommitteeError $
        verifyPerasCert testContext goodCert{pcBoostedBlock = mkBlock 0xbb}
    it "rejects a certificate with a voter removed" $
      shouldBeCommitteeError $
        verifyPerasCert testContext (modifyVoters (drop 1) goodCert)
    it "rejects a certificate with an extra voter" $ do
      -- forge without the largest pool, then claim it voted
      let partial = forgeTestCert (drop 1 testPools) goodRound testBlock
          full = NonEmpty.toList (perasCertVotersToSeats (pcVoters goodCert))
      shouldBeCommitteeError $
        verifyPerasCert testContext (modifyVoters (const full) partial)
    it "rejects a certificate with a wrong signature" $ do
      let other = forgeTestCert testPools goodRound (mkBlock 0xcc)
      shouldBeCommitteeError $
        verifyPerasCert testContext goodCert{pcSignature = pcSignature other}
    it "rejects a certificate with a wrong VRF output" $ do
      let swapVRF (seat, Just _) =
            let pool = seatPools Map.! seat
                vrfOutput =
                  either error id $
                    evalVRF
                      (VRFSignContext (getVRFSigningKey (Proxy @PerasBLSCrypto) (tpPrivateKey pool)))
                      (mkVRFElectionInput @PerasBLSCrypto testNonce (goodRound + 1))
             in (seat, Just (PerasVRFOutput (BLS.rawSignature (unPerasBLSCryptoVRFOutput vrfOutput))))
          swapVRF v = v
          swapFirst (v@(_, Nothing) : vs) = v : swapFirst vs
          swapFirst (v : vs) = swapVRF v : vs
          swapFirst [] = []
      shouldBeCommitteeError $
        verifyPerasCert testContext (modifyVoters swapFirst goodCert)
    it "rejects a certificate whose context has a different nonce" $
      verifyPerasCert
        ( either (error . show) id $
            mkPerasCertValidationContext NeutralNonce testStakeDistr testTargetCommitteeSize consensusQuorum
        )
        goodCert
        `shouldSatisfy` isLeft
