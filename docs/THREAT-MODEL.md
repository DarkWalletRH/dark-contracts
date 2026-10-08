# Threat model — contracts (DARK-CB-1 §17, contract-side)

§17 of the DARK-CB-1 specification covers the whole product. This file keeps the rows that touch
`contracts/` and says, for each, what in `contracts/` mitigates it and what is accepted before the
external audit. The spec is normative; where this file and §17 disagree, §17 wins.

Every row was re-checked on 2026-10-07 against `contracts/src`, the tests and the live mainnet
deployment. Where the original text no longer matches the code it is kept as written and marked,
and the correction is in [Implementation notes](#implementation-notes-2026-10-07). Paths are
relative to the repository root. I1–I15 are the invariants in [INVARIANTS.md](INVARIANTS.md); M
numbers are the mutations in [MUTATIONS.md](MUTATIONS.md); §n is a section of DARK-CB-1.

**Assets in scope here:** the USDG backing in `DarkVault`; the confidentiality of balances and
transfer amounts as far as the contracts can affect it; exit availability. User keys, disclosure
contents and server metadata belong to the SDK and server rows of §17 and are only referenced.

## Actors

| Actor | Capability | Worst case | Mitigation in `contracts/` | Pre-audit status |
|---|---|---|---|---|
| Malicious user or attacker | Crafts proofs and calldata; exploits a circuit, verifier or `DarkGrumpkin` soundness bug | Mints encrypted value and withdraws others' backing, **up to the TVL**. Invisible until exit: I1 still holds, and the last honest withdrawers revert on the `tvl` underflow | On-chain caps (`tvlCap` is the loss bound); every user-supplied point is canonical, on-curve and non-identity (`_requirePoint`, I12); every public input except `ct`/`amount` comes from storage, the registry or config (I13; *see note 2*); `DarkGrumpkin` is differentially fuzzed against `@noble/curves` over 500 cases including identity, doubling and P + (−P) (M28a–M28c; *see note 3*); invariants I1–I15; the [mutation kill report](MUTATIONS.md) | **Accepted, bounded by `tvlCap` ($50k at launch: a team decision, above the §5 beta column's $25k; *see note 1*)** |
| Malicious sender | Pollutes a recipient's pending; dust spam; lying hints | Recipient freeze if `D_r` were unconstrained | `D_r` is constrained in-circuit (M19; the constraint is pinned by the circuit negative tests `test_neg_ct_dr_x`, `test_neg_ct_dr_y` and `test_neg_mismatched_recipient_handle` in `circuits/transfer/src/main.nr`. No harness runs circuit mutations; M19 was killed by those three tests in the one-off manual run recorded in [MUTATIONS.md](MUTATIONS.md)); the pending/available split means a polluted pending never blocks `withdraw` of `available`; `minTransfer` (stored on-chain, enforced in the transfer circuit against public input 19); `applyPending(expectedPendingCount)` makes a racing transfer a clean `PendingChanged` retry, not a loss (*superseded: a racing transfer is now folded in, see note 4*) | mitigated |
| Front-runner / MEV | Copies or reorders txs | Invalidated proofs; a stolen registration | Sender identity is `msg.sender` everywhere (M1, I3); public inputs are storage-bound including the nonce, so a copied proof is dead (I13); registration is one-key-per-address and irreversible (I11) | mitigated |
| Chain observer | Reads everything public | Graph, timing and amount correlation (§2) | Nothing at the contract layer: deposit and withdraw amounts are public by design (*see note 5*) | accepted by design |
| Guardian key (compromised) | `pause`, `tightenCaps` | Blocks `deposit` and `transfer` | `withdraw` and `applyPending` have no `whenNotPaused` and no adjustable cap (I7, I8, M5, M6); `tightenCaps` can only tighten (I9, M11); the owner can replace the guardian through the timelock (*see note 6*) | accepted |
| Owner Safe / `DarkTimelock` (compromised) | `setCaps` after 48 h; `setGuardian`; `unpause`; `recoverERC20` (*note 6 adds two powers this list omits*) | Raises caps ahead of an exploit | Hard ceilings are immutable constants (`_checkCeilings`, I6, I9); `recoverERC20` can never move USDG (I10, M15); `renounceOwnership` reverts (I9, M16); no verifier, registry or token setter exists at all; no proxy, no `delegatecall`, no `selfdestruct` | accepted |
| Chain operator (Robinhood) | Filters txs, upgrades with no delay, centralized sequencer | Censors withdraws; changes the rules | Nothing at the app layer | **accepted, disclosed** |
| USDG issuer | May freeze the vault address | All accounts frozen | Nothing at the app layer; the balance-delta guard (M9) at least makes a fee-on-transfer or rebasing variant fail loudly instead of silently mis-accounting (*rebasing only partly: see note 7*) | **accepted, disclosed** |
| Malicious or upgraded USDG (token hook) | Re-enters a vault function during `safeTransferFrom` | Double-credit, or a deposit credited without funds | All four account functions share one `nonReentrant` guard, so the interaction-first deposit cannot re-enter any of them; the balance-delta guard rejects a transfer that did not move exactly `amount` (*see note 7*) | mitigated |
| Device thief / malware | Steals `sk` and therefore `s` | Total loss for that account | Out of scope for the contracts: a valid proof from a stolen key is indistinguishable from the owner's | residual risk accepted (SDK row) |
| Supply chain (verifier artifacts) | Swaps the generated verifier or one of its libraries | Accepted proofs that prove nothing | Verifier addresses are constructor-immutable and distinct (constructor asserts); the runtime codehash check lives in the deploy script and the team's off-chain monitor (§19: the generated verifier is three contracts, `HonkVerifier`, `RelationsLib` and `ZKTranscriptLib`, and the check covers all three); `contracts/test/DeployDarkTestnet.t.sol` pins the wiring so the two verifiers can never be swapped (M17) (*see note 8*) | mitigated; the codehash file itself was still a follow-up when this row was written (*done since, see note 8*) |

