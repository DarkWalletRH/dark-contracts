// compile -> execute -> gates -> prove -> write_vk -> verify -> write_solidity_verifier,
// for all four circuits, and write circuits/manifest.json with the measurements.
//
//   node tools/gen_prover.mjs && node tools/build.mjs
//
// Artifacts land in circuits/target/<circuit>/ (gitignored: proofs and vk blobs are rebuildable);
// only the generated .sol verifiers and manifest.json are committed.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// fileURLToPath, not .pathname: a checkout under a directory with a space gets back "%20", which
// readFileSync then takes literally.
const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
const NARGO = join(homedir(), '.nargo/bin/nargo');
const BB = join(homedir(), '.bb/bb');

const CIRCUITS = [
  { crate: 'register', pkg: 'dark_register', onchain: true },
  { crate: 'transfer', pkg: 'dark_transfer', onchain: true },
  { crate: 'withdraw', pkg: 'dark_withdraw', onchain: true },
  { crate: 'disclose_range', pkg: 'dark_disclose_range', onchain: false },
];

const run = (cmd, args, cwd = ROOT) =>
  execFileSync(cmd, args, { cwd, encoding: 'utf8', maxBuffer: 1 << 28 });
const sha256 = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
// The ACIR identity is the base64 `bytecode` field, not the whole artifact: the surrounding
// JSON carries debug symbols and file maps that move with the directory nargo was run from.
const acirHash = (path) =>
  createHash('sha256').update(JSON.parse(readFileSync(path, 'utf8')).bytecode).digest('hex');
const size = (path) => statSync(path).size;

run(NARGO, ['compile']);

const manifest = {
  spec: 'DARK-CB-1',
  // The toolchain is part of the identity: a different nargo or bb gives a different VK.
  nargo: run(NARGO, ['--version']).match(/nargo version = (\S+)/)[1],
  bb: run(BB, ['--version']).trim(),
  circuits: {},
};
const timings = {};

for (const { crate, pkg, onchain } of CIRCUITS) {
  const acir = `${ROOT}/target/${pkg}.json`;
  const out = `${ROOT}/target/${crate}`;
  mkdirSync(out, { recursive: true });

  run(NARGO, ['execute', crate], `${ROOT}/${crate}`);
  const witness = `${ROOT}/target/${crate}.gz`;

  const gates = JSON.parse(run(BB, ['gates', '-b', acir])).functions[0];

  const t0 = process.hrtime.bigint();
  run(BB, ['prove', '-b', acir, '-w', witness, '-o', out, '--verifier_target', 'evm', '--write_vk']);
  const proveMs = Number((process.hrtime.bigint() - t0) / 1000000n);

  run(BB, ['verify', '-k', `${out}/vk`, '-p', `${out}/proof`, '-i', `${out}/public_inputs`, '--verifier_target', 'evm']);

  let verifier = null;
  if (onchain) {
    verifier = `${ROOT}/verifiers/${crate}/Verifier.sol`;
    mkdirSync(`${ROOT}/verifiers/${crate}`, { recursive: true });
    run(BB, ['write_solidity_verifier', '-k', `${out}/vk`, '-o', verifier, '--verifier_target', 'evm']);
  }

  // The wire public-input count is what the contract passes. bb writes those wire
  // values to `public_inputs` as 32-byte words; the VK's publicInputsSize is 8 larger
  // (pairing-point limbs that travel inside the proof).
  const publicInputs = size(`${out}/public_inputs`) / 32;

  manifest.circuits[pkg] = {
    crate,
    onchain,
    acir_sha256: acirHash(acir),
    vk_sha256: sha256(`${out}/vk`),
    gate_count: gates.circuit_size,
    acir_opcodes: gates.acir_opcodes,
    public_input_count: publicInputs,
    proof_bytes: size(`${out}/proof`),
    vk_bytes: size(`${out}/vk`),
    verifier_sol_bytes: verifier ? size(verifier) : null,
    verifier_sol_sha256: verifier ? sha256(verifier) : null,
  };
  // Prove time is a machine property, not a circuit property, so it is reported and never
  // put in the manifest -- check-manifest.mjs must be able to fail on drift.
  timings[pkg] = proveMs;
  console.log(
    `${pkg}: ${gates.circuit_size} gates, ${publicInputs} public inputs, ` +
      `proof ${size(`${out}/proof`)} B, prove ${proveMs} ms`,
  );
}

writeFileSync(`${ROOT}/manifest.json`, `${JSON.stringify(manifest, null, 2)}\n`);
console.log('wrote manifest.json');
console.log('prove_ms (this machine, not manifested):', JSON.stringify(timings));
