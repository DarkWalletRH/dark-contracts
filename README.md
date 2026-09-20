<div align="center">

<img src=".github/assets/logo.png" alt="Dark" width="112" />

# Dark Contracts

**The on-chain half of Dark: the vault, the key registry, the Noir circuits and their verifiers — on Robinhood Chain.**

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-f5a0c4?style=flat-square)](#license)
[![Solidity 0.8.28](https://img.shields.io/badge/solidity-0.8.28-363636?style=flat-square&logo=solidity&logoColor=white)](contracts/foundry.toml)
[![Noir 1.0.0-beta.22](https://img.shields.io/badge/noir-1.0.0--beta.22-7b61ff?style=flat-square)](circuits/VERSIONS.toml)
[![Barretenberg 5.0](https://img.shields.io/badge/barretenberg-5.0-1f6feb?style=flat-square)](circuits/VERSIONS.toml)
[![Network: testnet](https://img.shields.io/badge/network-testnet%2046630-f5a0c4?style=flat-square)](#deployed-contracts)
[![Status: pre-audit](https://img.shields.io/badge/status-pre--audit-orange?style=flat-square)](#status)

[Website](https://darkwallet.cash) · [Whitepaper](https://darkwallet.cash/whitepaper) · [Docs](https://darkwallet.cash/docs) · [SDK](https://github.com/DarkWalletRH/dark-sdk) · [Exit tool](https://github.com/DarkWalletRH/dark-exit) · [Starter template](https://github.com/DarkWalletRH/Darkwallet)

</div>

---

## Overview

Dark keeps USDG balances **encrypted on chain**. A balance is a twisted ElGamal ciphertext over the
Grumpkin curve; a private transfer moves value between two ciphertexts without revealing the amount,
and a zero-knowledge proof shows the sender had it. Deposits and withdrawals are ordinary public token
transfers. There is no pool and no anonymity set: Dark hides *how much*, never *who*.

This release, **v0.9.0**, is the reviewed and hardened deployment on the Robinhood Chain **testnet**
of 2026-09-20. Among the hardening changes, `applyPending` accepts a lower bound on the pending-transfer
count instead of an exact match, so an incoming transfer that lands between the read and the
transaction can no longer make it revert.

This repository is everything that runs on chain or is proved off chain:

| Part | What it does |
|---|---|
| **`DarkVault`** | Holds the USDG. `deposit`, `applyPending`, `transfer` (private), `withdraw`. Caps with immutable hard ceilings, a guardian that can only pause and tighten caps, an owner that acts only through a 48-hour timelock. No proxy, no `delegatecall`, no upgrade path. |
| **`DarkKeyRegistry`** | Maps an account to its Grumpkin public key, proven with `dark_register`. Immutable, no owner, never pausable. |
| **`DarkGrumpkin`** | Clean-room Grumpkin arithmetic (`y² = x³ − 17` over F_r): on-curve and canonical checks, add, neg, sub, `mulG`. Differentially tested against `@noble/curves`. |
| **`MockUSDG`** | The testnet stand-in for USDG: 6 decimals, public `mint`. It has no value. |
| **Circuits** (`circuits/`) | `dark_register`, `dark_transfer`, `dark_withdraw` and `dark_disclose_range`, written in Noir. UltraHonk, keccak transcript, ZK on. |
| **Verifiers** | `bb`-generated Solidity verifiers for the three on-chain circuits, plus the two shared libraries they link. |

> [!NOTE]
> `withdraw`, `applyPending` and `register` can never be paused. Whatever happens to Dark's servers or
> keys, every user can always leave with their funds.

## Deployed contracts

### Robinhood Chain testnet — chain id `46630`

| Contract | Address |
|---|---|
| `DarkVault` | [`0x14fa77C25357C1Dc7de0DD7F36e0EbE807110aB7`](https://explorer.testnet.chain.robinhood.com/address/0x14fa77C25357C1Dc7de0DD7F36e0EbE807110aB7) |
| `DarkKeyRegistry` | [`0x850907E912c5F89B233252E3633BEfaBe66232B2`](https://explorer.testnet.chain.robinhood.com/address/0x850907E912c5F89B233252E3633BEfaBe66232B2) |
| `DarkTimelock` (owner, 48 h) | [`0x4522d92128219FE0F3DcFf17324617881C3f7D05`](https://explorer.testnet.chain.robinhood.com/address/0x4522d92128219FE0F3DcFf17324617881C3f7D05) |
| `DarkRegisterVerifier` | [`0x97dB97Eec8d722a5C48F0Fb1612D1DC160A7c085`](https://explorer.testnet.chain.robinhood.com/address/0x97dB97Eec8d722a5C48F0Fb1612D1DC160A7c085) |
| `DarkTransferVerifier` | [`0xAf2332Ef3910A9328418b4963BA0E50b9d5846Fe`](https://explorer.testnet.chain.robinhood.com/address/0xAf2332Ef3910A9328418b4963BA0E50b9d5846Fe) |
| `DarkWithdrawVerifier` | [`0x0905e66f00Bd3261A8E32Dc4b6Cb060a6B8A8f74`](https://explorer.testnet.chain.robinhood.com/address/0x0905e66f00Bd3261A8E32Dc4b6Cb060a6B8A8f74) |
| `RelationsLib` / `ZKTranscriptLib` | `0xb771CCeda9eABf17A0E26A1109bb36fb6ea8eE79` / `0x43804a423f7Da1297C91C47Fc959DBe937788e4c` |
| `MockUSDG` | [`0x77FfdE2D07f08f847944B6951dDd9243ae5EE950`](https://explorer.testnet.chain.robinhood.com/address/0x77FfdE2D07f08f847944B6951dDd9243ae5EE950) |

Deployed at block `122104964` (2026-09-20). RPC: `https://rpc.testnet.chain.robinhood.com`. The vault's
owner is `DarkTimelock`. On this testnet deployment the guardian, and the holder of the timelock's
proposer, executor and canceller roles, is the deployer's externally owned account; no multisig is
involved (`guardian()` on the vault returns it). This release has no mainnet deployment.

The record of these addresses is `contracts/deployments/deployments.ts`. The vault, the registry, the
three verifiers and their two libraries are pinned with their runtime codehashes in
`contracts/deployments/verifier-codehashes.json`.

**Testnet caps** sit at the vault's immutable hard ceilings (USDG): min deposit 0.000001 · max deposit
2,500 · max inflow per account 10,000 · min transfer 0.01 · max transfer 2,500 · total value locked
250,000.

## Reproduce the deployed bytecode

The verifiers do not have to be taken on trust. One command rebuilds the three verifiers and their two
libraries the way they were deployed — same compiler profile, same source, same linked library
addresses, same immutables — and compares the runtime bytecode's keccak with the pinned on-chain
codehash. It needs [Foundry](https://book.getfoundry.sh) (`forge` and `cast`) and Node.js 22, and
nothing from npm:

```bash
node scripts/check-verifier-bytecode.mjs
```

Expected: five `ok` lines for chain `46630` (`RelationsLib`, `ZKTranscriptLib` and the three
verifiers), each ending in *matches its pin*. In this release the vault and registry rows of the pin
file are not rebuilt by the script: they are pinned so that any change of code at their addresses is
detected. Compare them with the chain directly:

```bash
cast codehash 0x14fa77C25357C1Dc7de0DD7F36e0EbE807110aB7 --rpc-url https://rpc.testnet.chain.robinhood.com
```

`scripts/check-verifier-pins.mjs` ties each verifier to the circuit it was generated from: the SHA-256
of `circuits/verifiers/<circuit>/Verifier.sol` must equal the one recorded in `circuits/manifest.json`,
which in turn records the ACIR hash, the verification key and the gate count of each circuit. Expected:
seven `ok` lines for chain `46630`. Both checks run in CI.

## Trust model

| Who | Can | Cannot |
|---|---|---|
| **Anyone** | deposit, transfer privately, withdraw, register a key, leave at any time | read another account's balance or a transfer's amount |
| **Guardian** (the deployer's account on this testnet) | `pause()` deposits and transfers; tighten caps instantly | unpause, raise caps, move funds, change the verifiers |
| **Owner** (`DarkTimelock`, 48 h) | unpause, raise caps up to the hard ceilings, replace the guardian, recover tokens other than USDG, hand ownership on (two-step) | exceed the hard ceilings, touch USDG, change the registry, token or verifiers, renounce ownership, upgrade anything |

The registry, token, verifiers and hard ceilings are immutables set in the constructor. Every scheduled
owner action is visible on the timelock for 48 hours before it can execute.

## Repository layout

```
contracts/
  src/                 DarkVault, DarkKeyRegistry, DarkGrumpkin, interfaces, MockUSDG (testnet)
  script/              DeployDarkTestnet.s.sol, the mutation runner
  test/                unit, boundary, deploy-script, differential (Grumpkin vs @noble/curves) and invariant tests
  deployments/         deployments.ts (the deployment record) + verifier-codehashes.json (the pins)
  foundry.toml         solc 0.8.28 · cancun · via-IR · 1000 runs
circuits/
  lib/                 shared Noir: Grumpkin point checks, twisted ElGamal, range and binding helpers
  register/ transfer/ withdraw/ disclose_range/
  verifiers/           bb output for the three on-chain circuits (what was deployed)
  evm/test/            Foundry tests that drive the generated verifiers with real proofs
  tools/               build, manifest check, public-input flip test, prover-input, fixture and SRS generators
  foundry.toml         the verifier profile: solc 0.8.30 · cancun · 200 runs, no via-IR
  manifest.json        ACIR hash, VK and gate count per circuit; checked in CI
  public_inputs.toml   the normative public-input order of each circuit
  VERSIONS.toml        the exact nargo / bb versions
scripts/
  check-verifier-pins.mjs       verifier ↔ circuit tie
  check-verifier-bytecode.mjs   deployed verifier bytecode ↔ this source
```

## Build and test

**Contracts** — [Foundry](https://book.getfoundry.sh) and Node.js 22:

```bash
cd contracts
npm ci                       # OpenZeppelin 5, forge-std and @noble/curves come from npm; no submodules
forge test                   # unit, boundary, deploy-script, differential and invariant tests
forge test --match-path "test/invariant/*"   # the invariant suite alone
```

**Circuits** — the pinned toolchain from `circuits/VERSIONS.toml`:

```bash
noirup --version 1.0.0-beta.22
bbup   --version 5.0.0-nightly.20260522
cd circuits
nargo test --workspace
node tools/check-manifest.mjs       # recompiles and recomputes the manifest
node tools/flip-public-inputs.mjs   # dark_disclose_range rejects every flipped public input
forge test                          # the generated verifiers, driven with real proofs
```

| Circuit | Gates | Public inputs |
|---|---|---|
| `dark_register` | 3,586 | 5 |
| `dark_transfer` | 7,724 | 21 |
| `dark_withdraw` | 5,767 | 12 |
| `dark_disclose_range` | 5,112 | 9 (verified off chain) |

## Status

Pre-audit, testnet only. The contracts, circuits and verifiers in this release are what is deployed
on chain `46630`. `MockUSDG` has no value; do not send real assets to these addresses.

## Security

Please report vulnerabilities privately to **team@darkwallet.cash**. Do not open a public issue.
Include the affected contract or circuit, the chain, and where possible a reproduction (a Foundry test
or a witness). Anything that lets someone take, move or freeze funds, or learn a balance or a transfer
amount, is in scope. See
[darkwallet.cash/.well-known/security.txt](https://darkwallet.cash/.well-known/security.txt).

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option. The
contracts, circuits and deployment record carry an `MIT OR Apache-2.0` SPDX header; the deploy script
and Solidity tests are MIT. The `bb`-generated verifiers, and the tests that drive them, are
Apache-2.0 as generated.