## Where each mitigation lives

Test files are in `contracts/test/` unless a path is given. `invariant_*` functions are in
`contracts/test/invariant/DarkVault.invariant.t.sol`, with the handler in
`contracts/test/invariant/DarkVaultHandler.sol`.

| Mitigation | Code | Tests and mutations |
|---|---|---|
| Caps and hard ceilings | `DarkVault.deposit` (cap checks), `_checkCeilings`, the `HARD_MAX_*` constants | `DarkVault.t.sol`: `test_depositRevertsBelowMin`, `test_depositRevertsAboveMax`, `test_depositRevertsInflowCap`, `test_depositRevertsTvlCap`, `test_setCapsOnlyOwnerAndCeilings`, `test_constructorRejectsBadWiring` · `DarkVaultCapBoundaries.t.sol`: `test_depositExactlyAtEveryCapSucceeds` · `invariant_I6_caps` · M10a, M10b, M30, M36 (`_checkCeilings` is tested for the `maxDeposit` and `tvlCap` ceilings only; see [INVARIANTS.md](INVARIANTS.md) note 3) |
| Point validation | `DarkVault._requirePoint` → `DarkGrumpkin.isOnCurve` (both coordinates below the field modulus, on the curve; `(0,0)` fails); the same check in `DarkKeyRegistry.register` | `DarkVault.t.sol`: `test_transferRejectsBadPoints` · `DarkKeyRegistry.t.sol`: `test_rejectsIdentityOffCurveAndNonCanonical` · `DarkGrumpkin.t.sol`: `test_generatorOnCurve`, `test_nonCanonicalRejected`, `test_nonCanonicalInputsRejected` · `invariant_I11_registryKeys`, `invariant_I12_storedPointsValid` · M12, M13 |
| Public-input binding | `DarkVault._transferInputs` (21 inputs), `DarkVault._withdrawInputs` (12), the array in `DarkKeyRegistry.register` (5) | `DarkVault.t.sol`: `test_transferHappyPathEventAndBinding`, `test_withdrawHappyPathEventAndBinding` (`vm.expectCall` on the exact array) · `DarkKeyRegistry.t.sol`: `test_registerHappyPathAndBinding` · `invariant_I13_publicInputBinding` · M2, M3 · with real proofs, `circuits/evm/test/Verifiers.t.sol`: `test_RegisterRejectsEveryFlippedInput`, `test_TransferRejectsEveryFlippedInput`, `test_WithdrawRejectsEveryFlippedInput`, `test_ProofsAreNotInterchangeable` |
| `msg.sender` is the account; nonce | Every account function acts on `msg.sender`'s account; the nonce is public input index 4 (`pi[4]`, the fifth element) of transfer and withdraw | `invariant_I3_I4_isolationAndPendingCount` (backed by the handler's per-call `_onlyChanged` check), `invariant_I5_nonceIsOwnerActionCount` · M1, M1b, M4a–M4d |
| Curve arithmetic | `contracts/src/libraries/DarkGrumpkin.sol` | `DarkGrumpkin.t.sol`: `test_differentialAgainstNoble` (driving `contracts/test/js/diff_grumpkin.mjs` through `vm.ffi`), `test_identityAndNegation`, `test_homomorphism`, `test_mulGRejectsOversizedScalar` · M28a–M28c |
| Exit under pause and tightened caps | `withdraw` and `applyPending` carry `nonReentrant` only; `DarkKeyRegistry.register` has no pause at all | `DarkVault.t.sol`: `test_withdrawWorksWhilePausedAndWithCapsAtZero`, `test_applyPendingWorksWhilePaused` · `DarkKeyRegistry.t.sol`: `test_registerIsNeverPausable` · `invariant_I7_exitLiveness`, `invariant_I8_pauseScope` · M5, M6 |
| `tvl` underflow on over-withdrawal | `withdraw` (`_tvl - amount`, checked arithmetic) | `DarkVault.t.sol`: `test_withdrawMoreThanTvlReverts` · `invariant_I1_solvency`, `invariant_I2_encryptedConservation` · M29 |
| Pending/available split; `applyPending` bound | `transfer` writes only the recipient's `pending` and `pendingCount`; `applyPending` | `DarkVault.t.sol`: `test_transferHappyPathEventAndBinding` (recipient's nonce untouched), `test_applyPendingFoldsInLateArrivals`, `test_applyPendingWrongCountReverts` · M8, M14, M14b, M31, M32 |
| `D_r` and the transfer bounds, in-circuit | `circuits/transfer/src/main.nr` (`ct.D_recipient != r*pk_recipient`, `a < min_transfer`, `a > max_transfer`) | `nargo test`: `test_neg_ct_dr_x`, `test_neg_ct_dr_y`, `test_neg_mismatched_recipient_handle`, `test_neg_min_transfer`, `test_neg_max_transfer` · M19, M23 (listed as out of scope in MUTATIONS.md, run by no harness; killed in the one-off manual run recorded there) |
| Guardian powers | `pause`, `tightenCaps` (compares all six fields) | `DarkVault.t.sol`: `test_tightenCapsOnlyTightens`, `test_pauseRolesAndUnpauseOwnerOnly`, `test_setGuardian` · `DarkVaultCapBoundaries.t.sol`: `test_tightenCapsComparesAllSixFields` · `invariant_I9_adminPowers` · M11, M11b, M34 (the cited tests cover `maxDeposit`, `minDeposit` and `minTransfer` only; the `maxAccountInflow`, `maxTransfer` and `tvlCap` comparisons are untested, see [INVARIANTS.md](INVARIANTS.md) note 3) |
| Owner powers | `setCaps`, `setGuardian`, `unpause`, `recoverERC20`, the `renounceOwnership` override | `DarkVault.t.sol`: `test_setCapsOnlyOwnerAndCeilings`, `test_recoverERC20`, `test_renounceOwnershipDisabled` · `invariant_I9_adminPowers`, `invariant_I10_onlyWithdrawLowersBalance` · M15, M16 |
| Timelock and Safes at deploy | `contracts/script/DeployDarkMainnet.s.sol` | `DeployDarkMainnet.t.sol`: `test_wiresRolesCapsAndVerifiers` (48 h delay, owner Safe proposes and executes, launch caps), `test_refusesAnEoaAsASafe`, `test_refusesAOneKeyOwnerSafe`, `test_refusesATwoOfTwoOwnerSafe`, `test_refusesTheSameSafeForBothRoles`, `test_refusesWrongChain` |
| Token behaviour | The balance-delta guard in `deposit`; one `nonReentrant` guard shared by all four account functions | `DarkVault.t.sol`: `test_depositRevertsOnFeeOnTransferToken`, `test_tokenHookCannotReenterAnyAccountFunction` · M9, M39a–M39d |
| Verifier wiring and pins | `DarkVault` constructor (`verifiers equal`, `no code`); `_pin` in both deploy scripts; `contracts/deployments/verifier-codehashes.json` | `DeployDarkTestnet.t.sol`: `test_scriptWiresEachVerifierToItsOwnSlot`, `test_committedPinIsWellFormed` · `DeployDarkMainnet.t.sol`: `test_refusesAnUnpinnedVerifier`, `test_wiresRolesCapsAndVerifiers` · `DarkVault.t.sol`: `test_constructorRejectsBadWiring` · CI: `scripts/check-verifier-pins.mjs`, `scripts/check-verifier-bytecode.mjs` · M17, M17b, M17c |

