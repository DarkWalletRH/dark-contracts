# Audit guide

Start here. This file is for the security review of this repository: what Dark is, what is in
scope, which commit is under review and how to tie it to the chain, how to build and test
everything, and what we already know is wrong or have accepted. The design documents are in
[`docs/`](docs/). Facts marked with a date were checked on that date against this repository and
Robinhood Chain.

## 1. What Dark is

Dark keeps USDG balances encrypted on Robinhood Chain. After a one-time key registration, each
account holds two twisted-ElGamal ciphertexts over the Grumpkin curve in `DarkVault`: `available`,
which only the owner changes, and `pending`, which collects incoming transfers until the owner
folds it in. A private transfer moves a hidden amount from the sender's `available` to the
recipient's `pending`, and a Noir proof (UltraHonk, verified on chain by Solidity verifiers
generated with Barretenberg) shows that the sender owns the key, that the ciphertext is well formed
and within the caps, and that the remaining balance is not negative. Deposits and withdrawals are
ordinary public USDG transfers, and Dark hides amounts, never who transacts with whom: there is no
pool, no anonymity set and no relayer. The contracts are not upgradeable, and no role, the team's
included, can move the USDG that backs the balances.

## 2. Scope

**In scope.** Paths are relative to the repository root.

| Path | Lines | What it is |
|---|---|---|
| `contracts/src/DarkVault.sol` | 375 | USDG ↔ encrypted balances: `deposit`, `applyPending`, `transfer`, `withdraw`; caps, pause, admin |
| `contracts/src/DarkKeyRegistry.sol` | 50 | address → Grumpkin public key, proof of knowledge; no admin |
| `contracts/src/libraries/DarkGrumpkin.sol` | 144 | Grumpkin point checks, add, neg, sub, `mulG` |
| `contracts/src/interfaces/IDarkVault.sol`, `IDarkKeyRegistry.sol`, `IDarkVerifier.sol` | 173 | types, events, errors, the verifier ABI |
| `contracts/src/mocks/MockUSDG.sol` | 17 | testnet stand-in for USDG (public `mint`) |
| `circuits/lib/src/lib.nr` | 226 | shared Noir: point checks, scalars, ElGamal, range checks, `bind` |
| `circuits/{register,transfer,withdraw,disclose_range}/src/main.nr` | 832 | the four circuits (line counts include their in-file tests); `disclose_range` is verified off chain only |
| `circuits/verifiers/{register,transfer,withdraw}/Verifier.sol` | 3 × 2,465 | bb's output, byte for byte (sha256 pinned in `circuits/manifest.json`). The deployed bytecode was compiled from a copy with only the contract line renamed to `HonkVerifier_<crate>`; the rename is in the metadata hash, so compiling `Verifier.sol` as-is does not reproduce the pin. `scripts/lib/verifier-recipe.mjs` generates that copy (as `evm/src/<crate>.sol` under the `circuits/foundry.toml` profile) and `scripts/check-verifier-bytecode.mjs` rebuilds it. Each links one shared `RelationsLib` and `ZKTranscriptLib` per chain |
| `scripts/lib/verifier-recipe.mjs`, `scripts/deploy-verifiers.mjs` | 129 | how the verifiers were compiled, linked and deployed |
| `contracts/script/DeployDarkMainnet.s.sol` | 133 | mainnet deployment: timelock, registry, vault, Safe and pin checks |
| `scripts/check-verifier-pins.mjs`, `scripts/check-verifier-bytecode.mjs` | 409 | verifier ↔ circuit tie; source ↔ pinned bytecode |
| `circuits/public_inputs.toml`, `circuits/manifest.json`, `circuits/VERSIONS.toml`, `contracts/deployments/*` | — | public-input order, circuit hashes, toolchain pins, deployment record and codehash pins |

In total: 2,488 hand-written lines (Solidity and Noir, including the circuits' in-file tests) and
7,395 lines of generated verifier code.

`DarkTimelock` is an OpenZeppelin `TimelockController` instance with no custom source (its bytecode
is tied to the chain in section 3). Trusted dependencies, whose use by this code is in scope:
OpenZeppelin Contracts 5.6.1, the Noir standard library's `embedded_curve_ops` (nargo
1.0.0-beta.22), Barretenberg 5.0.0-nightly.20260522 (the verifier generator and prover), and Safe
v1.4.1 (the owner and guardian Safes on mainnet). Test-only: forge-std 1.9.7 and @noble/curves 2.4.0
(the oracle for the differential Grumpkin tests); exact versions are in `contracts/package-lock.json`
and `circuits/VERSIONS.toml`.

**Out of scope, but relevant.**

