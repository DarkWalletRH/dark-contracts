// SPDX-License-Identifier: MIT OR Apache-2.0
//! C4 `dark_disclose_range` (§6): the value behind this ciphertext is in [lo, hi].
//! Off-chain only -- verified in the browser with bb.js, never deployed.
//!
//! Public inputs, canonical order (§19 C1):
//!   [0] context_hash [1,2] pk [3,4] c [5,6] d [7] lo [8] hi
//!
//! `c`/`d` may be a viewer-recomputed sum ciphertext, which is how "flow total in [X, Y]"
//! works with the same circuit.
use dark_lib::{
    assert_key, assert_point_or_identity, assert_u48, assert_valid_point, as_u64, bind, decrypt,
    mul_g, scalar,
};
use std::embedded_curve_ops::EmbeddedCurvePoint;

fn main(
    s_lo: Field,
    s_hi: Field,
    v: u64,
    context_hash: pub Field,
    pk: pub EmbeddedCurvePoint,
    c: pub EmbeddedCurvePoint,
    d: pub EmbeddedCurvePoint,
    lo: pub Field,
    hi: pub Field,
) {
    assert_valid_point(pk);
    assert_point_or_identity(c);
    assert_point_or_identity(d);

    let s = scalar(s_lo, s_hi);
    assert_key(pk, s);

    // c - s*d == v*G.
    assert(decrypt(c, d, s) == mul_g(v), "c - s*d != v*G");

    // lo <= v <= hi < 2^48.
    let lo_u = as_u64(lo);
    let hi_u = as_u64(hi);
    assert_u48(hi_u);
    assert(lo_u <= v, "v < lo");
    assert(v <= hi_u, "v > hi");

    bind([context_hash]);
}

mod tests {
    use super::main;
    use dark_lib::{commit, h};
    use std::embedded_curve_ops::{EmbeddedCurvePoint, EmbeddedCurveScalar, multi_scalar_mul};

    global S: Field = 5;
    global S_INV_LO: Field = 0xc14da6573eaaacbb24138740e84afe5e;
    global S_INV_HI: Field = 0x1d08fbde871dc67f6e96903a4db401d1;
    global CTX: Field = 0x1e5f2dd00c3fbf55c8e22af4ca3071dee49808899f9aa44d1024abcdef012345;

    global VALUE: u64 = 250000000;
    global LO: Field = 100000000;
    global HI: Field = 500000000;

    fn pk() -> EmbeddedCurvePoint {
        multi_scalar_mul([h()], [EmbeddedCurveScalar::new(S_INV_LO, S_INV_HI)])
    }
    fn rho() -> EmbeddedCurveScalar {
        EmbeddedCurveScalar::new(0xfeedface, 0)
    }
    fn c() -> EmbeddedCurvePoint {
        commit(VALUE, rho())
    }
    fn d() -> EmbeddedCurvePoint {
        multi_scalar_mul([pk()], [rho()])
    }
    fn bump(p: EmbeddedCurvePoint, dx: Field, dy: Field) -> EmbeddedCurvePoint {
        EmbeddedCurvePoint { x: p.x + dx, y: p.y + dy }
    }
    fn run(pts: [EmbeddedCurvePoint; 3], ctx: Field, lo: Field, hi: Field) {
        main(S, 0, VALUE, ctx, pts[0], pts[1], pts[2], lo, hi);
    }
    fn points() -> [EmbeddedCurvePoint; 3] {
        [pk(), c(), d()]
    }

    #[test]
    fn test_accepts_a_value_in_range() {
        run(points(), CTX, LO, HI);
    }

    /// "balance >= X" and "balance <= X" are the same circuit with a saturated bound.
    #[test]
    fn test_accepts_open_ended_bounds() {
        run(points(), CTX, 0, 0xffffffffffff); // <= X form, hi = 2^48 - 1
        run(points(), CTX, VALUE as Field, 0xffffffffffff); // >= X form
    }

    // ---- negative test per public input --------------------------------------------------
    // [0] context_hash is a domain separator; circuits/evm/test/Verifiers.t.sol flips it at
    // the proof level.
    #[test]
    fn test_binding_input_executes_under_any_value() {
        run(points(), CTX + 1, LO, HI);
    }

    #[test(should_fail)] // [1] pk.x
    fn test_neg_pk_x() {
        let mut p = points();
        p[0] = bump(p[0], 1, 0);
        run(p, CTX, LO, HI);
    }

    #[test(should_fail)] // [2] pk.y
    fn test_neg_pk_y() {
        let mut p = points();
        p[0] = bump(p[0], 0, 1);
        run(p, CTX, LO, HI);
    }

    #[test(should_fail)] // [3] c.x
    fn test_neg_c_x() {
        let mut p = points();
        p[1] = bump(p[1], 1, 0);
        run(p, CTX, LO, HI);
    }

    #[test(should_fail)] // [4] c.y
    fn test_neg_c_y() {
        let mut p = points();
        p[1] = bump(p[1], 0, 1);
        run(p, CTX, LO, HI);
    }

    #[test(should_fail)] // [5] d.x
    fn test_neg_d_x() {
        let mut p = points();
        p[2] = bump(p[2], 1, 0);
        run(p, CTX, LO, HI);
    }

    #[test(should_fail)] // [6] d.y
    fn test_neg_d_y() {
        let mut p = points();
        p[2] = bump(p[2], 0, 1);
        run(p, CTX, LO, HI);
    }

    #[test(should_fail_with = "v < lo")] // [7] lo
    fn test_neg_lo() {
        run(points(), CTX, VALUE as Field + 1, HI);
    }

    #[test(should_fail_with = "v > hi")] // [8] hi
    fn test_neg_hi() {
        run(points(), CTX, LO, VALUE as Field - 1);
    }

    // ---- private-witness negatives --------------------------------------------------------
    #[test(should_fail_with = "c - s*d != v*G")]
    fn test_neg_lying_about_the_value() {
        main(S, 0, VALUE + 1, CTX, pk(), c(), d(), LO, HI);
    }

    #[test(should_fail_with = "amount is not below 2^48")]
    fn test_neg_hi_over_2_48() {
        run(points(), CTX, LO, 0x1000000000000);
    }

    #[test(should_fail_with = "s * P != H")]
    fn test_neg_not_my_ciphertext() {
        main(6, 0, VALUE, CTX, pk(), c(), d(), LO, HI);
    }
}