## Accepted pre-audit risks (contract-side)

1. **No public audit of the Honk Solidity verifier.** Barretenberg audits so far cover bigfield
   (Zellic 2024, Veridise 2025). The vault treats `IDarkVerifier.verify` as a trusted oracle; if it
   is unsound, the "malicious user" row applies and the loss is bounded by `tvlCap`.
2. **Real proofs are not exercised by this suite.** Every invariant here runs against
   `DarkTestVerifier` driven by the ghost oracle. Circuit soundness rests on the circuit properties
   listed at the end of §15 (no valid witness with a negative remainder; changing any single public
   input rejects the proof; a DLEQ proof fails if any transcript element changes; stable
   key-derivation vectors) plus `circuits/evm/test/Verifiers.t.sol` (each verifier accepts the
   committed real proofs and rejects every flipped public input), both outside the contracts suite.
   The planned `contracts/test/realproofs/` suite, real proofs driven through `DarkVault`, was never
   built; only the live end-to-end runs on testnet 46630 have sent a real proof through the vault
   (*see note 9*).
3. **`DarkGrumpkin.mulG` is plain double-and-add**, not the §5 window table. Correctness is
   differentially fuzzed (*see note 3*); gas is higher than the window-table design would cost; the §9 figures are measurements of this version.
4. **No `DarkGrumpkinTables`, no `DarkPublicInputs` codegen.** The public-input order is duplicated
   between `DarkVault`, the SDK and the circuits by hand until the planned codegen lands; a drift
   between them is caught by no automated test (the planned `contracts/test/realproofs/` does not
   exist); only a live end-to-end run against the deployed vault would show it (*partly superseded:
   the circuits and the SDK are now checked against one file, the contracts are not; see note 10*).
