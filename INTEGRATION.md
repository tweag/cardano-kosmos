# Kosmos `integration` branch log

Local-only integration of the latest open Peras work on top of `origin/main` (149b82d).
Nothing is pushed. This file records each step, what it required, and any fix-ups.

Note: kosmos commit SHAs quoted below refer to the local pre-squash history. The pushed branch
`peras/integration` has one commit per step; the per-repo branches are pushed as
`peras/kosmos-integration` (cardano-base on gdeest/cardano-base, the others on the tweag forks).

## Phase 1: vendor cardano-base

- Branch `integration` created from `origin/main` @ 149b82d.
- `git subrepo clone --branch=45b2a01c… git@github.com:gdeest/cardano-base.git packages/cardano-base` → commit 24500b6.
  - 45b2a01 is the head of IntersectMBO/cardano-base#701, which contains #700.
  - Required: the remote is gdeest's fork because no tweag/cardano-base fork exists yet. Repoint `.gitrepo` if one is created.
  - Note: git-subrepo needs the full 40-char SHA for `--branch` (the remote refuses abbreviated or unknown refs).
- "Add cardano-base packages" → commit e40624e: 13 packages added to `cabal.project` (cardano-crypto-wallet left out).
- First solver run failed. `cardano-ledger-core` requires `cardano-crypto-leios ^>=0.3`, but #700 bumps it to **0.4.0.0**.
  - This is an actual API break, not just a bound: `BitField` now wraps `Data.Bitmap.Bitmap` instead of `ByteArray`.
  - `cardano-ledger-binary` pattern-matches on it in its `EncCBOR`/`DecCBOR` instances and uses `bitFieldBytes`.
  - **Required, ledger side:** new local branch `peras/kosmos-integration` in the worktree `~/code/cardano-ledger-kosmos-integration`, off the kosmos pin 0f1b372 (tweag/cardano-ledger).
    - Commit 121116c "Adapt BitField codecs to cardano-crypto-leios 0.4" (codecs, bounds `leios >=0.4` / `^>=0.4`, `strict-containers >=0.1.7`, changelog).
    - **Upstream follow-up:** IntersectMBO/cardano-ledger needs the same change when #700 lands.
  - Pulled into kosmos → commit 57d9d0a.
    - With `--force`, git-subrepo had written the local worktree path into `.gitrepo`.
    - Amended to the kosmos convention: tweag remote, SHA as branch.
    - **Required before pushing:** push 121116c to tweag/cardano-ledger.
