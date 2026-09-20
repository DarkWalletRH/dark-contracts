#!/usr/bin/env node
// Mutation testing for the Dark contracts (§16).
//
// Each mutation is a mechanical source edit applied to a COPY of contracts/src (and script/), never
// to the working tree. The copy is compiled and the full `forge test` suite is run against it:
// a non-zero exit means the mutation was KILLED, exit 0 means it SURVIVED and a test is missing.
//
//   node script/mutate.mjs                # run all, rewrite audit/MUTATIONS.md
//   node script/mutate.mjs --only M7a,M12 # run a subset, print the table only
//   node script/mutate.mjs --keep         # leave the mutant workspaces for inspection
//
// Mutations whose target lives outside contracts/ (circuits, SDK, build) are listed in the report
// as out-of-scope with the lane that owns them; they are not run here.
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync, symlinkSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const WORK = join(ROOT, ".mutants");

const V = "src/DarkVault.sol";
const R = "src/DarkKeyRegistry.sol";
const G = "src/libraries/DarkGrumpkin.sol";
const D = "script/DeployDarkTestnet.s.sol";

/** @type {{id:string,spec:string,file:string,find:string,replace:string,expect:string}[]} */
const MUTATIONS = [
  {
    id: "M1",
    spec: "`transfer` takes the sender from the transaction instead of `msg.sender`",
    file: V,
    find: "        _requireRegistered(msg.sender);\n        if (!_registry.isRegistered(to)) revert RecipientNotRegistered(to);\n        if (to == msg.sender) revert SelfTransfer();",
    replace: "        _requireRegistered(tx.origin);\n        if (!_registry.isRegistered(to)) revert RecipientNotRegistered(to);\n        if (to == tx.origin) revert SelfTransfer();",
    expect: "I3, unit",
  },
  {
    id: "M1b",
    spec: "`transfer` debits an account taken from the transaction, not `msg.sender`",
    file: V,
    find: "        Account storage s = _accounts[msg.sender];\n        if (!_transferVerifier.verify(proof, _transferInputs(to, ct, s))) revert InvalidProof();",
    replace: "        Account storage s = _accounts[tx.origin];\n        if (!_transferVerifier.verify(proof, _transferInputs(to, ct, s))) revert InvalidProof();",
    expect: "I3, I13",
  },
  {
    id: "M2",
    spec: "P_r read from calldata instead of the registry",
    file: V,
    find: "        pi[7] = bytes32(pr.x);\n        pi[8] = bytes32(pr.y);",
    replace: "        pi[7] = bytes32(ct.dRecipient.x);\n        pi[8] = bytes32(ct.dRecipient.y);",
    expect: "I13",
  },
  {
    id: "M3",
    spec: "sender `available` passed from calldata instead of storage",
    file: V,
    find: "        pi[9] = bytes32(s.available.c.x);\n        pi[10] = bytes32(s.available.c.y);",
    replace: "        pi[9] = bytes32(ct.c.x);\n        pi[10] = bytes32(ct.c.y);",
    expect: "I13, I2",
  },
  {
    id: "M4a",
    spec: "`deposit` does not increment the nonce",
    file: V,
    find: "        _tvl = tvlAfter;\n        a.nonce += 1;",
    replace: "        _tvl = tvlAfter;",
    expect: "I5",
  },
  {
    id: "M4b",
    spec: "`applyPending` does not increment the nonce",
    file: V,
    find: "        a.pendingCount = 0;\n        a.nonce += 1;",
    replace: "        a.pendingCount = 0;",
    expect: "I5",
  },
  {
    id: "M4c",
    spec: "`transfer` does not increment the sender's nonce",
    file: V,
    find: "        r.pendingCount += 1;\n        s.nonce += 1;",
    replace: "        r.pendingCount += 1;",
    expect: "I5",
  },
  {
    id: "M4d",
    spec: "`withdraw` does not increment the nonce",
    file: V,
    find: "        a.netInflow = amount >= a.netInflow ? 0 : uint128(a.netInflow - amount);\n        a.nonce += 1;",
    replace: "        a.netInflow = amount >= a.netInflow ? 0 : uint128(a.netInflow - amount);",
    expect: "I5",
  },
  {
    id: "M5",
    spec: "`withdraw` gets `whenNotPaused`",
    file: V,
    find: "    function withdraw(uint256 amount, address to, bytes calldata proof, bytes calldata aeBalance)\n        external\n        nonReentrant\n    {",
    replace: "    function withdraw(uint256 amount, address to, bytes calldata proof, bytes calldata aeBalance)\n        external\n        nonReentrant\n        whenNotPaused\n    {",
    expect: "I7, I8",
  },
  {
    id: "M6",
    spec: "`applyPending` gets `whenNotPaused`",
    file: V,
    find: "    function applyPending(uint64 expectedPendingCount, bytes calldata aeBalance) external nonReentrant {",
    replace: "    function applyPending(uint64 expectedPendingCount, bytes calldata aeBalance) external nonReentrant whenNotPaused {",
    expect: "I7, I8",
  },
  {
    id: "M7a",
    spec: "`withdraw` adds `mulG(x)` to `available` instead of subtracting it",
    file: V,
    find: "        (a.available.c.x, a.available.c.y) = DarkGrumpkin.sub(a.available.c.x, a.available.c.y, gx, gy);",
    replace: "        (a.available.c.x, a.available.c.y) = DarkGrumpkin.add(a.available.c.x, a.available.c.y, gx, gy);",
    expect: "I2",
  },
  {
    id: "M7b",
    spec: "`withdraw` skips the `available` update",
    file: V,
    find: "        (uint256 gx, uint256 gy) = DarkGrumpkin.mulG(amount);\n        (a.available.c.x, a.available.c.y) = DarkGrumpkin.sub(a.available.c.x, a.available.c.y, gx, gy);",
    replace: "",
    expect: "I2",
  },
  {
    id: "M8",
    spec: "`transfer` credits the recipient's `available` instead of `pending`",
    file: V,
    find: "        (r.pending.c.x, r.pending.c.y) = DarkGrumpkin.add(r.pending.c.x, r.pending.c.y, ct.c.x, ct.c.y);",
    replace: "        (r.available.c.x, r.available.c.y) = DarkGrumpkin.add(r.available.c.x, r.available.c.y, ct.c.x, ct.c.y);",
    expect: "I2, I3, I4",
  },
  {
    id: "M9",
    spec: "the `deposit` balance-delta guard is removed",
    file: V,
    find: "        uint256 received = token.balanceOf(address(this)) - before;\n        if (received != amount) revert UnexpectedTransferAmount(amount, received);",
    replace: "",
    expect: "fee-on-transfer mock test",
  },
  {
    id: "M10a",
    spec: "the TVL cap becomes exclusive (`<=` becomes `<`)",
    file: V,
    find: "        if (tvlAfter > c.tvlCap) revert ExceedsTvlCap(tvlAfter, c.tvlCap);",
    replace: "        if (tvlAfter >= c.tvlCap) revert ExceedsTvlCap(tvlAfter, c.tvlCap);",
    expect: "I6, unit",
  },
  {
    id: "M10b",
    spec: "the TVL cap check is removed",
    file: V,
    find: "        if (tvlAfter > c.tvlCap) revert ExceedsTvlCap(tvlAfter, c.tvlCap);\n",
    replace: "",
    expect: "I6, unit",
  },
  {
    id: "M11",
    spec: "`tightenCaps` accepts a loosened `maxDeposit`",
    file: V,
    find: "        bool ok = newCaps.maxDeposit <= c.maxDeposit && newCaps.maxAccountInflow <= c.maxAccountInflow",
    replace: "        bool ok = newCaps.maxAccountInflow <= c.maxAccountInflow",
    expect: "I9, unit",
  },
  {
    id: "M11b",
    spec: "`tightenCaps` stops checking `minDeposit` (§19 C6)",
    file: V,
    find: "&& newCaps.tvlCap <= c.tvlCap && newCaps.minDeposit >= c.minDeposit\n            && newCaps.minTransfer >= c.minTransfer;",
    replace: "&& newCaps.tvlCap <= c.tvlCap\n            && newCaps.minTransfer >= c.minTransfer;",
    expect: "unit",
  },
  {
    id: "M12",
    spec: "the canonical-coordinate check (`x < r`) is removed for `ct` points",
    file: V,
    find: "    function _requirePoint(Point calldata p) private pure {\n        if (!DarkGrumpkin.isOnCurve(p.x, p.y)) revert InvalidPoint(); // canonical, on-curve, not the identity\n    }",
    replace: "    function _requirePoint(Point calldata p) private pure {\n        if (!DarkGrumpkin.isOnCurve(p.x % DarkGrumpkin.P, p.y % DarkGrumpkin.P)) revert InvalidPoint();\n    }",
    expect: "I12, non-canonical input test",
  },
  {
    id: "M13",
    spec: "the identity sentinel is accepted for `ct.c` / `ct.dSender` / `ct.dRecipient`",
    file: V,
    find: "        if (!DarkGrumpkin.isOnCurve(p.x, p.y)) revert InvalidPoint(); // canonical, on-curve, not the identity",
    replace: "        if (!DarkGrumpkin.isOnCurve(p.x, p.y) && !DarkGrumpkin.isIdentity(p.x, p.y)) revert InvalidPoint();",
    expect: "I12, unit",
  },
  {
    id: "M14",
    spec: "`applyPending` ignores `expectedPendingCount`",
    file: V,
    find: "        if (applied < expectedPendingCount) revert PendingChanged(expectedPendingCount, applied);\n",
    replace: "",
    expect: "unit, I15",
  },
  {
    id: "M14b",
    spec: "`applyPending` demands an exact `expectedPendingCount`",
    file: V,
    find: "        if (applied < expectedPendingCount) revert PendingChanged(expectedPendingCount, applied);",
    replace: "        if (applied != expectedPendingCount) revert PendingChanged(expectedPendingCount, applied);",
    expect: "unit",
  },
  {
    id: "M15",
    spec: "`recoverERC20` allows USDG",
    file: V,
    find: "        if (token == _usdg) revert CannotRecoverUSDG();\n",
    replace: "",
    expect: "I10, unit",
  },
  {
    id: "M16",
    spec: "`renounceOwnership` is not overridden",
    file: V,
    find: "    function renounceOwnership() public pure override {\n        revert RenounceDisabled();\n    }\n",
    replace: "",
    expect: "I9, unit",
  },
  {
    id: "M17",
    spec: "the deploy script swaps the transfer and withdraw verifiers",
    file: D,
    find: "            address(usdg), registry, transferVerifier, withdrawVerifier, address(timelock), guardianSafe, caps",
    replace: "            address(usdg), registry, withdrawVerifier, transferVerifier, address(timelock), guardianSafe, caps",
    expect: "deploy-script wiring test",
  },
  {
    id: "M17b",
    spec: "the deploy script skips the verifier address/codehash pin",
    file: D,
    find: '        _pin(pin, "DarkTransferVerifier", address(transferVerifier));\n',
    replace: "",
    expect: "deploy-script pin test",
  },
  {
    id: "M17c",
    spec: "the deploy script pins the verifiers but not the shared libraries (§19 X4)",
    file: D,
    find: '        _pin(pin, "RelationsLib", address(0));\n',
    replace: "",
    expect: "deploy-script pin test",
  },
  {
    id: "M28a",
    spec: "`DarkGrumpkin.add` mishandles doubling (the equal-x branch is never taken)",
    file: G,
    find: "        uint256 lambda;\n        if (x1 == x2) {",
    replace: "        uint256 lambda;\n        if (x1 == x2 && y1 != y2) {",
    expect: "differential fuzz vs noble",
  },
  {
    id: "M28b",
    spec: "`DarkGrumpkin.add` mishandles P + (-P) (no identity early return)",
    file: G,
    find: "            if (addmod(y1, y2, P) == 0) return (0, 0); // P + (-P) = identity\n",
    replace: "",
    expect: "differential fuzz vs noble",
  },
  {
    id: "M28c",
    spec: "`DarkGrumpkin.mulG` drops the Jacobian-to-affine z^3 factor",
    file: G,
    find: "        return (mulmod(X, zi2, P), mulmod(Y, mulmod(zi2, zi, P), P));",
    replace: "        return (mulmod(X, zi2, P), mulmod(Y, zi2, P));",
    expect: "differential fuzz vs noble",
  },
  // ---- additions beyond §16 (same method, contract-side gaps the list does not name) ----
  {
    id: "M29",
    spec: "`withdraw` does not lower `tvl`",
    file: V,
    find: "        uint256 tvlAfter = _tvl - amount; // checked: an underflow means the ghost accounting is broken",
    replace: "        uint256 tvlAfter = _tvl;",
    expect: "I1",
  },
  {
    id: "M30",
    spec: "`deposit` does not update `netInflow`",
    file: V,
    find: "        a.netInflow = uint128(inflowAfter);\n",
    replace: "",
    expect: "I6, unit",
  },
  {
    id: "M31",
    spec: "`transfer` does not increment the recipient's `pendingCount`",
    file: V,
    find: "        r.pendingCount += 1;\n",
    replace: "",
    expect: "I4",
  },
  {
    id: "M32",
    spec: "`applyPending` does not clear `pending`",
    file: V,
    find: "        delete a.pending;\n",
    replace: "",
    expect: "I2, I4",
  },
  {
    id: "M33",
    spec: "`withdraw` pays `msg.sender` instead of `to`",
    file: V,
    find: "        IERC20(_usdg).safeTransfer(to, amount); // CEI",
    replace: "        IERC20(_usdg).safeTransfer(msg.sender, amount); // CEI",
    expect: "handler withdraw-to-other check",
  },
  {
    id: "M34",
    spec: "`pause` loses its access control",
    file: V,
    find: "    function pause() external {\n        if (msg.sender != _guardian && msg.sender != owner()) revert NotGuardian();",
    replace: "    function pause() external {",
    expect: "I9, unit",
  },
  {
    id: "M35",
    spec: "the registry allows a key to be overwritten",
    file: R,
    find: "        if (_keys[msg.sender].y != 0) revert AlreadyRegistered(msg.sender);\n",
    replace: "",
    expect: "I11, unit",
  },
  {
    id: "M36",
    spec: "`minDeposit` becomes exclusive",
    file: V,
    find: "        if (amount < c.minDeposit) revert BelowMinDeposit(amount, c.minDeposit);",
    replace: "        if (amount <= c.minDeposit) revert BelowMinDeposit(amount, c.minDeposit);",
    expect: "I6, unit",
  },
  {
    id: "M37",
    spec: "`withdraw` loses the `netInflow` floor (underflows instead of clamping)",
    file: V,
    find: "        a.netInflow = amount >= a.netInflow ? 0 : uint128(a.netInflow - amount);",
    replace: "        a.netInflow = uint128(uint256(a.netInflow) - amount);",
    expect: "I6",
  },
  {
    id: "M38",
    spec: "`transfer` does not debit the sender's `available`",
    file: V,
    find: "        (s.available.c.x, s.available.c.y) = DarkGrumpkin.sub(s.available.c.x, s.available.c.y, ct.c.x, ct.c.y);",
    replace: "",
    expect: "I2",
  },
];