5. **Sybil.** Per-account caps (`maxAccountInflow`) are sybil-able by design; the TVL cap is the
   real loss bound.
6. **`aeBalance` is opaque to the contract.** Only its length is checked (0 or 56). A client that
   seals garbage locks itself out of the fast path, never out of exit (§7 step 5 falls back to
   history replay and BSGS).
7. **Donations to the vault are invisible.** `tvl` counts deposits minus withdrawals only, so a
   direct USDG transfer to the vault is unrecoverable (`recoverERC20` refuses USDG). This is a
   deliberate trade for I10: no owner path may ever move USDG.

## Implementation notes (2026-10-07)

Added when this document was published. Each was checked against the contracts and tests in this
repository, and, where it says so, against Robinhood Chain mainnet (chain id 4663, on 2026-10-07) with read-only `cast` calls that anyone can repeat with the addresses in the README.

1. **Launch caps, on chain.** `DeployDarkMainnet.caps()` sets `minDeposit` 1, `maxDeposit` 1,000,
   `maxAccountInflow` 2,500, `minTransfer` 0.01, `maxTransfer` 1,000 and `tvlCap` 50,000 USDG, and
   `test_wiresRolesCapsAndVerifiers` pins those values. The mainnet vault's `caps()` returns exactly
   them, and its only `CapsUpdated` event is the constructor's: the caps have not changed since
   deployment. Whatever the owner sets later, `HARD_MAX_TVL` (250,000 USDG) caps `tvlCap`, and so
   the loss, for this vault. The other immutable ceilings are `HARD_MAX_DEPOSIT` and
   `HARD_MAX_TRANSFER` (2,500 USDG) and `HARD_MAX_ACCOUNT_INFLOW` (10,000 USDG).
