// SPDX-License-Identifier: MIT OR Apache-2.0
//! C2 `dark_transfer` (§6): I own this balance, this is a well-formed ciphertext of an amount
//! inside the caps, and what is left over is still a valid 48-bit balance.
//!
//! Public inputs, canonical order (§19 C1, DarkVault._transferInputs):
//!   [0] chain_id [1] vault [2] sender [3] recipient [4] sender_nonce
//!   [5,6] pk_s [7,8] pk_r [9,10] avail.C [11,12] avail.D
//!   [13,14] ct.C [15,16] ct.D_sender [17,18] ct.D_recipient
//!   [19] min_transfer [20] max_transfer
use dark_lib::{
    assert_key, assert_point_or_identity, assert_u48, assert_valid_point, as_u64, bind, commit,
    decrypt, is_identity, mul_g, scalar,
};
use std::embedded_curve_ops::{EmbeddedCurvePoint, multi_scalar_mul};

fn main(
    s_lo: Field,
    s_hi: Field,
    r_lo: Field,
    r_hi: Field,
    a: u64,
    w: u64,
    chain_id: pub Field,
    vault: pub Field,
    sender: pub Field,
    recipient: pub Field,
    sender_nonce: pub Field,
    pk_s: pub EmbeddedCurvePoint,
    pk_r: pub EmbeddedCurvePoint,
    avail_c: pub EmbeddedCurvePoint,
    avail_d: pub EmbeddedCurvePoint,
    ct_c: pub EmbeddedCurvePoint,
    ct_ds: pub EmbeddedCurvePoint,
    ct_dr: pub EmbeddedCurvePoint,
    min_transfer: pub Field,
    max_transfer: pub Field,
) {
    // (1) keys are real points; a stored balance may be the identity (empty account).
    assert_valid_point(pk_s);
    assert_valid_point(pk_r);
    assert_point_or_identity(avail_c);
    assert_point_or_identity(avail_d);

    // (2) the sender owns pk_s.
    let s = scalar(s_lo, s_hi);
    assert_key(pk_s, s);

    let r = scalar(r_lo, r_hi);

    // (4) ct.C == a*G + r*H, with a in range.
    assert_u48(a);
    assert(commit(a, r) == ct_c, "ct.C != a*G + r*H");

    // (5) both handles use the SAME r. D_recipient binds the recipient's key, so a sender
    //     cannot pollute and freeze someone else's pending balance.
    assert(multi_scalar_mul([pk_s], [r]) == ct_ds, "ct.D_sender != r*pk_sender");
    assert(multi_scalar_mul([pk_r], [r]) == ct_dr, "ct.D_recipient != r*pk_recipient");

    // (3) r != 0. The limbs are already non-zero; this is the check that matters, since
    //     n is prime and pk_s is not the identity, r*pk_s == identity iff r == 0 mod n.
    assert(!is_identity(ct_ds), "r is zero mod n");

    // (6) min_transfer <= a <= max_transfer.
    assert(as_u64(min_transfer) <= a, "a < min_transfer");
    assert(a <= as_u64(max_transfer), "a > max_transfer");

    // (7) the remainder is a valid balance: (avail.C - ct.C) - s*(avail.D - ct.D_sender) == w*G.
    //     Spending the whole balance gives w = 0, i.e. the identity.
    assert_u48(w);
    assert(decrypt(avail_c - ct_c, avail_d - ct_ds, s) == mul_g(w), "remainder is not w*G");

    // (8) domain separators.
    bind([chain_id, vault, sender, recipient, sender_nonce]);
}

mod tests {
    use super::main;
    use dark_lib::{commit, g, h, mul_g};
    use std::embedded_curve_ops::{EmbeddedCurvePoint, EmbeddedCurveScalar, multi_scalar_mul};

    // s_sender = 5, s_recipient = 7; pk_i = s_i^-1 * H.
    global S: Field = 5;
    global S_INV_LO: Field = 0xc14da6573eaaacbb24138740e84afe5e;
    global S_INV_HI: Field = 0x1d08fbde871dc67f6e96903a4db401d1;
    global SR_INV_LO: Field = 0x7b256177a9659850b4a4e256329090bb;
    global SR_INV_HI: Field = 0x1ba70841a540edceb2770343b7b7a035;
    global R_LO: Field = 0x1234567890abcdef1234567890abcdef;
    global R_HI: Field = 0x0fedcba0987654320fedcba098765432;

    global CHAIN: Field = 46630;
    global VAULT: Field = 0x00000000000000000000000000000000000000fa;
    global SENDER: Field = 0x000000000000000000000000000000000000beef;
    global RECIPIENT: Field = 0x000000000000000000000000000000000000cafe;
    global NONCE: Field = 3;
    global MIN_T: Field = 1000000;
    global MAX_T: Field = 25000000000;

    global BALANCE: u64 = 500000000; // 500 USDG
    global AMOUNT: u64 = 120000000; // 120 USDG
    global REMAINDER: u64 = 380000000;

