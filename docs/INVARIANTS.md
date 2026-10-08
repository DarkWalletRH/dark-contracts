# Invariants I1–I15 (DARK-CB-1 §15)

One Handler-based stateful suite, `fail_on_revert = true`, in
`contracts/test/invariant/DarkVault.invariant.t.sol` with the handler in
`contracts/test/invariant/DarkVaultHandler.sol`.

```sh
cd contracts && npm ci    # forge-std and OpenZeppelin come from npm
forge test --match-path "test/invariant/*" -vv
```

Run settings (`[invariant]` in `contracts/foundry.toml`): `runs = 32`, `depth = 32`,
`fail_on_revert = true`. Three registered actors; seven handler actions (`deposit`,
`transferAction`, `applyPendingAction`, `withdrawAction`, `togglePause`, `capsChurn`,
`illegalCall`).

*Implementation note (2026-10-07):* at v1.0.3 the suite has 14 invariant functions (I3 and I4
share one), and all 14 pass: 32 runs and 1,024 handler calls each, 0 reverts.

## The ghost oracle

The handler holds a plaintext model of the confidential state for each actor: the secret `sk`, the
balance `bal`, the accumulated blinding `rho`, the pending balance and its blinding, the nonce, the
pending count and `netInflow`. It reproduces the on-chain ciphertexts exactly:

```
available.C == encG(bal  + h*rho)     available.D == encG(rho  * sk)
pending.C   == encG(pbal + h*prho)    pending.D   == encG(prho * sk)
```

`encG(k)` is `k*G` for `k >= 0` and `-(|k|*G)` otherwise (blinding sums go negative after a
transfer), and `h = 7` is a **test-only** discrete log of the second generator, so the oracle can
compute `rho*H` with the vault's own fixed-base `mulG`. This is sound for the vault because the
vault never touches `H`: it only adds and subtracts supplied points and `mulG(amount)` of a public
amount. Real `H` (§3, hash-to-curve, unknown dlog) matters to the circuits and the SDK, not here.

**"Decryption" is re-encryption.** I2 does not run a discrete log: the oracle encrypts its own
plaintext model and compares group elements with storage. Equal ciphertexts and a known plaintext
are the same statement as a successful decryption, and it costs no BSGS.

**The verifier is the oracle.** Before every proof-bearing call the handler derives the full
public-input array from its model (nonce and `available` from the ghost, keys from the registry,
caps from config) and arms `DarkTestVerifier` (`contracts/test/mocks/DarkTestVerifier.sol`) with
its hash. The vault's own array — built from storage, registry and config — must match or `verify`
returns false and the call reverts `InvalidProof`. The handler **catches** that revert rather than
letting `fail_on_revert` abort the run, counting it in `bindingFailures`, so a mismatch surfaces as
a named I13 failure instead of an opaque "call reverted". That is I13, and it is what kills
mutations M2 and M3 (§16: the recipient's key, or the sender's `available`, taken from calldata
instead of the registry or storage).

**Anti-vacuity.** The first handler call of every sequence runs a real deposit, transfer,
`applyPending`, withdraw and one rejected illegal call, so no run can pass on an empty vault;
`afterInvariant()` asserts all five counters are non-zero, plus the isolation, event and
public-input check counters.

## The table