- **[dark-sdk](https://github.com/DarkWalletRH/dark-sdk)** builds every proof the vault sees: key
  derivation (§4), encryption and hedged randomness (§3), `aeBalance` and transfer hints, the
  public-input encoder, witness generation, decryption with its BSGS fallback (§7), and DLEQ
  disclosures. A bug there can leak amounts or keys; it cannot by itself move another account's
  funds. **[dark-exit](https://github.com/DarkWalletRH/dark-exit)** withdraws without any Dark
  server.
- The API, indexer, Android app and website are closed source and out of scope. Dark's servers hold
  no user keys and have no on-chain powers.
- Supporting code here (tests, `circuits/tools/`, the testnet deploy script, the mutation runner,
  `scripts/record-deploy.mjs` and the npm package files) is not in scope.

## 3. The commit under review, and how to tie it to the chain

The commit under review is the one tagged **v1.0.4**, the tag this file ships in
(`git rev-parse 'v1.0.4^{commit}'`; the full hash is also in the v1.0.4 release notes; please quote it
in your report). Tags `v*` and `main` are protected: a tag cannot be moved or deleted. The deployed code has not changed since the mainnet launch tag
v1.0.0 (2026-09-28); later tags changed tests, tooling, comments in the deploy scripts and
documentation, the explanatory `_` string in `contracts/deployments/verifier-codehashes.json` and
comments in `contracts/deployments/deployments.ts` (no address, codehash or cap changed). This
prints nothing:

```bash
git diff --stat v1.0.0 -- contracts/src circuits/lib circuits/register circuits/transfer \
  circuits/withdraw circuits/disclose_range circuits/verifiers
```

The other in-scope files did change after v1.0.0, in comments and tool headers only (the deploy
script's comments, `circuits/public_inputs.toml` and `circuits/foundry.toml` comments, and the
`scripts/` headers and their deployment-record path). Review those changes with:

```bash
git diff v1.0.0 -- contracts/script/DeployDarkMainnet.s.sol circuits/public_inputs.toml \
  circuits/foundry.toml scripts/
```

**Source → pins (offline).** Rebuilds every deployed contract the way it was deployed (compiler
profile, source, linked library addresses, constructor immutables) and requires each runtime
codehash to equal its pin in `contracts/deployments/verifier-codehashes.json`. Needs Foundry and
Node.js 22. Expect fourteen `ok` lines and a summary naming chains 4663 and 46630; forge's lint
notes on the generated verifiers are noise.

```bash
(cd contracts && npm ci)
node scripts/check-verifier-bytecode.mjs
```

**Pins → chain.** Compares every pinned codehash with the live chains (bash or zsh; about 5 s):

```bash
for CHAIN in 4663 46630; do
  if [ "$CHAIN" = 4663 ]; then RPC=https://rpc.mainnet.chain.robinhood.com; else RPC=https://rpc.testnet.chain.robinhood.com; fi
  node -e "const p=require('./contracts/deployments/verifier-codehashes.json')['$CHAIN'];for(const[n,r]of Object.entries(p))console.log(n,r.address,r.codehash)" |
  while read -r name addr pinned; do
    live=$(cast codehash "$addr" --rpc-url "$RPC")
    if [ "$live" = "$pinned" ]; then echo "ok   $CHAIN $name $addr"; else echo "FAIL $CHAIN $name $addr live=$live pinned=$pinned"; fi
  done
done
```

**The timelock.** `DarkTimelock` has no immutables, so its runtime codehash is the hash of
OpenZeppelin's compiled `TimelockController`. All three values below were equal
(`0x9a660cf2a87a590841e8633fd97ec0f30302ec94ae62ec77aeaf9fded99b5a25`) on 2026-10-07:

```bash
(cd contracts && cast keccak "$(forge inspect TimelockController deployedBytecode)")
cast codehash 0xADbF7E3cf5418BeAC10BcDD3BBD9a51dc19EBC54 --rpc-url https://rpc.mainnet.chain.robinhood.com
cast codehash 0x4522d92128219FE0F3DcFf17324617881C3f7D05 --rpc-url https://rpc.testnet.chain.robinhood.com
```

Together the two steps show that the code at every pinned address is this source, with the vault's
and registry's immutables (USDG, registry, verifiers) equal to the deployment record. All 14 rows
matched on 2026-10-07. Storage (owner, guardian, caps) is read in section 5.

## 4. Architecture and trust model

The protocol is **[docs/DARK-CB-1.md](docs/DARK-CB-1.md)**, frozen on 2026-09-27; dated
implementation notes record where the code or later findings differ from it. The code's `§n`
comments cite it (the Solidity uses an older numbering, mapped at the top of that file).

- **Cryptography (§3).** Grumpkin, `y² = x³ − 17` over the BN254 scalar field, of prime order n.
  Secret s, public key P = s⁻¹·H, so s·P = H. A balance is (C, D) = (v·G + ρ·H, ρ·P); a transfer
  is one commitment with two handles, (a·G + r·H, r·P_sender, r·P_recipient). Amounts are in
  [0, 2⁴⁸), the identity is the sentinel (0, 0), and H comes from a public hash rule, so nobody
  knows log_G(H).
- **Contracts (§5, §12).** Every account function acts on `msg.sender`, and all four share one
  `nonReentrant` guard. `deposit` adds `mulG(x)` to `available.C`; `transfer` moves the ciphertext
  from the sender's `available` to the recipient's `pending`; `applyPending` folds `pending` in
  without a proof; `withdraw` subtracts `mulG(x)` and pays x. `withdraw`, `applyPending` and
  `register` can never be paused. A spend proof binds chain id, contract, sender, `to`, nonce, keys
  and the stored `available`, and a transfer proof also binds `minTransfer` and `maxTransfer`, so
  apart from a cap change (`setCaps`, or the guardian's `tightenCaps`) only the owner's own actions
  can invalidate a pending proof.
- **Circuits (§6).** `dark_register`: s·pk = H, for this chain, registry and caller.
  `dark_transfer`: key ownership, a well-formed ciphertext with one r in both handles, r ≢ 0,
  `minTransfer ≤ a ≤ maxTransfer`, and a remainder 0 ≤ w < 2⁴⁸. `dark_withdraw`: key ownership and
  a remainder in range after a public amount. `dark_disclose_range` (off chain): a range statement
  about one ciphertext.
- **Hidden (§2):** transfer amounts, and the balances of accounts that have used confidential
  transfers. Deposits, withdrawals, who pays whom, nonces, pending counts and TVL are public, and so
  is the exact balance of an account that has only deposited and withdrawn.
- **Loss bound.** A soundness bug in a circuit, a verifier or `DarkGrumpkin` lets an attacker mint
  encrypted value and withdraw other users' USDG, up to the vault's holdings: at most `tvlCap`
  (50,000 USDG today, never more than `HARD_MAX_TVL` = 250,000 USDG for this vault).
- **Companion reports:** [THREAT-MODEL.md](docs/THREAT-MODEL.md) (the contract side of §17),
  [INVARIANTS.md](docs/INVARIANTS.md) (I1–I15, §15), [MUTATIONS.md](docs/MUTATIONS.md) (§16) and
  [CIRCUITS-REPORT.md](docs/CIRCUITS-REPORT.md) (measurements, and what each circuit constrains).

| Role | Can | Cannot |
|---|---|---|
| Any account | register once; deposit, transfer, apply pending, withdraw on its own account | act on another account; read another balance or a transfer amount |
| Guardian | `pause` (blocks `deposit` and `transfer` only); `tightenCaps` (every max ≤ current, every min ≥ current), instantly | unpause; raise a cap; touch `withdraw`, `applyPending` or `register`; move funds |
| Owner = `DarkTimelock` (48 h) | `setCaps` up to the hard ceilings; `setGuardian`; `unpause`; `pause`; `tightenCaps`; `recoverERC20` for any token but USDG; two-step `transferOwnership` | move USDG; change the registry, token or verifiers (immutables); renounce ownership; upgrade anything |
| `DarkKeyRegistry` | — (no owner, no pause) | — |

## 5. Deployments, governance and caps

Addresses come from `contracts/deployments/deployments.ts` and
`contracts/deployments/verifier-codehashes.json`. **The same address holds different contracts on
the two chains**, so always read an address together with its chain id.

| Contract | Mainnet, chain id 4663 | Testnet, chain id 46630 |
|---|---|---|
| `DarkVault` | `0xeD7a0c6899a6AC94Aea7A5b2F8f24a948042DA9C` | `0x14fa77C25357C1Dc7de0DD7F36e0EbE807110aB7` |
| `DarkKeyRegistry` | `0x2E245135FD561965CC546c14C23C9162f36d9C87` | `0x850907E912c5F89B233252E3633BEfaBe66232B2` |
| `DarkTimelock` (owner) | `0xADbF7E3cf5418BeAC10BcDD3BBD9a51dc19EBC54` | `0x4522d92128219FE0F3DcFf17324617881C3f7D05` |
| Owner Safe (timelock proposer, executor, canceller) | `0xD1A9F36662561844e6d0B3e9f4cf908695e72305` (2-of-3) | the deployer EOA below |
| Guardian | `0x87879CbAfC1E92528b950444E693D3b2F07CB1d7` (Safe, 1-of-2) | `0x8FFB462Ae98Bb8975BD3FCE03df244637Dba9547` (deployer EOA) |
| `DarkRegisterVerifier` | `0xAf2332Ef3910A9328418b4963BA0E50b9d5846Fe` | `0x97dB97Eec8d722a5C48F0Fb1612D1DC160A7c085` |
| `DarkTransferVerifier` | `0x0905e66f00Bd3261A8E32Dc4b6Cb060a6B8A8f74` | `0xAf2332Ef3910A9328418b4963BA0E50b9d5846Fe` |
| `DarkWithdrawVerifier` | `0xaa921526C05b2F11204525D28A81391d91C4258a` | `0x0905e66f00Bd3261A8E32Dc4b6Cb060a6B8A8f74` |
| `RelationsLib` | `0x43804a423f7Da1297C91C47Fc959DBe937788e4c` | `0xb771CCeda9eABf17A0E26A1109bb36fb6ea8eE79` |
| `ZKTranscriptLib` | `0x97dB97Eec8d722a5C48F0Fb1612D1DC160A7c085` | `0x43804a423f7Da1297C91C47Fc959DBe937788e4c` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (EIP-1967 proxy) | `MockUSDG` `0x77FfdE2D07f08f847944B6951dDd9243ae5EE950` |
| Deploy block | 75,151,289 (2026-09-28) | 122,104,964 (2026-09-20) |

RPC: `https://rpc.mainnet.chain.robinhood.com`, `https://rpc.testnet.chain.robinhood.com`.
Explorers: `https://robinhoodchain.blockscout.com`, `https://explorer.testnet.chain.robinhood.com`.

**Mainnet governance, read on 2026-10-07 (block 82,955,595).** `owner()` is the timelock and
`pendingOwner()` is zero. `getMinDelay()` is 172,800 s (48 h). `PROPOSER_ROLE`, `EXECUTOR_ROLE` and
`CANCELLER_ROLE` are held by the owner Safe only, and `DEFAULT_ADMIN_ROLE` by the timelock itself
(deployed with admin `address(0)`), so its roles change only through the delay. The owner Safe's
threshold is 2 of 3 owners; the guardian Safe's is 1 of 2, and its two signers are also two of the
owner Safe's three. The vault has emitted only its constructor events (the caps have never changed,
it was never paused), the timelock has scheduled nothing, `tvl()` is 0 and the registry has no
registrations: no wallet has been released yet. To repeat:

```bash
RPC=https://rpc.mainnet.chain.robinhood.com
VAULT=0xeD7a0c6899a6AC94Aea7A5b2F8f24a948042DA9C; TL=0xADbF7E3cf5418BeAC10BcDD3BBD9a51dc19EBC54
OWNER_SAFE=0xD1A9F36662561844e6d0B3e9f4cf908695e72305; GUARDIAN_SAFE=0x87879CbAfC1E92528b950444E693D3b2F07CB1d7
cast call $VAULT 'owner()(address)' --rpc-url $RPC
cast call $VAULT 'guardian()(address)' --rpc-url $RPC
cast call $VAULT 'caps()((uint64,uint64,uint64,uint64,uint64,uint64))' --rpc-url $RPC
cast call $TL 'getMinDelay()(uint256)' --rpc-url $RPC
for R in PROPOSER_ROLE EXECUTOR_ROLE CANCELLER_ROLE; do cast call $TL 'hasRole(bytes32,address)(bool)' $(cast keccak $R) $OWNER_SAFE --rpc-url $RPC; done
cast call $OWNER_SAFE 'getThreshold()(uint256)' --rpc-url $RPC; cast call $OWNER_SAFE 'getOwners()(address[])' --rpc-url $RPC
cast call $GUARDIAN_SAFE 'getThreshold()(uint256)' --rpc-url $RPC; cast call $GUARDIAN_SAFE 'getOwners()(address[])' --rpc-url $RPC
```

The public RPC answers bursts with HTTP 403 (Cloudflare); run this block and the one in section 3
one at a time, or put `sleep 1` between calls.

**Caps** (USDG, 6 decimals; the contract stores micro-units). The mainnet values are
`DeployDarkMainnet.caps()`, equal to `caps()` on chain; `contracts/test/DeployDarkMainnet.t.sol`
pins all six fields. Ceilings are immutable constants in `DarkVault`. The last column is the
specification's pre-audit beta column (§5), which mainnet exceeds by team decision.

| Field | Mainnet now | Testnet | Hard ceiling | §5 beta column |
|---|---|---|---|---|
| `minDeposit` | 1 | 0.000001 (1 micro-unit) | none | 1 |
| `maxDeposit` (per tx) | 1,000 | 2,500 | 2,500 | 250 |
| `maxAccountInflow` (net public inflow) | 2,500 | 10,000 | 10,000 | 1,000 |
| `minTransfer` | 0.01 | 0.01 | ≥ 1 micro-unit | 0.01 |
| `maxTransfer` (per tx) | 1,000 | 2,500 | 2,500 | 250 |
| `tvlCap` | 50,000 | 250,000 | 250,000 | 25,000 |
| `withdraw` | uncapped | uncapped | — | uncapped |

Raising a cap takes the 48 h timelock; the guardian can lower one instantly. `tvlCap` is the real
loss bound: per-account caps are sybil-able.

## 6. Build and test

Toolchain: **Foundry** (forge installs solc 0.8.28 for `contracts/` and 0.8.30 for the verifier
profile), **Node.js 22** (22.18 or later for `scripts/build-abi.mjs`), and **nargo
1.0.0-beta.22** with **bb 5.0.0-nightly.20260522**, the pair pinned in `circuits/VERSIONS.toml`,
whose `noirup`/`bbup` lines install them (CI pins the installer commits). The circuit tools call
`~/.nargo/bin/nargo` and `~/.bb/bb` directly, not whatever is on `PATH`. Profiles:
`contracts/foundry.toml` (solc 0.8.28, cancun, via-IR, 1,000 optimizer runs, `ffi = true` for the
differential test, invariant runs 32 × depth 32, `fail_on_revert`) and `circuits/foundry.toml`
(solc 0.8.30, cancun, 200 runs, no via-IR: the profile the verifiers were deployed with).

Every command below was run on 2026-10-07 from a fresh clone at commit `b428b24` (v1.0.3 plus
pinned CI actions; v1.0.4 carries its contracts, circuits and tests unchanged), with forge
1.5.1-stable, Node.js 22.22.0 and the pinned nargo and bb, on an Apple M4 (10 cores). Times are
wall clock; the first `forge test` includes compilation.

```bash
cd contracts && npm ci                      # dependencies from npm, no submodules (1 s)
forge test                                  # 69 tests in 7 suites (18 s cold)
forge test --match-path 'test/invariant/*'  # the 14 invariant functions alone (3 s)
node script/mutate.mjs                      # 44 mutants: 44/44 killed (15-25 min); writes audit/MUTATIONS.md (gitignored)
node script/mutate.mjs --only M7a,M12       # a subset; prints the table only (1 min)
cd ..
node scripts/check-verifier-pins.mjs        # pinned verifiers ↔ circuits/manifest.json (< 1 s)
node scripts/check-verifier-bytecode.mjs    # source → pins, section 3 (24 s)
node scripts/build-abi.mjs --check          # npm package files match the sources (< 1 s)
(cd circuits && nargo test --workspace)     # 76 circuit tests (2 s)
node circuits/tools/check-manifest.mjs      # recompile; ACIR, VK, gates, public-input order (< 1 s)
node circuits/tools/flip-public-inputs.mjs  # disclose_range rejects each flipped public input (< 1 s)
forge test --root circuits                  # real proofs verify, flipped inputs fail; gas (1 s)
```

The 69 contract tests are unit tests (`DarkVault.t.sol`, `DarkKeyRegistry.t.sol`), cap
boundaries, both deploy scripts, the Grumpkin differential test against `@noble/curves` (through
`vm.ffi`) and the invariant suite. The 76 circuit tests are `dark_lib` 11, register 8, transfer 26,
withdraw 17 and disclose_range 14. CI (`.github/workflows/ci.yml`) runs everything above except
the mutation runner on every push to `main` and every pull request. Regenerating `Prover.toml`
files, proofs and fixtures (`circuits/tools/gen_prover.mjs`, `build.mjs`, `gen_fixtures.mjs`)
needs `npm ci` in `circuits/tools`, which installs the dark-sdk from GitHub; the steps are in
[docs/CIRCUITS-REPORT.md](docs/CIRCUITS-REPORT.md). CI does not run them: their outputs are
committed and checked.

## 7. Known issues and accepted risks

Numbered so findings can cite them. "Re-checked" means we reproduced it on 2026-10-07.

**Outside this code**

1. **Trusted setup.** KZG on BN254 over Aztec's Ignition SRS: soundness assumes one honest
   Ignition participant (1-of-N). Provers bundle a 2¹⁷-point slice pinned in
   `circuits/srs/MANIFEST.json`.
2. **Chain operator.** Robinhood Chain's centralized sequencer can filter any transaction,
   `withdraw` included, and the chain can be upgraded with no delay. "Exit is never blocked" holds
   against Dark's roles, not against the operator.
3. **USDG.** The issuer may be able to freeze the vault's address, and so every account (assumed,
   not verified); USDG is an EIP-1967 proxy, so its behaviour can change. The `deposit`
   balance-delta guard sees only its own `safeTransferFrom`, `withdraw` has none, and both trust
   `balanceOf`. A balance change between transactions (a negative rebase), or a fee taken from the
   vault on top of a withdrawn amount, leaves `balanceOf(vault) < tvl` (I1 broken) with no on-chain
   signal until the last withdrawals revert.
4. **The generated verifier.** We know of no public audit of Barretenberg's Honk Solidity verifier
   template; the vault treats `verify` as an oracle (loss bound: section 4).

**Contracts and deployment**

5. **`InvalidProof` is unreachable on chain.** The deployed verifiers `require` sumcheck and
   Shplemini and then return `true`, so a bad proof reverts with the verifier's own error (e.g.
   `SumcheckFailed()`). Only the test mock `DarkTestVerifier` returns `false`.
