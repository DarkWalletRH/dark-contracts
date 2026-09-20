// SPDX-License-Identifier: MIT OR Apache-2.0
//! C3 `dark_withdraw` (§6): I own this balance and it covers this public amount.
//!
//! Public inputs, canonical order (§19 C1, DarkVault._withdrawInputs):
//!   [0] chain_id [1] vault [2] account [3] to [4] nonce
//!   [5,6] pk [7,8] avail.C [9,10] avail.D [11] amount
//!
//! `to` is a binding input: a withdraw proof is only good for the recipient it was built for.
use dark_lib::{
    assert_key, assert_point_or_identity, assert_u48, assert_valid_point, as_u64, bind, decrypt,
    mul_g, scalar,
};
use std::embedded_curve_ops::EmbeddedCurvePoint;

fn main(
    s_lo: Field,
    s_hi: Field,
    w: u64,
    chain_id: pub Field,
    vault: pub Field,
    account: pub Field,
    to: pub Field,
    nonce: pub Field,
    pk: pub EmbeddedCurvePoint,
    avail_c: pub EmbeddedCurvePoint,
    avail_d: pub EmbeddedCurvePoint,
    amount: pub Field,
) {
    assert_valid_point(pk);
    assert_point_or_identity(avail_c);
    assert_point_or_identity(avail_d);

    let s = scalar(s_lo, s_hi);
    assert_key(pk, s);

    // 1 <= amount < 2^48. A zero withdraw is `AmountZero` on-chain (§19 C4); reject it here too.
    let amt = as_u64(amount);
    assert(amt != 0, "amount is zero");
    assert_u48(amt);

    // (avail.C - amount*G) - s*avail.D == w*G, with the remainder still a valid balance.
    assert_u48(w);
    assert(decrypt(avail_c - mul_g(amt), avail_d, s) == mul_g(w), "remainder is not w*G");

    bind([chain_id, vault, account, to, nonce]);
}

mod tests {
    use super::main;
    use dark_lib::{commit, h, mul_g};
    use std::embedded_curve_ops::{EmbeddedCurvePoint, EmbeddedCurveScalar, multi_scalar_mul};

    global S: Field = 5;
    global S_INV_LO: Field = 0xc14da6573eaaacbb24138740e84afe5e;
    global S_INV_HI: Field = 0x1d08fbde871dc67f6e96903a4db401d1;

    global CHAIN: Field = 46630;
    global VAULT: Field = 0x00000000000000000000000000000000000000fa;
    global ACCOUNT: Field = 0x000000000000000000000000000000000000beef;
    global TO: Field = 0x000000000000000000000000000000000000cafe;
    global NONCE: Field = 9;

    global BALANCE: u64 = 500000000;
    global AMOUNT: u64 = 200000000;
    global REMAINDER: u64 = 300000000;

    fn pk() -> EmbeddedCurvePoint {
        multi_scalar_mul([h()], [EmbeddedCurveScalar::new(S_INV_LO, S_INV_HI)])
    }
    fn rho() -> EmbeddedCurveScalar {
        EmbeddedCurveScalar::new(0xdeadbeef, 0)
    }
    fn avail_c() -> EmbeddedCurvePoint {
        commit(BALANCE, rho())
    }
    fn avail_d() -> EmbeddedCurvePoint {
        multi_scalar_mul([pk()], [rho()])
    }
    fn bump(p: EmbeddedCurvePoint, dx: Field, dy: Field) -> EmbeddedCurvePoint {
        EmbeddedCurvePoint { x: p.x + dx, y: p.y + dy }
    }

    fn run(w: u64, pi: [Field; 5], pts: [EmbeddedCurvePoint; 3], amount: Field) {
        main(S, 0, w, pi[0], pi[1], pi[2], pi[3], pi[4], pts[0], pts[1], pts[2], amount);
    }
    fn inputs() -> [Field; 5] {
        [CHAIN, VAULT, ACCOUNT, TO, NONCE]
    }
    fn points() -> [EmbeddedCurvePoint; 3] {
        [pk(), avail_c(), avail_d()]
    }

    #[test]
    fn test_accepts_a_real_withdraw() {
        run(REMAINDER, inputs(), points(), AMOUNT as Field);
    }

    #[test]
    fn test_accepts_a_full_withdraw() {
        run(0, inputs(), points(), BALANCE as Field);
    }

