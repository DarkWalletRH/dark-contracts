// Deploy the two Honk libraries and the three verifiers to a chain, and pin them.
//
//   node scripts/deploy-verifiers.mjs --rpc-url <url> [--pin-file <path>] -- <forge auth flags>
//   e.g.  … --rpc-url https://rpc.mainnet.chain.robinhood.com -- \
//           --account <keystore> --password-file <password-file>
//
// On testnet this was done by hand with `forge create`, and the recipe had to be recovered from the
// chain afterwards. This is that recipe as the thing that ships: the deploy-time
// sources from scripts/lib/verifier-recipe.mjs, the libraries from a build with no library
// settings, each verifier linked to exactly its own two. check:verifier-bytecode then proves the
// result byte-for-byte.
//
// Each contract's row is written to the pin file as soon as it lands, and a row whose address
// already carries its pinned codehash is skipped — so an interrupted run is resumed by running it
// again, never by redeploying what is already there.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CIRCUITS, LIBRARIES, SOURCES, makeProject } from './lib/verifier-recipe.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const argv = process.argv.slice(2);
const dash = argv.indexOf('--');
const own = dash < 0 ? argv : argv.slice(0, dash);
const auth = dash < 0 ? [] : argv.slice(dash + 1);
const opt = (name) => {
  const i = own.indexOf(name);
  return i < 0 ? undefined : own[i + 1];
};
const rpc = opt('--rpc-url');
const pinFile = opt('--pin-file') ?? join(ROOT, 'contracts/deployments/verifier-codehashes.json');
if (!rpc || auth.length === 0) {
  console.error('usage: deploy-verifiers.mjs --rpc-url <url> [--pin-file <path>] -- <forge auth flags>');
  process.exit(2);
}

const cast = (...a) => execFileSync('cast', a, { encoding: 'utf8' }).trim();
const chainId = cast('chain-id', '--rpc-url', rpc);
const pins = JSON.parse(readFileSync(pinFile, 'utf8'));
pins[chainId] ??= {};
const save = () => writeFileSync(pinFile, `${JSON.stringify(pins, null, 2)}\n`);

/** Skip a contract whose pinned address already carries its pinned code (a resumed run). */
function alreadyThere(name) {
  const row = pins[chainId][name];
  if (!row) return false;
  const live = cast('codehash', row.address, '--rpc-url', rpc);
  if (live.toLowerCase() === row.codehash.toLowerCase()) {
    console.log(`  skip ${name}: already at ${row.address} with its pinned code`);
    return true;
  }
  throw new Error(`${name} is pinned at ${row.address} but the code there does not match — resolve by hand, not by redeploying`);
}

function create(project, target, extra = []) {
  const out = execFileSync(
    'forge',
    ['create', target, '--rpc-url', rpc, '--broadcast', '--json', ...extra, ...auth],
    { cwd: project, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] },
  );
  const { deployedTo } = JSON.parse(out.slice(out.indexOf('{')));
  if (!/^0x[0-9a-fA-F]{40}$/.test(deployedTo ?? '')) throw new Error(`forge create ${target}: no address in ${out}`);
  return deployedTo;
}

function pin(name, address, extra = {}) {
  pins[chainId][name] = { address, codehash: cast('codehash', address, '--rpc-url', rpc), ...extra };
  save();
  console.log(`  ok   ${name} at ${address}`);
}

console.log(`chain ${chainId} via ${rpc}; pins → ${pinFile}`);
const project = makeProject();
try {
  // Libraries: a build with no library settings, as on testnet. Both live in every verifier file;
  // register.sol is the one they were created from.
  for (const lib of LIBRARIES) {
    if (alreadyThere(lib)) continue;
    pin(lib, create(project, `evm/src/register.sol:${lib}`));
  }
  for (const [name, crate] of Object.entries(SOURCES)) {
    if (alreadyThere(name)) continue;
    const file = `evm/src/${crate}.sol`;
    const libFlags = LIBRARIES.flatMap((lib) => ['--libraries', `${file}:${lib}:${pins[chainId][lib].address}`]);
    const verifierSolSha256 = createHash('sha256').update(readFileSync(join(CIRCUITS, 'verifiers', crate, 'Verifier.sol'))).digest('hex');
    pin(name, create(project, `${file}:HonkVerifier_${crate}`, libFlags), { verifierSolSha256 });
  }
} finally {
  rmSync(project, { recursive: true, force: true });
}

const p = pins[chainId];
console.log(`
Next — the vault and registry (contracts/script/DeployDarkMainnet.s.sol) take these:
  DARK_REGISTER_VERIFIER=${p.DarkRegisterVerifier.address}
  DARK_TRANSFER_VERIFIER=${p.DarkTransferVerifier.address}
  DARK_WITHDRAW_VERIFIER=${p.DarkWithdrawVerifier.address}
and \`npm run check:verifier-bytecode\` must pass on the updated pin file before anything is wired to them.`);