6. **`setCaps` checks only the hard ceilings** and `minTransfer ≥ 1`: not consistency
   (`minDeposit ≤ maxDeposit`, `minTransfer ≤ maxTransfer`, per-transaction caps ≤
   `maxAccountInflow` ≤ `tvlCap`), and not `minDeposit ≥ 1`, which §19's "a zero deposit is
   `BelowMinDeposit`" assumes (with `minDeposit = 0`, `deposit(0)` is a nonce-bumping no-op). That is
   left to the 48 h public review of each proposal and to off-chain monitoring. `tightenCaps`
   deliberately checks neither (I7: a min above its max disables `transfer`, never `withdraw`).
7. **Governance is a deploy-time property.** That both roles are Safes, the owner Safe's threshold
   ≥ 2 with ≥ 3 owners, and owner ≠ guardian are checked only by `DeployDarkMainnet.s.sol`.
   `setGuardian` takes any non-zero address and nothing requires the owner to be a timelock: after
   a `transferOwnership` has sat 48 h on the timelock and been accepted (`Ownable2Step`), the new
   owner acts with no delay, within the ceilings and with no path to USDG. On mainnet the guardian
   Safe's two signers are two of the owner Safe's three, so together they are an owner quorum,
   slowed only by the timelock.
8. **Verifier identity rests on the pins.** The vault's constructor checks only that its two
   verifiers differ and have code, the registry's only that its verifier has code; the deploy
   scripts' pin checks and section 3 cover the rest.
