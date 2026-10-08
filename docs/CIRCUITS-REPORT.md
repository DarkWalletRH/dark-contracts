# CIRCUITS-REPORT — the four DARK-CB-1 circuits, measured

Measured 2026-09-16 on an Apple M4 (10 threads), nargo 1.0.0-beta.22 + bb 5.0.0-nightly.20260522
(`circuits/VERSIONS.toml`), solc 0.8.30, `evm_version = cancun`, optimizer on / 200 runs.

> **Re-checked 2026-10-07** against this repository at tag v1.0.3, with the same nargo/bb pins,
> Foundry 1.5.1 and the same machine class. Every gate count, opcode count, public-input count,
> proof and VK size, verifier size, `verify()` gas and calldata figure below reproduced exactly, and
> `manifest.json` and the three generated `Verifier.sol` files rebuilt byte for byte. Prove times
> over three runs were 86–93, 120–161, 105–114 and 104–108 ms (register, transfer, withdraw,
> disclose_range), against 86, 118, 109 and 100 ms below. Where the 2026-09-16 text no longer matches
> the code or the spec as frozen, it is left as written and an *Implementation note* follows it.

Reproduce, from the repository root, with nargo and bb installed at the `circuits/VERSIONS.toml` pins
(the tools call `~/.nargo/bin/nargo` and `~/.bb/bb`) and Foundry on `PATH`. The first step installs
`@darkwalletrh/dark-sdk` from the public dark-sdk repository, at the tag `circuits/tools/package.json`
pins.

    npm --prefix circuits/tools ci
    cd circuits
    nargo test
    node tools/gen_prover.mjs && node tools/build.mjs && node tools/gen_fixtures.mjs
    forge test -vvvv | grep Measured
    npm --prefix tools run verify-manifest

> **Implementation note (2026-10-07):** `build.mjs` rewrites `manifest.json` and `verifiers/` from
> what it has just built, so the last step only proves something when it is followed by
> `git diff --exit-code -- manifest.json verifiers/`. CI instead runs `check-manifest.mjs` against the
> committed tree, before anything is rebuilt. `evm/test/Fixtures.sol` changes on every run because
> Honk proofs are randomised; the public inputs and every number below do not.

**Verdict: all four circuits meet §6 and §9 with room to spare.** The gate budget is the
loosest constraint in the spec — the largest circuit uses 12 % of it. Every §6 estimate was
pessimistic by 2–3×.

> **Implementation note (2026-10-07):** the §9 that this verdict and the table's "§9 estimate" row
> were checked against was a pre-measurement draft. On 2026-09-17 §9 was rewritten from transactions
> measured on testnet 46630, and whole transactions came in above those estimates: L2 execution is
> 3,751,806 gas for `transfer`, 3,653,555 for `withdraw` and about 3.44M for `register`, of which
> `verify()` (measured below, unchanged) is 61 %, 62 % and 64 %. Against the L2 gates §9 now sets
> (≤ 4.0M for `transfer` and `withdraw`, ≤ 3.7M for `register`) the headroom is about 6 %, 9 % and
> 7 %. "Room to spare" holds for the §6 gate budget, not for §9 gas.

## The measured table

| | `dark_register` | `dark_transfer` | `dark_withdraw` | `dark_disclose_range` |
|---|---|---|---|---|
| **Gates** (`bb gates` circuit_size) | **3,586** | **7,724** | **5,767** | **5,112** |
| §6 estimate | 4–6k (2¹³) | 18–30k (2¹⁵, worst 2¹⁶) | 9–14k (2¹⁴) | 9–14k (2¹⁴) |
| §6 budget ≤ 2¹⁶ = 65,536 | PASS (5.5 %) | PASS (11.8 %) | PASS (8.8 %) | PASS (7.8 %) |
| ACIR opcodes | 22 | 126 | 85 | 77 |
| **Public inputs (wire, §19 X2)** | **5** | **21** | **12** | **9** |
| §6 canonical count | 5 | 21 | 12 | 9 |
| VK `publicInputsSize` | 13 | 29 | 20 | 17 (derived) |
| Honk domain N / log N | 4096 / 12 | 8192 / 13 | 8192 / 13 | — |
| **Proof size** | 7,232 B | 7,616 B | 7,616 B | 7,616 B |
| VK size | 1,888 B | 1,888 B | 1,888 B | 1,888 B |
| **Prove time** (bb CLI, incl. VK computation) | 86 ms | 118 ms | 109 ms | 100 ms |
| `verify()` calldata | 7,524 B | 8,420 B | 8,132 B | n/a (off-chain) |
| **`verify()` gas** | **2,207,250** | **2,292,541** | **2,279,049** | n/a |
| §9 estimate for the whole tx | 2.3–2.6M | 2.6–3.0M | 2.5–2.9M | 0 |
| Verifier source | 102,143 B (2,465 lines) | 102,143 B | 102,143 B | not generated |