/** §16 entries that live outside contracts/ — reported, not run here. */
const OUT_OF_SCOPE = [
  ["M18", "circuit: the range check on `w` is removed", "circuits (lane circuits) — C-I1 nargo test"],
  ["M19", "circuit: `ct_dr == r·pk_r` is removed", "circuits — malformed-D_r negative test"],
  ["M20", "circuit: `s·pk_s == H` is removed", "circuits — wrong-key negative test"],
  ["M21", "circuit: `r != 0` is removed", "circuits — negative test"],
  ["M22", "circuit: on-curve assertions are removed", "circuits — off-curve negative test"],
  ["M23", "circuit: `a <= max_transfer` / `a >= min_transfer` is removed", "circuits — negative test"],
  ["M24", "circuit: a binding public input goes unused", "circuits — C-I2"],
  ["M25", "DLEQ challenge omits D, v or ctx", "SDK/circuits — C-I3"],
  ["M26", "SDK: the HKDF salt or info changes", "packages/dark-sdk — C-I4 vectors"],
  ["M27", "build: verifier generated with `--disable_zk` or a non-keccak oracle", "CI manifest-flag check"],
];

const args = process.argv.slice(2);
const only = (args.find((a) => a.startsWith("--only=")) ?? "").slice("--only=".length);
const onlyList = only ? only.split(",") : args.includes("--only") ? args[args.indexOf("--only") + 1].split(",") : [];
const keep = args.includes("--keep");

