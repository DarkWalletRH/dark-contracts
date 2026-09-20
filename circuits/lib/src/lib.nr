// SPDX-License-Identifier: MIT OR Apache-2.0
//! Shared Grumpkin helpers for the DARK-CB-1 circuits (spec §3, §6, §19 X1).
//!
//! Grumpkin is y^2 = x^3 - 17 over F_r, and r is exactly Noir's `Field` modulus,
//! so coordinates are canonical by construction: §3's "x < r, y < r" checks and the
//! "non-canonical x + r must never pass" rule are free here, there is no other
//! representation of a coordinate. The two checks that cost something are on-curve
//! and not-the-identity.
//!
//! The group order n is the BN254 *base* field, which is LARGER than r, so a scalar
//! does not fit in a Field. Scalars travel as the 128-bit limb pair `EmbeddedCurveScalar`
//! uses (§6: "`s` (lo/hi limbs)").
use std::embedded_curve_ops::{
    EmbeddedCurvePoint, EmbeddedCurveScalar, fixed_base_scalar_mul, multi_scalar_mul,
};

/// y^2 = x^3 + CURVE_B.
pub global CURVE_B: Field = -17;

/// Noir's embedded-curve generator (§3). `test_g_matches_std` pins it against
/// `fixed_base_scalar_mul` at the toolchain in VERSIONS.toml.
pub global G_X: Field = 1;
pub global G_Y: Field = 17631683881184975370165255887551781615748388533673675138860;

/// Nothing-up-my-sleeve second generator (§3, §19 K1/K2):
///   for i = 0, 1, ...  x = keccak256(ascii("DARK-CB-1/generator/H") || u32be(i)) mod r,
///   the first x with x^3 - 17 a square gives H = (x, the root whose LSB is 0).
/// Byte-for-byte `H` in packages/dark-sdk/src/grumpkin.ts. `test_h_matches_sdk` holds the
/// SDK's copy of the constant; circuits/tools/gen_prover.mjs re-derives it from the SDK at
/// witness time and fails the build on drift. Nobody knows log_G(H).
pub global H_X: Field = 0x1c670f693e0f1e5f2dd00c3fbf55c8e22af4ca3071dee49808899f9aa44d1024;
pub global H_Y: Field = 0x2574095592574b6dedda035b4a88af623685e955658a73e5af0701ee23e282bc;

/// 2^48: the amount range (§3). About $281M in USDG micro-units.
pub global MAX_AMOUNT: u64 = 0x1000000000000;

/// §19 X1: nargo 1.0.0-beta.22 `EmbeddedCurvePoint` has no `is_infinite`; the identity is (0, 0).
pub fn identity() -> EmbeddedCurvePoint {
    EmbeddedCurvePoint { x: 0, y: 0 }
}

pub fn g() -> EmbeddedCurvePoint {
    EmbeddedCurvePoint { x: G_X, y: G_Y }
}

pub fn h() -> EmbeddedCurvePoint {
    EmbeddedCurvePoint { x: H_X, y: H_Y }
}

pub fn is_identity(p: EmbeddedCurvePoint) -> bool {
    (p.x == 0) & (p.y == 0)
}

fn on_curve(p: EmbeddedCurvePoint) -> bool {
    p.y * p.y == p.x * p.x * p.x + CURVE_B
}

/// A key or a freshly supplied ciphertext component: on the curve and not the sentinel.
pub fn assert_valid_point(p: EmbeddedCurvePoint) {
    assert(!is_identity(p), "point is the identity sentinel");
    assert(on_curve(p), "point is not on Grumpkin");
}

/// A stored ciphertext component: on the curve, or the identity (an empty balance, or the
/// `(x*G, identity)` encoding of a public amount).
pub fn assert_point_or_identity(p: EmbeddedCurvePoint) {
    assert(on_curve(p) | is_identity(p), "point is neither on Grumpkin nor the identity");
}

/// A Grumpkin scalar from its 128-bit limbs, s = lo + hi * 2^128, asserted non-zero.
///
/// The limb range checks bound s below 2^256; that is NOT canonicality. n < 2^254, so the same
/// group element also has the limb encoding s + n, which passes both range checks. What rules
/// it out is the backend's Grumpkin MSM gadget, which rejects any scalar >= n: witness solving
/// fails ("... is not a valid grumpkin scalar") and bb is never reached. These functions add no
/// constraint of their own for it -- pinned by dark_register::tests::test_neg_s_plus_n.
pub fn scalar(lo: Field, hi: Field) -> EmbeddedCurveScalar {
    lo.assert_max_bit_size::<128>();
    hi.assert_max_bit_size::<128>();
    assert((lo != 0) | (hi != 0), "scalar is zero");
    EmbeddedCurveScalar::new(lo, hi)
}

/// §3/§6: amounts live in [0, 2^48). The u64 witness carries the 64-bit range check.
pub fn assert_u48(v: u64) {
    assert(v < MAX_AMOUNT, "amount is not below 2^48");
}

/// A public input the contract passes as a uint256 but which is a u64 on-chain value
/// (an amount, a cap). The bit-size assert is what makes the cast non-truncating.
pub fn as_u64(v: Field) -> u64 {
    v.assert_max_bit_size::<64>();
    v as u64
}

/// The key relation (§3): P = s^-1 * H, proved as s * P == H. Since n is prime and H is not
/// the identity, this also rules out s == 0 mod n whatever the limbs say.
pub fn assert_key(p: EmbeddedCurvePoint, s: EmbeddedCurveScalar) {
    assert(multi_scalar_mul([p], [s]) == h(), "s * P != H");
}