Wire public inputs + 8 = the VK's `publicInputsSize`, read off `NUMBER_OF_PUBLIC_INPUTS` in each
generated verifier (13, 29, 20): §19 X2 holds exactly, the 8 extra are the pairing-point limbs
that ride inside the proof. `dark_disclose_range` generates no verifier, so its 17 is the rule
applied rather than a reading.

> **Implementation note (2026-10-07):** it is now a reading as well. A throwaway verifier generated
> from `dark_disclose_range`'s VK (not committed) has `NUMBER_OF_PUBLIC_INPUTS = 17`, `N = 8192` and
> `LOG_N = 13`, which also fills the table's "—".

### Verifier bytecode (the §9 "96 KB" row)

§19 X4's three-contract shape is confirmed: each generated `Verifier.sol` deploys as
`HonkVerifier` plus two linked libraries. Runtime bytecode, identical for all three circuits to
within a byte:

| Contract | Runtime | EIP-170 margin |
|---|---|---|
| `HonkVerifier` | 17,829 B | 6,747 B |
| `RelationsLib` | 7,966 B | 16,610 B |
| `ZKTranscriptLib` | 6,151 B | 18,425 B |
| **one circuit's set** | **31,946 B** | |
| **all three on-chain circuits** | **95,838 B** | |

§9's "the verifiers (~33 KB) fit the 96 KB limit" is right per circuit (31.9 KB) and is almost
exactly the budget for all three together (93.6 KiB of 96 KiB). It is worth being precise about
what the number means: the binding limit is EIP-170's **24,576 B per contract**, which the
largest piece clears by 6.7 KB. Nothing needs splitting, but a future circuit that grows
`HonkVerifier` by 38 % hits EIP-170, not the 96 KB figure.

> **Implementation note (2026-10-07):** two corrections to this section.
>
> - *Deployed shape.* The libraries are not deployed per circuit. One `RelationsLib` and one
>   `ZKTranscriptLib` per chain are linked into all three verifiers (`scripts/lib/verifier-recipe.mjs`;
>   addresses and codehashes in `contracts/deployments/verifier-codehashes.json`). That is sound
>   because bb's library code is byte-identical across the three generated `Verifier.sol` files (they
>   differ only in the constants and verification key at the top) and the circuit-specific values
>   (VK hash, log N, public-input count) reach the libraries as call arguments. The deployed verifier code per
>   chain is therefore 3 × 17,829 + 7,966 + 6,151 = **67,604 B**, not the 95,838 B in the last row.
>   `scripts/check-verifier-bytecode.mjs` (CI) rebuilds all of it from source and requires every
>   pinned runtime codehash byte for byte. On 2026-10-07 it passed for all 14 pinned contracts on
>   4663 and 46630 (verifiers, libraries, vault and registry), and every pinned codehash equalled
>   `cast codehash` on the live chain.
> - *The 96 KB figure* comes from the same pre-measurement draft of §9; the current §9 does not cite
>   it. It is not an Ethereum-standard limit: those are 24,576 B of runtime code per contract
>   (EIP-170) and 49,152 B of initcode (EIP-3860). Every contract here clears both; the largest
>   initcode is `HonkVerifier`'s 18,156 B.

## What each circuit constrains, in English

### `dark_register` — 3,586 gates
*"I know the ElGamal secret behind this public key, and I am saying so on this chain, to this
registry, as this address."*

Checks `pk` is a real Grumpkin point and not the `(0,0)` identity, that the secret's limbs are
not both zero, and that `s · pk == H` — which is exactly `pk == s⁻¹ · H`, the §3 key relation.
`chain_id`, `registry` and `account` are carried as binding public inputs so the proof is worth
nothing on another chain, against another registry, or for another caller: that is what stops
key copying and front-run registration.

### `dark_transfer` — 7,724 gates
*"I own this balance, this ciphertext really encrypts an amount inside the caps, both handles
use the same randomness, and what is left over is still a valid balance."*