2. **Which public inputs the caller chooses.** Besides `ct` (transfer) and `amount` (withdraw), the
   caller also chooses `to`, the transfer recipient or withdraw destination, which is calldata.
   Binding it is still what prevents redirection: the vault credits or pays exactly the `to` the
   proof was made for. `chainId` and the vault's address come from the execution environment
   (`block.chainid`, `address(this)`), and the sender is `msg.sender`. Everything else (the
   sender's nonce and `available`, the registry keys, `minTransfer` and `maxTransfer`) is read from
   storage, the registry or `_caps` at call time. In `DarkKeyRegistry.register` the key `P` is
   caller-supplied by design; the proof of knowledge binds it to `msg.sender`, the chain and the
   registry.
3. **The differential test is a fixed corpus.** `test_differentialAgainstNoble` checks `mulG`,
   `add`, `neg` and `sub` against `@noble/curves` on 500 cases: 12 fixed edge cases (identity,
   doubling, P + (−P), the ends of the 2⁴⁸ scalar range), then pseudo-random 48-bit scalars, every
   fifth reuses `k1` (a doubling, or P + (−P) when the index is also a multiple of seven) and every
   seventh negates the second operand. The seed is derived from `block.timestamp`,
   which a default `forge test` run does not vary, so every run checks the same 500 cases
   (verified: two runs passed the same seed to `contracts/test/js/diff_grumpkin.mjs`). It is a
   deterministic differential test, not fresh fuzzing on each run. Non-canonical encodings are
   covered separately by `test_nonCanonicalInputsRejected`.
4. **`applyPending` takes a lower bound, not an exact count.** Since the malicious-sender row was
   written, `expectedPendingCount` has become a lower bound (§5). `applyPending` reverts
   `PendingChanged` only when the account holds *fewer* pending transfers than the caller expected
   (a stale read). A transfer that lands between the caller's read and its transaction is folded in
   with the rest. A sender therefore cannot make `applyPending` revert by racing it, which an
   exact-count check allowed (mutation M14b reinstates that check and is killed). The `aeBalance`
   sealed in that call then under-reports by the late amount. The client detects this because it
   checks value·G = C − s·D before trusting `aeBalance`, and it recovers by replaying history.
   Tests: `test_applyPendingFoldsInLateArrivals`, `test_applyPendingWrongCountReverts`.
5. **What a chain observer learns from a deposit-only account.** `deposit` and `withdraw` change
   only `available.C`, by ±`mulG(amount)`, and never touch `available.D`. An account that has never
   sent a confidential transfer or applied a received one therefore stores `(balance·G, identity)`,
   and its exact balance is public (§2, "the deposit-only account").
6. **Admin roles as deployed, and two owner powers the rows omit.**
   - On mainnet, `owner()` is the `DarkTimelock` listed in the README. Its `getMinDelay()` is
     172,800 s (48 h). `PROPOSER_ROLE`, `EXECUTOR_ROLE` and `CANCELLER_ROLE` are held by a single
     owner Safe with a 2-of-3 threshold. `DEFAULT_ADMIN_ROLE` is held only by the timelock itself,
     so its roles can change only through the delay.
   - The guardian is a separate Safe with a 1-of-2 threshold. Either of its signers can pause and
     tighten caps alone, so the compromise of one guardian key is the case the guardian row assumes.
     Its two signers are also two of the owner Safe's three signers (compare `getOwners()` on both
     Safes), so the guardian and owner rows are not independent: compromising both guardian keys is
     a 2-of-3 owner compromise as well, delayed only by the timelock.
   - `contracts/script/DeployDarkMainnet.s.sol` refuses an EOA in either role, the same Safe in
     both, an owner Safe with a threshold below 2 or fewer than 3 owners, a USDG without code or
     without 6 decimals, and any chain but 4663.
   - The owner row omits two owner powers. The owner can also `pause` and `tightenCaps`, as the
     guardian can. It can also start an `Ownable2Step` ownership transfer. Like every owner call,
     that transfer must pass the 48 h delay. Once a new owner accepts it, that owner acts with no
     delay, still within the hard ceilings and still with no path to USDG.
   - On 2026-10-07 no ownership transfer was pending (`pendingOwner()` is zero) and the timelock
     had no scheduled operation (no `CallScheduled` event since deployment).
