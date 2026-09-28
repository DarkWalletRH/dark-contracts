// The verifier deploy recipe, shared by scripts/deploy-verifiers.mjs (which ships it) and
// scripts/check-verifier-bytecode.mjs (which proves the chain matches it). One copy, so the thing
// that deploys and the thing that checks cannot drift apart. The "why" of each step is the long
// comment at the top of check-verifier-bytecode.mjs.
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const CIRCUITS = fileURLToPath(new URL('../../circuits', import.meta.url));

/** Pinned verifier name -> the crate whose bb output it was generated from. */
export const SOURCES = { DarkRegisterVerifier: 'register', DarkTransferVerifier: 'transfer', DarkWithdrawVerifier: 'withdraw' };
/** The two shared libraries, deployed once and linked into all three verifiers. */
export const LIBRARIES = ['RelationsLib', 'ZKTranscriptLib'];

/** The deploy-time source: bb's output with only the contract line renamed (see note 1). */
export function deployTimeSource(crate) {
  const bbOutput = readFileSync(join(CIRCUITS, 'verifiers', crate, 'Verifier.sol'), 'utf8');
  const renamed = bbOutput.replace(/^contract HonkVerifier is /m, `contract HonkVerifier_${crate} is `);
  if (renamed === bbOutput) throw new Error(`${crate}: could not find 'contract HonkVerifier is' to rename`);
  return renamed;
}

/** A throwaway Foundry project with the committed profile and the deploy-time sources. */
export function makeProject() {
  const dir = mkdtempSync(join(tmpdir(), 'dark-verifier-check-'));
  copyFileSync(join(CIRCUITS, 'foundry.toml'), join(dir, 'foundry.toml'));
  mkdirSync(join(dir, 'evm', 'src'), { recursive: true });
  for (const crate of Object.values(SOURCES)) writeFileSync(join(dir, 'evm', 'src', `${crate}.sol`), deployTimeSource(crate));
  return dir;
}