1. `pk_s` and `pk_r` are real points, not the identity; the stored `available` (C, D) is on the
   curve **or** the identity, because a never-funded account holds the identity.
2. `s · pk_s == H`: the prover owns the sender key.
3. `ct.C == a·G + r·H` with `a` a 48-bit amount — a well-formed twisted-ElGamal commitment.
4. `ct.D_sender == r · pk_s` and `ct.D_recipient == r · pk_r`, **the same r in both**. The
   recipient handle is the one that matters for other people: without it a sender could put
   garbage in someone else's `pending` and freeze it.
5. `r ≠ 0`, enforced as `ct.D_sender ≠ identity`. Checking the limbs is not enough — see the
   spec change below.
6. `min_transfer ≤ a ≤ max_transfer`, against the caps the vault passes in.
7. The solvency check: `(avail.C − ct.C) − s·(avail.D − ct.D_sender) == w·G` with `0 ≤ w < 2⁴⁸`.
   This is the whole overdraft defence. The subtraction is homomorphic, so `w` is the real
   remaining balance; forcing it into 48 bits is what stops an underflow wrapping into a huge
   fake balance. Spending everything gives `w = 0`, i.e. the identity, and that case is tested.
8. `chain_id`, `vault`, `sender`, `recipient`, `sender_nonce` bind the proof to one intent. The
   nonce is what makes a proof single-use, and `available` being in the statement is what makes
   it immune to front-running: only the owner can change its own `available`.

### `dark_withdraw` — 5,767 gates
*"I own this balance and it covers this public amount, which is going to this address."*

Same ownership and solvency shape as transfer, with the amount public instead of encrypted:
`(avail.C − amount·G) − s·avail.D == w·G`, `1 ≤ amount < 2⁴⁸`, `0 ≤ w < 2⁴⁸`. `to` is a binding
input, so a withdraw proof cannot be replayed to a different recipient. `pending` is never read,
which is why an incoming transfer cannot invalidate an in-flight withdraw.

> **Implementation note (2026-10-07):** `deposit` adds `x·G` to `available.C` and leaves
> `available.D` untouched, so an account that has only ever deposited holds `avail.D = (0,0)`. Its
> first withdraw feeds the identity into `s·avail.D` as a multi-scalar-multiplication operand, and its
> first transfer feeds it into `avail.D − ct.D_sender`. How far this case is covered is the second
> toolchain note under *Checks left behind*.

### `dark_disclose_range` — 5,112 gates (off-chain)
*"The value behind this ciphertext is between lo and hi, and I am the one who can read it."*

`s · pk == H`, `c − s·d == v·G`, and `lo ≤ v ≤ hi < 2⁴⁸`. Because `(c, d)` is just a ciphertext,
the same circuit covers "balance ≥ X" (hi saturated to 2⁴⁸−1), "balance ≤ X" (lo = 0),
"balance in [X, Y]", and flow totals over a sum ciphertext the viewer recomputes by adding the
published components. `context_hash` binds a disclosure to its link. Never deployed; verified in
the browser with bb.js.

## Checks left behind

- **`nargo test`, 70 tests.** Every public input that has an in-circuit relation gets a negative
  test (flip it, the circuit must fail), plus the private-witness attacks: overdraft, a
  mismatched recipient handle, `r = 0`, a zero secret, an off-curve or identity key, an amount at
  2⁴⁸, lying about the disclosed value.
- **`forge test`, 7 tests.** The generated verifiers verify the real proofs, and **every** public
  input is flipped one at a time and must be rejected — the only way to test `chain_id`, the
  contract address, the account and the nonce, which have no in-circuit relation to break. Also
  checks a transfer proof is not accepted by the withdraw verifier.
- **`tools/gen_prover.mjs`.** Witnesses come from `@darkwalletrh/dark-sdk`, not from hand-written
  vectors, so an SDK change that breaks the shared maths fails `nargo execute`. It refuses to run
  if `dark_lib`'s `H` is not the SDK's `H`.
- **`npm --prefix circuits/tools run verify-manifest`.** Recompiles, recomputes ACIR and VK
  hashes, gate counts and the public-input order against `manifest.json` and
  `public_inputs.toml`, and fails on drift. This is the check that catches a silent toolchain
  bump, which would otherwise ship verifiers that reject every proof.