7. **USDG is upgradeable; what the balance-delta guard catches.**
   - The USDG the mainnet vault is bound to (`0x5fc5…d168`, asserted by the constructor on chain
     4663) is an EIP-1967 proxy with its implementation slot set, so its behaviour can change
     through an upgrade of the implementation. The vault's defences against that are local.
   - The `deposit` guard compares the vault's own USDG balance immediately before and after
     `safeTransferFrom`, and reverts `UnexpectedTransferAmount` unless it rose by exactly
     `amount`. That catches a fee-on-transfer change at deposit time
     (`test_depositRevertsOnFeeOnTransferToken`), and a rebase only if it happens inside that
     transfer.
   - The guard does not see a balance change between transactions. A negative rebase would leave
     the vault holding less than `tvl`, breaking I1 with no on-chain signal until the last
     withdrawals revert for lack of funds. A positive rebase becomes an unrecoverable donation
     (risk 7). The USDG-issuer row's "or rebasing" therefore holds only for the in-transfer case.
   - `withdraw` has no delta guard. A fee deducted from the transferred amount would cost the
     recipient, not the vault's accounting; a fee charged to the sender on top of `amount` would
     lower the vault's balance by more than `tvl` on every withdraw, breaking I1 silently until the
     last withdrawals fail, exactly as a negative rebase would.
   - The guard trusts USDG's own `balanceOf`. A USDG upgraded to lie about balances falls under the
     USDG-issuer row (accepted), not the token-hook row.