| # | What it means | Where it is proved |
|---|---|---|
| I1 | Solvency: `USDG.balanceOf(vault) >= tvl`, and `tvl == Σ deposits − Σ withdrawals` | `invariant_I1_solvency`; ghost flow counters in the handler |
| I2 | Encrypted conservation: every stored ciphertext decrypts to the ghost plaintext and the plaintexts sum to `tvl` | `invariant_I2_encryptedConservation` |
| I3 | `available[A]` changes only in a tx whose `msg.sender == A` | `DarkVaultHandler._onlyChanged` after every action (snapshot of all actors before the call), counted by `isolationChecks` |
| I4 | `pending[A]` changes only by a transfer to A or A's own `applyPending`; `pendingCount[A]` counts the transfers since the last apply | `_onlyChanged` (pending half) + `invariant_I3_I4_isolationAndPendingCount` |
| I5 | `nonce[A]` increases by exactly 1 per owner action, never otherwise | `invariant_I5_nonceIsOwnerActionCount` (ghost counts the actions) |
| I6 | Deposit ∈ [`minDeposit`, `maxDeposit`]; `netInflow <= maxAccountInflow` and `tvl <= tvlCap` after every deposit; transfer amount ∈ [`minTransfer`, `maxTransfer`]; `tvl <= HARD_MAX_TVL` always | per-action asserts in `deposit`/`transferAction`; `invariant_I6_caps` for the always-true half (see note 1) |
| I7 | Exit liveness: paused and with every cap tightened to its most restrictive value, every account with a balance can `applyPending` then `withdraw` all of it | `invariant_I7_exitLiveness` (snapshot → pause → `tightenCaps` to the floor → drain → revert) |
| I8 | Pause blocks `deposit` and `transfer` only; `withdraw`, `applyPending` and `register` never revert for pause | `invariant_I8_pauseScope` (+ withdraw-while-paused inside I7) |
| I9 | The guardian never loosens a cap; `setCaps` never exceeds a hard ceiling; only the owner unpauses; `renounceOwnership` reverts | `invariant_I9_adminPowers`; `capsChurn` exercises both roles for real (see note 3) |
| I10 | No path other than `withdraw` lowers the vault's USDG balance; `recoverERC20(usdg, …)` always reverts | `invariant_I10_onlyWithdrawLowersBalance` |
| I11 | Registry keys are immutable once set, one per address, canonical, on-curve, not identity | `invariant_I11_registryKeys` |
| I12 | Every stored vault point is canonical and either on-curve or the `(0,0)` sentinel | `invariant_I12_storedPointsValid` |
| I13 | Public-input binding: every public input except `ct`/`amount` equals the pre-call storage, registry or config value | enforced in-run by the armed verifier; `invariant_I13_publicInputBinding` asserts `bindingFailures == 0`, `bindingsConsumed == transfers + withdrawals`, arms == consumed + failures, and no expectation left unconsumed (see note 2) |
| I14 | Event truthfulness: every event field equals the post-state | `_checkDepositEvent` / `_checkWithdrawEvent` / `_checkApplyEvent` / `_checkTransferEvent` decode the real log after every action; `invariant_I14_eventTruth` asserts one checked event per state change (see note 4) |
| I15 | Every revert has a legal cause | `illegalCall` probes `NotRegistered`, `AmountZero`, `ZeroAddress`, `BadRecipient`, `PendingChanged`, `SelfTransfer`/`EnforcedPause` and asserts the exact selector; `invariant_I15_revertsHaveLegalCause` asserts attempts == rejections. Everything else in the run must succeed (`fail_on_revert = true`) |

## Implementation notes (2026-10-07)

Where a note says that a test does or does not fail, that was checked against v1.0.3 by deleting
the named check from a scratch copy of `contracts/src/DarkVault.sol` and re-running the tests. The
deployed code performs every check named here: these are limits of the tests, not defects in the
contracts.

1. **Caps, keys and points: the suite checks state, not rejection** (I6, I11, I12). Apart from the
   I15 probes and the targeted probes inside the I8–I11 invariant functions, the handler only makes
   legal calls. It bounds every deposit and transfer amount into the current caps (and every
   withdrawal into the ghost balance) and builds every ciphertext from valid points. For caps, keys
   and points the suite therefore shows that the invariants hold along legal histories, not that
   the vault *rejects* illegal input. The per-action I6 asserts check amounts the handler bounded
   itself and cannot fail because the vault skipped a cap check (the one assert that reads vault
   state, `vault.tvl() <= tvlCap`, can only fail on a tvl-accounting defect, which I1 also
   catches): with all four deposit cap checks deleted, the
   invariant suite still passes, while `test_depositRevertsBelowMin`, `test_depositRevertsAboveMax`,
   `test_depositRevertsInflowCap`, `test_depositRevertsTvlCap` (`contracts/test/DarkVault.t.sol`)
   and `test_depositExactlyAtEveryCapSucceeds` (`contracts/test/DarkVaultCapBoundaries.t.sol`)
   fail. Bad keys and bad points are rejected in `test_rejectsIdentityOffCurveAndNonCanonical`
   (`contracts/test/DarkKeyRegistry.t.sol`) and `test_transferRejectsBadPoints`
   (`contracts/test/DarkVault.t.sol`); I11 and I12 check the stored state. Transfer amounts are hidden from the vault: their bounds are enforced by the
   transfer circuit, against the `minTransfer`/`maxTransfer` that `DarkVault._transferInputs`
   passes from config as its last two public inputs, which I13 binds.