> **Implementation note (2026-10-07): what has changed since.**
>
> - `nargo test` now runs **76** tests (`dark_lib` 11, register 8, transfer 26, withdraw 17,
>   disclose_range 14). The six added: `dark_register`'s `test_neg_s_plus_n`; `dark_transfer`'s
>   `test_accepts_a_transfer_from_a_deposit_only_account` and `test_neg_deposit_only_overdraft`;
>   `dark_withdraw`'s `test_accepts_a_withdraw_from_a_deposit_only_account`,
>   `test_accepts_a_full_withdraw_from_a_deposit_only_account` and `test_neg_deposit_only_overdraft`.
> - `dark_disclose_range` has no verifier, so its flip-every-public-input check is
>   `circuits/tools/flip-public-inputs.mjs`: it proves once with bb, then flips each of the 9 public
>   inputs and requires `bb verify` to reject every one. CI runs it.
> - `gen_prover.mjs` compares the `H` the SDK derives with a copy of `dark_lib`'s constant written
>   into the script, not with `circuits/lib/src/lib.nr` itself. A change to `lib.nr` alone is caught
>   by `check-manifest.mjs` (the ACIR hash moves) and by `nargo execute` on the SDK-made witnesses.
>   CI does not run `gen_prover.mjs` or `build.mjs`, so in this repository the SDK-to-circuit check
>   runs only when someone reproduces as above. Re-run on 2026-10-07 against dark-sdk v0.4.3: all
>   four committed `Prover.toml` files regenerated byte for byte.
> - What CI runs (`.github/workflows/ci.yml`): the circuits job runs `nargo test --workspace`,
>   `check-manifest.mjs`, `flip-public-inputs.mjs` and `forge test --root circuits`; the contracts
>   job, besides the contract tests, runs `scripts/check-verifier-pins.mjs` and
>   `scripts/check-verifier-bytecode.mjs`.

