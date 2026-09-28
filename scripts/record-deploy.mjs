// Turn a DeployDark{Testnet,Mainnet} broadcast into the committed record, mechanically.
//
//   node scripts/record-deploy.mjs 46630|4663
//
// Takes only the vault's address from forge's broadcast/…/run-latest.json and reads everything else
// back from the vault on chain — registry, all three verifiers, timelock, guardian, USDG — so the
// record is what the chain says, not what the deploy script meant (the testnet-only version
// never recorded the verifiers or the guardian). It cross-checks every verifier against its pin and
// the broadcast's own CREATEs, then rewrites the two places a deployment lives:
//   - contracts/deployments/verifier-codehashes.json  (DarkVault + DarkKeyRegistry rows)
//   - contracts/deployments/deployments.ts            (the chain's whole address block + deployBlock)
// and prints the ops/DEPLOYMENTS.md rows to append.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const CHAINS = {
  46630: { script: 'DeployDarkTestnet.s.sol', rpc: 'https://rpc.testnet.chain.robinhood.com', key: 'CHAIN_ID_TESTNET' },
  4663: { script: 'DeployDarkMainnet.s.sol', rpc: 'https://rpc.mainnet.chain.robinhood.com', key: 'CHAIN_ID_MAINNET' },
};
const CHAIN = process.argv[2];
const C = CHAINS[CHAIN];
if (!C) throw new Error(`usage: record-deploy.mjs ${Object.keys(CHAINS).join('|')}`);

const run = JSON.parse(readFileSync(join(ROOT, 'contracts/broadcast', C.script, CHAIN, 'run-latest.json'), 'utf8'));
// A real broadcast always carries receipts; only a dry-run file has none. Refuse rather than guess
// a deploy block — the indexer starts its mirror there, and a wrong one silently loses events.
if (!run.receipts?.length) throw new Error('no receipts: this looks like a dry-run file — broadcast first');
if (run.receipts.some((r) => Number(r.status) !== 1)) throw new Error('a transaction in this broadcast failed');
const deployBlock = Math.min(...run.receipts.map((r) => Number(r.blockNumber)));

// Two helpers, because `cast to-check-sum-address` is a pure local conversion and rejects --rpc-url.
const castRpc = (...args) => execFileSync('cast', [...args, '--rpc-url', C.rpc], { encoding: 'utf8' }).trim();
const checksum = (a) => execFileSync('cast', ['to-check-sum-address', a], { encoding: 'utf8' }).trim();
const read = (at, sig) => checksum(castRpc('call', at, sig));
const same = (a, b) => a.toLowerCase() === b.toLowerCase();

const created = Object.fromEntries(
  run.transactions.filter((t) => t.transactionType === 'CREATE').map((t) => [t.contractName, checksum(t.contractAddress)]),
);
if (!created.DarkVault) throw new Error('broadcast has no CREATE for DarkVault');
const vault = created.DarkVault;
const d = {
  vault,
  registry: read(vault, 'registry()(address)'),
  timelock: read(vault, 'owner()(address)'),
  guardian: read(vault, 'guardian()(address)'),
  usdg: read(vault, 'usdg()(address)'),
  transfer: read(vault, 'transferVerifier()(address)'),
  withdraw: read(vault, 'withdrawVerifier()(address)'),
};
d.register = read(d.registry, 'registerVerifier()(address)');