- Consensus, node, api and cli have no upper bound on `cardano-crypto-leios`, and none of them uses `BitField` internals.
- Solver OK. Base tests pass for `cardano-crypto-peras` and `cardano-crypto-leios`. A third suite also ran; its result is still to be confirmed from its log.
- **BLOCKER: build fails.** `cardano-ledger-core:testlib` and `cardano-keys` (from CHaP, not vendored) use `minSigPoPDST`. The vendored `cardano-crypto-class` no longer exports it.
  - Cause: kosmos builds against CHaP's released `cardano-crypto-class-2.6.0.0` (cardano-base 12168e4, July).
  - Since then, cardano-base master has made breaking BLS API changes without bumping the version:
    - 3d5e2ba1 / 6e1696d7 / 08e36b0a: DST handled internally, `minSigPoPDST` removed from the API, `ContextDSIGN = ()`.
  - #700/#701 sit on that master, and master's `cardano-crypto-leios` (58f5a53a, a7d4b8f7) needs the new crypto-class.
  - So vendoring cardano-base master pulls in unreleased breaking changes that the kosmos ledger pin and CHaP's `cardano-keys` don't support.
  - `cardano-crypto-peras` (#701) itself makes no DSIGN calls in its library, so it should build against the released crypto-class.
  - Stopped here pending a decision.
- **Decision: forget Leios.** Vendor only the packages #700/#701 are about: `cardano-strict-containers` (Data.Bitmap) and `cardano-crypto-peras` (Peras base types). Everything else, leios included, stays on CHaP releases.
  - Dropped local commit 57d9d0a (the ledger pull). The ledger leios-0.4 fix is no longer needed. Its local branch `peras/kosmos-integration` in `~/code/cardano-ledger-kosmos-integration` (121116c) is kept but unused.
  - Amended the "Add cardano-base packages" commit into "Add cardano-strict-containers and cardano-crypto-peras packages".
  - Not integrated: #700's refactor of `cardano-crypto-leios` onto `Bitmap`. It doesn't change behaviour.
- Rebuild results:
  - Solver OK.
  - `cardano-strict-containers` builds and its tests pass (Bitmap properties).
  - The `cardano-crypto-peras` library builds against the released `cardano-crypto-class-2.6.0.0`.
  - Its **testlib and tests** fail: they pass `()` as the BLS sign context, which is master's API.
  - **Required:** in-tree fix in `cardano-crypto-peras` `testlib/.../Gen.hs` and `test/.../Peras.hs`. Use `minSigPoPDST` from `Cardano.Crypto.DSIGN.BLS12381` (3 `signDSIGN` and 2 `verifyDSIGN` call sites).
    - This is the same `BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_` DST that master now selects internally.
    - It is kosmos-only: upstream #701 targets master and stays as is.
  - Moved to a per-repo branch as decided: `~/code/cardano-base-kosmos-integration`, branch `peras/kosmos-integration` off 45b2a01, commit e767a98.
    - Pulled into kosmos → commit d31cb5d. `.gitrepo` remote kept on the gdeest fork, with the SHA as branch.
    - **Required before pushing:** push e767a98 somewhere reachable.
  - Tests: `cardano-strict-containers` and `cardano-crypto-peras` both PASS.
- `cabal build all` then failed in **cardano-ledger-shelley-test-1.10.0.0 from CHaP**. It doesn't match the vendored ledger API (`NewEpochState`, `LedgerState`), and consensus's `unstable-cardano-testlib` needs it.
  - Not related to cardano-base; it's presumably broken on kosmos `main` too.
  - **Required:** vendor it from the ledger tree by adding `packages/cardano-ledger/eras/shelley/test-suite` to `cabal.project`.
  - Other vendored packages still resolved from CHaP: byron-spec-chain/ledger, cardano-diffusion, network-mux, acts-generic, … Watch these if they cause similar skew.
- Commit e5fee76 "Add cardano-ledger-shelley-test package" fixed it.
- `cabal build all` now fails only in **tx-generator** (cardano-node bench).
  - Its `myCodecs` type has 2 too few codec arguments, because the-big-pr's `Codecs` grew Leios codecs.
  - This is node-vs-consensus skew already on `main` and unrelated to this work. The testnet doesn't use tx-generator.
  - Not fixed.
- Built: `cardano-node`, `cardano-cli` and `cardano-testnet`. **Phase 1 done.**
## Phase 2: cardano-ledger #6164

- Ledger branch `peras/kosmos-integration` (`~/code/cardano-ledger-kosmos-integration`) reset to the pin 0f1b372, dropping the unused leios fix.
  - #6164 (8379de0) is about 150 commits behind the pin, so its commits were **cherry-picked with `-x`** rather than merged:
    - 81eeb2d → 0348361 Add EncCBOR, DecCBOR and Arbitrary instances for PerasCert to cardano-ledger-binary
    - 38ed008 → c886532 Use PerasCert from cardano-crypto-peras in the Dijkstra block body
    - 60542fa → 59b984d Specify the Peras certificate in the Dijkstra CDDL
    - 766d2fe → 25ce7eb Document the Peras voters bitmap as MSB-first in the Dijkstra CDDL
    - e72d65e → 0a3da87 Use PerasVotersBitmap from cardano-crypto-peras in cardano-ledger-binary and the Dijkstra CDDL
    - ea012db → 9dae892 Use Data.Bitmap from cardano-strict-containers in the PerasVotersBitmap codecs and generators
  - All conflicts were import lists and `build-depends` lines; both sides were kept.
  - Skipped:
    - ce37a2a: pins cardano-base in ledger's own `cabal.project`, which kosmos doesn't use.
    - 9ccf53d: "proofs of possession take no signing context" needs cardano-base master's crypto-class, which we don't vendor. The ledger keeps using `minSigPoPDST`.
    - 8379de0: version bumps and changelog only. The pin is already at binary 1.10.2.0 and dijkstra 0.5.0.0.
- Pulled into kosmos → commit 53f8a3a.

## Phase 3: ouroboros-network #5431

- `~/code/ouroboros-network-kosmos-integration` (a clone of tweag/ouroboros-network), branch `peras/kosmos-integration` off the pin 2fb6982.
  - d0ff06e: `--no-ff` merge of #5431 (`object_diffusion/termination_and_caught-up` @ 4ebc795, 9 commits, 0 behind). No conflicts.
- Pulled into kosmos → commit 80df428.
- **Required:** #5431 also changes `cardano-diffusion` (`maxCertSize`/`maxVoteSize`, ObjectDiffusion codec bounds), which kosmos resolved from CHaP. Vendor it by adding `packages/ouroboros-network/cardano-diffusion` to `cabal.project`.

## Phase 4: ouroboros-consensus

- `~/code/consensus-kosmos-integration` (a worktree of consensus-bis), branch `peras/kosmos-integration` off `peras/the-big-pr` @ ae2c76e (the kosmos pin). First-parent history:
  - 5747649, 9fc82f9, 0d0f575: **kosmos in-tree consensus patches replayed as commits**, so the subrepo pull keeps them (#45 error-message space; #46/#53/#57 AdvertLog tracer; #25/#37/#57 ChainDB tracing). The tree was then byte-identical to the vendored one.
  - 9668f60 Merge #2461 (vote forging).
    - Conflict: #2461 deletes the env-reading key methods whose text kosmos #45 had touched. Took #2461's version.
  - 9d9f972 Merge #2444 (VR-2B bootstrap round). Clean.
  - 382c45b Merge #2453 (VR-1B fix):
    - View.hs: took the fix, replacing the-big-pr's `const True` workaround.
    - Query.hs: kept the-big-pr's resolver handle and passed `latestCertSeen` without `forgetBoostedBlockStatus`.
  - 8e26d40 Merge #2484 (perasBlockMaxSlots):
    - Kept HEAD's `VR2B PerasBootstrapAndRecoveryInteractionOutcome` and added `VR3`.
    - Added `perasBlockMaxSlots` to the-big-pr's `mkPerasParams` (= ceiling (k/f), env override `PERAS_BLOCK_MAX_SLOTS`) instead of the hard-coded defaults #2484 edited.
    - Threaded `blockMaxSlots` through Query.
    - **Silent merge bug fixed:** both sides added a `PerasParams` field, so the CBOR list length had to go from 10 to 11 (plus one more `fromCBOR`).
  - a337835 Merge tweag #36 (object diffusion progress; includes #2321, #2322, `gsm_caught_up` and #2326's commit):
    - Dropped both `WithBoostedBlockStatus` (removed by #2453) and `PerasCertTicketNo` (removed by #2326).
    - The CertDB GC uses #2326's `pcdsCerts` without the status update.
    - `Apps` gets both the Leios `bLF` parameter and `PerasSupport ->`.
  - 1844ecd Merge tweag #37 (GDD cert weight):
    - #37 independently adds the same `perasBlockMaxSlots`, marked "TODO: plug in the voting rules". Kept #2484's version and deduplicated the export.
    - **Known:** Genesis/Governor.hs calls `getPerasParams`, which doesn't exist on the-big-pr (#37's own TODO). Expected to need an adaptation commit.
  - 0b532ee: **port** of the only new content in #2321's latest commit (a1f0b5d) relative to the stack: Peras-specific byte limits (`byteLimitsPerasCertDiffusion`/`Vote`). Merging a1f0b5d directly gave 39 duplicate-content conflict hunks.
- Pulled into kosmos → commit 7fc7220.

## Phase 5: build fixes

- "Add cardano-diffusion package" → 927fc2b.
- Build: **cardano-ledger-binary** failed in `DecCBOR PerasVotersBitmap`.
  - #6164 was written against an earlier revision of #700, where `Bitmap` wrapped a `ByteString`. The final #700 wraps a `ByteArray`.
  - **Required, ledger branch:** commit 2f0fb1c "Adapt PerasVotersBitmap codecs to the ByteArray-based Data.Bitmap" (decoder, CDDL generator, TreeDiff). The wire format is unchanged.
  - **Upstream follow-up:** #6164 needs this when it is rebased on the final #700.
  - Re-pulled → 6d89e83.
- Next build (`--keep-going`), three errors:
  - **Ledger cddl library:** `Data.ByteString.Short` hidden. Added `bytestring` to the `cddl` library deps and amended it into the same ledger commit, now 8a8a8f9.
    - Note: kosmos 6d89e83 now refers to the superseded ledger SHA 2f0fb1c. To clean up later by squashing the kosmos pull commits.
  - **Consensus ObjectPool/PerasCert.hs:** the stack used main's `getPerasEpochContextResolver`. On the-big-pr, the resolver lives in the ledger's `PerasState` and the handle only exposes `resolveRoundNo`.
  - **Consensus Genesis/Governor.hs (#37):** used `Ouroboros.Consensus.Ledger.SupportsPeras.getPerasParams`, which doesn't exist on the-big-pr (#37's own TODO).
  - **Required:** consensus commit 470a311 "Adapt the object diffusion stack to the-big-pr's epoch context resolver":
    - Requestability reads the bounds from ChainDB's current ledger `PerasState`. The test pool writer treats every ID as requestable, since its mock handle resolves every round.
    - The GDD takes `perasBlockMaxSlots` from the immutable ledger's epoch context, **with 0 when Peras is not enabled there**.
    - Dropped the `LedgerStateSupportsPeras` constraints (Governor, PeerSimulator test).
    - **Worth reviewing by the #36/#37 authors.**
  - Re-pulled → 9caf941 (ledger), 7e2d430 (consensus).
- Two import fixes amended into the consensus adaptation commit (now 81353f2) → kosmos a213186.
- Build: the ouroboros-consensus main library now compiles. **`lib:cardano` fails** in `Shelley/Node/Peras.hs`.
  - Ledger #6164 makes `SL.PerasCert` the structured cardano-crypto-peras certificate (4 fields), where it used to be opaque bytes.
  - Consensus still bridges through CBOR bytes (`toOpaqueLedgerPerasCert` / `fromOpaqueLedgerPerasCert`).
  - This is the expected consensus-side adaptation to #6164.
- Found the user's prototype: `~/code/peras-mono/ouroboros-consensus`, branch `gdeest/peras-cert-from-base` (PR_CONSENSUS_DESCRIPTION.md).
  - The relevant commits are e07b571, 455848f, bc2c1e4, 8ca6ae6, 56bcf9d, 98ac820 and 3b64511. 9b13b41 is skipped: it needs master crypto-class.
  - They are based on a the-big-pr that is 160 commits older. Cherry-picking hit a large conflict in `Peras/Cert/V1.hs` (the-big-pr's evolved voters code vs the newtype rewrite).
  - The prototype also makes `PerasRoundNo` a `Word32`, which would ripple into the freshly merged Genesis and object-diffusion code.
  - **STOPPED** for a decision. The consensus branch was reset to 81353f2; the prototype branch is untouched.
- **Decision: port the prototype** onto the the-big-pr-based consensus branch. Cherry-picked with `-x`:
  - e07b571 Use the Peras base types from cardano-crypto-peras.
    - Conflicts in the cabal deps (kept both) and in Types.hs imports (union).
    - `PerasRoundNo` now comes from cardano-crypto-peras.
  - 455848f changelog.
  - bc2c1e4 Make V1.PerasCert a newtype over the cardano-crypto-peras certificate.
    - Took the prototype's version: the-big-pr's only change to V1.hs since the prototype's base was the cert-size upper bound, which the prototype supersedes. V1.hs is now byte-identical to bc2c1e4.
  - 8ca6ae6 changelog.
  - 56bcf9d Take PerasCert directly from the Dijkstra block body.
    - The prototype side re-introduced the env-var hacks (`PerasTemporaryPublicKeyHackError`, `readPerasPrivateKeyFromEnv`) that #2461 removed, so kept HEAD there.
    - Kept HEAD's imports plus `strictMaybeToMaybe`, and HEAD's cabal deps.
  - 98ac820 changelog.
  - 3b64511 Use PerasCertSize and perasCertSizeUpperBound from cardano-crypto-peras.
  - Skipped 9b13b41 (BLS signing context removal, needs master crypto-class) and 59669f5 (pins).
- Follow-up consensus fixes, each its own commit:
  - 5a50f32 Use Word32 for the Peras bootstrap round. It is a Word32 in both cardano-crypto-peras `PerasRoundNo` and the ledger `plvBootstrapRound`.
  - fa9f161 Adapt the Peras base types to the final cardano-base#700 and the-big-pr:
    - ByteArray-backed Bitmap in the voters CBOR instances, as on the ledger side.
    - Orphan `ToJSON PerasRoundNo`, needed by the object-diffusion state.
  - aedc1bd Compute the GDD virtual last Peras round in Word64 (Word32 rounds vs Word64 slots).
- **`cabal build all` now passes except `tx-generator`.** That's the pre-existing node-bench vs the-big-pr `Codecs` skew, already on main, and unrelated.
- Testnet, CI-style check (`setup-testnet-env.sh devnet-env` + `wait-until-peras.sh`): **PASS**. node3 logged `Peras.Vote.Remote.Send.Init` after about 30s.
- 8-minute testnet run: object diffusion runs, but **no votes are cast**. Every node logs `Peras.Vote.Forging.NoForgingCredentials`.
  - Cause: #2461 replaces env-var key reading with an updatable `PerasVoteForging` that the node must install via `setPerasVoteForging`, and the vendored cardano-node doesn't do this.
  - **Required:** Agustín's companion branch IntersectMBO/cardano-node `peras/vote-forging` (82ce1ce "Testnet integration fixes", 69abbd9 "WIP implementing PerasVoteForging integration"). It is directly on the kosmos node pin df5e84e.
    - Not taken: `peras/bls-key-plumbing`, a further WIP key-file exploration.

## Phase 6: cardano-node

- `~/code/cardano-node-kosmos-integration` (a worktree of `~/code/cardano-node`), branch `peras/kosmos-integration` off the pin df5e84e:
  - 4e489ab: **kosmos in-tree node patches replayed** (Tracers.hs, Runtime.hs; #46/#53/#57). Byte-identical to the vendored tree.
  - 059485a: `--no-ff` merge of `peras/vote-forging`.
    - The only conflicts were with 82ce1ce, which makes the same adaptations as the kosmos patches against older consensus/ledger. Kept the kosmos side (current ledger's `NewEpochState` field order; AdvertLog instead of the debug HTTP tracer).
    - The vote-forging wiring (Run.hs, Startup.hs, Peras/Trace.hs) merged cleanly.
- Pulled into kosmos → a760e38.
- 8-minute testnet rerun:
  - Vote forging is now installed (`Startup.PerasVoteForgingUpdate`) and the rules are evaluated every round.
  - But every decision is `NoVote` with `VR2B PerasBootstrapDisabledAndNoLatestCertOnChain`.
  - #2444 requires an explicit bootstrap round, and the generated `dijkstra-genesis.json` does set `"perasBootstrapRound": 0`.
- **Root cause (also on kosmos main): the node ignores the Dijkstra genesis file.**
  - `Cardano/Node/Protocol/Cardano.hs` hard-codes `dijkstraGenesis <- pure Dijkstra.emptyDijkstraGenesis`, with the real reading code commented out under `-- FIXME: uncomment`.
  - So **no Peras (or Leios) genesis protocol parameter reaches the ledger**: bootstrap round `SNothing`, cert boost 0, committee size 1, ….
  - Main hides this because the testnet overrides most Peras params through `PERAS_*` env vars. Only the bootstrap round, now required by #2444, exposed it.
  - **Required:** node commit 9abd9cc "Read the Dijkstra genesis file instead of a hard-coded empty one" (restores the commented code) → kosmos 3da47a5.
  - Relevant to M1.4 "on-chain parameters, end-to-end".
- With the genesis read, the nodes **failed to start**: "Number of parameters supplied 369 does not match the expected number of 251" (PlutusV4 cost model).
  - This is presumably why the reading had been commented out.
  - `cardano-cli create-testnet-data` writes the full PlutusV4 list. cardano-testnet's own `defaultDijkstraGenesis` already trims it, but that file is only an input.
  - **Required, kosmos:** commit 592ad47 "Trim the PlutusV4 cost model in the generated Dijkstra genesis" (`scripts/setup-testnet-env.sh`, `jq '.plutusV4CostModel |= .[:251]'`).
- Testnet rerun:
  - **The on-chain bootstrap round now works.** Decisions show `VR2B (PerasBootstrapEnabledAndNoLatestCertOnChain (PerasRoundNo 0))`, and nodes vote in rounds 5, 10, 15, … with VR-2A, VR-2B and VR3 true.
  - Votes are forged and added (`AddedPerasVoteButDidntGenerateNewCert`).
  - But only nodes 1–2 ever vote. **Nodes 4–8 never add a block** and node 3 stalls at slot 1233.
  - Root cause: 2,253 × `TrMuxErrored … NodeToClient.hs:(503,5)-(514,27): Non-exhaustive patterns in function namespaceFor`.
    - The node's ObjectDiffusion message tracer lacks the messages added by #5431 (`MsgAwaitReply`, `MsgServerIdle`).
    - Tracing them throws inside the mini-protocol thread, which kills the connection, so chain sync never completes on most nodes.
  - **Required, node:** commit a4daa04 "Trace the new ObjectDiffusion messages MsgAwaitReply and MsgServerIdle" → kosmos a773a3a.

## Result: Peras works end to end (10-minute vanilla scenario, 8 nodes)

Logs archived in `devnet-env.integration-run-20261109/`.

- **All 8 nodes sync**: 80–89 blocks added each, zero tracer crashes, all reach `Consensus.GSM.EnterCaughtUp`.
- **On-chain parameters**: the genesis `perasBootstrapRound = 0` reaches consensus. VR-2B reports `PerasBootstrapEnabledAndNoLatestCertOnChain (PerasRoundNo 0)`, and the first votes come in round 5 (cooldown K = 5).
- **Votes**: 35 forged, 439 added across nodes, so diffusion works.
- **Certificates**: formed for rounds **5, 10, 11 and 26**. Each was received by every node (24–30 `AddCert` per round), and there were 29 × `PerasCertBoostsCurrentChain`.
- **VR-1A/VR-1B path**: votes in rounds 11, 12 and 27 because the previous round's certificate arrived within the arrival threshold, e.g. `VR1A := PerasRoundNo 11 :==: PerasRoundNo 11 :/\: SlotNo 910 :<=: SlotNo 930`. Rounds 11 and 27 then produced certificates.
- **VR3** (#2484, candidate age) is true in all 44 positive vote decisions.
- **Certificate inclusion in blocks**: 5 × `IncludeCert`. Inclusion rules later report the latest certificate on chain as `At (PerasRoundNo 26)`.
- **New object-diffusion protocol** (#5431, #2321, #2322, tweag #36):
  - about 2,400 × `Peras.Vote.Remote.Send.AwaitReply` and 2,300 × `Peras.Cert.Remote.Send.AwaitReply`;
  - inbound `StartedIdling`/`StoppedIdling`;
  - 47 × `IgnorePerasCertTooOld`.

- The kosmos side and each repo get a `peras/kosmos-integration` branch carrying all of its fixes. Consensus will be based on `peras/the-big-pr`.
