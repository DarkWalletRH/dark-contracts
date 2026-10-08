# DARK-CB-1 — Dark Confidential Balances v1

**Status:** **FROZEN 2026-09-27.** §3, §4 and §6 are fingerprinted and CI fails if they change — see *How to change this spec*. §19 was accepted on 2026-09-16; the findings of the three internal review rounds were folded in before the freeze.
**SPEC_VERSION** = `keccak256("DARK-CB-1")`

> **This published copy (2026-10-07).** The text is the frozen specification, prepared for publication: internal planning references, people and private file paths were removed or replaced with self-contained wording, and no normative statement was changed (so the wording of §3, §4 and §6 differs from the fingerprinted text only in those references and in the marked notes). Paragraphs marked *Implementation note (2026-10-07)* are additions: they record where the deployed code or later findings differ from the frozen text, and they do not amend it. The companion reports in this folder are `THREAT-MODEL.md`, `INVARIANTS.md`, `MUTATIONS.md` and `CIRCUITS-REPORT.md`.
>
> **Implementation note (2026-10-07): section citations in code.** The circuits cite this document's own numbering (`§3`, `§6`, `§19 C1`, `§19 X1`, …). The Solidity sources and `contracts/deployments/deployments.ts` use the numbering of an earlier draft, in which this specification was §6 and §7 of a larger, unpublished planning document: there, `§6.3`, `§6.4` and `§6.5` mean §3, §4 and §5 here, `§7.1` means §11, and README "Spec questions" in `DarkVault.sol` means §19. `§13` and `§14.n` in `contracts/deployments/deployments.ts` point into that planning document (its launch criteria and its list of open decisions); the facts they support are stated here (the beta notice, §18 item 5; MockUSDG as the testnet asset, §5; the owner and the guardian, §5 and §18 item 3). The dark-sdk (https://github.com/DarkWalletRH/dark-sdk) mixes both schemes: `§6.n` is §n here, `§7.1` and `§7.3` are §11 and §13, and `§7.7` and `§7.8` are steps 7 and 8 of §7. Paths of the form `packages/dark-sdk/…` in comments refer to the dark-sdk repository.

**Clean-room rule.** Nothing here comes from Ava Labs EncryptedERC or any fork of it. Nobody opens that repo. Design sources are the papers and permissive references in §10. No code is copied from any reference, including Solana zk-sdk and Anonymous Zether; we take ideas only.

## 1 · Overview

Every Dark account is an ordinary EOA, the wallet's existing account, plus a **Grumpkin privacy keypair derived on the device from that account's secret key**. After a one-time `register`, the account has two ciphertexts in `DarkVault`:
- **available**: spendable, and changed only by the owner;
- **pending**: incoming confidential transfers, which only the owner folds into available.

Both encrypt USDG micro-units. The vault holds the real USDG that backs them. There is no operator, relayer, holding wallet, ledger, or Dark-held key.

```
 public USDG ──approve(exact)+deposit(x)──▶ DarkVault.available[A] += Enc(x)                    (x public)
 DarkVault.available[A] ──transfer(proof)──▶ available[A] −= Enc_A(a) ; pending[B] += Enc_B(a)   (a hidden)
 DarkVault.pending[B]   ──applyPending()──▶ available[B] += pending[B] ; pending[B] = 0          (no proof)
 DarkVault.available[B] ──withdraw(x, to, proof)──▶ public USDG x → to                           (x public; never pausable)
 owner-made proof ──▶ darkwallet.cash/d/<id>#k=…  (ciphertext blob on api.darkwallet.cash; verified in the viewer's browser)
```

Every state-changing call requires `msg.sender == account`. Every spend also requires a SNARK proving three things:
- knowledge of the privacy key;
- correct encryption;
- a non-negative remainder.

A leaked Grumpkin key exposes amounts but cannot move funds. A leaked EOA key is a total loss for that account, because the Grumpkin key is derived from it.

