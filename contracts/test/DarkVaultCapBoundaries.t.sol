// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DarkBase} from "./DarkBase.t.sol";
import {IDarkVault} from "../src/interfaces/IDarkVault.sol";

/// @notice Cap boundaries: every cap is INCLUSIVE, and `tightenCaps` compares all six fields
///         (§19 C6). Added because mutations M10a and M11b survived the first kill run.
contract DarkVaultCapBoundariesTest is DarkBase {
    function _setCaps(IDarkVault.Caps memory c) internal {
        vm.prank(owner);
        vault.setCaps(c);
    }

    /// @dev Kills M10a (`tvl + x <= tvlCap` turned exclusive) and pins the other three bounds.
    function test_depositExactlyAtEveryCapSucceeds() public {
        _setCaps(
            IDarkVault.Caps({
                minDeposit: 10e6,
                maxDeposit: 40e6,
                maxAccountInflow: 60e6,
                minTransfer: 10_000,
                maxTransfer: 2_500e6,
                tvlCap: 100e6
            })
        );

        // exactly minDeposit
        deposit(alice, 10e6);
        // exactly maxDeposit
        deposit(alice, 40e6);
        // exactly maxAccountInflow (10 + 40 + 10 == 60)
        deposit(alice, 10e6);
        assertEq(vault.getAccount(alice).netInflow, 60e6, "inflow cap is inclusive");

        // one micro-unit past the account inflow cap
        fund(alice, 10e6);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.ExceedsAccountInflowCap.selector, 70e6, 60e6));
        vm.prank(alice);
        vault.deposit(10e6, "");

        // exactly tvlCap, from the second account (60 + 40 == 100)
        deposit(bob, 40e6);
        assertEq(vault.tvl(), 100e6, "tvl cap is inclusive");

        fund(bob, 10e6);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.ExceedsTvlCap.selector, 110e6, 100e6));
        vm.prank(bob);
        vault.deposit(10e6, "");
    }

    /// @dev Kills M11b: the guardian may not lower `minDeposit` either (§19 C6).
    function test_tightenCapsComparesAllSixFields() public {
        IDarkVault.Caps memory c = vault.caps();

        // NB: `Caps memory x = c` would ALIAS c, so each case re-reads the live caps.
        IDarkVault.Caps memory lowerMinDeposit = vault.caps();
        lowerMinDeposit.minDeposit = c.minDeposit - 1;
        vm.expectRevert(IDarkVault.NotTightening.selector);
        vm.prank(guard);
        vault.tightenCaps(lowerMinDeposit);

        IDarkVault.Caps memory lowerMinTransfer = vault.caps();
        lowerMinTransfer.minTransfer = c.minTransfer - 1;
        vm.expectRevert(IDarkVault.NotTightening.selector);
        vm.prank(guard);
        vault.tightenCaps(lowerMinTransfer);

        // raising a min field is tightening, and it sticks
        IDarkVault.Caps memory higher = vault.caps();
        higher.minDeposit = c.minDeposit + 1;
        higher.minTransfer = c.minTransfer + 1;
        vm.prank(guard);
        vault.tightenCaps(higher);
        assertEq(vault.caps().minDeposit, c.minDeposit + 1, "minDeposit not tightened");
        assertEq(vault.caps().minTransfer, c.minTransfer + 1, "minTransfer not tightened");
    }
}
