// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

/// @notice Grumpkin (y^2 = x^3 - 17 over the BN254 scalar field) point arithmetic, clean-room (§6.3).
/// @dev Identity is the sentinel (0,0), which is not on the curve. Coordinates are canonical (< P).
///      Points are passed as flat (x, y) pairs so callers can keep their own `Point` struct type.
library DarkGrumpkin {
    /// @dev The Grumpkin base field = the BN254 scalar field.
    uint256 internal constant P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    /// @dev b = -17 mod P.
    uint256 internal constant B = P - 17;
    uint256 internal constant GX = 1;
    uint256 internal constant GY = 17631683881184975370165255887551781615748388533673675138860;
    /// @dev mulG is only defined for amounts in the circuit range [0, 2^48).
    uint256 internal constant MAX_SCALAR = 1 << 48;

    error NotOnCurve();
    error ScalarTooLarge();

    function isIdentity(uint256 x, uint256 y) internal pure returns (bool) {
        return x == 0 && y == 0;
    }

    /// @notice x < P, y < P and y^2 == x^3 - 17. The identity sentinel is NOT on the curve.
    function isOnCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= P || y >= P) return false;
        return mulmod(y, y, P) == addmod(mulmod(mulmod(x, x, P), x, P), B, P);
    }

    /// @notice Every user-supplied point must be canonical, on-curve and not the identity (§6.3).
    function requireValid(uint256 x, uint256 y) internal pure {
        if (!isOnCurve(x, y)) revert NotOnCurve();
    }

    function neg(uint256 x, uint256 y) internal pure returns (uint256, uint256) {
        if (y == 0) return (x, y); // identity sentinel
        return (x, P - y);
    }

    /// @notice Affine addition; handles the identity sentinel, doubling and P + (-P).
    function add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256 x3, uint256 y3) {
        if (isIdentity(x1, y1)) return (x2, y2);
        if (isIdentity(x2, y2)) return (x1, y1);

        uint256 lambda;
        if (x1 == x2) {
            if (addmod(y1, y2, P) == 0) return (0, 0); // P + (-P) = identity
            // doubling: lambda = 3x^2 / 2y   (a = 0)
            uint256 num = mulmod(3, mulmod(x1, x1, P), P);
            lambda = mulmod(num, inv(mulmod(2, y1, P)), P);
        } else {
            lambda = mulmod(addmod(y2, P - y1, P), inv(addmod(x2, P - x1, P)), P);
        }
        x3 = addmod(mulmod(lambda, lambda, P), P - addmod(x1, x2, P), P);
        y3 = addmod(mulmod(lambda, addmod(x1, P - x3, P), P), P - y1, P);
    }

    function sub(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256, uint256) {
        (uint256 nx, uint256 ny) = neg(x2, y2);
        return add(x1, y1, nx, ny);
    }

    /// @notice k*G for k < 2^48, via Jacobian double-and-add with a single final inversion.
    // ponytail: plain double-and-add, no window table. §6.5 wants a 12x15 precomputed table
    // (script/gen_g_table.ts) for gas; swap it in when deposit/withdraw gas is measured and matters.
    function mulG(uint256 k) internal view returns (uint256, uint256) {
        if (k >= MAX_SCALAR) revert ScalarTooLarge();
        if (k == 0) return (0, 0);

        uint256 X;
        uint256 Y;
        uint256 Z; // Jacobian; Z == 0 is the identity
        for (uint256 i = 48; i > 0;) {
            unchecked {
                --i;
            }
            if (Z != 0) (X, Y, Z) = jDouble(X, Y, Z);
            if ((k >> i) & 1 == 1) {
                if (Z == 0) {
                    (X, Y, Z) = (GX, GY, 1);
                } else {
                    (X, Y, Z) = jAddG(X, Y, Z);
                }
            }
        }
        return toAffine(X, Y, Z);
    }

    // ---- internals ----

    /// @dev dbl-2009-l (a = 0).
    function jDouble(uint256 X, uint256 Y, uint256 Z) private pure returns (uint256, uint256, uint256) {
        uint256 A = mulmod(X, X, P);
        uint256 C = mulmod(Y, Y, P);
        uint256 D = mulmod(C, C, P);
        uint256 S = mulmod(2, addmod(mulmod(addmod(X, C, P), addmod(X, C, P), P), P - addmod(A, D, P), P), P);
        uint256 E = mulmod(3, A, P);
        uint256 X3 = addmod(mulmod(E, E, P), P - mulmod(2, S, P), P);
        uint256 Y3 = addmod(mulmod(E, addmod(S, P - X3, P), P), P - mulmod(8, D, P), P);
        return (X3, Y3, mulmod(2, mulmod(Y, Z, P), P));
    }

    /// @dev madd-2007-bl with the affine addend fixed to G (Z2 = 1).
    function jAddG(uint256 X1, uint256 Y1, uint256 Z1) private pure returns (uint256, uint256, uint256) {
        uint256 ZZ = mulmod(Z1, Z1, P);
        uint256 U2 = mulmod(GX, ZZ, P);
        uint256 S2 = mulmod(GY, mulmod(Z1, ZZ, P), P);
        uint256 H = addmod(U2, P - X1, P);
        uint256 r = mulmod(2, addmod(S2, P - Y1, P), P);
        if (H == 0) {
            if (r == 0) return jDouble(X1, Y1, Z1);
            return (0, 0, 0); // X1 == G and Y1 == -G.y
        }
        uint256 I = mulmod(4, mulmod(H, H, P), P);
        uint256 J = mulmod(H, I, P);
        uint256 V = mulmod(X1, I, P);
        uint256 X3 = addmod(mulmod(r, r, P), P - addmod(J, mulmod(2, V, P), P), P);
        uint256 Y3 = addmod(mulmod(r, addmod(V, P - X3, P), P), P - mulmod(2, mulmod(Y1, J, P), P), P);
        uint256 Z3 = addmod(addmod(mulmod(addmod(Z1, H, P), addmod(Z1, H, P), P), P - ZZ, P), P - mulmod(H, H, P), P);
        return (X3, Y3, Z3);
    }

    function toAffine(uint256 X, uint256 Y, uint256 Z) private view returns (uint256, uint256) {
        if (Z == 0) return (0, 0);
        uint256 zi = inv(Z);
        uint256 zi2 = mulmod(zi, zi, P);
        return (mulmod(X, zi2, P), mulmod(Y, mulmod(zi2, zi, P), P));
    }

    /// @dev a^(P-2) mod P via the modexp precompile (0x05). Reverts on a == 0 (never called with 0).
    function inv(uint256 a) private view returns (uint256 out) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x20)
            mstore(add(m, 0x20), 0x20)
            mstore(add(m, 0x40), 0x20)
            mstore(add(m, 0x60), a)
            mstore(add(m, 0x80), sub(P, 2))
            mstore(add(m, 0xa0), P)
            if iszero(staticcall(gas(), 0x05, m, 0xc0, m, 0x20)) { revert(0, 0) }
            out := mload(m)
        }
    }
}