> **Implementation note (2026-10-07): two behaviours rest on the toolchain, not on constraints**
> (`circuits/VERSIONS.toml`, "what a toolchain bump must re-check"), so a clean `verify-manifest` is
> not enough to clear a nargo/bb upgrade.
>
> 1. *Non-canonical scalars.* The circuits' own 128-bit limb checks admit both `s` and `s + n`
>    (n < 2²⁵⁴). Two toolchain behaviours reject `s + n`, neither written in the circuit source:
>    nargo's witness solver refuses to solve the `multi_scalar_mul` opcode for a scalar ≥ n (the
>    "is not a valid grumpkin scalar" error that `test_neg_s_plus_n` pins), and the pinned bb
>    builds every ACIR MSM scalar with `cycle_scalar(lo, hi)`, whose constructor adds an in-circuit
>    check that lo + hi·2¹²⁸ < n (`validate_scalar_is_in_field`: a borrow subtraction under range
>    constraints). Checked 2026-10-07 on `dark_register` with s = 5: a witness built by hand with
>    the limbs of s + n (the solver's inverse witnesses recomputed) proves with bb, but `bb verify`
>    rejects it, while the honest witness verifies. Nothing false becomes provable either way,
>    because `s` and `s + n` give the same group elements. The guards that matter, against a zero
>    scalar, are constraints in the circuit source: `assert_key` (`s·P == H`) and
>    `ct.D_sender ≠ identity` in transfer.
> 2. *The identity as an operand* (the deposit-only account, see the note under `dark_withdraw`).
>    The deposit-only `nargo test` cases cover it under the solver only. The two committed
>    `Prover.toml` files that carry `avail_d` (`transfer`, `withdraw`) hold a non-identity one, and
>    `disclose_range`'s `d` is non-identity too, so no committed bb proof or Solidity-verifier
>    fixture exercises it. Ad-hoc check on 2026-10-07, not committed: deposit-only witnesses for
>    `dark_withdraw` and `dark_transfer`, generated with the SDK as `gen_prover.mjs` does but with
>    `available = (B·G, identity)` for B = 500 USDG, proved with the pinned bb, passed `bb verify`,
>    and verified under the generated `withdraw` and `transfer` Solidity verifiers.

Not done here: proving the same circuits with bb.js and noir-rs and asserting one byte-identical
VK across all three (§6 asks for it; noir-rs still lags at beta.19), and verifying against
deployed bytecode on an anvil fork.

> **Implementation note (2026-10-07):** §6 as frozen no longer targets noir-rs (native proving runs
> bb.js in a WebView) and lists both remaining items as not in CI. Status today: no committed check
> proves with bb.js (the production prover, pinned to the same barretenberg build in
> `circuits/VERSIONS.toml`) and compares the result with the bb CLI; every proof in this repository's
> checks was made with the bb CLI. The deployed-bytecode item is covered another way, described in
> the note under *Verifier bytecode*. No test runs proofs against the live addresses on a fork.

## What §6 got wrong

Numbered in the order they were proposed as spec edits.

> **Implementation note (2026-10-07):** all eight were settled in the spec before it was frozen.
> Items 1–5 and 7 are now §6 and §3 text (item 1 also as §19 X1). Item 6 became the
> "Measured 2026-09-16" line in §6, whose table keeps its original estimate column. Item 8 lapsed
> when §9 was rewritten from measurements on 2026-09-17. They stay here as the record of what
> measurement changed.

1. **`is_infinite` does not exist** (already recorded as §19 X1, but §6's `dark_lib` rules bullet
   still says "identity is handled via `is_infinite`"). The bullet itself needs rewriting to
   "identity is the `(0,0)` sentinel; a stored ciphertext component is asserted on-curve **or**
   identity, a key is asserted on-curve **and** not identity".
2. **Scalars are limb pairs everywhere, not just in `dark_register`.** §6 lists C1's private
   input as "`s` (lo/hi limbs)" but C2's as plain "`s`, `r`". The Grumpkin group order is the
   BN254 base field, which is *larger* than `Field`'s modulus, so no Grumpkin scalar fits in a
   `Field`. Every scalar in every circuit is `(lo, hi)` with both limbs asserted to 128 bits.
3. **"`r ≠ 0`" is not a limb check.** Non-zero limbs can still reduce to `0 mod n`. The sound
   check is `ct.D_sender ≠ identity` (n is prime and `pk_s` is not the identity, so
   `r·pk_s = identity` iff `r ≡ 0`). Implemented that way; §6's condition (3) should say so.
4. **A negative test per binding public input is impossible at the execution level.** `chain_id`,
   `vault`/`registry`, `sender`, `recipient`, `account`, `to`, `nonce` and `context_hash` are
   pure domain separators: there is nothing in the circuit for them to contradict, so flipping
   one still solves the witness. They are bound by Honk's public-input delta, so the negative
   test belongs against the verifier, where it passes. §6's bullet should say which level each
   kind of input is tested at.
5. **The SHA-256 manifest entry cannot be over the ACIR JSON file.** `target/<pkg>.json` carries
   debug symbols and a file map that change with the directory `nargo` was invoked from, so the
   file hash is not reproducible; the `bytecode` field is. `manifest.json` hashes that.
6. **Gate estimates are 2–3× too high.** Replace §6's estimate column with the measured numbers
   above, and note the budget is not close to binding.
7. **An earlier draft of §3 named a file that does not exist** (`circuits/scripts/derive_h.ts`); the
   published §3 names the right one. `H` is derived by `src/grumpkin.ts` (`deriveH()`) in the dark-sdk repository and cross-checked
   by `circuits/tools/gen_prover.mjs`. The measured constant, for the record and for
   `DarkGrumpkin.sol`:
   `H.x = 0x1c670f693e0f1e5f2dd00c3fbf55c8e22af4ca3071dee49808899f9aa44d1024`,
   `H.y = 0x2574095592574b6dedda035b4a88af623685e955658a73e5af0701ee23e282bc`.
   (Note this is **not** the spike's H: the spike, an early throwaway prototype circuit that is not
   in this repository, used the tag `DARK-CB-1/H/v1`; §19 K1 settled on `DARK-CB-1/generator/H`.)

   > **Implementation note (2026-10-07):** `DarkGrumpkin.sol` does not carry `H` and does not need
   > it: it validates points, computes `amount·G` (`mulG`, used by `deposit` and `withdraw`), and
   > adds or subtracts ciphertexts componentwise; it never forms a commitment, so it never touches
   > `H` (§3 says the same). The constant lives in `circuits/lib/src/lib.nr`, with a cross-check copy in
   > `circuits/tools/gen_prover.mjs` whose drift error message still names `DarkGrumpkin.sol`.
8. **§9's "96 KB limit" needs one clarifying clause.** The per-contract limit is EIP-170's
   24,576 B; 96 KB is the initcode/deployment budget. Both hold, with 6.7 KB of margin on the
   binding one. Numbers above.

   > **Implementation note (2026-10-07):** see the note under *Verifier bytecode*: 96 KB is not an
   > Ethereum-standard initcode limit (EIP-3860's is 49,152 B), and the current §9 does not cite it.
