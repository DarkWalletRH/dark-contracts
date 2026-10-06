<div align="center">

<img src=".github/assets/logo.png" alt="Dark" width="112" />

# Dark Contracts

**The on-chain half of Dark: the vault, the key registry, the Noir circuits and their verifiers — on Robinhood Chain.**

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-f5a0c4?style=flat-square)](#license)
[![Solidity 0.8.28](https://img.shields.io/badge/solidity-0.8.28-363636?style=flat-square&logo=solidity&logoColor=white)](contracts/foundry.toml)
[![Noir 1.0.0-beta.22](https://img.shields.io/badge/noir-1.0.0--beta.22-7b61ff?style=flat-square)](circuits/VERSIONS.toml)
[![Barretenberg 5.0](https://img.shields.io/badge/barretenberg-5.0-1f6feb?style=flat-square)](circuits/VERSIONS.toml)
[![CI](https://img.shields.io/github/actions/workflow/status/DarkWalletRH/dark-contracts/ci.yml?branch=main&style=flat-square&label=CI)](.github/workflows/ci.yml)
[![Status: pre-audit](https://img.shields.io/badge/status-pre--audit-orange?style=flat-square)](#status)

[Website](https://darkwallet.cash) · [Whitepaper](https://darkwallet.cash/whitepaper) · [Docs](https://darkwallet.cash/docs) · [SDK](https://github.com/DarkWalletRH/dark-sdk) · [Exit tool](https://github.com/DarkWalletRH/dark-exit) · [Starter template](https://github.com/DarkWalletRH/Darkwallet)

</div>

---

## Overview

Dark keeps USDG balances **encrypted on chain**. A balance is a twisted ElGamal ciphertext over the
Grumpkin curve; a private transfer moves value between two ciphertexts without revealing the amount,
and a zero-knowledge proof shows the sender had it. Deposits and withdrawals are ordinary public token
transfers. There is no pool and no anonymity set: Dark hides *how much*, never *who*.

This repository is everything that runs on chain or is proved off chain:

| Part | What it does |
|---|---|
| **`DarkVault`** | Holds the USDG. `deposit`, `applyPending`, `transfer` (private), `withdraw`. Caps with immutable hard ceilings, a guardian that can only pause and tighten caps, an owner that acts only through a 48-hour timelock. No proxy, no `delegatecall`, no upgrade path. |
| **`DarkKeyRegistry`** | Maps an account to its Grumpkin public key, proven with `dark_register`. Immutable, no owner, never pausable. |
| **`DarkGrumpkin`** | Clean-room Grumpkin arithmetic (`y² = x³ − 17` over F_r): on-curve and canonical checks, add, neg, sub, `mulG`. Differentially tested against `@noble/curves`. |
| **Circuits** (`circuits/`) | `dark_register`, `dark_transfer`, `dark_withdraw` and `dark_disclose_range`, written in Noir. UltraHonk, keccak transcript, ZK on. |
| **Verifiers** | `bb`-generated Solidity verifiers for the three on-chain circuits, plus the two shared libraries they link. |

> [!NOTE]
> `withdraw`, `applyPending` and `register` can never be paused. Whatever happens to Dark's servers or
> keys, every user can always leave with their funds.

## Deployed contracts

### Robinhood Chain mainnet — chain id `4663`

| Contract | Address |
|---|---|
| `DarkVault` | [`0xeD7a0c6899a6AC94Aea7A5b2F8f24a948042DA9C`](https://robinhoodchain.blockscout.com/address/0xeD7a0c6899a6AC94Aea7A5b2F8f24a948042DA9C) |
| `DarkKeyRegistry` | [`0x2E245135FD561965CC546c14C23C9162f36d9C87`](https://robinhoodchain.blockscout.com/address/0x2E245135FD561965CC546c14C23C9162f36d9C87) |
| `DarkTimelock` (owner, 48 h) | [`0xADbF7E3cf5418BeAC10BcDD3BBD9a51dc19EBC54`](https://robinhoodchain.blockscout.com/address/0xADbF7E3cf5418BeAC10BcDD3BBD9a51dc19EBC54) |
| Owner Safe (2-of-3) | `0xD1A9F36662561844e6d0B3e9f4cf908695e72305` |
| Guardian Safe (1-of-2) | `0x87879CbAfC1E92528b950444E693D3b2F07CB1d7` |
| `DarkRegisterVerifier` | [`0xAf2332Ef3910A9328418b4963BA0E50b9d5846Fe`](https://robinhoodchain.blockscout.com/address/0xAf2332Ef3910A9328418b4963BA0E50b9d5846Fe) |
| `DarkTransferVerifier` | [`0x0905e66f00Bd3261A8E32Dc4b6Cb060a6B8A8f74`](https://robinhoodchain.blockscout.com/address/0x0905e66f00Bd3261A8E32Dc4b6Cb060a6B8A8f74) |
| `DarkWithdrawVerifier` | [`0xaa921526C05b2F11204525D28A81391d91C4258a`](https://robinhoodchain.blockscout.com/address/0xaa921526C05b2F11204525D28A81391d91C4258a) |
| `RelationsLib` / `ZKTranscriptLib` | `0x43804a423f7Da1297C91C47Fc959DBe937788e4c` / `0x97dB97Eec8d722a5C48F0Fb1612D1DC160A7c085` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |

Deployed at block `75151289` (2026-09-28). Every contract in this table with a link is
source-verified on [Blockscout](https://robinhoodchain.blockscout.com) as an exact match. The owner
Safe holds the timelock's proposer, executor and canceller roles; the timelock is the vault's owner. The vault, the registry, the three verifiers and
their two libraries are pinned with their runtime codehashes in
`contracts/deployments/verifier-codehashes.json`.

The testnet deployment (chain id `46630`: `MockUSDG`, caps at the hard ceilings) is recorded in
`contracts/deployments/deployments.ts` and exported by the npm package as `deployments[46630]`.

**Launch caps** (USDG): min deposit 1 · max deposit 1,000 · max inflow per account 2,500 · min transfer
0.01 · max transfer 1,000 · total value locked 50,000. The vault's immutable hard ceilings are 2,500
(deposit) · 10,000 (inflow per account) · 2,500 (transfer) · 250,000 (total value locked). Raising a
cap goes through the timelock; lowering one is instant for the guardian.

## Reproduce the deployed bytecode

Nothing above has to be taken on trust. One command rebuilds every deployed contract the way it was
deployed — same compiler profile, same source, same linked library addresses, same constructor
immutables — and compares the runtime bytecode's keccak with the pinned on-chain codehash. It needs
[Foundry](https://book.getfoundry.sh) (`forge` and `cast`) and Node.js 22:

```bash
cd contracts && npm ci && cd ..
node scripts/check-verifier-bytecode.mjs
```

Expected: fourteen `ok` lines (seven contracts on each chain), each ending in *matches its pin*, and a
summary line that names both chains. The pins live in `contracts/deployments/verifier-codehashes.json`;
read them back from chain with `cast codehash <address> --rpc-url https://rpc.mainnet.chain.robinhood.com`.

`scripts/check-verifier-pins.mjs` ties each verifier to the circuit it was generated from: the SHA-256
of `circuits/verifiers/<circuit>/Verifier.sol` must equal the one recorded in `circuits/manifest.json`,
which in turn records the ACIR hash, the verification key and the gate count of each circuit. Both
checks run in CI on every push to `main` and on every pull request (see the CI badge).

## Using the npm package

`@darkwalletrh/dark-contracts` carries what an integrator needs and nothing else: the ABIs, the
deployment record, the bytecode pins and the Solidity sources. It has no dependencies. Install it from
a release tag:

```bash
npm install github:DarkWalletRH/dark-contracts#v1.0.1
```

| Export | Contents |
|---|---|
| `darkVaultAbi` | `DarkVault`: functions, events and custom errors |
| `darkKeyRegistryAbi` | `DarkKeyRegistry` |
| `darkVerifierAbi` | `verify(bytes, bytes32[])`, the interface the three generated verifiers implement |
| `timelockAbi` | OpenZeppelin `TimelockController`, deployed as `DarkTimelock` |
| `deployments` | Keyed by chain id (`4663`, `46630`): `chainId`, `vault`, `registry`, `verifiers`, `libraries`, `timelock`, `guardian`, `usdg`, `deployBlock`, `codehashes`, `rpcUrl`, `explorer` |

The ABIs are typed as literals, so [viem](https://viem.sh) and abitype infer function names, arguments
and return types. Check the code at an address before you rely on it:

```ts
import { darkVaultAbi, deployments } from '@darkwalletrh/dark-contracts';
import { createPublicClient, http, keccak256 } from 'viem';

const dark = deployments[4663];
const client = createPublicClient({ transport: http(dark.rpcUrl) });

const code = await client.getCode({ address: dark.vault });
if (!code || keccak256(code) !== dark.codehashes.DarkVault) throw new Error('unexpected vault bytecode');

const caps = await client.readContract({ address: dark.vault, abi: darkVaultAbi, functionName: 'caps' });
```

`deployBlock` is a number; pass `BigInt(dark.deployBlock)` as viem's `fromBlock`. The package also
ships `abi/<Contract>.json` (plain ABI JSON for other toolchains), `contracts/deployments/` and
`contracts/src/`. The interfaces in `contracts/src/interfaces/` have no imports outside that directory
and pin `pragma solidity 0.8.28`; with Foundry, map them in with
`@darkwalletrh/dark-contracts/=node_modules/@darkwalletrh/dark-contracts/`.

`abi/`, `index.js` and `index.d.ts` are generated by `node scripts/build-abi.mjs` (Foundry,
`contracts/node_modules` and Node.js ≥ 22.18). The generator refuses to write if the deployment record
and the pins disagree on an address. CI runs it with `--check` and fails if the committed files differ
from what the sources produce.

## Trust model

| Who | Can | Cannot |
|---|---|---|
| **Anyone** | deposit, transfer privately, withdraw, register a key, leave at any time | read another account's balance or a transfer's amount |
| **Guardian** (Safe, 1-of-2) | `pause()` deposits and transfers; tighten caps instantly | unpause, raise caps, move funds, change the verifiers |
| **Owner** (Safe, 2-of-3, through a 48 h timelock) | unpause, raise caps up to the hard ceilings, replace the guardian, recover tokens other than USDG, hand ownership on (two-step) | exceed the hard ceilings, touch USDG, change the registry, token or verifiers, renounce ownership, upgrade anything |
| **Deployer** | nothing after deployment | — |

The registry, token, verifiers and hard ceilings are immutables set in the constructor. Every scheduled
owner action is visible on the timelock for 48 hours before it can execute.

## Repository layout

```
contracts/
  src/                 DarkVault, DarkKeyRegistry, DarkGrumpkin, interfaces, MockUSDG (testnet)
  script/              DeployDarkMainnet.s.sol, DeployDarkTestnet.s.sol, the mutation runner
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
  check-verifier-bytecode.mjs   deployed bytecode ↔ this source
  lib/verifier-recipe.mjs       the verifier build recipe the bytecode check replays
  build-abi.mjs                 generates the npm package's abi/, index.js and index.d.ts
abi/                   generated ABIs
index.js, index.d.ts   the npm package entry point (generated)
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

Pre-audit. The contracts, circuits and verifiers in this repository are byte-for-byte what is deployed
on mainnet, under launch caps. Do not rely on them to secure funds you cannot afford to lose. The beta
notice shown in the wallet reads from the same deployment record.

## Security

Please report vulnerabilities privately to **team@darkwallet.cash**. Do not open a public issue.
Include the affected contract or circuit, the chain, and where possible a reproduction (a Foundry test
or a witness). Anything that lets someone take, move or freeze funds, or learn a balance or a transfer
amount, is in scope. See
[darkwallet.cash/.well-known/security.txt](https://darkwallet.cash/.well-known/security.txt).

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option. The
contracts, circuits and deployment record carry an `MIT OR Apache-2.0` SPDX header; the deploy scripts
and Solidity tests are MIT. The `bb`-generated verifiers, and the tests that drive them, are
Apache-2.0 as generated.
