// rebuild the live verifiers from this commit and prove the pinned bytecode.
//
//   node scripts/check-verifier-bytecode.mjs      (npm run check:verifier-bytecode; needs forge + cast)
//
// Two review findings said the same thing from two angles. First: the verifiers were deployed by
// hand with `forge create --libraries`, `broadcast/` is gitignored, and two contradictory Foundry
// profiles existed — so given the commit alone nobody could reproduce the bytes now live at the
// pinned addresses. Second: the deploy script proves the code AT each pinned library address
// matches, but not that those addresses are the ones actually LINKED into a verifier's bytecode.
//
// One experiment settles both, and this script is that experiment made permanent: rebuild each
// contract the way it was deployed, and keccak the runtime bytecode. If it equals the pinned
// codehash, then the profile is the shipped one; the pinned library addresses are precisely what
// is linked in (any other address at those offsets changes the hash); and the immutables the chain
// carries are the ones the source defines. Byte-for-byte, metadata included.
//
// What "the way it was deployed" turned out to mean — each of these was learned by a mismatch:
//
//   1. The source. The chain was built from renamed copies of circuits/verifiers/<n>/Verifier.sol
//      at the path evm/src/<n>.sol, with ONLY the contract line changed (HonkVerifier →
//      HonkVerifier_<n>). That path and that exact content are inside the metadata hash. The copy
//      was gitignored, and tools/gen_fixtures.mjs — the only generator in the repo — suffixes every
//      top-level declaration, so it does not reproduce it either. This script regenerates the
//      deploy-time file itself, in a temporary project, so the recipe finally lives in git.
//   2. The library settings. `forge create --libraries` records the linked addresses in solc's
//      `settings.libraries`, which every contract in that compilation carries in its metadata. The
//      libraries were deployed first with no such setting; each verifier with exactly its own two.
//      So: one plain build for the libraries, then one build per verifier — never one build for all.
//   3. A library's runtime bytecode begins `PUSH20 <its own address>`, zeroed in the artifact and
//      filled at its own deployment. It is patched before hashing.
//   4. `BaseZKHonkVerifier`'s constructor args become immutables — also zeroed in the artifact and
//      filled at deployment. Foundry lists their slots under `immutableReferences`; the values are
//      computed from the source constants, not read from the chain, so nothing here is circular.
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// fileURLToPath, not .pathname: the checkout may live under a directory with a space, and .pathname
// hands back "%20", which readFileSync takes literally.
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const CIRCUITS = join(ROOT, 'circuits');
const pins = JSON.parse(readFileSync(join(ROOT, 'contracts/deployments/verifier-codehashes.json'), 'utf8'));

/** Pinned verifier name -> the crate whose bb output it was generated from. */
const SOURCES = { DarkRegisterVerifier: 'register', DarkTransferVerifier: 'transfer', DarkWithdrawVerifier: 'withdraw' };
/** The two shared libraries, deployed once and linked into all three verifiers. */
const LIBRARIES = ['RelationsLib', 'ZKTranscriptLib'];

/**
 * How `BaseZKHonkVerifier`'s constructor derives each immutable from the source constants, in
 * declaration order. bb generates this and it is identical across the three verifiers. If bb ever
 * changes it, the hash stops matching and this table is what to update — the hash is the oracle,
 * so a wrong entry here cannot produce a false pass.
 */
const IMMUTABLES = {
  $N: (c) => c('N'),
  $LOG_N: (c) => c('LOG_N'),
  $VK_HASH: (c) => c('VK_HASH'),
  $NUM_PUBLIC_INPUTS: (c) => c('NUMBER_OF_PUBLIC_INPUTS'),
  $MSMSize: (c) => c('NUMBER_UNSHIFTED_ZK') + c('LOG_N') + c('LIBRA_COMMITMENTS') + 2n,
};

// `cast keccak` rather than a JS library: this runs in the circuits CI job, which has foundry on
// PATH and no node_modules.
const keccak = (hex) => execFileSync('cast', ['keccak', `0x${hex.replace(/^0x/, '')}`], { encoding: 'utf8' }).trim();
const word = (v) => v.toString(16).padStart(64, '0');
const same = (a, b) => a.toLowerCase() === b.toLowerCase();

let failures = 0;
const fail = (m) => { console.error(`  FAIL ${m}`); failures++; };
const ok = (m) => console.log(`  ok   ${m}`);