/// v * G for a 48-bit v. v = 0 gives the identity, which is what an exactly-emptied
/// balance looks like.
pub fn mul_g(v: u64) -> EmbeddedCurvePoint {
    fixed_base_scalar_mul(EmbeddedCurveScalar::from_field(v as Field))
}

/// v * G + rho * H, the twisted-ElGamal commitment (§3).
pub fn commit(v: u64, rho: EmbeddedCurveScalar) -> EmbeddedCurvePoint {
    multi_scalar_mul([g(), h()], [EmbeddedCurveScalar::from_field(v as Field), rho])
}

/// Decrypt to a point: C - s * D (§3).
pub fn decrypt(c: EmbeddedCurvePoint, d: EmbeddedCurvePoint, s: EmbeddedCurveScalar) -> EmbeddedCurvePoint {
    c - multi_scalar_mul([d], [s])
}

/// Public inputs that are pure domain separators (chainId, contract, account, nonce) have no
/// other constraint to live in. Honk binds every public input through the public-input delta,
/// so a proof already does not verify under a different value -- circuits/evm/test/Verifiers.t.sol
/// proves that against the real verifier, flipping each input of each circuit in turn. This
/// forces them into a multiplication gate as well, so the property does not rest on the backend
/// alone and `nargo` does not warn them away.
pub fn bind<let N: u32>(values: [Field; N]) {
    let mut acc: Field = 0;
    for i in 0..N {
        acc = acc * 7 + values[i] * values[i];
    }
    // Non-removable: the compiler cannot decide `acc != -1`, so the inverse constraint stays.
    assert(acc != -1, "binding accumulator hit the impossible value");
}

mod tests {
    use super::{
        as_u64, assert_key, assert_point_or_identity, assert_u48, assert_valid_point, commit,
        decrypt, g, h, identity, is_identity, mul_g, scalar, G_Y, H_X, H_Y,
    };
    use std::embedded_curve_ops::{EmbeddedCurvePoint, EmbeddedCurveScalar, fixed_base_scalar_mul};

    /// §3: CI asserts G equals `std::embedded_curve_ops`'s generator at the pinned nargo.
    #[test]
    fn test_g_matches_std() {
        assert(fixed_base_scalar_mul(EmbeddedCurveScalar::new(1, 0)) == g());
        assert(G_Y == 17631683881184975370165255887551781615748388533673675138860);
    }

    /// The SDK's `H` (packages/dark-sdk/src/grumpkin.ts, derived at import time from
    /// keccak256("DARK-CB-1/generator/H" || u32be(i))), copied here as a literal.
    #[test]
    fn test_h_matches_sdk() {
        let sdk_h = EmbeddedCurvePoint {
            x: 0x1c670f693e0f1e5f2dd00c3fbf55c8e22af4ca3071dee49808899f9aa44d1024,
            y: 0x2574095592574b6dedda035b4a88af623685e955658a73e5af0701ee23e282bc,
        };
        assert(h() == sdk_h);
        assert((H_X == sdk_h.x) & (H_Y == sdk_h.y));
    }

    #[test]
    fn test_generators_on_curve() {
        assert_valid_point(g());
        assert_valid_point(h());
    }

    #[test]
    fn test_identity_is_the_sentinel() {
        assert(is_identity(identity()));
        assert(!is_identity(g()));
        assert(mul_g(0) == identity());
        assert(g() - g() == identity());
        assert_point_or_identity(identity());
    }

    #[test(should_fail_with = "point is the identity sentinel")]
    fn test_identity_rejected_as_key() {
        assert_valid_point(identity());
    }

    #[test(should_fail_with = "point is not on Grumpkin")]
    fn test_off_curve_rejected() {
        assert_valid_point(EmbeddedCurvePoint { x: 3, y: 4 });
    }

    /// The canonicality rule of §3: x + r is the same Field element as x, there is no
    /// second encoding for the backend to accept.
    #[test]
    fn test_coordinates_are_canonical_by_construction() {
        let p = g();
        let wrapped = EmbeddedCurvePoint { x: p.x + 0, y: p.y };
        assert(wrapped == p);
    }

    #[test(should_fail_with = "scalar is zero")]
    fn test_zero_scalar_rejected() {
        let _ = scalar(0, 0);
    }

    #[test(should_fail_with = "amount is not below 2^48")]
    fn test_u48_bound() {
        assert_u48(0x1000000000000);
    }

    #[test(should_fail)]
    fn test_as_u64_rejects_wide_field() {
        let _ = as_u64(0x10000000000000000);
    }

    /// The whole ElGamal round trip, in-circuit: P = s^-1 H, C = vG + rH, D = rP, C - sD = vG.
    #[test]
    fn test_elgamal_roundtrip() {
        // s = 5, s^-1 mod n. n = 21888242871839275222246405745257275088696311157297823662689037894645226208583.
        let s_inv = EmbeddedCurveScalar::new(
            0xc14da6573eaaacbb24138740e84afe5e,
            0x1d08fbde871dc67f6e96903a4db401d1,
        );
        let p = std::embedded_curve_ops::multi_scalar_mul([h()], [s_inv]);
        let s = scalar(5, 0);
        assert_key(p, s);

        let rho = scalar(123456789, 0);
        let v: u64 = 42;
        let c = commit(v, rho);
        let d = std::embedded_curve_ops::multi_scalar_mul([p], [rho]);
        assert(decrypt(c, d, s) == mul_g(v));
    }
}