    fn pk_s() -> EmbeddedCurvePoint {
        multi_scalar_mul([h()], [EmbeddedCurveScalar::new(S_INV_LO, S_INV_HI)])
    }
    fn pk_r() -> EmbeddedCurvePoint {
        multi_scalar_mul([h()], [EmbeddedCurveScalar::new(SR_INV_LO, SR_INV_HI)])
    }
    fn r() -> EmbeddedCurveScalar {
        EmbeddedCurveScalar::new(R_LO, R_HI)
    }

    // The sender's stored available balance: encrypted under pk_s with its own randomness rho.
    fn rho() -> EmbeddedCurveScalar {
        EmbeddedCurveScalar::new(0xdeadbeef, 0)
    }
    fn avail_c() -> EmbeddedCurvePoint {
        commit(BALANCE, rho())
    }
    fn avail_d() -> EmbeddedCurvePoint {
        multi_scalar_mul([pk_s()], [rho()])
    }
    fn ct_c() -> EmbeddedCurvePoint {
        commit(AMOUNT, r())
    }
    fn ct_ds() -> EmbeddedCurvePoint {
        multi_scalar_mul([pk_s()], [r()])
    }
    fn ct_dr() -> EmbeddedCurvePoint {
        multi_scalar_mul([pk_r()], [r()])
    }

    fn run(
        a: u64,
        w: u64,
        pi: [Field; 5],
        pts: [EmbeddedCurvePoint; 7],
        caps: [Field; 2],
    ) {
        main(
            S, 0, R_LO, R_HI, a, w, pi[0], pi[1], pi[2], pi[3], pi[4], pts[0], pts[1], pts[2],
            pts[3], pts[4], pts[5], pts[6], caps[0], caps[1],
        );
    }

    fn inputs() -> [Field; 5] {
        [CHAIN, VAULT, SENDER, RECIPIENT, NONCE]
    }
    fn points() -> [EmbeddedCurvePoint; 7] {
        [pk_s(), pk_r(), avail_c(), avail_d(), ct_c(), ct_ds(), ct_dr()]
    }
    fn caps() -> [Field; 2] {
        [MIN_T, MAX_T]
    }
    fn bump(p: EmbeddedCurvePoint, dx: Field, dy: Field) -> EmbeddedCurvePoint {
        EmbeddedCurvePoint { x: p.x + dx, y: p.y + dy }
    }

    // a deposit-only sender. `deposit` stores (x*G, identity), so `avail_d` is the
    // (0,0) sentinel — not a real curve point — and this is the everyday flow where it reaches the
    // balance-conservation `decrypt` as an OPERAND rather than as the result of P - P. Every other
    // test here uses a non-zero rho, so the path was previously exercised only in production.
    fn zero_rho() -> EmbeddedCurveScalar {
        EmbeddedCurveScalar::new(0, 0)
    }
    fn deposit_only_points() -> [EmbeddedCurvePoint; 7] {
        [pk_s(), pk_r(), commit(BALANCE, zero_rho()), dark_lib::identity(), ct_c(), ct_ds(), ct_dr()]
    }

    #[test]
    fn test_accepts_a_transfer_from_a_deposit_only_account() {
        run(AMOUNT, BALANCE - AMOUNT, inputs(), deposit_only_points(), caps());
    }

    #[test(should_fail_with = "remainder is not w*G")]
    fn test_neg_deposit_only_overdraft() {
        // Pinned to the exact assert: this fails balance conservation, NOT assert_u48 — both
        // a and w are well inside 48 bits here, so the range check never fires. Without the
        // should_fail_with a later refactor could make it fail for an unrelated reason and still
        // look green, which is the vacuous-negative trap.
        run(AMOUNT, BALANCE, inputs(), deposit_only_points(), caps());
    }

    #[test]
    fn test_accepts_a_real_transfer() {
        run(AMOUNT, REMAINDER, inputs(), points(), caps());
    }

    /// Spending the entire balance leaves the identity, not a point.
    #[test]
    fn test_accepts_a_full_balance_transfer() {
        let full = BALANCE;
        let pts = [
            pk_s(),
            pk_r(),
            avail_c(),
            avail_d(),
            commit(full, r()),
            ct_ds(),
            ct_dr(),
        ];
        run(full, 0, inputs(), pts, caps());
    }

    // ---- negative test per public input --------------------------------------------------
    // [0..4] chain_id, vault, sender, recipient, sender_nonce: domain separators, bound at the
    // proof level (circuits/evm/test/Verifiers.t.sol), so they execute under any value.
    #[test]
    fn test_binding_inputs_execute_under_any_value() {
        run(AMOUNT, REMAINDER, [CHAIN + 1, VAULT + 1, SENDER + 1, RECIPIENT + 1, NONCE + 1], points(), caps());
    }