9. **Public-input arrays are hand-written.** `DarkKeyRegistry.register`,
   `DarkVault._transferInputs` and `_withdrawInputs` build theirs inline (the `DarkPublicInputs`
   codegen of §5 and §6 was never built). `check-manifest.mjs` checks the circuits against
   `circuits/public_inputs.toml` and the dark-sdk generates its encoder from it; nothing checks the
   contracts against it, and no test drives a real proof through `DarkVault`
   (`contracts/test/realproofs/` was never built). Unit tests pin each array against a copy in the
   test. Re-checked by hand: the arrays match (5, 21, 12 entries), and real proofs have passed
   through the testnet vault in end-to-end runs.
10. **`DarkGrumpkin.mulG` is plain Jacobian double-and-add**, not §5's 12×15 window table
    (`DarkGrumpkinTables` and `script/gen_g_table.ts` do not exist; the comment above `mulG` in
    the deployed source says so). §9's gas is for this version.
11. **Small things.** `withdraw` emits `Withdrawn` before `safeTransfer` (§5 lists it after; CEI
    holds). `DarkGrumpkin.inv`'s comment says it reverts on 0; the modexp precompile returns 0
    (re-checked on 4663); the zero case is unreachable for on-curve inputs. The same address holds
    different contracts on 4663 and 46630 (section 5).