// The chain must agree with the broadcast and with the pins before either is written down.
for (const [name, key] of [['DarkKeyRegistry', 'registry'], ['TimelockController', 'timelock'], ['MockUSDG', 'usdg']]) {
  if (created[name] && !same(created[name], d[key])) throw new Error(`${name}: broadcast created ${created[name]}, vault reads ${d[key]}`);
}
const pinPath = join(ROOT, 'contracts/deployments/verifier-codehashes.json');
const pins = JSON.parse(readFileSync(pinPath, 'utf8'));
const p = pins[CHAIN] ?? {};
for (const [name, key] of [['DarkRegisterVerifier', 'register'], ['DarkTransferVerifier', 'transfer'], ['DarkWithdrawVerifier', 'withdraw']]) {
  if (!p[name] || !same(p[name].address, d[key])) throw new Error(`${name}: vault wired ${d[key]}, pin says ${p[name]?.address}`);
  if (!same(castRpc('codehash', d[key]), p[name].codehash)) throw new Error(`${name}: code at ${d[key]} does not match its pin`);
}
if (!same(castRpc('call', d.timelock, 'getMinDelay()(uint256)').split(' ')[0], '172800')) throw new Error('timelock delay is not 48 h');

// --- pin file -------------------------------------------------------------------------------------
const vaultHash = castRpc('codehash', d.vault);
const registryHash = castRpc('codehash', d.registry);
p.DarkVault = { ...p.DarkVault, address: d.vault, codehash: vaultHash };
p.DarkKeyRegistry = { ...p.DarkKeyRegistry, address: d.registry, codehash: registryHash };
pins[CHAIN] = p;
writeFileSync(pinPath, `${JSON.stringify(pins, null, 2)}\n`);

// --- SDK deployments --------------------------------------------------------------------------------
const sdkPath = join(ROOT, 'contracts/deployments/deployments.ts');
let sdk = readFileSync(sdkPath, 'utf8');
const start = sdk.indexOf(`[${C.key}]: {`);
if (start < 0) throw new Error(`deployments.ts has no [${C.key}] block`);
const end = sdk.indexOf('\n  },', start);
let seg = sdk.slice(start, end);
const anchor = '...UNDEPLOYED,\n';
if (!seg.includes(anchor)) throw new Error(`deployments.ts [${C.key}] block has no ...UNDEPLOYED`);
const setLine = (key, value) => {
  const re = new RegExp(`\\n(\\s*)${key}:[^\\n]*\\n`);
  if (re.test(seg)) seg = seg.replace(re, (_m, ind) => `\n${ind}${key}: ${value},\n`);
  else seg = seg.replace(anchor, `${anchor}    ${key}: ${value},\n`);
};
// Remove any existing verifiers object (possibly multi-line) before writing the new one.
seg = seg.replace(/\n\s*verifiers:\s*\{[\s\S]*?\},\n/, '\n');
setLine('deployBlock', `${deployBlock}n`);
setLine('usdg', `'${d.usdg}'`);
setLine('guardian', `'${d.guardian}'`);
setLine('timelock', `'${d.timelock}'`);
seg = seg.replace(anchor, `${anchor}    verifiers: {\n      register: '${d.register}',\n      transfer: '${d.transfer}',\n      withdraw: '${d.withdraw}',\n    },\n`);
setLine('registry', `'${d.registry}'`);
setLine('vault', `'${d.vault}'`);
sdk = sdk.slice(0, start) + seg + sdk.slice(end);
writeFileSync(sdkPath, sdk);

const today = new Date().toISOString().slice(0, 10);
console.log(`recorded chain ${CHAIN}, deploy block ${deployBlock}`);
for (const [k, v] of Object.entries(d)) console.log(`  ${k.padEnd(9)} ${v}`);
console.log('\nrows for ops/DEPLOYMENTS.md:');
console.log(`| ${today} | \`DarkTimelock\` (OZ TimelockController) | \`${d.timelock}\` | — | 48 h delay; proposer/executor/canceller = the owner Safe |`);
console.log(`| ${today} | \`DarkKeyRegistry\` | \`${d.registry}\` | — | immutable, no admin. codehash \`${registryHash}\` |`);
console.log(`| ${today} | **\`DarkVault\`** | **\`${d.vault}\`** | — | owner = the timelock, guardian = \`${d.guardian}\`, USDG \`${d.usdg}\`. codehash \`${vaultHash}\` |`);