const selected = onlyList.length ? MUTATIONS.filter((m) => onlyList.includes(m.id)) : MUTATIONS;
if (onlyList.length && selected.length !== onlyList.length) {
  throw new Error(`unknown mutation id in --only: ${onlyList.join(",")}`);
}

const results = [];
for (const m of selected) {
  const dir = join(WORK, m.id);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  for (const d of ["src", "test", "script"]) cpSync(join(ROOT, d), join(dir, d), { recursive: true });
  cpSync(join(ROOT, "foundry.toml"), join(dir, "foundry.toml"));
  if (!existsSync(join(dir, "node_modules"))) symlinkSync(join(ROOT, "node_modules"), join(dir, "node_modules"));

  const target = join(dir, m.file);
  const before = readFileSync(target, "utf8");
  const hits = before.split(m.find).length - 1;
  if (hits !== 1) {
    throw new Error(`${m.id}: pattern matched ${hits} times in ${m.file} (expected exactly 1) — the mutation is stale`);
  }
  writeFileSync(target, before.replace(m.find, m.replace));

  let killed = false;
  let detail = "";
  try {
    execFileSync("forge", ["test", "--root", dir], { cwd: dir, stdio: "pipe", encoding: "utf8" });
    detail = "all tests passed";
  } catch (e) {
    killed = true;
    const out = `${e.stdout ?? ""}${e.stderr ?? ""}`;
    const fail = out.match(/\[FAIL[^\]]*\][^\n]*/);
    const compile = out.match(/^Error[^\n]*/m);
    detail = (fail?.[0] ?? compile?.[0] ?? "forge test failed").trim().slice(0, 150);
  }
  if (!keep) rmSync(dir, { recursive: true, force: true });
  results.push({ ...m, killed, detail });
  process.stdout.write(`${killed ? "KILLED  " : "SURVIVED"} ${m.id.padEnd(5)} ${m.spec}\n${killed ? "" : ""}`);
}