**Circuits and proving**

12. **Non-canonical scalars.** The 128-bit limb checks admit both s and s + n, and three texts
    disagree on what refuses s + n: the `scalar()` comment in `circuits/lib/src/lib.nr` (the MSM
    gadget; "bb is never reached"), §3's frozen text (bb, at witness solving), and
    `circuits/VERSIONS.toml` item 1 with §3's note (only nargo's solver, so a hand-built witness
    would pass bb). Re-checked on `dark_register` with s = 5: a hand-built witness carrying the
    limbs of 5 + n (solver hints recomputed) proves with the pinned bb and fails `bb verify`, while
    the honest one verifies, so the pinned bb also constrains it
    ([docs/CIRCUITS-REPORT.md](docs/CIRCUITS-REPORT.md) traces this to bb's MSM scalar handling).
    Our current understanding is that measured result (the pinned bb also rejects s + n at
    verification); the `lib.nr` comment and §3's frozen wording predate it.
    Not exploitable either way: s and s + n give the same points, and the zero-scalar guards are
    constraints (`assert_key`; `ct_ds ≠ identity` in transfer). Please confirm; both behaviours need
    re-checking on any nargo or bb change.
13. **The identity as an operand (exit liveness).** `deposit` stores `(x·G, identity)`, so a
    deposit-only account's first withdraw feeds `(0, 0)` into `s·avail.D` as an MSM operand (its
    first transfer, into `avail.D − ct.D_sender`); the pinned `EmbeddedCurvePoint` has no
    `is_infinite` flag. Committed coverage is solver-only (`test_accepts_a_{transfer,withdraw}_from_a_deposit_only_account`):
    the committed `Prover.toml` files use a non-identity `avail_d`, and the live end-to-end runs
    proved a deposit-only transfer only. Re-checked, not committed: deposit-only withdraw and
    transfer witnesses prove with the pinned bb, pass `bb verify` and verify under the generated
    Solidity verifiers (`circuits/VERSIONS.toml`, §3's note and `docs/THREAT-MODEL.md` note 9 predate this). A committed fixture is
    missing.
14. **Circuit mutations are not automated.** No harness runs M18–M27; `contracts/script/mutate.mjs`
    only lists them, and the report it generates still says they are "run by the suite that covers
    those files"; no such suite exists, and `docs/MUTATIONS.md` corrects that in a note. A manual run of M18–M24 on
    2026-10-07 left survivors, each explained in [docs/MUTATIONS.md](docs/MUTATIONS.md): M18,
    `assert_u48(w)` removed (w is still a `u64` witness, and `HARD_MAX_TVL` keeps balances far below
    2⁴⁸); M20 at the transfer call site (transfer has no wrong-secret negative); M21, the
    `ct_ds ≠ identity` guard (unreachable from `nargo test`; on chain `_requirePoint` rejects an
    identity `ct.dSender`); M22 in `assert_point_or_identity` (only the solver rejects an off-curve
    stored point, and the vault supplies those from storage); M24, by design (binding is UltraHonk's
    public-input delta, which the flip tests check). M27's "CI manifest-flag check" (§16, §18 item
    9) does not exist; the protection is indirect (`build.mjs` always passes
    `--verifier_target evm`, and CI fails if a verifier stops matching its manifest hash, pins,
    deployed bytecode or fixture proofs). §15's CP1 "wraparound w = n − 1" test does not exist and
    cannot as stated: w is a `u64` witness.