    #[test(should_fail)] // [5] pk_s.x
    fn test_neg_pk_s_x() {
        let mut p = points();
        p[0] = bump(p[0], 1, 0);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail)] // [6] pk_s.y
    fn test_neg_pk_s_y() {
        let mut p = points();
        p[0] = bump(p[0], 0, 1);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail)] // [7] pk_r.x
    fn test_neg_pk_r_x() {
        let mut p = points();
        p[1] = bump(p[1], 1, 0);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail)] // [8] pk_r.y
    fn test_neg_pk_r_y() {
        let mut p = points();
        p[1] = bump(p[1], 0, 1);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail)] // [9] avail.C.x
    fn test_neg_avail_c_x() {
        let mut p = points();
        p[2] = bump(p[2], 1, 0);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail)] // [10] avail.C.y
    fn test_neg_avail_c_y() {
        let mut p = points();
        p[2] = bump(p[2], 0, 1);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail)] // [11] avail.D.x
    fn test_neg_avail_d_x() {
        let mut p = points();
        p[3] = bump(p[3], 1, 0);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail)] // [12] avail.D.y
    fn test_neg_avail_d_y() {
        let mut p = points();
        p[3] = bump(p[3], 0, 1);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail_with = "ct.C != a*G + r*H")] // [13] ct.C.x
    fn test_neg_ct_c_x() {
        let mut p = points();
        p[4] = bump(p[4], 1, 0);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail_with = "ct.C != a*G + r*H")] // [14] ct.C.y
    fn test_neg_ct_c_y() {
        let mut p = points();
        p[4] = bump(p[4], 0, 1);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail_with = "ct.D_sender != r*pk_sender")] // [15] ct.D_sender.x
    fn test_neg_ct_ds_x() {
        let mut p = points();
        p[5] = bump(p[5], 1, 0);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail_with = "ct.D_sender != r*pk_sender")] // [16] ct.D_sender.y
    fn test_neg_ct_ds_y() {
        let mut p = points();
        p[5] = bump(p[5], 0, 1);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail_with = "ct.D_recipient != r*pk_recipient")] // [17] ct.D_recipient.x
    fn test_neg_ct_dr_x() {
        let mut p = points();
        p[6] = bump(p[6], 1, 0);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail_with = "ct.D_recipient != r*pk_recipient")] // [18] ct.D_recipient.y
    fn test_neg_ct_dr_y() {
        let mut p = points();
        p[6] = bump(p[6], 0, 1);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    #[test(should_fail_with = "a < min_transfer")] // [19] min_transfer
    fn test_neg_min_transfer() {
        run(AMOUNT, REMAINDER, inputs(), points(), [AMOUNT as Field + 1, MAX_T]);
    }

    #[test(should_fail_with = "a > max_transfer")] // [20] max_transfer
    fn test_neg_max_transfer() {
        run(AMOUNT, REMAINDER, inputs(), points(), [MIN_T, AMOUNT as Field - 1]);
    }

    // ---- private-witness negatives --------------------------------------------------------
    /// Overdraft: claiming a remainder that does not match the ciphertext.
    #[test(should_fail_with = "remainder is not w*G")]
    fn test_neg_overdraft() {
        let pts = [pk_s(), pk_r(), avail_c(), avail_d(), commit(BALANCE + 1, r()), ct_ds(), ct_dr()];
        run(BALANCE + 1, 0, inputs(), pts, caps());
    }

    /// The recipient handle must use the same r as the commitment.
    #[test(should_fail_with = "ct.D_recipient != r*pk_recipient")]
    fn test_neg_mismatched_recipient_handle() {
        let mut p = points();
        p[6] = multi_scalar_mul([pk_r()], [EmbeddedCurveScalar::new(999, 0)]);
        run(AMOUNT, REMAINDER, inputs(), p, caps());
    }

    /// r = 0 leaks the amount: ct.C would be a*G and both handles the identity.
    #[test(should_fail_with = "scalar is zero")]
    fn test_neg_zero_randomness() {
        main(
            S, 0, 0, 0, AMOUNT, REMAINDER, CHAIN, VAULT, SENDER, RECIPIENT, NONCE, pk_s(), pk_r(),
            avail_c(), avail_d(), mul_g(AMOUNT), dark_lib::identity(), dark_lib::identity(), MIN_T,
            MAX_T,
        );
    }

    #[test(should_fail_with = "amount is not below 2^48")]
    fn test_neg_amount_over_2_48() {
        let big: u64 = 0x1000000000000;
        let pts = [pk_s(), pk_r(), avail_c(), avail_d(), commit(big, r()), ct_ds(), ct_dr()];
        run(big, 0, inputs(), pts, [MIN_T, 0x2000000000000]);
    }

    /// G must be the std generator, or commit() and mul_g() would disagree.
    #[test]
    fn test_g_is_std_generator() {
        assert(mul_g(1) == g());
    }
}
