// Reference Grumpkin via @noble/curves, for the differential test in test/DarkGrumpkin.t.sol.
// Usage: node test/js/diff_grumpkin.mjs <seed-hex> [count]
//
// Prints JSON arrays of `count` cases (the first EDGE.length are the §19 X1 edge cases, the rest
// are pseudo-random): k1, k2, neg2 (1 = the second operand is negated), the two operand points and
// their sum. k == 0 means the identity, which the contract encodes as (0, 0) (§19 X1).
import { createHash } from "node:crypto";
import { weierstrass } from "@noble/curves/abstract/weierstrass.js";

const p = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const n = 21888242871839275222246405745257275088696311157297823662689037894645226208583n;
const Point = weierstrass({
  p,
  n,
  h: 1n,
  a: 0n,
  b: p - 17n,
  Gx: 1n,
  Gy: 17631683881184975370165255887551781615748388533673675138860n,
});

const MAX = (1n << 48n) - 1n;

// [k1, k2, neg2] — identity, doubling, P + (-P) and the range ends (§19 X1).
const EDGE = [
  [0n, 0n, 0], // identity + identity
  [0n, 5n, 0], // identity + P
  [5n, 0n, 0], // P + identity
  [0n, 5n, 1], // identity + (-P)
  [7n, 7n, 1], // P + (-P) = identity
  [9n, 9n, 0], // doubling
  [1n, 1n, 0], // G + G
  [1n, 2n, 0], // G + 2G (x1 != x2, the plain branch)
  [MAX, 1n, 0], // largest in-range scalar + G
  [MAX, MAX, 0], // doubling at the top of the range
  [MAX, MAX, 1], // P + (-P) at the top of the range
  [1n, MAX, 1], // G - MAX*G
];

const seed = process.argv[2] ?? "0x00";
const count = Number(process.argv[3] ?? 500);
const hex = (v) => "0x" + v.toString(16);

let state = seed;
const next = () => {
  state = "0x" + createHash("sha256").update(state).digest("hex");
  return BigInt(state) % (1n << 48n); // circuit range
};

const mul = (k) => (k === 0n ? null : Point.BASE.multiply(k));
const aff = (q) => (q === null ? { x: 0n, y: 0n } : q.toAffine());

const out = { k1: [], k2: [], neg2: [], p1x: [], p1y: [], p2x: [], p2y: [], sx: [], sy: [] };
for (let i = 0; i < count; i++) {
  let k1, k2, neg2;
  if (i < EDGE.length) {
    [k1, k2, neg2] = EDGE[i];
  } else {
    k1 = next();
    k2 = i % 5 === 0 ? k1 : next(); // every 5th random case is a doubling
    neg2 = i % 7 === 0 ? 1 : 0; // and every 7th subtracts
  }
  const a = mul(k1);
  let b = mul(k2);
  if (neg2 && b !== null) b = b.negate();
  const sum = a === null ? b : b === null ? a : a.add(b);

  out.k1.push(hex(k1));
  out.k2.push(hex(k2));
  out.neg2.push(hex(BigInt(neg2)));
  out.p1x.push(hex(aff(a).x));
  out.p1y.push(hex(aff(a).y));
  out.p2x.push(hex(aff(b).x));
  out.p2y.push(hex(aff(b).y));
  out.sx.push(hex(aff(sum).x));
  out.sy.push(hex(aff(sum).y));
}
process.stdout.write(JSON.stringify(out));