15. **The H cross-check is not in public CI.** H is a constant in `circuits/lib/src/lib.nr` and is
    derived at runtime by the dark-sdk. The only public comparison, `circuits/tools/gen_prover.mjs`,
    checks the SDK's H against a literal copy in the script, and CI does not run it;
    `test_h_matches_sdk` and the dark-sdk's test are self-comparisons; the check §3 and §19 describe
    runs in the maintainers' private CI. Re-checked: the dark-sdk's `deriveH()` and an independent
    derivation from §3's rule both give `lib.nr`'s constant (a drift would make every proof fail).
    Stale text: `lib.nr` cites the SDK file by a `packages/dark-sdk/…` path (it is
    `src/grumpkin.ts` in the dark-sdk) and says `gen_prover.mjs` "fails the build on drift"; its error message names
    `DarkGrumpkin.sol`, which carries no H.
16. **bb.js is not cross-checked.** Production proving uses bb.js (in a WebView on Android), but
    every committed proof and the recorded end-to-end runs used the bb CLI, and nothing compares
    the two. No test sends proofs to the live verifier addresses on a fork; section 3 shows
    bytecode identity instead.
17. **Gas headroom is thin.** Against §9's L2 gates: about 6 % for transfer, 7 % for register and
    9 % for withdraw; `verify()` is about 61 % of a transfer's L2 gas. No test asserts a bound.

