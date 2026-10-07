// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DarkGrumpkin} from "../src/libraries/DarkGrumpkin.sol";

contract DarkGrumpkinTest is Test {
    function test_generatorOnCurve() public pure {
        assertTrue(DarkGrumpkin.isOnCurve(DarkGrumpkin.GX, DarkGrumpkin.GY));
        assertFalse(DarkGrumpkin.isOnCurve(0, 0)); // the identity sentinel is not on the curve
    }

    function test_nonCanonicalRejected() public view {
        (uint256 x, uint256 y) = DarkGrumpkin.mulG(7);
        assertTrue(DarkGrumpkin.isOnCurve(x, y));
        assertFalse(DarkGrumpkin.isOnCurve(x + DarkGrumpkin.P, y)); // x + r must never pass
        assertFalse(DarkGrumpkin.isOnCurve(x, y + DarkGrumpkin.P));
        assertFalse(DarkGrumpkin.isOnCurve(x, y + 1));
    }

    function test_identityAndNegation() public view {
        (uint256 x, uint256 y) = DarkGrumpkin.mulG(12345);
        (uint256 ax, uint256 ay) = DarkGrumpkin.add(0, 0, x, y);
        assertEq(ax, x);
        assertEq(ay, y);
        (uint256 sx, uint256 sy) = DarkGrumpkin.sub(x, y, x, y); // P + (-P) = identity
        assertEq(sx, 0);
        assertEq(sy, 0);
        (uint256 nx, uint256 ny) = DarkGrumpkin.neg(0, 0);
        assertEq(nx, 0);
        assertEq(ny, 0);
    }

    function mulG(uint256 k) external view returns (uint256, uint256) {
        return DarkGrumpkin.mulG(k);
    }

    function test_mulGRejectsOversizedScalar() public {
        vm.expectRevert(DarkGrumpkin.ScalarTooLarge.selector);
        this.mulG(1 << 48);
    }

    function test_homomorphism() public view {
        (uint256 ax, uint256 ay) = DarkGrumpkin.mulG(1_000_000);
        (uint256 bx, uint256 by) = DarkGrumpkin.mulG(2_500_000);
        (uint256 sx, uint256 sy) = DarkGrumpkin.add(ax, ay, bx, by);
        (uint256 cx, uint256 cy) = DarkGrumpkin.mulG(3_500_000);
        assertEq(sx, cx);
        assertEq(sy, cy);
    }

    /// @notice 500 cases of mulG, add, neg and sub differentially checked against @noble/curves,
    ///         starting with the edge cases: identity, doubling, P + (-P) and the ends of
    ///         the 2^48 scalar range. Non-canonical inputs are covered below.
    function test_differentialAgainstNoble() public {
        string[] memory cmd = new string[](4);
        cmd[0] = "node";
        cmd[1] = "test/js/diff_grumpkin.mjs";
        cmd[2] = vm.toString(keccak256(abi.encode(block.timestamp, "dark-grumpkin")));
        cmd[3] = "500";
        string memory json = string(vm.ffi(cmd));

        uint256[] memory k1 = vm.parseJsonUintArray(json, ".k1");
        uint256[] memory k2 = vm.parseJsonUintArray(json, ".k2");
        uint256[] memory neg2 = vm.parseJsonUintArray(json, ".neg2");
        uint256[] memory p1x = vm.parseJsonUintArray(json, ".p1x");
        uint256[] memory p1y = vm.parseJsonUintArray(json, ".p1y");
        uint256[] memory p2x = vm.parseJsonUintArray(json, ".p2x");
        uint256[] memory p2y = vm.parseJsonUintArray(json, ".p2y");
        uint256[] memory sx = vm.parseJsonUintArray(json, ".sx");
        uint256[] memory sy = vm.parseJsonUintArray(json, ".sy");

        assertEq(k1.length, 500, "case count");
        for (uint256 i = 0; i < k1.length; i++) {
            (uint256 ax, uint256 ay) = DarkGrumpkin.mulG(k1[i]);
            assertEq(ax, p1x[i], "mulG x");
            assertEq(ay, p1y[i], "mulG y");

            (uint256 bx, uint256 by) = DarkGrumpkin.mulG(k2[i]);
            if (neg2[i] == 1) (bx, by) = DarkGrumpkin.neg(bx, by);
            assertEq(bx, p2x[i], "neg/mulG x");
            assertEq(by, p2y[i], "neg/mulG y");

            (uint256 cx, uint256 cy) = DarkGrumpkin.add(ax, ay, bx, by);
            assertEq(cx, sx[i], "add x");
            assertEq(cy, sy[i], "add y");

            // sub must agree with add-of-negation on the same pair
            (uint256 ux, uint256 uy) = DarkGrumpkin.mulG(k2[i]);
            (uint256 dx, uint256 dy) =
                neg2[i] == 1 ? DarkGrumpkin.sub(ax, ay, ux, uy) : DarkGrumpkin.add(ax, ay, ux, uy);
            assertEq(dx, sx[i], "sub x");
            assertEq(dy, sy[i], "sub y");

            // every result is the identity sentinel or a canonical on-curve point
            assertTrue(DarkGrumpkin.isIdentity(cx, cy) || DarkGrumpkin.isOnCurve(cx, cy), "result invalid");
        }
    }

    /// @notice Non-canonical encodings of a valid point are rejected, including the
    ///         coordinates of the reference points the differential run produced.
    function test_nonCanonicalInputsRejected() public {
        string[] memory cmd = new string[](4);
        cmd[0] = "node";
        cmd[1] = "test/js/diff_grumpkin.mjs";
        cmd[2] = "0x01";
        cmd[3] = "24";
        string memory json = string(vm.ffi(cmd));
        uint256[] memory px = vm.parseJsonUintArray(json, ".p1x");
        uint256[] memory py = vm.parseJsonUintArray(json, ".p1y");

        for (uint256 i = 0; i < px.length; i++) {
            if (px[i] == 0 && py[i] == 0) continue; // identity: never "on curve"
            assertTrue(DarkGrumpkin.isOnCurve(px[i], py[i]), "reference point off curve");
            assertFalse(DarkGrumpkin.isOnCurve(px[i] + DarkGrumpkin.P, py[i]), "x + r accepted");
            assertFalse(DarkGrumpkin.isOnCurve(px[i], py[i] + DarkGrumpkin.P), "y + r accepted");
            assertFalse(DarkGrumpkin.isOnCurve(px[i], DarkGrumpkin.P - py[i] + DarkGrumpkin.P), "-y + r accepted");
        }
    }
}