**Non-goals for v1:**
- sender or recipient anonymity (no ring, no anonymity set);
- confidential ETH or any other token;
- relayers or gasless transactions;
- a global auditor key;
- transfers to unregistered addresses;
- privacy-preserving migration between vault versions;
- an ERC-7984 interface (possible later as a view layer, https://eips.ethereum.org/EIPS/eip-7984).

## 2 · What is and isn't hidden (the honest privacy properties; the app's user-facing wording derives from this)

**Encrypted:** USDG balances inside Dark, and the amounts of confidential transfers between two registered Dark accounts. **Everything else is public.**

| Party | Can learn | Cannot learn |
|---|---|---|
| **Anyone on-chain** | That A registered and A's public key. Every **deposit amount** and depositor. Every **withdraw amount**, withdrawer and destination. That A sent a confidential transfer to B, plus block, time and gas. B's pending count. Every account's nonce. Total USDG in `DarkVault` (TVL). **The exact balance of any account that has never used confidential transfers** (it is just deposits minus withdrawals). Lower bounds: a withdraw of x proves balance ≥ x; a transfer proves balance ≥ `minTransfer`. The caps bound every transfer amount. Amount and timing correlation (deposit 123.45, then withdraw 123.45 elsewhere). ETH, every other token, swaps, Stock Token trades | Confidential transfer amounts. The balance of an account that uses confidential transfers, beyond the bounds above. Transfer notes. `aeBalance`. The privacy secret |
| **Dark's servers** (api, worker, DO Postgres, Vercel, DO edge logs) | Everything public, plus request metadata: which accounts a client queries (address + IP at the HTTP layer); sign-in (address ↔ IP); RPC traffic through `/v1/rpc`, incl. every signed transaction and private-mode read, unless the user picks the public or a custom RPC (Settings → Network); disclosure uploads (which signed-in wallet uploaded a blob of what size, and when it was created, expired, revoked or fetched); **with private-payment notifications on, the link between a device's push token and its account, and when that account receives private payments**; the Stock Token residence attestation and IP country; agent chat text in transit to OpenAI (not stored). The `owner_hmac`/`account_hmac`/`wallet_hmac` columns use Dark-held keys over addresses anyone can list, so they protect only against a database-only leak, not against Dark | Balances, amounts, notes, disclosure contents (the key sits in the URL fragment and never reaches a server). Dark **cannot** move funds, block `withdraw`/`applyPending`, change verifiers or read keys. **No Dark or auditor key decrypts anything** (auditor key: none in v1, §1). Caveat: on the web, Dark serves the wallet code and the viewer code on every load, so a malicious or compromised Dark deploy could exfiltrate keys or `#k` (§17); the mobile apps and the open-source `dark-exit` tool don't depend on that |
| **Recipient of a transfer** | The amount and note of *that* transfer; the sender's address and the time; that the sender's balance was ≥ a at that moment | The sender's balance or other activity beyond what the public sees |
| **Sender of a transfer** | The amount it sent; that the recipient is registered; the recipient's pending count | The recipient's balance, or anything else it received |
| **Disclosure recipient** (holds `darkwallet.cash/d/<id>#k=…`) | Exactly the disclosed statement: an exact value or a range for one pinned ciphertext (a balance, `available` or `total`, at block B; one transfer; or a flow total over a block range), plus the account address, label and expiry. **With the address they can read everything already public about that account** (deposits, withdrawals, counterparties, ETH and tokens). **They can save and re-share it, and it stays mathematically valid forever.** Two balance disclosures at B and B′ together reveal the net confidential flow between them | The secret, other balances or amounts, future balances. A link grants no spend or view capability beyond the statement |
| **Dark team with admin keys** (owner `DarkTimelock`, guardian Safe) | Nothing extra | They cannot move funds or read balances. They can only pause `deposit`/`transfer`, tighten caps instantly (guardian), and raise caps after a 48 h timelock (owner), never above the immutable stage-2 ceilings |
| **Providers behind Dark's proxy** (Alchemy, Blockscout PRO, LI.FI, GMGN, CoinGecko, DexScreener, OpenAI chat, Expo push sender) | Query metadata for the addresses they serve. They see Dark's IP, not the user's; the query contents still name addresses. Expo's push service sees that a notification was sent and when; payloads never carry amounts or counterparties. OpenAI sees chat text, and public balances only if sharing is on; **agent tools never read the private balance** (v1) | Amounts or balances. Decryption happens only on the device |
| **Providers the device talks to directly** (they see the user's IP) | **OpenAI Realtime** (voice): the audio, the transcript and the device's IP, because WebRTC media and SDP go from the device to `api.openai.com`. **Google STUN** (`stun:stun.l.google.com:19302`): the device IP during a voice call (default: keep it and disclose; a self-hosted STUN on DO is the alternative). **Expo, APNs and FCM**: the device and its push token when the app obtains and refreshes it. **The public Robinhood RPC**: IP and queried addresses when the user picks it, when the app falls back to it, and for the `/d/<id>` viewer's browser `eth_call`s. **Vercel**: the IP of every visitor to darkwallet.cash and app.darkwallet.cash | Amounts or balances |
| **Chain operator** (Robinhood Chain) | Everything public, plus submitter IPs at its RPC. **It can censor or filter any transaction, including withdraws** (`ArbFilteredTransactionsManager`), and can upgrade the chain with no delay (https://l2beat.com/scaling/projects/robinhood) | Amounts or balances |
| **USDG issuer** | Everything public. It may be able to **freeze the `DarkVault` address**, which would freeze every account (assumed yes, and disclosed) | Amounts or balances |

**The deposit-only account.** `deposit` adds `(x·G, identity)` (§3), so an account whose `available` has only ever received public deposits and lost public withdrawals stores a ciphertext with no randomness: anyone can compute its exact balance. The SDK tracks this as `balancePublic` (true until the account's first confidential transfer in or out, including an applied pending transfer), and the app says so in plain words. Copy never says "only you can see this" about a balance while `balancePublic` is true.

**Things Dark does not claim.** Dark does not claim anonymity or unlinkability, and it does not claim to hide who pays whom or when. It is not a mixer: nothing is shuffled between users and there are no pooled notes. All balances are backed 1:1 by USDG held at one non-custodial contract address whose source is public (https://github.com/DarkWalletRH/dark-contracts). That is an accounting fact, and the app's copy must not deny it.

## 3 · Cryptographic building blocks (normative)

- **Curves.**
  - **BN254** is the proof system's curve (KZG; the pairing precompiles `0x06`/`0x07`/`0x08` are live on 4663, and `ecPairing("")` returned 1 on 2026-09-14).
  - **Grumpkin** is the encryption curve: `y² = x³ − 17` over F_r, where r = the BN254 scalar field = `21888242871839275222246405745257275088548364400416034343698204186575808495617`.
  - The Grumpkin group order n = the BN254 base field = `21888242871839275222246405745257275088696311157297823662689037894645226208583`. It is prime, so there is no cofactor.
- **Generators.**
  - `G` is Noir's embedded-curve generator `(1, 17631683881184975370165255887551781615748388533673675138860)`. CI asserts it equals `std::embedded_curve_ops` G at the pinned nargo.
  - `H` is nothing-up-my-sleeve. For i = 0, 1, …: x = `uint256(keccak256("DARK-CB-1/generator/H" ‖ u32be(i))) mod r`. The first x for which x³ − 17 is a square gives H = (x, √ with even LSB).
  - The dark-sdk's `src/grumpkin.ts` (`deriveH()`) computes it; `circuits/tools/gen_prover.mjs` re-derives it and refuses to build if `dark_lib`'s constant differs. Settled value: H.x = `0x1c670f693e0f1e5f2dd00c3fbf55c8e22af4ca3071dee49808899f9aa44d1024`, H.y = `0x2574095592574b6dedda035b4a88af623685e955658a73e5af0701ee23e282bc` (the spike used a different tag and so a different H; the spike is throwaway). It is hard-coded in `dark_lib::constants` and **derived at runtime** by the SDK (`grumpkin.ts`: `export const H = deriveH()`). `DarkGrumpkin.sol` does not carry it and does not need to — the contract validates points and adds ciphertexts componentwise, and never forms a commitment. **Corrected at the freeze (2026-09-20):** an earlier draft said the constant lived in three places and that CI diffed all three. It did not. `gen_prover.mjs` does not re-derive it, no CI step compared the circuit's constant with the SDK's, and `grumpkin.test.ts`'s "H is deterministic" imports both `H` and `deriveH` from the same module, so it proves the derivation is stable across two calls and pins nothing. A spec-check script is now that comparison — spec value against the circuit constant against what the SDK actually derives — and it runs in the maintainers' CI (the script is not part of this repository). Nobody knows log_G(H).
  - *Implementation note (2026-10-07):* in the published repositories the only derive-and-compare is `circuits/tools/gen_prover.mjs`, which imports the SDK's runtime-derived `H` and refuses to write the Prover.toml files if it differs from a literal copy of `dark_lib`'s constant (it does not read `lib.nr`, and CI never runs it because the Prover.toml files are committed), so the frozen sentence "`gen_prover.mjs` does not re-derive it" above no longer holds; `test_h_matches_sdk` in `circuits/lib/src/lib.nr` compares the constant (`dark_lib::H_X`/`H_Y` at the crate root; there is no `constants` module) with a literal copy of itself, and the dark-sdk's "H is deterministic" test is the self-comparison described above. The cross-check that runs in CI is the maintainers' spec check described above (not published; §19 K1). Checked by hand on 2026-10-07: `deriveH()` from the public dark-sdk returns exactly the H.x and H.y above, which equal `H_X` and `H_Y` in `circuits/lib/src/lib.nr`.
- **Point encoding.**
  - Points are `(x, y)` with x, y < r.
  - The **identity is the sentinel `(0,0)`**, which is not on the curve.
  - Every user-supplied point must pass all four checks: x < r, y < r, `y² = x³ − 17 mod r`, and not the sentinel. The canonicality check is critical: a non-canonical `x + r` must never pass.
  - In circuits the identity is the `(0,0)` sentinel (§19 X1); every non-identity input point is asserted on-curve.
- **Scalar encoding.** Circuit scalars are two 128-bit limbs, which bound a witness
  below 2²⁵⁶. The group order n is ~2²⁵⁴, so a witness of `s + n` passes the limb range checks and
  is still congruent to s — the limbs alone do **not** enforce canonicality. What rejects it is the
  proving backend: bb's Grumpkin MSM gadget refuses any scalar ≥ n at witness-solving time, before
  the prover runs. This is a real soundness dependency that lives **outside the circuit's own
  constraints**, and it is written here because it is invisible in the constraint listing.
  `dark_register::tests::test_neg_s_plus_n` pins it, and per `circuits/VERSIONS.toml` a toolchain
  bump is not cleared by a VK-hash diff alone — that test has to stay green.

  *Implementation note (2026-10-07):* the later analysis recorded in `circuits/VERSIONS.toml` differs from this paragraph. The rejection that `test_neg_s_plus_n` pins comes from nargo's ACVM solver, not from a bb constraint, so a prover who builds the witness by hand and calls bb directly never meets it. Canonicality is not constrained and does not need to be: s + n and s give the same group elements, so no false statement becomes provable. The guards that matter are the two that rule out a zero scalar, `assert_key` (s·P == H, so s ≢ 0 mod n) and the `!is_identity(ct_ds)` check in `dark_transfer` (so r ≢ 0 mod n). The test is kept as a solver regression check across toolchain bumps.
- **The identity as an operand.** Because `deposit` stores `(x·G, identity)`, a
  deposit-only account's first transfer or withdraw feeds the `(0,0)` sentinel into circuit point
  arithmetic as an **input**, not merely as the result of `P − P`. Noir's pinned `EmbeddedCurvePoint`
  carries no `is_infinite` flag, so the correctness of that case is the stdlib's, not ours. Verified
  on nargo/bb 1.0.0-beta.22 and pinned by
  `test_accepts_a_{transfer,withdraw}_from_a_deposit_only_account` plus the matching overdraft
  negatives. Same toolchain-bump rule applies.

  *Implementation note (2026-10-07):* per `circuits/VERSIONS.toml`, those tests run under nargo's ACVM solver only, and no bb proof covers the case (nargo 1.0.0-beta.22 with bb 5.0.0-nightly.20260522, `circuits/VERSIONS.toml`; "bb 1.0.0-beta.22" above is the nargo version). Every committed `Prover.toml` has a non-identity `avail_d`, so `circuits/tools/build.mjs`, `circuits/tools/check-manifest.mjs` and `circuits/evm/test/Verifiers.t.sol` never prove or verify a `(0,0)` MSM operand. The live end-to-end run proved a deposit-only transfer, not a deposit-only withdraw.
- **Twisted ElGamal with decrypt handles** (PGC https://eprint.iacr.org/2019/319 ; Solana Confidential Balances https://www.solana-program.com/docs/confidential-balances).
  - Secret s ∈ [1, n); public key **P = s⁻¹·H**, so that **s·P = H**.
  - Encrypt v ∈ [0, 2⁴⁸) with randomness ρ: **C = v·G + ρ·H**, **D = ρ·P**. Decrypt: **C − s·D = v·G**.
  - A transfer uses one commitment with two handles: **C_t = a·G + r·H**, **D_s = r·P_sender**, **D_r = r·P_recipient**.
  - The homomorphism is componentwise point addition, valid only under the same P. A public amount x is the ciphertext `(x·G, identity)`.
- **Amounts.**
  - USDG micro-units (6 dp). The circuit range is **[0, 2⁴⁸)**, about $281M.
  - `HARD_MAX_TVL = 250_000e6` (< 2³⁸) in the pre-audit v1 vault, so if the system is sound no honest balance reaches 2⁴⁸ and the range check never blocks an honest user.
- **Domain-separation tags** (ASCII, exact):

| Use | Tag |
|---|---|
| H derivation | `DARK-CB-1/generator/H` |
| HKDF salt | `darkwallet.cash/conf-bal/v1` |
| s derivation info | `DARK-CB-1/elgamal-s` ‖ u64be(chainId) ‖ u8(ctr) |
| AE key info | `DARK-CB-1/ae-key` ‖ u64be(chainId) |
| AE AAD | `DARK-CB-1/ae/v1` ‖ u64be(chainId) ‖ vault(20) ‖ account(20) |
| Hint KDF salt | `DARK-CB-1/hint/v1` |
| Hint info/AAD | u64be(chainId) ‖ vault(20) ‖ from(20) ‖ to(20) ‖ u64be(fromNonce) |
| Transfer randomness r (hedged) | `DARK-CB-1/transfer-r/v1` |
| Hint ephemeral k (hedged) | `DARK-CB-1/hint-k/v1` |
| DLEQ challenge | `DARK-CB-1/dleq/v1` |
| DLEQ hedged nonce | `DARK-CB-1/dleq-nonce/v1` |
| Disclosure context | `DARK-CB-1/disclose/v1` |
| Disclosure blob AAD | `DARK-CB-1/disclosure-blob/v1` ‖ id |

- **Fixed-size blobs.** The sizes are fixed so lengths never leak note sizes, and the contract enforces them.
  - **`aeBalance`** (56 B) = nonce(24) ‖ XChaCha20-Poly1305(k_ae, u64be(value) ‖ u64be(nonceAfter), AAD = AE AAD). It is an owner-only hint, and the client **always verifies** it: value·G == C − s·D.
  - **`hint`** (240 B, for the recipient) = R_e.x(32) ‖ R_e.y(32) ‖ nonce(24) ‖ XChaCha20-Poly1305(k_h, u64be(a) ‖ u8(noteLen) ‖ note[127], AAD = hint info).
    - The sender samples k, sets R_e = k·H and K = k·P_r, and derives k_h = HKDF-SHA256(K.x ‖ K.y, salt, info). The recipient recomputes K = (s_r⁻¹ mod n)·R_e.
    - **The hint is not proven in-circuit.** The recipient checks a·G == C_t − s_r·D_r and, on a mismatch, falls back to BSGS bounded by the `maxTransfer` in force at that transfer's block (§7 step 5). A lying sender therefore costs the recipient a sub-second search and cannot touch funds.
    - This deliberately deviates from the research sketch (an in-circuit Poseidon memo). It removes one variable-base multiplication, one MSM and a sponge from the pre-audit circuit.
  - **`senderHint`** (176 B) = nonce(24) ‖ XChaCha20-Poly1305(k_ae, u64be(a) ‖ u8(noteLen) ‖ note[127], AAD = hint info). It lets the sender rebuild its own history from the 12 words.
  - **Hint keys never come from r·H.** Since r·H = C_t − a·G, anyone could test candidate amounts; hint keys must come from an independent ECDH.
  - **k must never equal r.** If it did, R_e = k·H = C_t − a·G would let anyone test amounts over [`minTransfer`, `maxTransfer`], and K = k·P_r = r·P_r = D_r, which the event publishes, would hand everyone the hint key. So r and k use **different tags and different CSPRNG draws** (below), and the SDK asserts R_e ≠ C_t − a·G and K ≠ D_r before sending (a property test covers it; mutation M29). The hint is off-circuit, so no circuit test would catch this.
- **Randomness.** r, k and the DLEQ nonces are hedged: `HashToScalar(tag ‖ 32 fresh CSPRNG bytes ‖ s ‖ context)`, with the tag from the table above and a separate 32-byte draw for each of r and k; the context for r and k is (chainId, vault, from, to, fromNonce). HashToScalar is SHA-512 mod n, rejecting 0. The CSPRNG is `crypto.getRandomValues` (expo-crypto on native). r must never repeat, and the circuit enforces r ≠ 0.
  *Implementation note (2026-10-07):* the dark-sdk also hedges the XChaCha20-Poly1305 nonces of `aeBalance`, `hint` and `senderHint`: nonce = HMAC-SHA256(key, `DARK-CB-1/aead-nonce/v1` ‖ 32 fresh CSPRNG bytes ‖ AAD ‖ plaintext) truncated to 24 bytes (`src/hint.ts`). The tag is not in the table above; the nonce travels inside the blob and openers never recompute it, so the wire format is unchanged and §19 K8 still holds (every seal still consumes a fresh draw).

## 4 · Key hierarchy (frozen at the spec freeze; changing it after launch strands balances)

```
BIP39 12 words ──(the wallet's existing derivation, unchanged: ethers fromMnemonic, m/44'/60'/0'/0/0)
                   ──▶ sk (secp256k1, 32 B) ──▶ EOA = Dark account
raw imported key ─────────────────────────────────────────────────────────▶ sk
sk ──HKDF-SHA512-Extract(salt="darkwallet.cash/conf-bal/v1")──▶ PRK
PRK ──HKDF-Expand(info="DARK-CB-1/elgamal-s"‖u64be(chainId)‖u8(ctr), 64 B) mod n (reject 0; ctr++)──▶ s ; P = s⁻¹·H
PRK ──HKDF-Expand(info="DARK-CB-1/ae-key"‖u64be(chainId), 32 B)──▶ k_ae
per transfer: k (hedged) ──▶ R_e = k·H, K = k·P_r ──HKDF-SHA256──▶ k_h
```

This mirrors the pattern of Solana zk-sdk `derivation.rs` (Apache-2.0; a protocol-scoped salt and a 64-byte wide reduction), with no code copied.

- **The 12 words recover everything:** words → sk → account, s, P, k_ae → on-chain state → decryption. A raw-key import recovers only from that raw key.
- **chainId is in the info string**, so testnet and mainnet keys differ.
- **s and k_ae are never persisted.** They are derived after unlock and wiped on lock. **s is never exported**; there is no "share viewing key" feature.
- **Vectors.** The dark-sdk's `test/vectors/keys.v1.json` holds ≥ 8 vectors, including the BIP39 test mnemonic `abandon ×11 about` at chainIds 4663 and 46630 (mnemonic → sk → s → P → k_ae). They run in SDK CI, the Noir tests and Foundry.
  - *Implementation note (2026-10-07):* the published `keys.v1.json` holds 5 vectors. All of them start from a raw secret key (at chain ids 4663 and 46630) and none from a mnemonic, so the mnemonic → sk step is not covered by them. Only the dark-sdk's `test/keys.test.ts` reads the file; no Noir or Foundry test does.
- **Future external or hardware wallets** will need a signature-derived IKM and must refuse to sign any message starting with `DARK-CB-1/`. Not in v1.
- **Registration** (`DarkKeyRegistry.register(P, proof)`), once per address, by that address.
  - The proof is `dark_register`: knowledge of s with s·P = H, with public inputs chainId, the registry address and `msg.sender`. This stops key copying and front-run registration.
  - The registry rejects non-canonical, off-curve and identity points and second registrations. It has **no admin, no pause, no upgrade**. A future vault takes the registry address as a constructor parameter, so v2 reuses it **unless** the audit finds a problem in `dark_register`, its verifier or the key encoding; then a new registry ships with v2 and users re-register (the same derived P with a new proof, one extra transaction).
- **Rotation and loss.**
  - There is no in-place rotation in v1. To rotate, create a new account and confidential-transfer the balance to it in chunks ≤ `maxTransfer`. The old→new link is public; the amounts are hidden.
  - Lost phrase: the funds are unrecoverable (self-custody). A newly created phrase must pass the phrase quiz before onboarding completes, so before the wallet can hold anything.
  - Leaked s (but not sk): privacy is lost, funds are not; migrate.
  - Leaked sk: total loss for that account.
  - If the derived P ≠ the registry's P, the client **hard-stops** with `KEY_DERIVATION_MISMATCH`.

## 5 · Contracts (`contracts/`, Foundry, Solidity pinned at freeze, OZ 5.x)

| Contract | Role | Admin |
|---|---|---|
| `DarkKeyRegistry` | address → Grumpkin P, proof-of-knowledge verified | none (immutable, no owner) |
| `DarkVault` | USDG ↔ encrypted balances: deposit, applyPending, transfer, withdraw; caps; pause | owner = `DarkTimelock`, set in the constructor; guardian = the 1-of-2 guardian Safe, set in the constructor; `Ownable2Step` for any later owner change |
| `DarkTimelock` | an OZ `TimelockController` **instance** (no custom source), deployed by `DeployDark{Testnet,Mainnet}.s.sol` before the vault; 48 h delay; proposer = executor = canceller = the owner Safe (2-of-3 by default); **admin = `address(0)`** (otherwise an admin could grant itself proposer/executor and skip the delay); the team's off-chain monitor checks its role members and `getMinDelay()` | none |
| `DarkRegisterVerifier`, `DarkTransferVerifier`, `DarkWithdrawVerifier` | `bb write_solidity_verifier` output (ZK Honk, keccak), contract renamed only, never hand-edited (Apache-2.0 headers) | none |
| `IDarkVerifier` | `verify(bytes proof, bytes32[] publicInputs) → bool` (the bb verifier ABI) | n/a |
| `DarkGrumpkin` (lib) | clean-room canonical/on-curve checks, add, neg, sub, `mulG(amount < 2⁴⁸)` via a 12×15 precomputed window table in projective coordinates with one inversion (modexp `0x05`) | n/a |
| `DarkGrumpkinTables` (lib) | generated `j·16^i·G` constants (`script/gen_g_table.ts`; CI regenerates and diffs) | n/a |
| `DarkPublicInputs` (lib) | builds each circuit's `bytes32[]` in canonical order; code-generated from `circuits/public_inputs.toml` (also into the dark-sdk's `src/publicInputs.ts`) | n/a |
| `MockUSDG` | testnet only (6 dp, public `mint`) | n/a |

> **Implementation note (2026-10-07).** Two rows of this table were never built. `DarkGrumpkin.mulG` is plain Jacobian double-and-add over the 48 bits with one final inversion (modexp `0x05`), not the 12×15 window table, so there is no `DarkGrumpkinTables` library and no `script/gen_g_table.ts`; correctness is the same, and the gas in §9 is what this version costs. There is no `DarkPublicInputs` library either: `DarkKeyRegistry.register`, `DarkVault._transferInputs` and `DarkVault._withdrawInputs` build their arrays inline. `circuits/public_inputs.toml` is the machine-readable copy of that order, `circuits/tools/check-manifest.mjs` checks each circuit's compiled ABI against it, and the dark-sdk generates its encoder from it, but no automated check compares the contracts' inline arrays with the TOML; their agreement rests on real proofs verifying through the deployed contracts in the live end-to-end runs (§9, §18b). On testnet (46630) the guardian is the deployer EOA, not a Safe (`contracts/deployments/deployments.ts`).

**Upgradeability.** None: no proxy, no `selfdestruct`, no `delegatecall`, and no setter for verifiers, registry or USDG. New versions are redeployed.
- **Sunset of a version:** the guardian sets `maxDeposit = maxTransfer = 0` and pauses. `withdraw` and `applyPending` stay open forever.
- **Migration to v2** is user-initiated (withdraw from v1 → deposit into v2; **those amounts are public**, and the app says so). v2 takes the registry address as a constructor parameter and reuses `DarkKeyRegistry` unless a register-circuit fix ships a new one (§4).
- **Owner-key loss.** With a 2-of-2 owner Safe, losing one signer's key permanently freezes `unpause`, `setCaps` and `setGuardian` (never funds: exit stays open). The recovery is a new vault version and a public migration. Whether to move to 2-of-3 before mainnet was an open decision. *Implementation note (2026-10-07):* decided: the mainnet owner Safe is 2-of-3, and `DeployDarkMainnet.s.sol` refuses an owner Safe with fewer than 3 owners or a threshold below 2.

**Fees.** None. There is no fee, fee setter or fee recipient; users pay gas in ETH. Any fee needs a new version.

**Roles.**
- There is **no operator and no relayer. No role can move USDG.**
- The owner can only `setCaps` (within the hard ceilings), `setGuardian`, `unpause`, `recoverERC20` (any token except USDG), `pause`/`tightenCaps` (next bullet) and a two-step `transferOwnership`/`acceptOwnership` (`Ownable2Step`); a transfer proposed through `DarkTimelock` is public for 48 h, after which the new owner acts without a delay.
- The guardian or the owner can `pause` and `tightenCaps`.
- `renounceOwnership` reverts.

```solidity
// contracts/src/interfaces/IDarkVerifier.sol — matches the generated bb Honk verifier ABI
interface IDarkVerifier { function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool); }

// contracts/src/interfaces/IDarkKeyRegistry.sol
interface IDarkKeyRegistry {
    struct Point { uint256 x; uint256 y; }                       // canonical (< r); (0,0) = identity sentinel (never valid here)
    event KeyRegistered(address indexed account, uint256 px, uint256 py);
    error AlreadyRegistered(address account);
    error NotRegistered(address account);
    error InvalidPoint();                                         // non-canonical, off-curve, or identity
    error InvalidProof();
    function register(Point calldata publicKey, bytes calldata proof) external;   // caller = the account itself; not pausable
    function keyOf(address account) external view returns (Point memory);        // reverts NotRegistered
    function isRegistered(address account) external view returns (bool);
    function registerVerifier() external view returns (IDarkVerifier);
}

// contracts/src/interfaces/IDarkVault.sol — interface excerpt
interface IDarkVault {
    struct Point { uint256 x; uint256 y; }                        // (0,0) = identity
    struct Ciphertext { Point c; Point d; }                       // C = v·G + ρ·H, D = ρ·P
    struct TransferCt { Point c; Point dSender; Point dRecipient; }
    struct Caps {                                                 // micro-USDG
        uint64 minDeposit; uint64 maxDeposit; uint64 maxAccountInflow;
        uint64 minTransfer; uint64 maxTransfer; uint64 tvlCap;
    }
    struct AccountView {
        Ciphertext available; Ciphertext pending;
        uint64 nonce; uint64 pendingCount; uint128 netInflow; bytes aeBalance;   // aeBalance: 56 B or empty
    }

    // ---- account owner (msg.sender is the account; always registered; all four share one nonReentrant guard) ----
    function deposit(uint256 amount, bytes calldata aeBalance) external;                        // whenNotPaused
    function applyPending(uint64 expectedPendingCount, bytes calldata aeBalance) external;      // NEVER pausable
    function transfer(address to, TransferCt calldata ct, bytes calldata proof,
                      bytes calldata hint, bytes calldata senderHint, bytes calldata aeBalance) external;  // whenNotPaused
    function withdraw(uint256 amount, address to, bytes calldata proof, bytes calldata aeBalance) external; // NEVER pausable, no adjustable cap

    // ---- admin ----
    function setCaps(Caps calldata newCaps) external;       // owner (DarkTimelock, 48 h); <= hard ceilings; minTransfer >= 1
    function tightenCaps(Caps calldata newCaps) external;   // guardian or owner; every max-field <= current, every min-field >= current
    function setGuardian(address guardian) external;        // owner
    function pause() external;                              // guardian or owner — blocks deposit + transfer ONLY
    function unpause() external;                            // owner only
    function recoverERC20(address token, address to, uint256 amount) external;  // owner; reverts CannotRecoverUSDG if token == usdg

    // ---- views ----
    function getAccount(address account) external view returns (AccountView memory);
    function caps() external view returns (Caps memory);
    function tvl() external view returns (uint256);         // Σ deposits − Σ withdrawals (internal; donations excluded —
                                                            // USDG sent directly to the vault is therefore permanently
                                                            // unrecoverable, since recoverERC20 refuses USDG (I10))
    function usdg() external view returns (address);
    function registry() external view returns (IDarkKeyRegistry);
    function transferVerifier() external view returns (IDarkVerifier);
    function withdrawVerifier() external view returns (IDarkVerifier);
    function guardian() external view returns (address);
    function SPEC_VERSION() external pure returns (bytes32);      // keccak256("DARK-CB-1")
    // immutable ceilings of the pre-audit v1 vault = the stage-2 column; anything beyond needs a new, audited vault
    function HARD_MAX_TVL() external pure returns (uint64);             // 250_000e6
    function HARD_MAX_TRANSFER() external pure returns (uint64);        // 2_500e6
    function HARD_MAX_DEPOSIT() external pure returns (uint64);         // 2_500e6
    function HARD_MAX_ACCOUNT_INFLOW() external pure returns (uint64);  // 10_000e6

    // ---- events: every event carries post-state ciphertexts so the indexer can rebuild any account at any block ----
    event Deposited(address indexed account, uint64 nonceAfter, uint256 amount, uint256[4] availableAfter, uint128 netInflowAfter, uint256 tvlAfter);
    event PendingApplied(address indexed account, uint64 nonceAfter, uint64 appliedCount, uint256[4] availableAfter);
    event ConfidentialTransfer(address indexed from, address indexed to, uint64 fromNonceAfter,
        uint256[6] transferCt /* C.x,C.y,Ds.x,Ds.y,Dr.x,Dr.y */, uint256[4] fromAvailableAfter,
        uint256[4] toPendingAfter, uint64 toPendingCountAfter, bytes hint, bytes senderHint);
    event Withdrawn(address indexed account, address indexed to, uint64 nonceAfter, uint256 amount, uint256[4] availableAfter, uint128 netInflowAfter, uint256 tvlAfter);
    event CapsUpdated(Caps oldCaps, Caps newCaps, address indexed by);          // setCaps and tightenCaps
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    // plus OZ Paused(address), Unpaused(address), OwnershipTransferStarted/OwnershipTransferred

    error NotRegistered(address account);        error RecipientNotRegistered(address to);   error SelfTransfer();
    error InvalidPoint();                        error InvalidProof();                       error AmountZero();
    error AmountTooLarge();                      // >= 2^48
    error BelowMinDeposit(uint256 amount, uint256 min);
    error ExceedsDepositCap(uint256 amount, uint256 cap);
    error ExceedsAccountInflowCap(uint256 inflowAfter, uint256 cap);
    error ExceedsTvlCap(uint256 tvlAfter, uint256 cap);
    error UnexpectedTransferAmount(uint256 expected, uint256 received);   // balance-delta guard
    error PendingChanged(uint64 expected, uint64 actual);
    error BadBlobLength(uint256 got, uint256 expected);                   // aeBalance 56/0, hint 240, senderHint 176
    error ExceedsHardCeiling();  error NotTightening();  error NotGuardian();  error ZeroAddress();
    error CannotRecoverUSDG();   error RenounceDisabled();
}
```

**Storage per account.** `available` and `pending` (8 words); `nonce` (u64) ‖ `pendingCount` (u64) ‖ `netInflow` (u128) packed in one slot; `aeBalance` (a length slot plus 2 data slots when 56 B). Globals: `tvl` and `caps`. Contracts never use `block.number`, which returns an L1 estimate on Arbitrum chains (https://docs.robinhood.com/chain/differences-from-ethereum/).

**Constructor** `(usdg, registry, transferVerifier, withdrawVerifier, owner, guardian, initialCaps)`:
- asserts `IERC20Metadata(usdg).decimals() == 6`;
- on chainId 4663, asserts `usdg == 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`;
- asserts the two verifiers are distinct and have code;
- asserts the caps are within the hard ceilings.

The verifiers' runtime codehash is checked against `contracts/deployments/verifier-codehashes.json` by the deploy script and by the team's off-chain monitor, not in the constructor, because a constructor check would be circular with the build.

The pin file is keyed by chain id and holds, per contract, `address` + `codehash` (plus `verifierSolSha256` tying the three verifiers back to `circuits/manifest.json`). `DeployDarkTestnet.s.sol` fails closed before `startBroadcast`: for each of `DarkRegisterVerifier`, `DarkTransferVerifier`, `DarkWithdrawVerifier` the env-supplied address must equal the pinned address (`UnpinnedVerifier`) and the live `extcodehash` at it must equal the pinned hash (`VerifierCodehashMismatch`); `RelationsLib` and `ZKTranscriptLib` are code-checked the same way with no env address, because a library swapped at its pinned address changes verification without changing any verifier's codehash (§19 X4). There is no entry for `block.chainid` ⇒ the script reverts. `DARK_CODEHASH_PIN` overrides the file path for tests only; it is not a trust boundary against the deployer, who can edit the file — the independent check is the team's off-chain monitor comparing the committed file with chain.

*Implementation note (2026-10-07):* `DeployDarkMainnet.s.sol` applies the same gate. Anyone can repeat the comparison with chain using `cast codehash`. In CI, `scripts/check-verifier-bytecode.mjs` rebuilds every pinned contract from this source and requires its codehash to equal the pin; it compares against the committed pins, not against live chain state.

| Function | Caller | Paused? | Checks (in order) | Effects |
|---|---|---|---|---|
| `register(P, proof)` (registry) | account | n/a (never pausable) | not yet registered; P canonical, on-curve, not identity; `verify(proof, [chainId, registry, msg.sender, P.x, P.y])` | `keyOf[msg.sender] = P`; `KeyRegistered` |
| `deposit(x, ae)` | account | **blocked** | `nonReentrant`; registered; `ae.length ∈ {0,56}`; `x ≥ minDeposit`; `x ≤ maxDeposit`; `netInflow + x ≤ maxAccountInflow`; `tvl + x ≤ tvlCap`; `x < 2⁴⁸` | `safeTransferFrom(sender → vault, x)` with the balance-delta guard (interaction first, deliberately; the shared guard stops an upgradeable-USDG hook re-entering any account function mid-deposit); `available.c += mulG(x)`; `netInflow += x`; `tvl += x`; `nonce++`; `aeBalance = ae`; `Deposited` |
| `applyPending(expected, ae)` | account | **allowed** | `nonReentrant`; registered; `pendingCount >= expected` (else `PendingChanged`) — a **lower bound**, so a late transfer folds in instead of griefing the call; `ae.length ∈ {0,56}` | `available += pending`; `pending = identity`; `pendingCount = 0`; `nonce++`; `aeBalance = ae`; `PendingApplied(…, appliedCount = the count actually folded in, …)` |
| `transfer(to, ct, proof, hint, sHint, ae)` | account | **blocked** | `nonReentrant`; sender and `to` registered; `to ≠ sender`; blob lengths 240/176/(0 or 56); `ct.c`, `ct.dSender`, `ct.dRecipient` canonical, on-curve, not identity; `transferVerifier.verify(proof, pi)`, where **every public input except `ct` comes from storage, the registry or config** (chainId, `address(this)`, sender, `to`, sender nonce, P_s, P_r, sender `available`, `minTransfer`, `maxTransfer`) | `available_s.c −= ct.c`; `available_s.d −= ct.dSender`; `pending_to.c += ct.c`; `pending_to.d += ct.dRecipient`; `pendingCount_to++`; `nonce_s++`; `aeBalance_s = ae`; `ConfidentialTransfer` |
| `withdraw(x, to, proof, ae)` | account | **allowed** | `nonReentrant`; registered; `0 < x < 2⁴⁸`; `to ∉ {0, vault}`; `ae.length ∈ {0,56}`; `withdrawVerifier.verify(proof, pi)` with `pi` from storage (chainId, vault, account, `to`, nonce, P, available, x). **No adjustable cap** | `available.c −= mulG(x)`; `tvl −= x` (checked; underflow reverts); `netInflow = max(0, netInflow − x)`; `nonce++`; `aeBalance = ae`; then `safeTransfer(to, x)` (CEI); `Withdrawn` |
| `setCaps` | owner (timelock) | n/a | `maxDeposit ≤ HARD_MAX_DEPOSIT`, `maxAccountInflow ≤ HARD_MAX_ACCOUNT_INFLOW`, `maxTransfer ≤ HARD_MAX_TRANSFER`, `tvlCap ≤ HARD_MAX_TVL`; `1 ≤ minTransfer` | `caps = new`; `CapsUpdated` |
| `tightenCaps` | guardian or owner | n/a | each max-field ≤ current, each min-field ≥ current | `caps = new`; `CapsUpdated` |
| `pause` / `unpause` | guardian or owner / owner | n/a | OZ | affects `deposit` and `transfer` only |
| `recoverERC20` | owner | n/a | `token ≠ usdg`; `to ≠ 0` | transfers a stray non-USDG token |

**Why only these caps exist.**
- An encrypted balance cannot be capped on-chain without a proof on receipt. A proof on `applyPending` would cost about 2.4M gas and could block exit.
- So the enforceable per-account cap is **net public inflow** (`maxAccountInflow`), alongside per-transaction caps on deposit and transfer and the global `tvlCap`.
- Per-account caps are sybil-able. **The TVL cap is the real loss bound.**
- `withdraw` deliberately has no guardian-adjustable cap (a locked design decision). Whether to add an immutable global outflow rate limit was an open decision (default: none). *Implementation note (2026-10-07):* v1 has none.

**Defaults and caps** (micro-USDG in the contract). **Mainnet launched above the beta column, by team decision** (2026-09-28): max deposit 1,000 · max inflow per account 2,500 · max transfer 1,000 · `tvlCap` 50,000 USDG, as hard-coded in `DeployDarkMainnet.caps()` and pinned by `contracts/test/DeployDarkMainnet.t.sol`. No script checks caps against the beta column.

| Cap | Testnet (MockUSDG) | **Mainnet beta (pre-audit)** | After the audit report is resolved (stage 2) | Hard ceiling (immutable, v1) |
|---|---|---|---|---|
| `minDeposit` | 1 | **1 USDG** | 1 USDG | — |
| `maxDeposit` (per tx) | 2,500 | **250 USDG** | 2,500 USDG | `HARD_MAX_DEPOSIT` 2,500 USDG |
| `maxAccountInflow` (net public inflow per account) | 10,000 | **1,000 USDG** | 10,000 USDG | `HARD_MAX_ACCOUNT_INFLOW` 10,000 USDG |
| `minTransfer` | 0.01 | **0.01 USDG** | 0.01 USDG | ≥ 1 micro-unit |
| `maxTransfer` (per tx) | 2,500 | **250 USDG** | 2,500 USDG | `HARD_MAX_TRANSFER` 2,500 USDG |
| `tvlCap` | 250,000 | **25,000 USDG** | 250,000 USDG | `HARD_MAX_TVL` 250,000 USDG |
| withdraw | uncapped | **uncapped (exit is never blocked)** | uncapped | — |

The v1 vault's immutable ceilings equal the stage-2 column, so "caps rise only after the audit" is enforced by bytecode past stage 2, not only by policy: anything beyond stage 2 needs a new, audited vault version (and a public migration). The raise from beta to stage 2 follows the post-audit rule of §18 item 7 and runs through `DarkTimelock` (48 h public delay); the testnet caps sit at the ceilings so the same bytecode is exercised.

*Implementation note (2026-10-07):* `DeployDarkTestnet.s.sol` sets the testnet `minDeposit` to 1 micro-unit (0.000001 MockUSDG), not 1 USDG; the other testnet values match the table. `withdraw` emits `Withdrawn` before the `safeTransfer`, not after it as the effects column above suggests (`contracts/src/DarkVault.sol`); the CEI property is unchanged.

## 6 · Circuits (`circuits/`, Noir workspace)

The crates are `dark_lib` (shared), `dark_register`, `dark_transfer`, `dark_withdraw` and `dark_disclose_range` (off-chain only). Each circuit's artifacts are ACIR JSON, a VK, a Solidity verifier (on-chain circuits only), and a SHA-256 of the ACIR **`bytecode` field** in `circuits/manifest.json` (not of `target/<pkg>.json`, which carries debug symbols and a file map that change with the directory nargo ran in, so it is not reproducible).

Versions are pinned in one file, `circuits/VERSIONS.toml`: nargo, bb, `@aztec/bb.js`, `@noir-lang/noir_js`, noir-rs/barretenberg-rs, mopro. CI (`.github/workflows/ci.yml`, job `circuits`) installs that nargo/bb pair at the pinned versions and then: runs `nargo test --workspace`; recompiles every circuit and fails on any drift in the committed ACIR hash, **VK hash**, gate count, opcode count, generated-verifier hash or public-input order (`circuits/tools/check-manifest.mjs`); and runs the generated Solidity verifiers against the committed proof fixtures (`forge test --root circuits`). Any VK mismatch fails the build.

*Implementation note (2026-10-07):* `circuits/VERSIONS.toml` pins nargo, bb, `@aztec/bb.js` and `@noir-lang/noir_js`. It has no noir-rs/barretenberg-rs or mopro entry, because native proving does not use them (next paragraph).

Not in CI yet: proving each circuit with bb.js as well as the bb CLI, and verifying against the **deployed verifier bytecode** on an anvil fork. noir-rs is not a target at all — native proving runs bb.js in a WebView instead.

*Implementation note (2026-10-07):* this is still true of this repository's CI. What CI does is rebuild every deployed contract, the verifiers and their libraries included, and require each runtime codehash to equal its pin (`scripts/check-verifier-bytecode.mjs`), while `circuits/evm/test/Verifiers.t.sol` verifies real proofs against the generated verifiers. No CI job submits a proof to the deployed bytecode itself.

**The public-input order is normative.** It is generated from `circuits/public_inputs.toml` into both `DarkPublicInputs.sol` and the dark-sdk's `src/publicInputs.ts`. (*Implementation note (2026-10-07):* `DarkPublicInputs.sol` was never built; see the note under §5's table.)

**Scalars are limb pairs, never a single `Field`.** The Grumpkin group order n is the BN254 base field, which is *larger* than Noir's `Field` modulus, so no Grumpkin scalar fits in one `Field`. Every scalar (`s`, `r`) in every circuit is a 128-bit lo/hi limb pair with both limbs range-asserted.

**`dark_lib` rules, applied in every circuit:**
- every non-identity input point is asserted on-curve;
- the identity is the `(0,0)` sentinel (nargo 1.0.0-beta.22 has no `is_infinite` field, §19 X1): a stored ciphertext component is asserted **on-curve or identity**, a key is asserted **on-curve and not identity**;
- point add/sub uses the complete std operation;
- range checks are `u64` casts plus `assert(x < 2^48)`;
- every binding public input appears in a non-removable constraint. Inputs with an in-circuit relation get a `nargo test` negative test; the pure domain separators (`chain_id`, `vault`/`registry`, `sender`, `recipient`, `account`, `to`, `nonce`, `context_hash`) have nothing in-circuit to contradict — they are bound by Honk's public-input delta, so their negative test lives against the generated verifier (`circuits/evm/test/Verifiers.t.sol`).

The gate budget is ≤ 2¹⁶ per circuit. **Measured 2026-09-16** (`bb gates`, nargo 1.0.0-beta.22 + bb 5.0.0-nightly.20260522): C1 3,586 · C2 7,724 · C3 5,767 · C4 5,112 — the largest is 11.8 % of budget, so it does not bind. Wire public inputs 5 / 21 / 12 / 9; the VK's `publicInputsSize` is always wire + 8 pairing-point limbs (§19 X2). Verify gas 2.21M / 2.29M / 2.28M.

| Circuit | Public inputs (canonical order) | Private | Constraints | Estimate |
|---|---|---|---|---|
| **C1 `dark_register`** (on-chain, once) | `[0] chain_id, [1] registry, [2] account, [3] pk.x, [4] pk.y` (5) | `s` (lo/hi limbs) | pk on-curve, not identity; s ≠ 0; **s·pk == H**; binding inputs used | 1 variable-base mult; ~4–6k gates (2¹³) |
| **C2 `dark_transfer`** | `[0] chain_id, [1] vault, [2] sender, [3] recipient, [4] sender_nonce, [5,6] pk_s, [7,8] pk_r, [9..12] avail (C.x,C.y,D.x,D.y), [13,14] ct_c, [15,16] ct_ds, [17,18] ct_dr, [19] min_transfer, [20] max_transfer` (21) | `s` (lo/hi limbs), `r` (lo/hi limbs), `a` (u64), `w` (u64 = balance − a) | (1) pk_s and pk_r on-curve, not identity; avail on-curve or identity. (2) s ≠ 0 and **s·pk_s == H**. (3) r ≠ 0, enforced as `ct_ds != identity` (non-zero limbs can still reduce to 0 mod n; since n is prime and pk_s is not the identity, `r·pk_s == identity` iff `r ≡ 0 mod n`). (4) **ct_c == a·G + r·H**. (5) **ct_ds == r·pk_s** and **ct_dr == r·pk_r** (the second stops a sender from polluting and freezing the recipient's pending). (6) `min_transfer ≤ a ≤ max_transfer`, a < 2⁴⁸. (7) **(avail.C − ct_c) − s·(avail.D − ct_ds) == w·G** with 0 ≤ w < 2⁴⁸ (full-balance w = 0 gives identity). (8) binding inputs used | 4 variable-base mults + 1 two-point fixed MSM + 1 short fixed-base mult + ranges; ~18–30k gates (2¹⁵; worst case 2¹⁶) |
| **C3 `dark_withdraw`** | `[0] chain_id, [1] vault, [2] account, [3] to, [4] nonce, [5,6] pk, [7..10] avail, [11] amount` (12) | `s` (lo/hi limbs), `w` | pk on-curve, not identity; avail on-curve or identity; s ≠ 0, **s·pk == H**; 1 ≤ amount < 2⁴⁸; **(avail.C − amount·G) − s·avail.D == w·G**, 0 ≤ w < 2⁴⁸; binding inputs (including `to`) used | ~9–14k gates (2¹⁴) |
| **C4 `dark_disclose_range`** (off-chain; verified in the browser with bb.js; never deployed) | `[0] context_hash, [1,2] pk, [3,4] c, [5,6] d, [7] lo, [8] hi` (9) | `s` (lo/hi limbs), `v` | on-curve checks; **s·pk == H**; **c − s·d == v·G**; lo ≤ v ≤ hi < 2⁴⁸; context_hash used | ~9–14k gates (2¹⁴). Covers "balance ≥ X", "≤ X", "in [X,Y]", and flow totals over the viewer-recomputed sum ciphertext |

**Exact disclosure uses DLEQ, not a circuit** (`@darkwalletrh/dark-sdk/disclosure`, `src/disclosure.ts` in the dark-sdk; Chaum–Pedersen per RFC 9497 §2.2, https://www.rfc-editor.org/rfc/rfc9497.html).
- **Statement:** for public (G, H, P, C, D, v, ctx) with T = C − v·G, there exists s with **s·P = H ∧ s·D = T**.
- **Prover:**
  1. k = hedged nonce; A1 = k·P, A2 = k·D.
  2. **c = HashToScalar("DARK-CB-1/dleq/v1" ‖ G ‖ H ‖ P ‖ C ‖ D ‖ u64be(v) ‖ ctx ‖ T ‖ A1 ‖ A2)**. Every statement element and every prover message is hashed (the Solana "phantom challenge" lesson, https://blog.zksecurity.xyz/posts/solana-phantom-challenge-bug/).
  3. z = k − c·s mod n. The proof is (c, z), 64 B.
- **Verifier:** A1′ = z·P + c·H, A2′ = z·D + c·T; accept iff c == HashToScalar(… A1′ ‖ A2′).
- If D is the identity, the verifier just checks C == v·G. Points are hashed as 64-byte x ‖ y, and the identity as 64 zero bytes.

**Front-running and staleness (why pending exists).**
- A spend proof commits to the sender's exact `available` and `nonce`, both read from storage. **Only the owner can change its own `available`**, so nobody else can invalidate an owner's in-flight proof. This is the Zether front-running problem (https://eprint.iacr.org/2019/191), solved with Solana's pending/available split.
- Incoming transfers only touch `pending`, which no proof references, and `withdraw` never depends on `pending`.
- `applyPending(expected…)` treats `expected` as a **lower bound**: it reverts `PendingChanged` only when the account holds *fewer* pending transfers than the caller accounted for, which only a stale read can produce. A transfer that lands after the owner built its `aeBalance` folds in instead of reverting, so nobody can grief the call by paying gas plus ≥ `minTransfer` to bump the count. The fold is exact — `pending` is a ciphertext accumulator and the count is not an arithmetic input — and the only casualty is that `aeBalance` then under-reports by the late amount. The client always checks `value·G == C − s·D` before believing `aeBalance` (§3), so it detects that and falls back to the §12 replay/BSGS path, exactly as for an empty `aeBalance`. (*Implementation note (2026-10-07):* "§12" here means the replay/BSGS path of §7 steps 5–6 of this document.)
- The client serializes owner actions per account, one in flight.

## 7 · Client flows (`DarkClient` in the SDK; `DarkProvider`/`useDark` in the app; `DarkProver` implementations)

**Provers.**
- `NativeDarkProver` (mopro/noir-rs UniFFI Swift/Kotlin in a local Expo Module; background thread; dev client required).
- `WebDarkProver` (the dark-sdk's `src/prover/web.ts`: bb.js + noir_js in a Worker; multithreaded under COOP/COEP on `app.darkwallet.cash`, with a single-thread fallback).
- `NodeDarkProver` (CI and the end-to-end smoke tests).

*Implementation note (2026-10-07):* `NativeDarkProver` was never built. As §6 says, the Android app proves with `WebDarkProver` inside a WebView, and dark-exit's offline page uses `WebDarkProver` too; the dark-exit CLI uses `NodeDarkProver`. Because bb accepts the SRS only in whole 4 MiB chunks, the bundled SRS slice is 2¹⁷ G1 points plus G2, not the 2¹⁶ + 1 stated below; it is still bundled and pinned by SHA-256 (`circuits/srs/MANIFEST.json`, `circuits/tools/extract-srs.mjs`).

Every prover returns `{proof, publicInputs, ms}`. **The SDK re-derives the public inputs and rejects the proof on any mismatch**, then simulates with viem `simulateContract` before sending. Artifacts and the SRS slice (2¹⁶ + 1 G1 points plus G2) are bundled and hash-pinned against `manifest.json`, never fetched from Aztec's CRS host.

0. **Sync.** Read `getAccount(A)`, `caps()`, `tvl()` and `registry.keyOf(A)` at one block (Multicall3) via the transport chosen in Settings → Network (Dark relay `/v1/rpc` by default; the public Robinhood RPC or a custom RPC otherwise), falling back to the public RPC automatically when the relay fails. Derive s and check s·P == H. If SDK `deployments[chainId]` holds zero addresses, stop at `not_deployed` (§11).
1. **Register** (first open of the Private tab): derive s and P → prove `dark_register` → simulate → send `register` → receipt → cache. Needs about 2.5M gas of ETH (about $0.50), and the UI says so. (*Implementation note (2026-10-07):* §9 measured 3.72M gas for `register`.)
2. **Deposit x (public).**
   1. Show the headroom (`maxDeposit`, `maxAccountInflow − netInflow`, `tvlCap − tvl`).
   2. `ae = seal(k_ae, balance + x, nonce + 1)`.
   3. `USDG.approve(vault, x)`, **exact**.
   4. Simulate and send `deposit(x, ae)`.
   5. Soft-confirm in under 1 s, then show "finalizing" until L1-final (~13 min after the batch posts).
   6. Refresh from `Deposited.availableAfter`. The deposit is labelled **public**. The phrase quiz (§4) must have passed.
3. **Private transfer a → B.**
   1. B must be registered; if not, offer an "invite to Dark" link and **never fall back silently to a public transfer**.
   2. If available < a and pending is non-empty, `applyPending` first.
   3. Decrypt b and require `minTransfer ≤ a ≤ min(b, maxTransfer)`.
   4. Sample r; compute C_t, D_s, D_r and w = b − a.
   5. Prove `dark_transfer` (≤ 3 s mid-range Android, ≤ 10 s browser).
   6. Build `hint` and `senderHint`, and `ae = seal(w, nonce + 1)`.
   7. Simulate and send.
   8. Confirmation: "Sent privately. The amount is encrypted on-chain. The fact that you paid B is public."
   A stale nonce or available triggers a rebuild. Transfers are never auto-approved.
4. **Withdraw x to any address (default: own).** Decrypt b; require x ≤ b; prove `dark_withdraw`; `ae = seal(b − x)`; send. The UI warns that the amount and destination are public. It works while the vault is paused.
5. **Balance decryption** (normative; the bounds never depend on the *current* caps, which the guardian can lower to 0 at any time, so exit keeps working in exactly the paused and tightened state the guarantee is about).
   - Available: open `aeBalance` and check value·G == C − s·D. If that fails, replay history (step 6). As a last resort, run BSGS bounded by **`tvl()`**, the vault's real liability (balance ≤ tvl if the system is sound), **never by `tvlCap`**: a 2¹⁶-entry table and about 2¹⁹ steps at the $25k beta TVL; at the $250k v1 ceiling about 2²² steps as a lo/hi split BSGS in the prover worker. **The bound is clamped to the contract's immutable ceiling (`HARD_MAX_TVL`, and `HARD_MAX_TRANSFER` for the per-transfer case) before it is used.** `tvl()` and `maxTransfer` arrive over the same transport §2 says may serve wrong data, and BSGS time is linear in the bound: an absurd value does not produce a wrong balance, it produces a client that never finishes decrypting one — hanging the exact self-rescue this section promises. The ceiling is a local constant, never read from the chain, because reading it would ask the untrusted transport for the number meant to police it.
   - Pending: Σ verified hint amounts since the last `PendingApplied`, checked against pending; a failed or lying hint falls back to a per-transfer BSGS bounded by **the `maxTransfer` in force at that transfer's block** (from `CapsUpdated` history; `HARD_MAX_TRANSFER` if unknown), never the current cap (≤ 2³² at the v1 ceiling, well under 1 s).
   - Decrypted values never leave the device. The UI never shows a stale number; it shows "—" plus retry.
   - **Drill (end-to-end smoke test):** caps tightened to 0 + paused + `aeBalance` empty + one garbage-hint 0.01 USDG transfer sitting in pending + indexer down → the app still applies pending and withdraws the full balance.
6. **History reconstruction.**
   - Merge `Deposited`/`Withdrawn`/`PendingApplied` for A and `ConfidentialTransfer` with `from = A` or `to = A` by (block, logIndex), taken from `/v1/dark/accounts/:address/events`, with direct `eth_getLogs` (vault/registry address + the account topic, paged by halving on the 10,000-log error) via `/v1/rpc` or the public RPC as the fallback.
   - Sent amounts come from `senderHint` and received amounts from `hint`, each verified, with BSGS as the fallback.
   - The replayed balance must equal the on-chain decryption. **A server that omits events is detected**, and the client switches to direct RPC (a one-account replay from `deployBlock` finishes in under 30 s).
7. **Create a disclosure.**
   1. Pick a kind: `balance_exact`/`balance_range` at block B (default: the latest `safe` block) with `component` = `available` or `total` (`total` is the homomorphic sum available + pending, valid because both are under P; the viewer recomputes it); `transfer_exact` (tx hash, role); `flow_total_exact`/`flow_total_range` over [B1, B2] (direction, optional counterparty).
   2. Add a label (≤ 64 chars) and an expiry (default 30 days, maximum 365).
   3. Build the proof: DLEQ for exact kinds, `dark_disclose_range` on the device for range kinds. For flow totals, the ciphertext is the homomorphic sum of **all** matching handles in the range, which the viewer recomputes itself, so omissions fail verification.
   4. `context_hash = keccak256(abi.encode(...)) mod r` over the fixed 19-member tuple pinned in §18b W1.
   5. The document `DarkDisclosureV2 {v:2, chainId, vault, registry, account, kind, component?, block|blockRange, txHash?, role?, direction?, counterparty?, pk, c, d, claim:{value|lo,hi}, proof, contextHash, label, createdAt, expiresAt, id, ownerSig}`. **This list and the `context_hash` preimage (§18b, row W1) name the same context members**: `id`, `role`, `direction` and `counterparty` are in the document so the viewer can rebuild the preimage; `registry` and `label` are in the preimage so the document cannot restate them. The remaining document fields are bound elsewhere — `claim` *is* `lo`/`hi`, `pk`/`c`/`d` are checked against chain, `v` is bound by the tuple's tag, and `proof`/`contextHash`/`ownerSig` are the proof machinery itself. `ownerSig` is the **EIP-712** signature of §8; a cross-implementation test vector (SDK vs viewer) pins every field.
   6. Generate a random 32-byte K_link and encrypt: blob = XChaCha20-Poly1305(K_link, doc, AAD = `DARK-CB-1/disclosure-blob/v1` ‖ id), at most **65,536 bytes of ciphertext** (the decoded size; the API enforces it after base64 decoding).
   7. `POST /v1/disclosures {id, blob, expiresAt, revokeTokenHash}` (SIWE) → `{id}`. The revoke token is 32 random bytes kept on the device. The **client** mints the id (§18b W5) and sends it — the id is inside the signed document and is the blob's AEAD associated data, so the server cannot assign one afterwards; the response echoes it, and a duplicate id is refused (409) rather than overwritten.
   8. The link is **`https://darkwallet.cash/d/<id>#k=<base64url(K_link)>`**. Testnet ids start with `t_`. The fragment never reaches a server.
   9. K_link, the revoke token and the label are stored in the vault under `darkwallet.disclosures.<chainId>.<account>`.
8. **Viewer** (`darkwallet.cash/d/$id`, client-rendered).
   1. `GET https://api.darkwallet.cash/v1/disclosures/:id` (or `api-testnet.` for `t_` ids) returns 200 with the blob, 410 or 404.
   2. Decrypt with `#k`.
   3. Check `registry.keyOf(account) == pk`, and that (c, d) equals the ciphertext at B from **two sources**: api `/v1/dark/accounts/:address/ciphertext?block=B`, and a browser `eth_call` at B against the public RPC (for `component = total`, the viewer adds available + pending itself). For transfer and flow kinds, recompute from logs.
   4. Check the proof (DLEQ with noble; range with bb.js using the bundled VK; single-thread is fine, so darkwallet.cash needs no COOP/COEP), then `context_hash`, `ownerSig` (over the JCS form) and `expiresAt`. The rendered statement names the component ("available balance" or "total incl. pending") and the address caveat.
   5. Render one of the states: **Verified (independent)** (both sources agree), **Verified by Dark's archive only** (the public RPC lacks archive state), **Public balance — not proof of ownership**, **Invalid**, **Expired**, **Revoked or not found**, **Unsupported version**.
   6. **The `public_balance` state is normative, not cosmetic.** When the disclosed ciphertext has `d = identity` the balance is already public to anyone with the address (§2, the deposit-only account) and the proof over it demonstrates no knowledge of the privacy secret — so a stranger can mint such a link against a victim's address. The viewer MUST NOT show the word "Verified", a checkmark, or any ownership wording for it. It says the amount is a matter of public record at that block and that the link proves nothing about who created it. `verifyDisclosure` returns the verdict `public_balance` for this, for exact and range kinds alike.
   `/d/*` rules: no third-party scripts or analytics; CSP `connect-src` limited to `api.darkwallet.cash`, `api-testnet.darkwallet.cash` and `rpc.mainnet/testnet.chain.robinhood.com`, with `'wasm-unsafe-eval'`; `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, `noindex`. The footer carries the beta notice and the caveat.
9. **Revoke.** `DELETE /v1/disclosures/:id` with the session owner or `X-Revoke-Token`. The blob is purged and a 410 tombstone remains. **UI text:** "Revoking stops this link from working. Anyone who already opened it may have saved the proof, and a saved proof stays valid forever."
10. **Recovery on a new device.** 12 words → sk → address → registry P → derive s and check the match (hard stop on mismatch) → `getAccount` → `aeBalance` or replay → history → `GET /v1/disclosures` for the id list. Old links whose K_link is not in the vault backup show "key unavailable; revoke only".

## 8 · Signing domains and other defaults

- **Sign-in.** EIP-4361 SIWE, **built on the device from pinned constants**:
  - `domain = SIWE_DOMAIN` (`app.darkwallet.cash`; staging `app-testnet.darkwallet.cash`), `uri = https://<domain>`, `chainId = DARK_CHAIN_ID`, `version = 1`, a 128-bit nonce with a 5-min TTL, `issuedAt`, and `expirationTime = issuedAt + 10 min`.
  - The statement is "Sign in to Dark. This does not move funds."
  - `POST /v1/auth/nonce` returns only `{nonce, issuedAt, expiresAt}`. The app fills the template itself; the server accepts only that exact template, byte for byte. The app never signs a server-supplied string or hash (a compromised API could otherwise hand it a SIWE message for another dApp's domain).
  - The session is an opaque 32-byte token stored as `sha256` with a 24 h TTL. The mobile app signs silently with the active account (the key is on the device); the web app does the same after unlock.
- **Disclosure owner signature.** **EIP-712 typed data** (see §18b W10). Not `personal_sign`: a blind EIP-191 signature over a raw 32-byte hash carries no Dark domain, so any other dApp's "sign this hash" prompt yielded a valid Dark disclosure signature.
- **Agent intents** (`DarkIntent`) are **not signed messages**. They are server-proposed JSON validated again on the device. Execution is a normal LI.FI transaction, checked against the pinned allowlist and decoded, then signed on the device after the confirmation screen.
- **The contracts use no EIP-712 domain** (msg.sender is the only authorization). Nothing from any prior project's domains or keys is reused.

## 9 · Gas and cost on Robinhood Chain (**measured on 46630, 2026-09-17**)

**What "gas" means here, because two different numbers are both true.** Robinhood Chain is an Arbitrum
Orbit chain, so a receipt's `gasUsed` is **L2 execution + an L1 data component** (`gasUsedForL1`). The
L2 half is ours: our contracts, our verifier, our storage. The L1 half is a function of calldata size
and the *current Ethereum base fee*, and we do not control it — it moves without any change on our
side. Every budget below therefore states both, and **the gate is on the L2 half**.

**The old "≤ 3.5M for a transfer" line was a pre-measurement estimate of `verify()` alone and matches
nothing real; it is replaced by the two gates below.** For reference, `verify()` in isolation is
2.29M (forge, execution only) — the rest of a transfer is the vault's own ciphertext arithmetic,
caps and storage.

| Operation | Total `gasUsed` | L2 execution | L1 data | L1 share | Calldata |
|---|---|---|---|---|---|
| `approve` | 53,031 | 45,921 | 7,110 | 13.4 % | 68 B |
| `deposit` | 149,295 | 138,313 | 10,982 | 7.4 % | 164 B |
| `applyPending` | 96,530 | ~89,000 | ~7,500 | ~7.8 % | 100 B |
| `register` (once) | 3,721,828 | ~3,443,000 | ~279,000 | ~7.5 % | 8,612 B |
| **`transfer`** | **4,069,223** | **3,751,806** | **317,417** | **7.8 %** | 8,612 B |
| `withdraw` | 3,946,835 | 3,653,555 | 293,280 | 7.4 % | 7,876 B |
| disclosure create / view / revoke | 0 (off-chain) | 0 | 0 | — | — |

**Gates (restated from measurement):**
1. **L2 execution ≤ 4.0M for `transfer`, ≤ 4.0M for `withdraw`, ≤ 3.7M for `register`.** This is the
   number our code owns; a circuit or contract change that breaches it is a regression and CI can
   assert it. Today: 3.75M / 3.65M / ~3.44M.
   - **Headroom is thin and asymmetric: `transfer` has ~6 % (249k gas) and `register` ~7 % (257k),
     while `withdraw` has ~9 %.** Any further contract change that adds storage or a check to the
     transfer path will trip the gate before it feels expensive, so measure `transfer` before
     proposing one. Raising a gate is a decision, not a fix: the ceiling exists because these three
     calls must stay affordable on 4663, and a verifier change is the only lever that moves the
     number materially.
2. **Total transaction gas is reported, not gated**, because its L1 half depends on Ethereum's base
   fee. At the observed 0.01 gwei and today's L1 price, a full value pass (approve → deposit →
   transfer → applyPending → withdraw) cost **0.0000837 ETH across 6 transactions**. The app must
   quote the user a fee from a live `eth_estimateGas` at send time, never from a constant in this doc.

**Consequence for the UI:** at 8.6 KB of calldata, a transfer's L1 component is ~7.8 % of its gas
today. If Ethereum's base fee rises 10×, that share roughly grows with it while the L2 half stays
flat — so fee quotes must be live, and the honest-copy line about cost cannot name a fixed number.

The Groth16 fallback costs about 0.35–0.45M gas per transfer (~$0.07–0.09). `IDarkVerifier` is the seam for swapping verifiers in a new vault version. The client always uses `eth_estimateGas`, which includes the L1 component on Arbitrum chains. There is no gas sponsorship in v1, so users need ETH on 4663.

## 10 · Version pins, license record, design references

**Spike checks added by this spec:**
- measured gate counts for all 4 circuits;
- the public-input count the generated verifier expects (pairing-point limbs);
- the Grumpkin G constant and complete point addition at the pinned nargo;
- the `evm_version` the chain accepts;
- noir-rs building the pinned ACIR (noir-rs is at 1.0.0-beta.19 while upstream is at 1.0.0-rc.1).

**License record for every ZK and crypto dependency** (checked 2026-09-14; enforced by a license-check job in the maintainers' CI, which fails on any GPL/AGPL/LGPL package in the app, web, SDK, api or worker trees):

| Dependency | License | Used in | Verdict | Source |
|---|---|---|---|---|
| Ava Labs EncryptedERC and any fork | custom: Avalanche-only, non-commercial | — | **FORBIDDEN; do not open** | https://github.com/ava-labs/EncryptedERC/blob/main/LICENSE.md |
| Noir / nargo / `@noir-lang/noir_js` (1.0.0-rc.1, 2026-09-09) | MIT OR Apache-2.0 | circuits, web prover | OK; pin exact (still a release candidate) | https://github.com/noir-lang/noir ; https://registry.npmjs.org/@noir-lang/noir_js |
| Barretenberg (bb, in aztec-packages) | Apache-2.0 | prover, VK and verifier generation | OK; keep NOTICE | https://github.com/AztecProtocol/aztec-packages/blob/master/barretenberg/LICENSE |
| `@aztec/bb.js` 5.2.0 | MIT | web prover, viewer | OK | https://registry.npmjs.org/@aztec/bb.js |
| Generated Honk Solidity verifier templates | Apache-2.0 (SPDX header) | `Dark*Verifier.sol` | OK; verify on Blockscout as Apache-2.0 | https://github.com/AztecProtocol/aztec-packages/tree/master/barretenberg/sol |
| noir-rs | Apache-2.0 | native prover | OK; lags upstream (beta.19); lockstep risk | https://github.com/zkmopro/noir-rs |
| mopro (mopro-ffi, mopro-cli) | Apache-2.0 / MIT | native bindings build | OK | https://github.com/zkmopro/mopro |
| uniffi-rs / uniffi-bindgen-react-native (0.31.0-5 on npm, 2026-09-14) | MPL-2.0 | generated bindings | OK (file-level copyleft; we modify no MPL files). MPL §3.2 still requires, when covered files ship in executable form, a notice and a way to get their source: the in-app **Open-source licenses** screen links the source | https://github.com/mozilla/uniffi-rs ; https://www.npmjs.com/package/uniffi-bindgen-react-native ; https://www.mozilla.org/en-US/MPL/2.0/ |
| noir-lang/poseidon | Apache-2.0 | reserved; not used in v1 circuits | OK | https://github.com/noir-lang/poseidon |
| `@noble/curves` 2.4.0, `@noble/hashes`, `@noble/ciphers` | MIT | SDK crypto, viewer; `@noble/hashes` is also the Argon2id implementation of the native and web vaults | OK | https://www.npmjs.com/package/@noble/curves ; https://www.npmjs.com/package/@noble/hashes ; https://www.npmjs.com/package/@noble/ciphers |
| viem | MIT | SDK, app | OK | https://github.com/wevm/viem |
| OpenZeppelin Contracts 5.x | MIT | contracts (incl. `TimelockController`) | OK | https://github.com/OpenZeppelin/openzeppelin-contracts |
| Foundry (forge, anvil), forge-std | Apache-2.0 / MIT | dev tool, tests | OK (not distributed) | https://github.com/foundry-rs/foundry |
| Slither (optional) | AGPL-3.0 | CI tool only | OK as an undistributed tool; never a runtime dependency of the api/worker (the license check covers that tree) | https://github.com/crytic/slither |
| Dark's own code in the public repositories (`contracts/` and `circuits/` here, dark-sdk, dark-exit) | MIT OR Apache-2.0 (SPDX headers) | https://github.com/DarkWalletRH | ours to license | — |
| circom, snarkjs 0.7.6, ffjavascript, circomlibjs, circomspect | GPL-3.0 | Groth16 fallback only, as build tools | **Never shipped** | https://github.com/iden3/snarkjs ; https://github.com/iden3/circom |
| circomlib | LGPL-3.0 (git, since PR #120, 2025-01-21) / GPL-3.0 (npm 2.0.5) | — | **Avoid** (clean-room templates if the fallback is used) | https://github.com/iden3/circomlib |
| rapidsnark (and its RN wrappers) | LGPL-3.0 core | — | **Avoid** (static linking on iOS) | https://github.com/iden3/rapidsnark |
| `@iden3/js-crypto` 1.3.3 | AGPL-3.0 | — | **Avoid** | https://registry.npmjs.org/@iden3/js-crypto |
| circom-witnesscalc; arkworks circom-compat; p0tion | MIT; Apache-2.0; MIT | Groth16 fallback only | OK | https://github.com/iden3/circom-witnesscalc ; https://github.com/arkworks-rs/circom-compat ; https://github.com/privacy-ethereum/p0tion |
| Groth16 fallback **Solidity verifier** | clean-room Solidity over the EIP-197 pairing precompiles (or gnark's Apache-2.0 exporter) | Groth16 fallback only | OK. **snarkjs `zkey export solidityverifier` is forbidden**: its template carries `SPDX-License-Identifier: GPL-3.0` and would put GPL-derived code on-chain (arkworks has no Solidity exporter) | https://github.com/iden3/snarkjs/blob/master/templates/verifier_groth16.sol.ejs ; https://eips.ethereum.org/EIPS/eip-197 |
| gnark / gnark-crypto | Apache-2.0 | — | not selected (no mobile or web path) | https://github.com/Consensys-Incorporated/gnark |
| Solana zk-sdk (design reference) | Apache-2.0 | ideas only | OK to study; no code copied | https://github.com/solana-program/zk-elgamal-proof |
| Anonymous Zether (design reference) | Apache-2.0 | ideas only | OK to study; no code copied | https://github.com/Consensys-Incorporated/anonymous-zether |
| Zama FHEVM | BSD-3-Clause-Clear, no patent grant; commercial use needs a patent license | only if the FHE alternative is adopted | ask the price | https://github.com/zama-ai/fhevm |
| OZ Confidential Contracts (ERC-7984 on FHEVM); Fhenix cofhe-contracts | MIT; MIT | only if the FHE alternative is adopted | usable only on a supported coprocessor network | https://github.com/OpenZeppelin/openzeppelin-confidential-contracts ; https://github.com/FhenixProtocol/cofhe-contracts |

*Implementation note (2026-10-07):* the versions in this table are the ones current when the licenses were checked. The pinned toolchain is nargo and `@noir-lang/noir_js` 1.0.0-beta.22 with bb and `@aztec/bb.js` 5.0.0-nightly.20260522 (`circuits/VERSIONS.toml`); `@noble/curves` is 2.x in `contracts/` (the differential test) and 1.x in the dark-sdk. noir-rs and mopro are not used (§6, §7). In dark-contracts the `MIT OR Apache-2.0` header is on the contract sources, the circuits and the deployment record; the deploy scripts and the Solidity tests carry `MIT` only; the bb-generated verifiers and the tests and fixture generator that drive them carry `Apache-2.0` as generated. The repository as a whole is offered under both licences (LICENSE-MIT and LICENSE-APACHE; README, License).

**Design references** (ideas only):
- Zether https://eprint.iacr.org/2019/191 : account-based encrypted balances, the front-running analysis.
- Anonymous Zether https://eprint.iacr.org/2020/293 : on-chain ElGamal accounting, register-with-proof.
- PGC https://eprint.iacr.org/2019/319 : twisted ElGamal, one commitment with two handles.
- Solana Confidential Balances https://www.solana-program.com/docs/confidential-balances : pending/available, proof-free apply, AE balance.
- Solana zk-sdk derivation (§4).
- RFC 9497 §2.2 : DLEQ.
- Noir embedded curve ops https://noir-lang.org/docs/dev/noir/standard_library/cryptographic_primitives/embedded_curve_ops .
- bb Solidity verifier guide https://barretenberg.aztec.network/docs/how_to_guides/how-to-solidity-verifier/ .
- Aztec Ignition SRS https://github.com/AztecProtocol/aztec-packages/blob/master/barretenberg/trusted_setup.md : the 1-of-N trust statement, and bundling only the needed G1 prefix.
- Groth16 setup exploits https://blog.zksecurity.xyz/posts/groth16-setup-exploit/ : fallback only.
- 0xPARC zk-bug-tracker https://github.com/0xPARC/zk-bug-tracker .
- Base ZKP benchmarks https://blog.base.dev/benchmarking-zkp-systems .

---


*Implementation note (2026-10-07):* in the public dark-sdk, §11's client status appears as `DarkStatus` (coarser than the table below), §13's lifecycle as `ActionState` (which adds `unknown`: submitted, then lost from view, so not to be retried), and the viewer's result in §14 as `DisclosureVerdict`.

## 11 · Account registration

**On-chain:** `Unregistered → Registered`. It is irreversible, one key per address, with no admin override.

**Client** (`useDark().status`):

| From → To | Trigger | Notes |
|---|---|---|
| `no_key → key_derived` | unlock + open the Private tab | HKDF (§4); nothing is persisted |
| `key_derived → registered` | `keyOf(A)` exists **and** equals the derived P | the recovery path |
| `key_derived → key_mismatch` | the on-chain P ≠ the derived P | **terminal hard stop** `KEY_DERIVATION_MISMATCH`; no proofs are ever built; links to support |
| `key_derived → needs_gas` | ETH < the estimated register cost | shows the funding screen |
| `key_derived → proving` | user taps "Enable private balance" | `dark_register` |
| `proving → submitted` | proof ok, public inputs re-derived and equal, simulate ok | `register` tx sent |
| `submitted → registered` | receipt + `KeyRegistered` | soft-confirmed; the UI marks L1-final later |
| `proving \| submitted → failed` | prover error, revert (`AlreadyRegistered` → refresh → `registered`), dropped tx | retry allowed |

## 12 · Per-account balance (on-chain)

**Only the owner's actions mutate `available`, and each one increments `nonce` by exactly 1.**

| Sub-machine | From → To | Actor · call | Paused? | Notes |
|---|---|---|---|---|
| pending | `Empty(0) → NonEmpty(1)`; `NonEmpty(n) → NonEmpty(n+1)` | any registered sender · `transfer(to=A)` | blocked | adds (C_t, D_r) |
| pending | `NonEmpty(n) → Empty(0)` | A · `applyPending(n, ae)` | **allowed** | available += pending |
| pending | `NonEmpty(n) → Empty(0)` | A · `applyPending(m < n, ae)` | **allowed** | the late arrivals fold in; `appliedCount = n`; `aeBalance` under-reports and the client re-derives |
| pending | `NonEmpty(n) → NonEmpty(n)` (revert) | A · `applyPending(m > n)` | — | `PendingChanged`; the caller read stale state |
| available | `Enc(b) → Enc(b + x)` | A · `deposit(x)` | blocked | x public |
| available | `Enc(b) → Enc(b + p)` | A · `applyPending` | allowed | p = pending |
| available | `Enc(b) → Enc(b − a)` | A · `transfer` + proof | blocked | a hidden; 0 ≤ b − a |
| available | `Enc(b) → Enc(b − x)` | A · `withdraw(x)` + proof | **allowed** | x public; 0 ≤ b − x |

**Exit guarantee.** While paused, and with every cap tightened to its most restrictive value, any registered account can always `applyPending` and then `withdraw` its full balance. The only exceptions are the chain operator censoring the call and the USDG issuer freezing the vault (§2).

## 13 · Owner action lifecycle (client; one in flight per account)

| From → To | Trigger |
|---|---|
| `idle → building` | user confirms the action (deposit, apply, transfer, withdraw) on the device |
| `building → proving` | inputs read at one block (nonce n, available) |
| `proving → simulating` | proof returned and public inputs equal the SDK's own |
| `simulating → submitted` | `simulateContract` ok; tx signed and sent via `/v1/rpc` |
| `submitted → soft_confirmed → final` | receipt (< 1 s); L1 finality (~13 min after the batch posts) |
| `building \| proving \| simulating \| submitted → stale` | on-chain nonce ≠ n or available changed → back to `building`, at most 3 times automatically |
| `simulating \| submitted → reverted(reason)` | a custom error, mapped to user text by `friendlyError` |
| `submitted → dropped` | not mined within the timeout → re-check the nonce → `stale` or `final` |

## 14 · Disclosure link

Server `dw_disclosures.status` ∈ `active · revoked · expired`. The client adds `draft · uploading · key_unavailable`.

| From → To | Actor | Effect |
|---|---|---|
| `draft → uploading → active` | owner device · `POST /v1/disclosures` | blob stored; the link works |
| `active → revoked` | owner (session or revoke token) · `DELETE` | blob purged; GET returns 410 (terminal) |
| `active → expired` | `disclosureSweeper` at `expires_at` (GET refuses after `expires_at` even before the sweep) | blob purged; 410 (terminal) |
| `active → key_unavailable` (client only) | recovered device without a vault backup of K_link | the list shows "revoke only" |

**Viewer states:** `fetching → decrypting → verifying →` one of `verified_independent · verified_dark_only · public_balance · invalid · expired · revoked · unsupported_version`. `public_balance` is §7.8 step 6: a true statement about a balance that is already public, never rendered as "Verified".

**Honest invariant:** revocation removes availability, **not validity**. A saved document keeps verifying offline forever.

## 15 · Invariants (Handler-based stateful Foundry tests, `fail_on_revert = true`, anti-vacuity checks)

The harness uses a `DarkTestVerifier` that accepts a proof only if the handler's ghost oracle (which knows each test account's s and plaintext balances) says the statement is true. `IDarkVerifier.verify` is `view`, so the vault staticcalls it and a mock cannot record anything: instead the harness **arms** the verifier with the public-input array the oracle derives from its own model, and the call reverts `InvalidProof` if the vault passes anything else — which is what proves I13. The oracle cannot decrypt (that needs the dlog of H); it **re-encrypts** its plaintext model with the vault's own `mulG` and compares group elements. The reference Grumpkin is differentially fuzzed against `@noble/curves` via `vm.ffi` (500 cases, the first of which are the §19 X1 edge cases: identity, doubling, P + (−P) and the ends of the amount range). Real proofs are checked only against the verifiers, in `circuits/evm/test/Verifiers.t.sol`; the planned `test/realproofs/` suite that drives them through `DarkVault` was never built.

*Implementation note (2026-10-07):* the suite is `contracts/test/invariant/` (`DarkVault.invariant.t.sol`, `DarkVaultHandler.sol`) with `contracts/test/mocks/DarkTestVerifier.sol`, and `INVARIANTS.md` in this folder reports it. Its anti-vacuity checks (`afterInvariant`) fail any run that never deposited, withdrew, transferred, applied pending, verified a proof, checked an event, probed an illegal call or checked isolation.

| # | Invariant |
|---|---|
| I1 | **Solvency:** `USDG.balanceOf(vault) ≥ tvl`, and `tvl == Σ deposits − Σ withdrawals` (ghost) |
| I2 | **Encrypted conservation:** Σ over accounts of (dec(available) + dec(pending)) == `tvl` |
| I3 | `available[A]` changes only in a tx whose `msg.sender == A` |
| I4 | `pending[A]` changes only by `+ (C_t, D_r)` from a transfer to A, or is reset to identity by A's `applyPending`; `pendingCount[A]` equals the number of transfers since A's last apply |
| I5 | `nonce[A]` increases by exactly 1 per owner action and never otherwise |
| I6 | Caps: every deposit ∈ [`minDeposit`, `maxDeposit`]; `netInflow ≤ maxAccountInflow` and `tvl ≤ tvlCap` after every deposit; every transfer amount (ghost) ∈ [`minTransfer`, `maxTransfer`]; `tvl ≤ HARD_MAX_TVL` always |
| I7 | **Exit liveness** (snapshot and revert probe every run): every account with ghost balance b > 0 can `applyPending` then `withdraw(b)` while paused and after `tightenCaps` to the most restrictive values. "Most restrictive" means every min-field at `type(uint64).max`: `tightenCaps` deliberately does not re-run the hard-ceiling check, so `minTransfer` can end up above `maxTransfer`, which bricks `transfer` (intended) while leaving `withdraw` open (required) |
| I8 | Pause scope: while paused, `deposit` and `transfer` revert with `EnforcedPause`; `withdraw`, `applyPending` and `register` never revert for pause |
| I9 | The guardian never loosens a cap; `setCaps` never exceeds a hard ceiling; only the owner unpauses; `renounceOwnership` reverts |
| I10 | No path other than `withdraw` lowers the vault's USDG balance; `recoverERC20(usdg, …)` always reverts |
| I11 | Registry keys are immutable once set, one per address, canonical, on-curve, not identity |
| I12 | Every stored vault point is canonical and either on-curve or the `(0,0)` sentinel |
| I13 | Public-input binding: every public input passed to a verifier (except `ct`/`amount`) equals the pre-call storage, registry or config value |
| I14 | Event truthfulness: every event field equals the post-state |
| I15 | Every revert has a legal cause. With `fail_on_revert = true` nothing in a run may revert, so this is **not** a passive invariant: it is proved by explicit handler probes that make one call per custom error with exactly one illegal input and assert that exact error (`NotRegistered`, `AmountZero`, `ZeroAddress`, `BadRecipient`, `PendingChanged`, `SelfTransfer`/`EnforcedPause`) |

**Circuit properties** (nargo tests plus SDK property tests):
- **CP1:** no valid witness exists with a negative remainder (a wraparound w = n − 1 test).
- **CP2:** changing any single public input rejects the proof (one negative test per input, per circuit).
- **CP3:** a DLEQ proof fails if any transcript element changes.
- **CP4:** key-derivation vectors are stable.

## 16 · Mutation list (each must be killed; `contracts/script/mutate.mjs` writes the kill report)

| # | Mutation | Killer |
|---|---|---|
| M1 | `transfer` credits a caller-supplied sender instead of `msg.sender` (ABI-preserving: read it from a calldata field or `tx.origin`; taking a new parameter would not compile, which is a false kill) | I3, unit |
| M2 | P_r read from calldata, not the registry | I13 (the planned realproofs suite was never built) |
| M3 | sender `available` passed from calldata, not storage | I13, I2 |
| M4 | nonce not incremented on one action (×4 actions) | I5 |
| M5 | `withdraw` gets `whenNotPaused` | I7, I8 |
| M6 | `applyPending` gets `whenNotPaused` | I7, I8 |
| M7 | `withdraw` does `available.c += mulG(x)`, or skips the update | I2 |
| M8 | `transfer` credits the recipient's `available` instead of `pending` | I4, the front-run test |
| M9 | the `deposit` balance-delta guard is removed | fee-on-transfer mock test |
| M10 | `tvl + x ≤ tvlCap` becomes `<`, or is removed | I6 |
| M11 | `tightenCaps` accepts a loosening field | I9 |
| M12 | the canonical-coordinate check (`x < r`) is removed for `ct` | I12, non-canonical input test |
| M13 | the identity sentinel is accepted for `ct.c`/`ct.dSender`/`ct.dRecipient` | I12 |
| M14 | `applyPending` ignores `expectedPendingCount` | unit |
| M15 | `recoverERC20` allows USDG | I10 |
| M16 | `renounceOwnership` is not overridden | I9 |
| M17 | the deploy script swaps the transfer and withdraw verifiers | deploy-script codehash check (the planned realproofs suite was never built) |
| M18 | circuit: the range check on w is removed | CP1 |
| M19 | circuit: `ct_dr == r·pk_r` is removed | malformed-D_r negative test |
| M20 | circuit: `s·pk_s == H` is removed | wrong-key negative test |
| M21 | circuit: `r ≠ 0` is removed | negative test |
| M22 | circuit: on-curve assertions are removed | off-curve negative test |
| M23 | circuit: `a ≤ max_transfer` / `a ≥ min_transfer` is removed | negative test |
| M24 | circuit: a binding public input goes unused (e.g. `recipient`) | CP2 |
| M25 | DLEQ challenge omits D, v or ctx | CP3 |
| M26 | SDK: the HKDF salt or info changes | CP4 |
| M27 | build: verifier generated with `--disable_zk` or a non-keccak oracle | CI manifest-flag check |
| M28a | `DarkGrumpkin.add` mishandles doubling | differential fuzz vs noble |
| M28b | `DarkGrumpkin.add` mishandles P + (−P) | differential fuzz vs noble |
| M28c | `DarkGrumpkin` Jacobian→affine conversion is wrong | differential fuzz vs noble |

**Scope.** M18–M27 are circuit, SDK and build mutations covered by the circuit and SDK test suites; the contracts' kill report records them as out-of-scope rows naming the suite that covers them rather than faking a contracts-side kill. **Every cap comparison needs an inclusive-boundary test:** M10a (`<=` → `<` on `tvlCap`) and the §19 C6 `minDeposit` comparison both survived a 43-test happy-path suite; off-by-one cap mutations are invisible without explicit boundary tests.

*Implementation note (2026-10-07):* `contracts/script/mutate.mjs` runs 44 contract-side mutants: the contract rows above, several split into variants (M1b, M4a–M4d, M7a/M7b, M10a/M10b, M11b, M14b, M17b/M17c), plus M29–M39d, which extend this list (for example M29 "`withdraw` does not lower `tvl`", M33 "`withdraw` pays `msg.sender` instead of `to`", M39a–M39d "an account function loses `nonReentrant`"). The runner's M29 is therefore not the mutation that §3 calls M29 (a hint whose R_e or K coincides with the transfer randomness), which an SDK property test covers. M27's "CI manifest-flag check" is not a separate CI step; `MUTATIONS.md` describes the indirect protection that exists. The runner's M17 swaps the two constructor arguments and is killed by the deploy-script wiring test (`test_scriptWiresEachVerifierToItsOwnSlot`, `contracts/test/DeployDarkTestnet.t.sol`); the codehash pin kills the other reading of M17, a wrong env address, and M17b/M17c cover the pin itself. The kill report as of this release is `MUTATIONS.md` in this folder.

## 17 · Threat model

Assets: the USDG backing in `DarkVault`; the confidentiality of balances and transfer amounts; user keys (sk, s, k_ae); disclosure contents; and exit availability.

| Actor | Capability | Worst case | Mitigation | Pre-audit status |
|---|---|---|---|---|
| Malicious user or attacker | Crafts proofs and calldata; exploits a circuit, verifier or `DarkGrumpkin` soundness bug | Mints encrypted value and withdraws others' backing, **up to the TVL**. The theft is invisible until exit: I1 still holds, and the last honest withdrawers fail on the `tvl` underflow | Caps (the TVL cap is the loss bound); 3 internal rounds; invariants + mutations; real-proof verifier tests (`circuits/evm/test/Verifiers.t.sol`; the planned `test/realproofs/` through `DarkVault` was never built); the bounty; the external audit; an outflow alert from the team's off-chain monitor | **Accepted, bounded by `tvlCap` ($50k at launch, §5)** |
| Malicious sender | Pollutes a recipient's pending; dust spam; lying hints | Recipient freeze (if D_r were unconstrained) | D_r is constrained (M19); `minTransfer`; hints verified with a BSGS fallback | mitigated |
| Front-runner / MEV | Copies or reorders txs | Invalidated proofs; a stolen registration | `msg.sender` binding; storage-bound public inputs; the pending/available split; the FCFS sequencer (https://docs.robinhood.com/chain/transaction-finality/) | mitigated |
| Chain observer | Reads everything public | Graph, timing and amount correlation (§2) | Honest copy; no anonymity claims | accepted by design |
| Dark servers / insider | Metadata; can serve wrong data | A fake ciphertext to a viewer; omitted history | The viewer's two-source check; client replay == on-chain decryption; no keys server-side | mitigated; metadata leak accepted |
| Guardian key (compromised) | `pause`, `tightenCaps` | Blocks deposit and transfer | Cannot block exit; the owner replaces the guardian (timelocked) | accepted |
| Owner Safe / timelock (compromised) | Raises caps after 48 h; replaces the guardian | Raises caps ahead of an exploit | 48 h public delay; the team's off-chain monitor alerts on `CallScheduled`; no power over funds | accepted |
| Chain operator (Robinhood) | Filters txs (`ArbFilteredTransactionsManager`), upgrades with no delay, runs a centralized sequencer (https://l2beat.com/scaling/projects/robinhood) | Censors withdraws; changes the rules | None at the app layer; disclosed in docs and whitepaper | **accepted** |
| USDG issuer | May freeze the vault address | All accounts frozen | Disclosed; check the USDG admin ABI | **accepted** |
| Supply chain (npm, nargo/bb releases, Expo modules, the SRS file) | Swaps artifacts | Key exfiltration; VK drift | Exact pins; `manifest.json` hashes checked in CI, at deploy and at app start; bundled SRS; lockfiles; no runtime CDN code (unpkg removed) | mitigated |
| Device thief / malware / web XSS | An unlocked device; script injection | Steals sk and therefore s: total loss for that account | SecureStore `WHEN_UNLOCKED_THIS_DEVICE_ONLY` + biometric ACL; the encrypted web vault on an isolated origin with strict CSP; s in memory only; wiped on lock | residual risk accepted |
| Disclosure recipient | Re-shares a saved proof | A permanent leak of that one statement | UI copy, expiry, scoping; no s export | accepted by design |
| Providers behind Dark's proxy (Alchemy, Blockscout, LI.FI, GMGN, CoinGecko, DexScreener, OpenAI chat, Expo push sender) | Metadata | Linking addresses (they see Dark's IP, not the user's) | Server-side proxies; generic push payloads; agent tools exclude the private balance | accepted |
| Providers the device reaches directly (OpenAI Realtime, Google STUN, Expo/APNs/FCM, the public Robinhood RPC when chosen) | Metadata incl. the user's IP; voice audio | Linking a device IP to an address, and hearing voice sessions | Opt-in voice and push; disclosed in §2, in the app's copy and in the privacy policy; self-hosted STUN on DO is the alternative | accepted, disclosed |
| Dark release pipeline (a compromised Vercel team or project, EAS, App Store Connect, Play Console, or a build laptop) | Ships malicious app or web-wallet code | Web: JS that exfiltrates every web user's seed at the next unlock. Native: a malicious store build | Vercel projects with enforced 2FA and deployment protection; production web deploys only from a tagged CI job (app) or a clean checkout at `origin/main` (site), with each release's web-export SHA-256 published; hardware-key 2FA on EAS, ASC and Play; the open-source `dark-exit` tool and mobile apps don't depend on the web origin; docs state that web users trust Dark's hosting for code integrity | mitigated, disclosed |
| OTA update channel (`expo-updates`) | Pushes JS to installed apps without store review | Silent key exfiltration on every device | **`expo-updates` is not installed in v1**; if ever added, only with expo-updates code signing under an offline key, and a new threat-model review | excluded in v1 |

*Implementation note (2026-10-07):* v1 ships as an Android APK downloaded from darkwallet.cash: there is no iOS build, no app-store listing and no hosted web wallet at launch (darkwallet.cash/app redirects to /download). The web-wallet and app-store parts of the rows above describe surfaces that are not live. For the APK, /download is built to publish the file's SHA-256 and the signing certificate's fingerprint beside the link, and to offer no file until both exist. The browser surfaces that are live are the disclosure viewer (darkwallet.cash/d/) and dark-exit's offline page. The contract-side threat model is `THREAT-MODEL.md` in this folder. As of 2026-10-07 /download offers no file: the first APK release has not been published, so the mainnet contracts are live with no released client; the integrity fields above apply from the first release on.

**Other accepted pre-audit risks:**
- There is no public audit of the Honk Solidity verifier (Barretenberg audits so far cover bigfield: Zellic 2024, Veridise 2025).
- Noir is at rc.1 and bb churns, so we run lockstep CI.
- The Ignition SRS is a 1-of-N trust assumption.
- Key derivation v1 is a one-way door.
- App-store and regulatory review of confidential transfers with no auditor key.

## 18 · Pre-audit launch guardrails (locked items)

1. **Testnet beta first** on 46630 with `MockUSDG`.
   - An internal phase first, then an external tester cohort.
   - Every private flow is scripted on iOS, Android and web (end-to-end smoke tests + Maestro/Playwright).
   - Mainnet deploys only after: (a) all invariants and mutations pass, (b) the three internal review rounds have closed with their fixes re-reviewed, and (c) at least **7 consecutive days of testnet beta on 46630 running the exact mainnet-candidate runtime codehashes** of `DarkVault`, `DarkKeyRegistry` and the verifiers, and the `manifest.json` VKs (differing only in constructor args), with no open high or critical finding. **Any change to `contracts/src/**`, `circuits/**` or the SDK crypto restarts the 7-day clock**; only the launch date moves. The external cohort has a floor: ≥ 20 testers and ≥ 200 private transactions covering every flow, including the §18.10 exit drill. The codehash comparison is recorded in the maintainers' launch checklist.
   - **Review cutoff:** a high or critical finding still open after **Fri Nov 13** moves the launch. A fix after the second or third review round that touches contracts or circuits gets a testnet redeploy and an end-to-end smoke run.
2. **Caps are enforced on-chain** (§5 table). Raising them takes the 48 h timelock; the guardian can tighten instantly; the hard ceilings are immutable. The beta column is not enforced by `DeployDarkMainnet.s.sol`; mainnet runs the higher launch caps (§5).
3. **The guardian pause never blocks exit.** It stops `deposit` and `transfer` only (I7, I8, M5, M6).
   - Guardian = a 1-of-2 Safe (either signer can act instantly).
   - Owner = `DarkTimelock` (48 h), proposed by the owner Safe (2-of-3 by default; hardware wallets only).
4. **Three internal adversarial rounds:** finder agents → refuter passes → fixes → **review the fixes too**. They use the zk-bug-tracker classes, Fiat–Shamir "hash everything", non-canonical encodings, and identity/doubling edge cases, and update the mutation list each round (one round after another, with an addendum to the third).
5. **A visible beta notice in three states**, driven by one constant (`BETA_NOTICE_STATE` in SDK `deployments[chainId]`, read by the app through `useDark().betaNotice` and by the website through a sync script). The exact strings are below; the state is flipped only with a recorded team decision:
   - `pre_audit` (testnet beta and launch day, until kickoff): "Beta — unaudited. The external audit by <firm> starts <date>. Deposits are capped."
   - `in_audit`: "Beta — external audit by <firm> in progress. Deposits are capped."
   - `audited`: "Audit report published <date> (link)."
   - If the audit hasn't started within 14 days of launch, the guardian tightens `maxDeposit` to 0 and the notice says so.
   - Shown: in the app's Private tab header; on the enable-private-balance, deposit, transfer and withdraw screens; on darkwallet.cash (banner + docs); in the whitepaper; in the `/d/<id>` viewer footer; in the store listings.
   - **Risk acknowledgement:** a one-time checkbox on the enable-private-balance screen, stored per account, with the app's "Beta risks" text. Registration cannot be sent until it is ticked.
6. **A bug bounty is live at mainnet** (its testnet scope opens first).
7. **The external audit starts the week after mainnet** (Mon 2026-11-23; a signed engagement letter with a start date ≤ 7 days after launch is a launch-gate item). **Caps rise only after the audit:** no critical or high finding may be accepted; medium, low and info findings may be accepted with a published rationale. Caps are raised only on the vault version that contains every fix. If a fix needed a new vault or verifier, v1 is sunset (`maxDeposit = maxTransfer = 0`) and never raised, and users migrate (§5). The auditor confirms the fix review in writing, or re-reviews, before the timelock proposal.
8. **Monitoring and incident response:** alerts from the team's off-chain monitor; numbered guardian steps in the maintainers' incident procedure (tighten `maxDeposit`/`maxTransfer` to 0 → pause → announce; users exit via `withdraw`).
9. **Pinned, reproducible artifacts:** `manifest.json` hashes are checked in CI, at deploy (verifier codehash) and at app start. M27 asserts the ZK flavor and the keccak oracle.
10. **Exit without Dark.** The contract guarantee ("Dark can never pause withdrawals") must also hold if every Dark server is down, taken down or compromised:
   - **App fallback:** reads and `eth_sendRawTransaction` fall back automatically to `https://rpc.mainnet.chain.robinhood.com` (or the user's custom RPC from Settings → Network) whenever `/v1/rpc` fails. History replay uses topic-filtered `eth_getLogs` against `DarkVault` directly (§7). Both public RPC hosts are in the app CSP `connect-src`.
   - **Balance recovery never depends on current caps:** the available-balance BSGS is bounded by `tvl()` or `HARD_MAX_TVL`, and each pending transfer's BSGS by the `maxTransfer` in force at that transfer's block (from `CapsUpdated` history) or `HARD_MAX_TRANSFER`, never by the current, possibly tightened, caps (§7 step 5).
   - **`dark-exit`:** an open-source CLI and a static offline exit page, published at https://github.com/DarkWalletRH/dark-exit. It takes the 12 words or a raw key, reads state from any RPC, decrypts (`aeBalance` → history replay → BSGS), proves `dark_withdraw` locally with `NodeDarkProver`, and broadcasts. `/docs` has "How to withdraw without Dark".
   - **Drill (a launch gate):** with `api.darkwallet.cash` and `app.darkwallet.cash` unreachable, caps tightened to 0, the vault paused, `aeBalance` empty, one garbage-hint transfer in pending and the indexer down, a funded testnet account applies pending and withdraws its full balance on native, on web (public-RPC fallback) and with the CLI.

*Implementation note (2026-10-07):* parts of this section describe a schedule that was overtaken. The mainnet contracts were deployed on 2026-09-28 (block 75151289). By team decision that day, item 1 (c) was waived as a whole: the 7-day mainnet-candidate soak and the external-cohort floor (no external tester cohort ran on testnet before the deploy). It was waived on the grounds that the contracts and circuits were byte-identical to what had run on testnet and passed the internal reviews, with only the mainnet configuration new; the launch caps in §5 were the stated mitigation. The Nov 13 cutoff and the dates in item 7 belong to the superseded schedule. The beta-notice constant of item 5 is the `betaNoticeState` field of `deployments[chainId]` (`contracts/deployments/deployments.ts` and the dark-sdk), and it reads `pre_audit` on both chains. Item 9's M27 check is likewise indirect (see the note under §16). For the platforms v1 ships on, see the note after §17's table. Item 6: as of 2026-10-07 no bounty terms or funded budget are published; `/.well-known/security.txt` on darkwallet.cash and api.darkwallet.cash gives a contact address only. Item 10's drill was run in reduced form on 2026-09-29, on a fork of 46630: the dark-exit CLI alone recovered a deposit-only account with every non-RPC request blocked. The full scenario (paused vault, caps at 0, empty `aeBalance`, a garbage-hint transfer in pending, indexer down) and the native and web legs have not been run; the same applies to the drill named in §7 step 5 and §19 K9.


## 18b · Wire formats pinned by the SDK implementation and the live E2E (2026-09-16)

These were implemented, exercised end to end on 46630, and are now normative. Ids `W*` so kill
reports and the viewer can cite them. Anything here overrides a looser earlier sentence.

| # | Item | Pinned form |
|---|---|---|
| W1 | `context_hash` preimage | One fixed 19-parameter `abi.encode` tuple, always all 19, never a variable list: `(string tag, uint256 chainId, address vault, address registry, address account, string kind, string component, uint256 blockFrom, uint256 blockTo, bytes32 txHash, string role, string direction, address counterparty, uint256 lo, uint256 hi, uint256 createdAt, uint256 expiresAt, string id, string label)`, `tag = "DARK-CB-1/disclose/v2"`. Absent optionals encode as `""` / `0` / `address(0)` / `bytes32(0)`; a single-block kind repeats B in both block slots. **Every member is a `DarkDisclosureV2` field, and the verifier rebuilds the tuple from the document and rejects a mismatch** — without that, the DLEQ binds only `context_hash` and anyone holding the link can restate the expiry, kind, component, block range or label. `registry` and `label` were added in v2 for exactly that reason. A flow kind carries `blockRange` and no `block`; every other kind carries `block` and no `blockRange`. |
| W2 | Disclosure blob | `nonce(24) ‖ XChaCha20-Poly1305(K_link, frame(JCS(document)), AAD = "DARK-CB-1/disclosure-blob/v1" ‖ id)`, mirroring `aeBalance`, with `frame` as pinned in W11. The 65,536-byte cap applies to the **whole blob including the nonce**, checked after base64 decoding; the largest frame is sized so a full blob is exactly 65,536 B. |
| W3 | DLEQ challenge input and encoding | `ctx` in the challenge is the **32-byte big-endian `context_hash`**, not its preimage. The proof is `c(32) ‖ z(32)` big-endian, 64 B. |
| W4 | Hint AAD nonce | The hint AAD uses the sender's **pre-state** nonce, while `ConfidentialTransfer` publishes `fromNonceAfter` (post-state, §19 C9). A recipient rebuilding from logs must use `fromNonceAfter − 1`. |
| W5 | Disclosure id | `base64url(12 random bytes)`, prefixed `t_` on testnet and bare on mainnet. The API's id validation must accept exactly this. |
| W6 | Disclosure kinds | `kind ∈ {balance_exact, balance_range}` with a separate `component ∈ {available, total}` (§7.7's shape). "balance_available" is **not** a kind; anything using that naming is wrong. |
| W7 | `PendingApplied` history amount | The sum of verified `transfer_in` entries since the previous `PendingApplied`. |
| W8 | `balancePublic` is sticky | The first confidential transfer **in or out** sets it false **forever**; fully withdrawing afterwards does not make a balance public again. **Corrected 2026-09-28:** this row used to say only a *received* transfer counted, contradicting §2 — so an account that had only sent privately kept reporting a public balance even though its ciphertext now carried the transfer's randomness (found on an anvil fork: deposit 50, withdraw 20, send 10 → still `true`). The SDK now reads it off the ciphertext — public exactly when `available.D` is the identity and nothing is pending — which is what the disclosure viewer's `public_balance` verdict already used. False does not mean nobody knows the balance: the counterparty of a transfer, knowing the amount and the prior public balance, can compute it. |
| W9 | Prover temp files | `nargo` has no `--program-dir`, so a prover file must sit inside the crate: `NodeDarkProver` writes `circuits/<crate>/.dark-prove-<pid>-<n>.toml` and removes it in a `finally`; `circuits/.gitignore` carries `.dark-prove-*.toml` so a crashed run cannot leave a tracked file. |
| W10 | `ownerSig` | **EIP-712**, domain `{name: "DARK-CB-1", version: "1", chainId, verifyingContract: vault}`, primary type `Disclosure(address account,string kind,string claim,string label,uint64 expiresAt,bytes32 document)`. `claim` is `"value=<n>"` for an exact kind and `"lo=<n>,hi=<n>"` for a range kind; `document` is `keccak256(JCS(document without ownerSig))`, which binds every remaining field. The five plain members exist so the wallet prompt is readable. `ownerSig` is **required**: a document without one is `invalid`, never `verified`. |
| W13 | Claim shape is bound to the kind | A `claim` is **exactly** `{value}` for an exact kind (`*_exact`) or **exactly** `{lo, hi}` for a range kind (`*_range`). A document carrying both is rejected outright, by the context builder and by the verifier. Pinned because the two shapes were being chosen by *which keys were present* rather than by the kind, and the branches disagreed: the `context_hash` preimage preferred `value` while the range proof was checked against `lo`/`hi`. Since `context_hash` is a free public input to `dark_disclose_range`, an honest proof of `0 ≤ v ≤ 2⁴⁸−1` over the owner's real ciphertext satisfied a context hash that said "exactly N" — and the owner signs the document themselves, so every other check passed. A stranger was shown a **false exact balance as Verified** (red-team review, 2026-09-18, with a working PoC). Implementations MUST branch on `kind`, never on claim shape. |
| W12 | Range-proof verification settings | `dark_disclose_range` proofs are produced and verified with **`verifier_target = evm`** on both sides: bb's `--verifier_target evm` (which keeps ZK **on**) and bb.js's `{ verifierTarget: 'evm' }`. bb.js's older `{ keccak: true }` means keccak **and ZK disabled** and is NOT the same setting — pairing it with an evm-target proof makes bb.js reject a perfectly valid proof while returning only `false`, with no diagnostic. The viewer verifies against the committed `vk_sha256` from `circuits/manifest.json`, compiled in, never fetched. Pinned because nothing in either library checks that the two sides agree. |
| W11 | Disclosure blob framing | The JCS plaintext is framed before sealing: `u32be(length) ‖ plaintext ‖ zero padding` to the smallest of **2048 / 16384 / 65496** bytes. A blob's length therefore reveals only which of three buckets the document fell into, never the magnitude of the amount inside it. Every balance disclosure lands in the 2048-byte frame; the larger two exist for Honk range proofs. |

*Implementation note (2026-10-07):* W1's tag `DARK-CB-1/disclose/v2` supersedes the `DARK-CB-1/disclose/v1` disclosure-context tag in §3's table, under this section's override rule; the dark-sdk (`src/disclosure.ts`) uses v2.

*Implementation note (2026-10-07):* W9 is superseded in the published dark-sdk (`src/prover.ts`): `NodeDarkProver` passes absolute paths to `nargo execute` (`-p`), so the prover TOML and the solved witness, both of which contain `s_lo`/`s_hi`, live in a fresh `mkdtemp` directory under the OS temp dir (`dark-prove-*`, files mode 0600) and the `finally` block overwrites both before deleting them; nothing is written inside the crate. `circuits/.gitignore` still lists `.dark-prove-*.toml` only as a leftover.

**Measured on the live testnet (2026-09-16), for §9's budget table:** register 3,721,828 gas · transfer 4,030,277 · withdraw 3,911,372 · deposit 147,936 (+52,139 approve) · applyPending 95,180. One full value pass (approve → deposit → transfer → applyPending → withdraw) costs **0.0000824 ETH** at 0.01 gwei. Prove times with a cached VK: 194–228 ms desktop, 541 ms on an Android browser.

## 19 · Resolved spec questions (accepted 2026-09-16)

Every ambiguity the first implementations hit is resolved here in favour of the reading already in
the code, so nothing has to change. These are normative; the sections above are read subject to them.
Ids `C*` were raised by the contracts implementation, `K*` by the SDK implementation and `X*` by the spike.

**Contracts**

| # | Question | Resolution |
|---|---|---|
| C1 | Public-input order and encoding | The order the contracts build (`DarkKeyRegistry.register`, `DarkVault._transferInputs`, `DarkVault._withdrawInputs`; the same order as §6's table) is canonical: addresses left-padded `uint160`, everything else a big-endian `uint256` in one `bytes32`; `ct` before the cap bounds. Circuits and the SDK re-derive this order; `circuits/public_inputs.toml` is the hand-maintained machine-readable copy of it, which `circuits/tools/check-manifest.mjs` asserts against every compiled circuit. |
| C2 | `withdraw(to == vault)` | `BadRecipient()`; `to == 0` keeps `ZeroAddress()`. |
| C3 | `AmountTooLarge` unreachable on deposit | Keep the check in §5's order; only `withdraw` can raise it. |
| C4 | `AmountZero` only on withdraw | Correct: a zero deposit is `BelowMinDeposit` because `minDeposit ≥ 1` in every caps column. |
| C5 | `setCaps` with `minTransfer == 0` | Reverts `ExceedsHardCeiling` (the `minTransfer ≥ 1` rule is a ceiling check). No new error. |
| C6 | `tightenCaps` field set | Compares all six fields, `minDeposit` included: the guardian can never loosen anything. |
| C7 | Registered test | `keyOf(a).y != 0`. The group order is prime, so no valid point has `y == 0`; no extra flag. |
| C8 | `applyPending` requires registration | Yes, per §5's table; an unregistered account cannot hold pending state anyway. |
| C9 | Event fields | All event amounts, ciphertexts, `tvlAfter`, `netInflowAfter` and `nonceAfter` are post-state. |
| C10 | Constructor guardian | May not be zero: reverts `ZeroAddress`. |

**Keys, encryption, SDK**

| # | Question | Resolution |
|---|---|---|
| K1 | `H` counter encoding | `keccak256(ascii("DARK-CB-1/generator/H") ‖ u32be(i))`, no separator and no length prefix, `i` from 0. CI cross-checks the SDK's `H` against the circuit's. (*Implementation note (2026-10-07):* that CI is the maintainers' spec check, which is not published; in the published repositories only `circuits/tools/gen_prover.mjs` compares the two, and CI does not run it. See the note under §3, Generators.) |
| K2 | `H` sign convention | Take either root, negate when `y & 1 == 1`, so the stored `y` is even. |
| K3 | `ctr` start in the `s` info string | Starts at 0; the normal path is `ctr = 0` and `keys.v1.json` pins it. |
| K4 | HKDF Expand hash | HKDF-SHA512 throughout (64-byte wide output for `s`, 32 bytes for `k_ae`). The hint KDF stays HKDF-SHA256 as separately specified. |
| K5 | `HashToScalar` rejection | Re-hash `msg ‖ u8(attempt)`. The Noir side must match if it is ever hashed in-circuit. |
| K6 | `s` width in the hedged preimage | 32-byte big-endian. |
| K7 | Point bytes in KDF input | `x(32) ‖ y(32)` big-endian; the identity is 64 zero bytes and never legitimately appears. |
| K8 | `aeBalance` nonce | A fresh CSPRNG draw per seal, not a counter, so a reused `k_ae` at the same account nonce stays safe. |
| K9 | `openBalance` on a bad tag | Returns `null`, never throws, so §7 step 5 can fall back to history replay / BSGS (the caps-at-0 + garbage-hint + indexer-down drill depends on it). |

**Spike corrections to the sections above**

| # | Correction |
|---|---|
| X1 | §6's "identity is handled via `is_infinite`" does not hold: `EmbeddedCurvePoint` in nargo 1.0.0-beta.22 has no `is_infinite` field and the identity is `(0, 0)`. Circuits and the SDK encode the identity as `(0, 0)`; `DarkGrumpkin` already does. |
| X2 | Public-input counting: `DarkPublicInputs` and the verifier call site count **wire** public inputs (10 in the spike), not the VK's `publicInputsSize` (18). The difference is 8 pairing-point limbs that travel inside the proof. |
| X4 | The generated Honk verifier is **three contracts**: `HonkVerifier` + `RelationsLib` + `ZKTranscriptLib`, linked at compile time. Deploy scripts deploy all three, the deployment record (`contracts/deployments/deployments.ts`, `contracts/deployments/verifier-codehashes.json`) records all three, and the verifier-codehash check pins the library addresses as well (a swapped library changes behaviour without changing the verifier's codehash). Confirmed on 46630 on 2026-09-16. |
| X3 | `evm_version = cancun` (shanghai works and costs ~31k more gas; prague is identical to cancun). No hardfork argument with Robinhood Chain is needed. |

## How to change this spec

**The spec is frozen (2026-09-27).** §3 (encodings), §4 (key derivation) and §6 (circuit statements) are fingerprinted, and a check in the maintainers' CI fails if their wording changes (whitespace-only reflows do not count). To change one: (1) open a PR with a two-person review; (2) bump the `SPEC_VERSION` line at the top; (3) re-record the fingerprints with the check's refreeze mode, which **refuses if the version line has not changed**. Every other section may still be edited normally — clarifications, operational detail, new measurements.

Before the freeze (2026-09-27), this document tracked §6 and §7 of an internal planning document (the source of the older `§6.n` citations described at the top) and could change freely. After the freeze, any change to §3 (encodings), §4 (key derivation) or §6 (circuit statements) requires a two-person-reviewed PR and a bump of `SPEC_VERSION`. Other sections still need a two-person-reviewed PR.