**What the green test suite does not show**

18. **Cap-check gap (I9).** The code is correct, but each of five deletions leaves all 69 contract
    tests passing (re-checked): `tightenCaps` without its `maxAccountInflow`, `maxTransfer` or
    `tvlCap` comparison, and `_checkCeilings` (`setCaps`, constructor) without the
    `maxAccountInflow` or `maxTransfer` ceiling. No mutant covers them; such a regression would let
    the 1-of-2 guardian raise a cap instantly.
19. **Invariant blind spots** (re-checked). With both `verify` calls deleted, or all four deposit
    cap checks deleted, all 14 invariants still pass; unit tests catch both
    ([docs/INVARIANTS.md](docs/INVARIANTS.md)). Three of I13's four assertions hold by construction,
    the handler submits only in-cap amounts, and I14 checks part of the transfer event and no admin
    events.
20. **Coarse kills, fixed seeds.** M1 dies only because no registered account is ever `tx.origin`
    for another caller; M39a–M39d die on a selector mismatch (`NotRegistered`, not
    `ReentrancyGuardReentrantCall`), so re-entry by a registered caller is untested.
    `test_differentialAgainstNoble` seeds from `block.timestamp`, which forge keeps fixed (the same
    500 cases every run), and `contracts/foundry.toml` pins no fuzz seed.
21. **Outside CI.** The mutation runner, the proof and fixture generators, and any pins-to-chain
    comparison: CI's bytecode check stops at the committed pins, and `test_committedPinIsWellFormed`
    checks one address and two non-zero hashes offline, whatever its comment says. The off-chain
    monitor §5 and §17 rely on (codehash against chain, `CallScheduled` and outflow alerts) is not
    public. CI does not pin Foundry. M17–M17c mutate only `DeployDarkTestnet.s.sol`; the mainnet
    script has its own `_pin` and wiring, tested without a library-swap case.

**Off-chain components (out of scope, for context)**

22. **The hedge context omits the amount.** r and k are
    `HashToScalar(tag ‖ 32 CSPRNG bytes ‖ s ‖ (chainId, vault, from, to, fromNonce))` (§3). With a
    broken CSPRNG, a retry at the same nonce and recipient with another amount reuses r and k, and
    the two ciphertexts reveal the difference of the amounts.
23. **SDK ↔ specification drift.** §4's key vectors are 5 raw-key vectors, not at least 8, with no
    BIP39 mnemonic vector, read only by the dark-sdk's own tests. §18b's `DARK-CB-1/disclose/v2`
    overrides §3's `…/v1`; the AEAD nonce tag `DARK-CB-1/aead-nonce/v1` is not in §3's table.
    `NativeDarkProver` was never built (bb.js in a WebView instead); the SRS slice is 2¹⁷ points,
    not 2¹⁶ + 1.
24. **Platform.** v1 is an Android APK only (spec text about a web wallet, app stores and iOS
    describes surfaces that are not live), and as of 2026-10-07 no APK has been released.

**Launch guardrails not met (§18)**

25. Item 1 (c) was waived at the 2026-09-28 deploy by team decision: the 7-day testnet soak of the
    exact mainnet codehashes and the external-tester floor (the code was byte-identical to what had
    run on testnet). Mainnet caps exceed §5's beta column: deposit 1,000 vs 250, inflow per account
    2,500 vs 1,000, transfer 1,000 vs 250, `tvlCap` 50,000 vs 25,000 USDG.
