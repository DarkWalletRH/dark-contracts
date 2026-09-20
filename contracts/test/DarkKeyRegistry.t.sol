// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DarkBase} from "./DarkBase.t.sol";
import {IDarkKeyRegistry} from "../src/interfaces/IDarkKeyRegistry.sol";
import {IDarkVerifier} from "../src/interfaces/IDarkVerifier.sol";
import {DarkGrumpkin} from "../src/libraries/DarkGrumpkin.sol";

contract DarkKeyRegistryTest is DarkBase {
    address carol = address(0xCA201);

    function test_registerHappyPathAndBinding() public {
        IDarkKeyRegistry.Point memory p = regPt(99);

        bytes32[] memory pi = new bytes32[](5);
        pi[0] = bytes32(block.chainid);
        pi[1] = bytes32(uint256(uint160(address(registry))));
        pi[2] = bytes32(uint256(uint160(carol)));
        pi[3] = bytes32(p.x);
        pi[4] = bytes32(p.y);

        vm.expectCall(address(registerV), abi.encodeCall(IDarkVerifier.verify, (hex"aa", pi)));
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDarkKeyRegistry.KeyRegistered(carol, p.x, p.y);
        vm.prank(carol);
        registry.register(p, hex"aa");

        assertTrue(registry.isRegistered(carol));
        assertEq(registry.keyOf(carol).x, p.x);
        assertEq(address(registry.registerVerifier()), address(registerV));
    }

    function test_registerTwiceReverts() public {
        IDarkKeyRegistry.Point memory p = regPt(5);
        vm.expectRevert(abi.encodeWithSelector(IDarkKeyRegistry.AlreadyRegistered.selector, alice));
        vm.prank(alice);
        registry.register(p, hex"01");
    }

    function test_keyOfUnregisteredReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IDarkKeyRegistry.NotRegistered.selector, carol));
        registry.keyOf(carol);
    }

    function test_rejectsIdentityOffCurveAndNonCanonical() public {
        IDarkKeyRegistry.Point memory p = regPt(7);

        vm.startPrank(carol);
        vm.expectRevert(IDarkKeyRegistry.InvalidPoint.selector);
        registry.register(IDarkKeyRegistry.Point(0, 0), hex"01");

        vm.expectRevert(IDarkKeyRegistry.InvalidPoint.selector);
        registry.register(IDarkKeyRegistry.Point(p.x, p.y + 1), hex"01");

        vm.expectRevert(IDarkKeyRegistry.InvalidPoint.selector);
        registry.register(IDarkKeyRegistry.Point(p.x + DarkGrumpkin.P, p.y), hex"01");
        vm.stopPrank();
    }

    function test_badProofReverts() public {
        IDarkKeyRegistry.Point memory p = regPt(7);
        registerV.setResult(false);
        vm.expectRevert(IDarkKeyRegistry.InvalidProof.selector);
        vm.prank(carol);
        registry.register(p, hex"01");
    }

    function test_registerIsNeverPausable() public {
        IDarkKeyRegistry.Point memory p = regPt(7);
        vm.prank(guard);
        vault.pause();
        vm.prank(carol);
        registry.register(p, hex"01");
        assertTrue(registry.isRegistered(carol));
    }
}