2. **I13: only `bindingFailures == 0` can fail on a vault defect.** `verify` is `view`, so the mock
   cannot record that it was called. The handler increments `bindingsConsumed` itself when the
   call succeeds and clears each expectation itself, so the other three assertions hold by
   construction. A vault that never calls its verifiers therefore passes this suite: with both
   `verify` calls deleted, all 14 invariants still pass. That defect is caught by
   `test_transferHappyPathEventAndBinding` and `test_withdrawHappyPathEventAndBinding`
   (`vm.expectCall` with the exact public-input array), and by
   `test_transferRevertsBadProofAndWhenPaused` and `test_withdrawRevertPaths` (`InvalidProof` when
   the verifier returns false), all in `contracts/test/DarkVault.t.sol`. M2 and M3 are killed by
   this suite on their own: M2 fails I13, and M3 fails I13 and the anti-vacuity check. The handler
   counts any revert of a proof-bearing call as a binding failure, not only `InvalidProof`. Public
   inputs 0–3 (chain id, vault, `msg.sender`, `to`) come from the execution context and the call's
   own `to` argument rather than from storage; the handler arms them with the same values.
3. **I9 is tested for some cap fields only.** The in-run probe tries to loosen only `maxDeposit`.
   The `capsChurn` asserts check four fields after a guardian write, but the handler only ever asks
   for tighter caps. The unit tests cover loosening `maxDeposit`, `minDeposit` and `minTransfer`,
   and exceeding the `maxDeposit` and `tvlCap` ceilings (plus `minTransfer = 0`).
   `test_tightenCapsComparesAllSixFields` exercises the two min fields only, despite its name. No
   test fails if `tightenCaps` stops comparing `maxAccountInflow`, `maxTransfer` or `tvlCap`, or if
   `_checkCeilings` (used by `setCaps` and the constructor) stops enforcing the `maxAccountInflow`
   or `maxTransfer` ceiling. Each of those five deletions leaves the full contracts suite (69 tests)
   passing.
4. **I14: the transfer event is compared in part.** `_checkTransferEvent` compares every post-state
   field of `ConfidentialTransfer`. Of the echoed ciphertext it compares only `c.x` and
   `dRecipient.x`, and it does not compare the two hint blobs. The whole event, data included, is
   checked by `vm.expectEmit` in `test_transferHappyPathEventAndBinding`. The handler decodes no
   admin events; `CapsUpdated` and `GuardianUpdated` are checked in `test_tightenCapsOnlyTightens`
   and `test_setGuardian`.

## What is NOT proved here, and why

- **Soundness of the statements themselves.** The mock verifier accepts what the oracle says is
  true. That a *real* proof exists only for a true statement is a circuit property (the circuit
  properties listed at the end of §15) and belongs to the nargo tests and
  `circuits/evm/test/Verifiers.t.sol`. A `contracts/test/realproofs/` suite, driving real proofs
  through `DarkVault`, was planned and never built. Nothing here can substitute for it.
- **Anything needing a real `H`.** The ghost's `H = 7*G` makes the algebra checkable on-chain. A
  test that depends on `H`'s dlog being unknown (e.g. binding of the Pedersen commitment) cannot be
  written this way and is a circuit or SDK (`DarkWalletRH/dark-sdk`) test.
- **I13 for the register circuit.** `DarkKeyRegistry.register` is covered by a unit test with
  `vm.expectCall` (`test_registerHappyPathAndBinding` in `contracts/test/DarkKeyRegistry.t.sol`),
  not by the handler: registration happens once per actor in `setUp`.
- **Real-proof gas and verifier codehash** (§18.9) — not invariants. The verifier codehash pin is
  a deploy-time check; real-proof `verify` gas is only measured, by
  `circuits/evm/test/Verifiers.t.sol`, and no deploy script checks it. The wiring half of M17 is
  covered by `contracts/test/DeployDarkTestnet.t.sol`.

  *Implementation note (2026-10-07):* §16 now lists the deploy-script codehash check as M17's only
  killer, since the real-proof suite does not exist. `test_scriptWiresEachVerifierToItsOwnSlot` in
  `contracts/test/DeployDarkTestnet.t.sol` covers the wiring and the deploy script's address and
  codehash pins (mutations M17, M17b and M17c). `contracts/test/DeployDarkMainnet.t.sol` covers the
  mainnet script (`test_wiresRolesCapsAndVerifiers`, `test_refusesAnUnpinnedVerifier`). Real-proof
  `verify` gas is measured by `circuits/evm/test/Verifiers.t.sol`. CI ties the pinned verifiers to
  the circuits (`scripts/check-verifier-pins.mjs`) and rebuilds the deployed bytecode from source
  (`scripts/check-verifier-bytecode.mjs`).