const killedCount = results.filter((r) => r.killed).length;
process.stdout.write(`\n${killedCount}/${results.length} killed\n`);

if (!onlyList.length) {
  const rows = results
    .map(
      (r) =>
        `| ${r.id} | ${r.spec} | \`${r.file}\` | ${r.expect} | ${r.killed ? "**killed**" : "**SURVIVED**"} | ${r.killed ? r.detail.replace(/\|/g, "\\|") : "missing test"} |`,
    )
    .join("\n");
  const skipped = OUT_OF_SCOPE.map(([id, spec, owner]) => `| ${id} | ${spec} | ${owner} |`).join("\n");
  const md = `# Mutation kill report (§16)

Generated by \`node script/mutate.mjs\` — every row is a mechanical edit applied to a throwaway copy
of \`contracts/src\` (and \`contracts/script\`), compiled and run against the full \`forge test\` suite.
A mutation is **killed** when that run fails. Re-run after any test or source change.

**Result: ${killedCount}/${results.length} killed, ${results.length - killedCount} survived.**

| # | Mutation | File | §16 killer | Result | Failing check |
|---|---|---|---|---|---|
${rows}

## Out of scope for this lane

These §16 mutations target circuits, the SDK or the build, not \`contracts/\`. They are run by the
lane that owns those files.

| # | Mutation | Owner |
|---|---|---|
${skipped}
`;
  mkdirSync(join(ROOT, "audit"), { recursive: true });
  writeFileSync(join(ROOT, "audit", "MUTATIONS.md"), md);
  process.stdout.write("wrote audit/MUTATIONS.md\n");
}

process.exit(killedCount === results.length ? 0 : 1);