8. **Verifier pinning today, and its limits.**
   - The codehash file the supply-chain row calls a follow-up exists:
     `contracts/deployments/verifier-codehashes.json`. For each chain it pins the address and
     runtime codehash of the three verifiers, `RelationsLib`, `ZKTranscriptLib`, `DarkVault` and
     `DarkKeyRegistry`, and ties each verifier to its circuit through `verifierSolSha256`.
   - Both deploy scripts (`contracts/script/DeployDarkTestnet.s.sol` and
     `contracts/script/DeployDarkMainnet.s.sol`) check the pins before broadcasting. They refuse a
     verifier whose address is not the pinned one (`UnpinnedVerifier`), and any of the five
     verifier contracts whose live codehash differs from its pin (`VerifierCodehashMismatch`).
   - `test_scriptWiresEachVerifierToItsOwnSlot` covers a wrong address, a library swapped at its
     pinned address, and the happy path for all three verifier slots, not only the vault's two.
   - In CI, `scripts/check-verifier-pins.mjs` requires every pinned verifier to match
     `circuits/manifest.json`. `scripts/check-verifier-bytecode.mjs` rebuilds every pinned contract
     from source and requires its pinned codehash byte for byte. At deploy time,
     `scripts/record-deploy.mjs` reads the wiring back from chain.
   - On 2026-10-07 all seven mainnet codehashes in the pin file matched the chain
     (`cast codehash`). The vault's and the registry's verifier slots held the pinned addresses.
   - Limit: nothing in CI compares the pin file with the chain. That comparison happens at deploy
     time and in the off-chain monitor, and anyone can repeat it with `cast codehash`. The comment
     on `test_committedPinIsWellFormed` says the committed file "must match what is live on
     46630". The test itself checks one testnet address and that both library codehashes are
     non-zero, with no chain access.
   - Limit: the vault's constructor asserts only that the transfer and withdraw verifiers differ and
     have code, and `DarkKeyRegistry`'s constructor only that its verifier has code. The
     distinctness and identity of all three rest on the pins.
   - Limit: mutations M17–M17c run against `DeployDarkTestnet.s.sol` only. The mainnet script's
     wiring is covered by `test_wiresRolesCapsAndVerifiers` and `test_refusesAnUnpinnedVerifier`.
     It has no library-swap test of its own, though its `_pin` is the same code.
   - Caution: the same address can hold different contracts on the two chains. For example,
     `0xAf23…46Fe` is `DarkRegisterVerifier` on 4663 and `DarkTransferVerifier` on 46630. Always
     resolve an address together with its chain id, as the pin file and the deploy scripts do.
9. **Real proofs through a deployed vault.** The current testnet vault has processed real
   `transfer` and `withdraw` proofs. `circuits/VERSIONS.toml` records a gap that bears on exit.
   For a withdraw from a deposit-only account (`available.D` is the identity, see note 5), only
   nargo's solver has checked the witness (`test_accepts_a_withdraw_from_a_deposit_only_account`,
   `test_accepts_a_full_withdraw_from_a_deposit_only_account`); no bb proof has been produced. The
   live runs proved a deposit-only *transfer*, not a deposit-only withdraw. The committed
   `circuits/transfer/Prover.toml` and `circuits/withdraw/Prover.toml` both use a non-identity
   `avail_d`, so neither the manifest build nor
   `circuits/evm/test/Verifiers.t.sol` covers that case.
10. **Public-input order: what is checked now.**
    - `circuits/public_inputs.toml` now records each circuit's public-input order as data. CI
      (`circuits/tools/check-manifest.mjs`) asserts that every compiled circuit's public inputs
      match it, name for name and in order. The SDK's encoder (`src/publicInputs.ts` in the public
      `DarkWalletRH/dark-sdk` repository) is generated from it.
    - The contract side is still written by hand. Nothing automated compares
      `DarkVault._transferInputs`, `DarkVault._withdrawInputs` or the array in
      `DarkKeyRegistry.register` with that file.
    - `test_transferHappyPathEventAndBinding`, `test_withdrawHappyPathEventAndBinding` and
      `test_registerHappyPathAndBinding` pin each array with `vm.expectCall`, but against copies
      written into the tests. No test sends a real proof through `DarkVault`.
    - Compared by hand on 2026-10-07, the three contract arrays match the file entry for entry
      (5, 21 and 12 inputs). A later contract-side drift would still show only in a live
      end-to-end run.
