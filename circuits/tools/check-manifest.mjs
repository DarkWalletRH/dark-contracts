// `npm --prefix tools run verify-manifest` -- recompiles every circuit, recomputes the ACIR and
// VK hashes, and fails on any drift from circuits/manifest.json. It also asserts each circuit's
// public inputs are exactly circuits/public_inputs.toml's list, in order, so the contracts and
// the SDK can codegen against that file and trust it.
//
// This is the one check that catches a silent toolchain bump: a different nargo or bb gives a
// different VK, which means every deployed verifier is wrong.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// fileURLToPath, not .pathname: a checkout under a directory with a space gets back "%20", which
// readFileSync then takes literally.
const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
const NARGO = join(homedir(), '.nargo/bin/nargo');
const BB = join(homedir(), '.bb/bb');

const manifest = JSON.parse(readFileSync(`${ROOT}/manifest.json`, 'utf8'));
const errors = [];
const eq = (what, got, want) => {
  if (String(got) !== String(want)) errors.push(`${what}: have ${got}, manifest says ${want}`);
};

// --- public_inputs.toml ---------------------------------------------------------------------
// Tiny reader for the one shape this file has: `key = value` and `key = [ ... ]` under [table].
function readToml(text) {
  const out = {};
  let table = out;
  const lines = text.replace(/\\\n/g, '').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\s*#.*$/, '').trim();
    if (!line) continue;
    const t = line.match(/^\[(.+)\]$/);
    if (t) {
      table = out[t[1]] = {};
      continue;
    }
    let m = line.match(/^(\w+)\s*=\s*(.*)$/);
    if (!m) continue;
    let [, key, value] = m;
    if (value.startsWith('[')) {
      while (!value.includes(']')) value += lines[++i].replace(/\s*#.*$/, '').trim();
      table[key] = [...value.matchAll(/"([^"]*)"/g)].map((x) => x[1]);
    } else if (value.startsWith('"')) table[key] = value.slice(1, value.lastIndexOf('"'));
    else table[key] = value === 'true' ? true : value === 'false' ? false : Number(value);
  }
  return out;
}

/** The wire public inputs of a compiled circuit, in ABI order, structs flattened to x/y. */
function abiPublicInputs(acir) {
  const names = [];
  for (const p of JSON.parse(readFileSync(acir, 'utf8')).abi.parameters) {
    if (p.visibility !== 'public') continue;
    if (p.type.kind === 'struct') for (const f of p.type.fields) names.push(`${p.name}.${f.name}`);
    else names.push(p.name);
  }
  return names;
}

// --- recompute --------------------------------------------------------------------------------
execFileSync(NARGO, ['compile'], { cwd: ROOT, stdio: 'inherit' });
const declared = readToml(readFileSync(`${ROOT}/public_inputs.toml`, 'utf8'));
const tmp = mkdtempSync(join(tmpdir(), 'dark-vk-'));

try {
  for (const [pkg, want] of Object.entries(manifest.circuits)) {
    const acir = `${ROOT}/target/${pkg}.json`;
    // The base64 `bytecode` field, not the artifact: see tools/build.mjs.
    const acirSha = createHash('sha256').update(JSON.parse(readFileSync(acir, 'utf8')).bytecode).digest('hex');
    eq(`${pkg} acir_sha256`, acirSha, want.acir_sha256);

    const gates = JSON.parse(execFileSync(BB, ['gates', '-b', acir], { encoding: 'utf8' })).functions[0];
    eq(`${pkg} gate_count`, gates.circuit_size, want.gate_count);
    eq(`${pkg} acir_opcodes`, gates.acir_opcodes, want.acir_opcodes);

    execFileSync(BB, ['write_vk', '-b', acir, '-o', `${tmp}/${pkg}`, '--verifier_target', 'evm'], {
      stdio: ['ignore', 'ignore', 'inherit'],
    });
    eq(
      `${pkg} vk_sha256`,
      createHash('sha256').update(readFileSync(`${tmp}/${pkg}/vk`)).digest('hex'),
      want.vk_sha256,
    );

    const spec = declared[pkg];
    if (!spec) {
      errors.push(`${pkg}: missing from public_inputs.toml`);
    } else {
      const actual = abiPublicInputs(acir);
      eq(`${pkg} public_input_count`, actual.length, want.public_input_count);
      eq(`${pkg} public_inputs.toml count`, spec.count, actual.length);
      if (actual.join(',') !== spec.inputs.join(',')) {
        errors.push(
          `${pkg} public-input order drifted from public_inputs.toml:\n  circuit: ${actual.join(', ')}\n  toml:    ${spec.inputs.join(', ')}`,
        );
      }
    }

    if (want.verifier_sol_sha256) {
      const sol = `${ROOT}/verifiers/${want.crate}/Verifier.sol`;
      eq(
        `${pkg} verifier_sol_sha256`,
        createHash('sha256').update(readFileSync(sol)).digest('hex'),
        want.verifier_sol_sha256,
      );
      eq(`${pkg} verifier_sol_bytes`, statSync(sol).size, want.verifier_sol_bytes);
    }
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

eq('nargo', execFileSync(NARGO, ['--version'], { encoding: 'utf8' }).match(/nargo version = (\S+)/)[1], manifest.nargo);
eq('bb', execFileSync(BB, ['--version'], { encoding: 'utf8' }).trim(), manifest.bb);

if (errors.length) {
  console.error(`\nmanifest drift (${errors.length}):\n - ${errors.join('\n - ')}`);
  process.exit(1);
}
console.log(`manifest.json matches: ${Object.keys(manifest.circuits).length} circuits, ACIR + VK + public-input order.`);
