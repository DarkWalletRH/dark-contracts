// SPDX-License-Identifier: MIT OR Apache-2.0
//! C1 `dark_register` (§6, §4 "Registration"): I know the s behind this public key.
//!
//! Public inputs, canonical order (§19 C1, DarkKeyRegistry.register):
//!   [0] chain_id  [1] registry  [2] account  [3] pk.x  [4] pk.y
//!
//! Binding chain, registry and caller is what stops a proof being replayed on another chain
//! or front-run into someone else's registration.
use dark_lib::{assert_key, assert_valid_point, bind, scalar};
use std::embedded_curve_ops::EmbeddedCurvePoint;

fn main(
    s_lo: Field,
    s_hi: Field,
    chain_id: pub Field,
    registry: pub Field,
    account: pub Field,
    pk: pub EmbeddedCurvePoint,
) {
    assert_valid_point(pk);
    assert_key(pk, scalar(s_lo, s_hi));
    bind([chain_id, registry, account]);
}

mod tests {
    use super::main;
    use std::embedded_curve_ops::{EmbeddedCurvePoint, EmbeddedCurveScalar, multi_scalar_mul};

    // s = 5; pk = s^-1 * H. Same vector as dark_lib::tests::test_elgamal_roundtrip.
    global S_LO: Field = 0xc14da6573eaaacbb24138740e84afe5e;
    global S_HI: Field = 0x1d08fbde871dc67f6e96903a4db401d1;
    global CHAIN: Field = 46630;
    global REGISTRY: Field = 0x00000000000000000000000000000000000000ce;
    global ACCOUNT: Field = 0x000000000000000000000000000000000000beef;

    fn pk() -> EmbeddedCurvePoint {
        multi_scalar_mul([dark_lib::h()], [EmbeddedCurveScalar::new(S_LO, S_HI)])
    }

    #[test]
    fn test_accepts_a_real_key() {
        main(5, 0, CHAIN, REGISTRY, ACCOUNT, pk());
    }

    // ---- negative test per public input -------------------------------------------------
    // [3]/[4] pk: flipping either coordinate breaks s*pk == H (or the curve check first).
    #[test(should_fail)]
    fn test_neg_pk_x() {
        let p = pk();
        main(5, 0, CHAIN, REGISTRY, ACCOUNT, EmbeddedCurvePoint { x: p.x + 1, y: p.y });
    }

    #[test(should_fail)]
    fn test_neg_pk_y() {
        let p = pk();
        main(5, 0, CHAIN, REGISTRY, ACCOUNT, EmbeddedCurvePoint { x: p.x, y: p.y + 1 });
    }

    // [0] chain_id, [1] registry, [2] account are domain separators: they have no in-circuit
    // relation to fall out of, so execution still succeeds and the binding is at the proof
    // level. circuits/evm/test/Verifiers.t.sol flips each against the real verifier.
    #[test]
    fn test_binding_inputs_execute_under_any_value() {
        main(5, 0, CHAIN + 1, REGISTRY + 1, ACCOUNT + 1, pk());
    }

    #[test(should_fail_with = "s * P != H")]
    fn test_neg_wrong_secret() {
        main(6, 0, CHAIN, REGISTRY, ACCOUNT, pk());
    }

    #[test(should_fail_with = "scalar is zero")]
    fn test_neg_zero_secret() {
        main(0, 0, CHAIN, REGISTRY, ACCOUNT, pk());
    }

    #[test(should_fail_with = "point is the identity sentinel")]
    fn test_neg_identity_key() {
        main(5, 0, CHAIN, REGISTRY, ACCOUNT, EmbeddedCurvePoint { x: 0, y: 0 });
    }

    // dark_lib::scalar's limb range checks allow s and s + n alike (n < 2^254 < 2^256), so
    // canonicality is not something the circuit constrains. This records where it IS enforced:
    // the backend's Grumpkin MSM rejects any scalar >= n, so a witness carrying s + n cannot be
    // solved at all and never reaches bb. Limbs of 5 + n, with 5 the secret in test_accepts_a_real_key.
    #[test(should_fail_with = "is not a valid grumpkin scalar")]
    fn test_neg_s_plus_n() {
        main(
            0x97816a916871ca8d3c208c16d87cfd4c, // (5 + n) mod 2^128
            0x30644e72e131a029b85045b68181585d, // (5 + n) >> 128
            CHAIN,
            REGISTRY,
            ACCOUNT,
            pk(),
        );
    }
}