26. Item 10: the exit drill has run only in reduced form (a fork of 46630, the dark-exit CLI, a
    deposit-only account), without the paused-vault, caps-at-0, empty-`aeBalance` and garbage-hint
    cases or the native and web legs.
27. Items 5 and 6: no bug-bounty terms or budget are published (`security.txt` gives a contact
    only). If the audit has not started 14 days after launch (2026-10-12), item 5 has the guardian
    tighten `maxDeposit` to 0. `betaNoticeState` reads `pre_audit` and moves to `in_audit` at kickoff.

**Documentation drift (informational)**

28. The Solidity and `deployments.ts` cite an older numbering (`§6.3`–`§6.5`, `§7.1`, `§13`,
    `§14.n`, README "Spec questions"), mapped at the top of `docs/DARK-CB-1.md`; deployed comments
    cannot change without changing codehashes. Spec nits, mostly annotated in place: register gas
    "~2.5M" (§7) vs 3.72M total gasUsed, 3.44M L2 execution (§9); §10's license table predates the pins and calls everything
    dual-licensed (deploy scripts and Solidity tests are MIT); §6's "§12 replay/BSGS path" is §7
    steps 5–6; §3's "Corrected at the freeze (2026-09-20)" predates the 2026-09-27 freeze; §3's
    "nargo/bb 1.0.0-beta.22" (bb is 5.0.0-nightly.20260522). `circuits/VERSIONS.toml` says every
    committed `Prover.toml` has a non-identity `avail_d` (only transfer and withdraw have an `avail_d`
    field; register has none and disclose_range's is `d`, also non-identity), and `circuits/.gitignore`
    still lists `.dark-prove-*.toml`. §3's "mutation M29" (an SDK property test on hints) is not the
    runner's M29 ("`withdraw` does not lower `tvl`"): §16 ends at M28c, the runner goes on to M39d.
    §15's I13 says every input but `ct`/`amount` comes from storage, the registry or config; chain
    id, vault, `msg.sender` and `to` come from the call itself (by design; `to` is bound in the
    proof). The dark-sdk's state type names differ from §11–§14's (noted before §11).

## 8. Where we would like you to look hardest

1. **Proof ↔ public-input binding.** Each input must reach the verifier in the order and encoding
   the circuit expects, with the value the contract means: chain id, vault or registry, `msg.sender`,
   `to`, nonce, registry keys, stored `available`, caps. Compare the three inline arrays with
   `circuits/public_inputs.toml` and each circuit's `main`; look for replay across chains, vaults,
   accounts, recipients or nonces, and for caller-controlled inputs the proof does not pin.
2. **Ciphertext accounting and solvency.** `mulG` in `deposit` and `withdraw`, the transfer's
   subtraction and pending addition, `DarkGrumpkin.add` at the identity, doubling and P + (−P), and
   the `tvl` and `netInflow` bookkeeping: can any sequence of calls make the encrypted balances
   exceed the USDG held (I1, I2)?
3. **Pending transfers.** The pending/available split against front-running, `applyPending`'s
   lower-bound count, dust griefing, the recipient-handle constraint, `aeBalance` handling.
4. **Registration and key substitution.** Can anyone register or act under a key whose secret they
   do not know, or make `keyOf` return something other than what was proven?
5. **Caps and pause.** No role may block `withdraw`, `applyPending` or `register`; `tightenCaps`
   must only tighten and `setCaps` never exceed a ceiling (issue 18); extreme or inconsistent caps
   (issue 6).
6. **Circuit soundness.** Range checks (`assert_u48`, `u64` witnesses, `as_u64` on public inputs),
   the remainder relation, non-canonical scalars (issue 12), the identity as an input (issue 13),
   r ≢ 0 and s ≢ 0, curve checks, and anything that rests on the witness solver rather than on a
   constraint.
7. **Verifier and pin integrity.** That the deployed verifiers are bb's output for these circuits
   with ZK on and a keccak transcript, linked to the pinned libraries; that
   `scripts/check-verifier-bytecode.mjs` proves what it claims; that no deploy path could wire a
   different verifier.

## 9. Prior review

The code went through several internal adversarial review rounds and automated red-team passes.
No critical issue was found in the contracts or the circuits. Those rounds found and fixed issues
rated up to High in the SDK and in the deploy and pin tooling (for example, nothing tied the pin
file to `circuits/manifest.json` before `scripts/check-verifier-pins.mjs` existed); none rated High
was in the contracts or the circuits. Fixes from them that shipped before the freeze include the
`applyPending` pending-count lower bound in the vault (testnet redeploy of 2026-09-20) and an
SDK-side disclosure-verifier fix (§18b, 2026-09-18: a claim's shape must be bound to its kind). The
review records themselves are not public. The code has **not** had an independent audit: this is
the first.

## 10. Contact

Report security issues privately to **team@darkwallet.cash**; please do not open a public issue.
See [darkwallet.cash/.well-known/security.txt](https://darkwallet.cash/.well-known/security.txt).