/** The deploy-time source: bb's output with only the contract line renamed (see note 1). */
function deployTimeSource(crate) {
  const bbOutput = readFileSync(join(CIRCUITS, 'verifiers', crate, 'Verifier.sol'), 'utf8');
  const renamed = bbOutput.replace(/^contract HonkVerifier is /m, `contract HonkVerifier_${crate} is `);
  if (renamed === bbOutput) throw new Error(`${crate}: could not find 'contract HonkVerifier is' to rename`);
  return renamed;
}

/**
 * Evaluate a `constant NAME = <expr>;` from a Solidity source, resolving other constants
 * recursively. The generated verifier only uses integer literals, names, + - * and parentheses,
 * and the expression is checked to be exactly that before it is evaluated.
 */
function constantsOf(source) {
  const raw = Object.fromEntries([...source.matchAll(/constant\s+(\w+)\s*=\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));
  const memo = new Map();
  const ev = (name) => {
    if (memo.has(name)) return memo.get(name);
    if (!(name in raw)) throw new Error(`constant ${name} not found in source`);
    let expr = raw[name];
    for (const ref of [...new Set(expr.match(/[A-Za-z_]\w*/g) ?? [])]) {
      if (ref in raw) expr = expr.replace(new RegExp(`\\b${ref}\\b`, 'g'), ev(ref).toString());
    }
    if (!/^[0-9a-fA-Fx+\-*()\s]+$/.test(expr)) throw new Error(`unexpected expression for ${name}: ${raw[name]}`);
    const value = Function(`return (${expr.replace(/\b(0x[0-9a-fA-F]+|\d+)\b/g, '$1n')});`)();
    memo.set(name, value);
    return value;
  };
  return ev;
}

/** Immutable declarations of the base contract, in source order. */
const declaredImmutables = (source) => [...source.matchAll(/^\s*uint256\s+internal\s+immutable\s+(\$\w+);/gm)].map((m) => m[1]);

/** A throwaway Foundry project with the committed profile and the deploy-time sources. */
function makeProject() {
  const dir = mkdtempSync(join(tmpdir(), 'dark-verifier-check-'));
  copyFileSync(join(CIRCUITS, 'foundry.toml'), join(dir, 'foundry.toml'));
  mkdirSync(join(dir, 'evm', 'src'), { recursive: true });
  for (const crate of Object.values(SOURCES)) writeFileSync(join(dir, 'evm', 'src', `${crate}.sol`), deployTimeSource(crate));
  return dir;
}

/** `forge build` in the project, into its own out dir, with optional --libraries flags. */
function build(project, outName, libFlags = []) {
  execFileSync('forge', ['build', '--force', ...libFlags], {
    cwd: project,
    env: { ...process.env, FOUNDRY_OUT: outName, FOUNDRY_CACHE_PATH: `${outName}-cache` },
    stdio: ['ignore', 'ignore', 'inherit'],
  });
  return (contract, file) => {
    const p = join(project, outName, file, `${contract}.json`);
    return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null;
  };
}

const project = makeProject();
try {
  for (const [chainId, chainPins] of Object.entries(pins)) {
    if (chainId === '_') continue;
    console.log(`chain ${chainId}`);

    // --- libraries: a plain build (no --libraries setting), self-address patched, then hashed -----
    console.log('  forge build (plain, for the libraries)…');
    const plain = build(project, 'out-libs');
    for (const lib of LIBRARIES) {
      const pin = chainPins[lib];
      if (!pin) { fail(`${lib}: not pinned for chain ${chainId}`); continue; }
      const art = plain(lib, 'register.sol');
      if (!art) { fail(`${lib}: no artifact`); continue; }
      let code = art.deployedBytecode.object.replace(/^0x/, '');
      // Assert the guard is where we think it is, so a compiler that moves it fails here rather
      // than letting us patch twenty bytes of something else.
      if (code.slice(0, 2) !== '73') { fail(`${lib}: runtime does not start with PUSH20 (0x73)`); continue; }
      if (code.slice(2, 42) !== '0'.repeat(40)) { fail(`${lib}: expected a zeroed self-address at byte 1`); continue; }
      code = '73' + pin.address.replace(/^0x/, '').toLowerCase() + code.slice(42);
      const got = keccak(code);
      same(got, pin.codehash)
        ? ok(`${lib}: rebuilt, self-address patched — matches its pin`)
        : fail(`${lib}: rebuilt ${got.slice(0, 18)}… ≠ pinned ${pin.codehash.slice(0, 18)}… — the profile has drifted from what shipped`);
    }

    // --- verifiers: one build each, linked to exactly its own two libraries, immutables filled ----
    for (const [name, crate] of Object.entries(SOURCES)) {
      const pin = chainPins[name];
      if (!pin) { fail(`${name}: not pinned for chain ${chainId}`); continue; }
      const file = `${crate}.sol`;
      const libFlags = LIBRARIES.flatMap((lib) => ['--libraries', `evm/src/${file}:${lib}:${chainPins[lib].address}`]);
      console.log(`  forge build (${file}, linked to ${LIBRARIES.join('+')} at their pins)…`);
      const linked = build(project, `out-${crate}`, libFlags);
      const art = linked(`HonkVerifier_${crate}`, file);
      if (!art) { fail(`${name}: no HonkVerifier_${crate} artifact under ${file}`); continue; }
      const deployed = art.deployedBytecode;

      const unlinked = Object.values(deployed.linkReferences ?? {}).flatMap((f) => Object.keys(f));
      if (unlinked.length) { fail(`${name}: still has unlinked references to ${unlinked.join(', ')}`); continue; }

      // The metadata must record exactly these two addresses and nothing else — that is part of
      // what the hash covers, and what `forge create --libraries` wrote on chain.
      const recorded = JSON.parse(art.rawMetadata).settings.libraries ?? {};
      const expected = Object.fromEntries(LIBRARIES.map((lib) => [`evm/src/${file}:${lib}`, chainPins[lib].address.toLowerCase()]));
      const recordedNorm = Object.fromEntries(Object.entries(recorded).map(([k, v]) => [k, v.toLowerCase()]));
      if (JSON.stringify(recordedNorm) !== JSON.stringify(expected)) { fail(`${name}: metadata libraries ${JSON.stringify(recorded)} ≠ expected ${JSON.stringify(expected)}`); continue; }

      const source = readFileSync(join(project, 'evm', 'src', file), 'utf8');
      const c = constantsOf(source);
      const declared = declaredImmutables(source);
      const groups = Object.entries(deployed.immutableReferences ?? {}).sort(([a], [b]) => Number(a) - Number(b));
      // Declaration order is astId order. `$N` is declared but never read at runtime, so the
      // compiler gives it no slots; when exactly one declaration is missing it is that one.
      let names = declared;
      if (groups.length === declared.length - 1 && declared[0] === '$N') names = declared.slice(1);
      if (groups.length !== names.length) { fail(`${name}: ${groups.length} immutable groups for declarations ${declared.join(', ')}`); continue; }

      let code = deployed.object.replace(/^0x/, '');
      const filled = [];
      let bad = false;
      for (const [i, [, positions]] of groups.entries()) {
        const imm = names[i];
        if (!(imm in IMMUTABLES)) { fail(`${name}: no rule to derive ${imm} — update IMMUTABLES`); bad = true; break; }
        const value = IMMUTABLES[imm](c);
        for (const { start, length } of positions) {
          if (length !== 32) { fail(`${name}: ${imm} slot length ${length} ≠ 32`); bad = true; break; }
          code = code.slice(0, start * 2) + word(value) + code.slice((start + length) * 2);
        }
        if (bad) break;
        filled.push(`${imm}=${value < 1_000_000n ? value : `0x${value.toString(16).slice(0, 8)}…`}`);
      }
      if (bad) continue;

      const got = keccak(code);
      same(got, pin.codehash)
        ? ok(`${name}: rebuilt, linked at the pins, immutables ${filled.join(' ')} — matches its pin byte-for-byte, metadata included`)
        : fail(`${name}: rebuilt ${got.slice(0, 18)}… ≠ pinned ${pin.codehash.slice(0, 18)}… — profile, source, linked address or immutable derivation has drifted from the chain`);
    }
  }
} finally {
  rmSync(project, { recursive: true, force: true });
}

console.log(
  failures === 0
    ? '\n[check-verifier-bytecode] every pinned verifier and library is reproducible from this commit, with the pinned libraries linked in (the vault and registry rows are pinned for drift detection and are not rebuilt here)'
    : `\n[check-verifier-bytecode] ${failures} FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
