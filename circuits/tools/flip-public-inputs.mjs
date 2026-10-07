// dark_disclose_range has no on-chain verifier, so the "reject every flipped public input" test
// that circuits/evm/test/Verifiers.t.sol runs for the other three circuits has nowhere to live:
// its `nargo test` negatives only cover the 6 inputs with an in-circuit relation, and the three
// that are pure domain separators (context_hash, and lo/hi at the proof level) cannot fail there.
//
// This is that venue. Prove once with the pinned bb, verify, then flip each of the 9 public
// inputs in turn and assert bb refuses every single one.
//
//   node circuits/tools/flip-public-inputs.mjs
//
// bb CLI, not bb.js: they are the same pinned barretenberg (circuits/VERSIONS.toml), and the CLI is
// what the circuits CI job has on PATH. Disclose proofs are verified in the browser with bb.js.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// fileURLToPath, not .pathname: a checkout under a directory with a space gets back "%20", which
// readFileSync then takes literally.
const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
const NARGO = join(homedir(), '.nargo/bin/nargo');
const BB = join(homedir(), '.bb/bb');
const PKG = 'dark_disclose_range';
const CRATE = 'disclose_range';
// public_inputs.toml order, so a failure names the input that stopped being bound.
const NAMES = ['context_hash', 'pk.x', 'pk.y', 'c.x', 'c.y', 'd.x', 'd.y', 'lo', 'hi'];

const out = mkdtempSync(join(tmpdir(), 'dark-flip-'));
const acir = `${ROOT}/target/${PKG}.json`;
const verify = (inputs) =>
  execFileSync(BB, ['verify', '-k', `${out}/vk`, '-p', `${out}/proof`, '-i', inputs, '--verifier_target', 'evm'], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });

try {
  execFileSync(NARGO, ['compile', '--silence-warnings'], { cwd: ROOT, stdio: 'inherit' });
  execFileSync(NARGO, ['execute', CRATE, '--silence-warnings'], { cwd: `${ROOT}/${CRATE}`, stdio: 'inherit' });
  execFileSync(
    BB,
    ['prove', '-b', acir, '-w', `${ROOT}/target/${CRATE}.gz`, '-o', out, '--verifier_target', 'evm', '--write_vk'],
    { stdio: ['ignore', 'ignore', 'inherit'] },
  );

  const real = readFileSync(`${out}/public_inputs`);
  if (real.length !== NAMES.length * 32) {
    throw new Error(`${PKG} has ${real.length / 32} public inputs, expected ${NAMES.length} (manifest.json)`);
  }
  verify(`${out}/public_inputs`); // throws if the honest proof does not verify

  const accepted = [];
  for (let i = 0; i < NAMES.length; i++) {
    const flipped = Buffer.from(real);
    flipped[i * 32 + 31] ^= 1; // low bit of word i; every input here is far from the field modulus
    const path = `${out}/flipped_${i}`;
    writeFileSync(path, flipped);
    try {
      verify(path);
      accepted.push(`[${i}] ${NAMES[i]}`);
    } catch {
      // expected: bb rejects the proof
    }
  }

  if (accepted.length) {
    console.error(`\n${PKG} VERIFIED under a flipped public input -- not bound:\n - ${accepted.join('\n - ')}`);
    process.exit(1);
  }
  console.log(`${PKG}: honest proof verifies; all ${NAMES.length} public inputs rejected when flipped.`);
} finally {
  rmSync(out, { recursive: true, force: true });
}