    // a deposit-only account spending for the first time. `deposit` stores
    // (x*G, identity), so `avail_d` is the (0,0) sentinel rather than a real curve point — and the
    // sentinel is not on the curve, so this is the one everyday flow where the identity reaches
    // `decrypt` as an OPERAND rather than as the result of P - P. Every other test here uses a
    // non-zero rho, so without this the path was exercised only in production.
    fn zero_rho() -> EmbeddedCurveScalar {
        EmbeddedCurveScalar::new(0, 0)
    }
    fn deposit_only_points() -> [EmbeddedCurvePoint; 3] {
        [pk(), commit(BALANCE, zero_rho()), dark_lib::identity()]
    }

    #[test]
    fn test_accepts_a_withdraw_from_a_deposit_only_account() {
        run(REMAINDER, inputs(), deposit_only_points(), AMOUNT as Field);
    }

    #[test]
    fn test_accepts_a_full_withdraw_from_a_deposit_only_account() {
        run(0, inputs(), deposit_only_points(), BALANCE as Field);
    }

    #[test(should_fail_with = "remainder is not w*G")]
    fn test_neg_deposit_only_overdraft() {
        // Pinned to the exact assert: balance conservation, not assert_u48.
        run(REMAINDER, inputs(), deposit_only_points(), (BALANCE + 1) as Field);
    }

    // ---- negative test per public input --------------------------------------------------
    // [0..4] are domain separators; circuits/evm/test/Verifiers.t.sol flips them at the
    // proof level.
    #[test]
    fn test_binding_inputs_execute_under_any_value() {
        run(REMAINDER, [CHAIN + 1, VAULT + 1, ACCOUNT + 1, TO + 1, NONCE + 1], points(), AMOUNT as Field);
    }

    #[test(should_fail)] // [5] pk.x
    fn test_neg_pk_x() {
        let mut p = points();
        p[0] = bump(p[0], 1, 0);
        run(REMAINDER, inputs(), p, AMOUNT as Field);
    }

    #[test(should_fail)] // [6] pk.y
    fn test_neg_pk_y() {
        let mut p = points();
        p[0] = bump(p[0], 0, 1);
        run(REMAINDER, inputs(), p, AMOUNT as Field);
    }

    #[test(should_fail)] // [7] avail.C.x
    fn test_neg_avail_c_x() {
        let mut p = points();
        p[1] = bump(p[1], 1, 0);
        run(REMAINDER, inputs(), p, AMOUNT as Field);
    }

    #[test(should_fail)] // [8] avail.C.y
    fn test_neg_avail_c_y() {
        let mut p = points();
        p[1] = bump(p[1], 0, 1);
        run(REMAINDER, inputs(), p, AMOUNT as Field);
    }

    #[test(should_fail)] // [9] avail.D.x
    fn test_neg_avail_d_x() {
        let mut p = points();
        p[2] = bump(p[2], 1, 0);
        run(REMAINDER, inputs(), p, AMOUNT as Field);
    }

    #[test(should_fail)] // [10] avail.D.y
    fn test_neg_avail_d_y() {
        let mut p = points();
        p[2] = bump(p[2], 0, 1);
        run(REMAINDER, inputs(), p, AMOUNT as Field);
    }

    #[test(should_fail_with = "remainder is not w*G")] // [11] amount
    fn test_neg_amount() {
        run(REMAINDER, inputs(), points(), AMOUNT as Field + 1);
    }

    // ---- private-witness negatives --------------------------------------------------------
    #[test(should_fail_with = "amount is zero")]
    fn test_neg_zero_amount() {
        run(BALANCE, inputs(), points(), 0);
    }

    #[test(should_fail_with = "remainder is not w*G")]
    fn test_neg_overdraft() {
        run(0, inputs(), points(), BALANCE as Field + 1);
    }

    #[test(should_fail_with = "s * P != H")]
    fn test_neg_wrong_secret() {
        main(6, 0, REMAINDER, CHAIN, VAULT, ACCOUNT, TO, NONCE, pk(), avail_c(), avail_d(), AMOUNT as Field);
    }

    /// A withdraw of the whole balance really does leave the identity.
    #[test]
    fn test_full_withdraw_leaves_identity() {
        assert(mul_g(0) == dark_lib::identity());
    }
}
