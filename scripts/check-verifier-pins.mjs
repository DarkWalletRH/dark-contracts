// tie contracts/deployments/verifier-codehashes.json back to circuits/manifest.json.
//
//   node scripts/check-verifier-pins.mjs   (npm run check:verifier-pins)
//
// The pin file's own header says "`verifierSolSha256` ties each row back to circuits/manifest.json".
// It did not. The field was recorded and never compared, so the tie was a sentence rather than a
// check — the same shape as §3's claimed three-way H cross-check, which also did not exist.
//
// Why it matters. `check-manifest.mjs` recompiles the circuits and keeps manifest.json honest, and
// the deploy script refuses to wire a verifier whose address or on-chain codehash is not in the pin
// file. Both are real. But every check the deploy script runs is self-referential to the pin file,
// so nothing could distinguish "the pin file is internally consistent" from "the pin file is
// current". Change a circuit, regenerate, leave the pin file alone, and the deploy wires the OLD
// verifier into a new vault with every check green.
//
// The loud direction of that failure is harmless: proofs from the new circuit simply fail against
// the old verifier. The quiet direction is the one to care about — if the circuit change FIXED a
// soundness bug, deploying the stale verifier leaves the bug exploitable while everything looks
// normal to honest users.
import { readFileSync } from 'node:fs';

const read = (p) => JSON.parse(readFileSync(new URL(`../${p}`, import.meta.url), 'utf8'));
const pins = read('contracts/deployments/verifier-codehashes.json');
const manifest = read('circuits/manifest.json').circuits;

/** Generated verifier name -> the circuit it was generated from. */
const VERIFIER_TO_CIRCUIT = {
  DarkRegisterVerifier: 'dark_register',
  DarkTransferVerifier: 'dark_transfer',
  DarkWithdrawVerifier: 'dark_withdraw',
};

/**
 * Entries that legitimately carry no `verifierSolSha256` — the shared libraries, and the vault and
 * registry. This is an allowlist rather than an "if the field is missing, skip", because the
 * latter lets a verifier silently lose its tie by dropping the field — a check that passes because
 * there is nothing left to check is not a check.
 */
const NOT_CIRCUIT_GENERATED = new Set([
  'RelationsLib',
  'ZKTranscriptLib',
  // the vault and registry are pinned here too, so the drift monitor covers
  // them. They are not generated from a circuit — their codehashes are deployment-specific because
  // Solidity bakes immutables into runtime bytecode — so they carry no verifierSolSha256 either.
  'DarkVault',
  'DarkKeyRegistry',
]);

let failures = 0;
const fail = (msg) => {
  console.error(`  FAIL ${msg}`);
  failures++;
};
const ok = (msg) => console.log(`  ok   ${msg}`);

for (const [chainId, entries] of Object.entries(pins)) {
  if (chainId === '_') continue;
  console.log(`chain ${chainId}`);

  for (const [name, row] of Object.entries(entries)) {
    const circuit = VERIFIER_TO_CIRCUIT[name];

    if (!circuit) {
      if (!NOT_CIRCUIT_GENERATED.has(name)) {
        fail(`${name}: not a known verifier or library — add it to VERIFIER_TO_CIRCUIT or NOT_CIRCUIT_GENERATED`);
      } else if (row.verifierSolSha256) {
        fail(`${name} is not generated from a circuit but carries verifierSolSha256`);
      } else {
        ok(`${name} (not circuit-generated; pinned for drift detection only)`);
      }
      continue;
    }

    const want = manifest[circuit]?.verifier_sol_sha256;
    if (!want) {
      fail(`${name}: circuits/manifest.json has no verifier_sol_sha256 for ${circuit}`);
      continue;
    }
    if (!row.verifierSolSha256) {
      fail(`${name}: pin entry has no verifierSolSha256, so nothing ties it to ${circuit}`);
      continue;
    }
    if (row.verifierSolSha256.toLowerCase() !== want.toLowerCase()) {
      fail(
        `${name}: pinned verifier is STALE — pin ${row.verifierSolSha256.slice(0, 18)}… ` +
          `but ${circuit} now generates ${want.slice(0, 18)}…. Redeploy that verifier and update the pin.`,
      );
      continue;
    }
    ok(`${name} matches ${circuit}`);
  }

  // Every circuit that is supposed to have an on-chain verifier must actually be pinned here, or a
  // whole circuit could go missing from the pin file without anything noticing.
  for (const [circuit, entry] of Object.entries(manifest)) {
    if (!entry.onchain) continue;
    const pinned = Object.entries(VERIFIER_TO_CIRCUIT).find(([, c]) => c === circuit)?.[0];
    if (!pinned) fail(`${circuit} is on-chain but no verifier name maps to it`);
    else if (!entries[pinned]) fail(`${circuit} is on-chain but ${pinned} has no entry for chain ${chainId}`);
  }
}

console.log(
  failures === 0
    ? '\n[check-verifier-pins] every pinned verifier matches the circuit it was generated from'
    : `\n[check-verifier-pins] ${failures} FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
