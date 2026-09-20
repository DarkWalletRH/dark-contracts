// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DarkBase} from "../DarkBase.t.sol";
import {DarkVaultHandler} from "./DarkVaultHandler.sol";
import {IDarkVault} from "../../src/interfaces/IDarkVault.sol";
import {IDarkKeyRegistry} from "../../src/interfaces/IDarkKeyRegistry.sol";
import {DarkGrumpkin} from "../../src/libraries/DarkGrumpkin.sol";

/// @notice I1-I15 (§15) as one Handler-based stateful suite, `fail_on_revert = true`.
///         The ghost oracle lives in the handler.
contract DarkVaultInvariants is DarkBase {
    DarkVaultHandler internal handler;
    address internal carol = address(0xCA201);
    uint256 internal constant SK_A = 11;
    uint256 internal constant SK_B = 22;
    uint256 internal constant SK_C = 33;

    function setUp() public override {
        super.setUp();
        register(carol, SK_C);
        handler = new DarkVaultHandler(
            vault,
            registry,
            usdg,
            transferV,
            withdrawV,
            owner,
            guard,
            [alice, bob, carol],
            [SK_A, SK_B, SK_C]
        );
        targetContract(address(handler));

        bytes4[] memory sel = new bytes4[](7);
        sel[0] = DarkVaultHandler.deposit.selector;
        sel[1] = DarkVaultHandler.withdrawAction.selector;
        sel[2] = DarkVaultHandler.transferAction.selector;
        sel[3] = DarkVaultHandler.applyPendingAction.selector;
        sel[4] = DarkVaultHandler.togglePause.selector;
        sel[5] = DarkVaultHandler.capsChurn.selector;
        sel[6] = DarkVaultHandler.illegalCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// @dev Anti-vacuity: a run that never moved money would pass everything trivially.
    function afterInvariant() public view {
        assertGt(handler.deposits(), 0, "vacuous: no deposit");
        assertGt(handler.withdrawals(), 0, "vacuous: no withdrawal");
        assertGt(handler.transfers(), 0, "vacuous: no transfer");
        assertGt(handler.applies(), 0, "vacuous: no applyPending");
        assertGt(handler.boundChecks(), 0, "vacuous: no proof was ever verified (I13)");
        assertGt(handler.eventChecks(), 0, "vacuous: no event was ever checked (I14)");
        assertGt(handler.illegalCallsRejected(), 0, "vacuous: no revert probe (I15)");
        assertGt(handler.isolationChecks(), 0, "vacuous: no isolation check (I3/I4)");
    }

    // ------------------------------------------------------------------ I1

    /// @dev I1: USDG balance >= tvl, and tvl == deposits - withdrawals (ghost).
    function invariant_I1_solvency() public view {
        assertGe(usdg.balanceOf(address(vault)), vault.tvl(), "I1 vault underfunded");
        assertEq(vault.tvl(), handler.totalDeposited() - handler.totalWithdrawn(), "I1 tvl != ghost flow");
    }

    // ------------------------------------------------------------------ I2

    /// @dev I2: the decryption of every stored ciphertext equals the ghost plaintext, and the
    ///      plaintexts sum to tvl. "Decryption" is the oracle re-encrypting its own model and
    ///      comparing group elements, which is equivalent and needs no discrete log.
    function invariant_I2_encryptedConservation() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actor(i);
            IDarkVault.AccountView memory v = vault.getAccount(a);
            _eq4([v.available.c.x, v.available.c.y, v.available.d.x, v.available.d.y], handler.ghostAvailable(a), "I2 available");
            _eq4([v.pending.c.x, v.pending.c.y, v.pending.d.x, v.pending.d.y], handler.ghostPendingCt(a), "I2 pending");
            sum += handler.ghostBalance(a) + handler.ghostPending(a);
        }
        assertEq(sum, vault.tvl(), "I2 sum of plaintexts != tvl");
    }

    // --------------------------------------------------------------- I3/I4

    /// @dev I3/I4: enforced per call inside the handler (`_onlyChanged`); here the counters prove
    ///      the checks ran and `pendingCount` still matches the ghost's transfer count.
    function invariant_I3_I4_isolationAndPendingCount() public view {
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actor(i);
            assertEq(vault.getAccount(a).pendingCount, handler.ghost(a).pendingCount, "I4 pendingCount");
        }
    }

    // ------------------------------------------------------------------ I5

    /// @dev I5: nonce == the ghost's count of owner actions (+1 each, never otherwise).
    function invariant_I5_nonceIsOwnerActionCount() public view {
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actor(i);
            assertEq(vault.getAccount(a).nonce, handler.ghost(a).nonce, "I5 nonce drift");
        }
    }

    // ------------------------------------------------------------------ I6

    /// @dev I6: per-deposit and per-transfer bounds are asserted in the handler; globally the hard
    ///      ceiling holds always and netInflow tracks the ghost.
    function invariant_I6_caps() public view {
        assertLe(vault.tvl(), uint256(vault.HARD_MAX_TVL()), "I6 hard tvl ceiling");
        IDarkVault.Caps memory c = vault.caps();
        assertLe(c.maxDeposit, vault.HARD_MAX_DEPOSIT(), "I6 maxDeposit ceiling");
        assertLe(c.maxAccountInflow, vault.HARD_MAX_ACCOUNT_INFLOW(), "I6 inflow ceiling");
        assertLe(c.maxTransfer, vault.HARD_MAX_TRANSFER(), "I6 maxTransfer ceiling");
        assertLe(c.tvlCap, vault.HARD_MAX_TVL(), "I6 tvlCap ceiling");
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actor(i);
            assertEq(vault.getAccount(a).netInflow, handler.ghost(a).netInflow, "I6 netInflow drift");
        }
    }

    // ------------------------------------------------------------------ I7

    /// @dev I7: paused, with every cap tightened to its most restrictive value, every account with
    ///      a ghost balance can applyPending and withdraw everything.
    function invariant_I7_exitLiveness() public {
        uint256 snap = vm.snapshotState();

        if (!vault.paused()) {
            vm.prank(guard);
            vault.pause();
        }
        vm.prank(guard);
        vault.tightenCaps(
            IDarkVault.Caps({
                minDeposit: type(uint64).max,
                maxDeposit: 0,
                maxAccountInflow: 0,
                minTransfer: type(uint64).max,
                maxTransfer: 0,
                tvlCap: 0
            })
        );

        uint256 exited;
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actor(i);
            uint256 b = handler.ghostBalance(a) + handler.ghostPending(a);
            if (b == 0) continue;
            uint64 pc = handler.ghost(a).pendingCount;
            if (pc > 0) {
                vm.prank(a);
                vault.applyPending(pc, "");
            }
            handler.armExit(a, a, b);
            uint256 before = usdg.balanceOf(a);
            vm.prank(a);
            vault.withdraw(b, a, hex"01", "");
            assertEq(usdg.balanceOf(a) - before, b, "I7 exit blocked");
            exited++;
        }
        assertEq(vault.tvl(), 0, "I7 tvl not drained by the exit probe");

        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ I8

    /// @dev I8: pause blocks deposit and transfer only; applyPending and register never see it.
    function invariant_I8_pauseScope() public {
        uint256 snap = vm.snapshotState();
        if (!vault.paused()) {
            vm.prank(guard);
            vault.pause();
        }

        // arguments are evaluated first: any call made while expectRevert is armed consumes it.
        address a = handler.actor(0);
        address b = handler.actor(1);
        IDarkVault.TransferCt memory t = ct(7);
        bytes memory hint = blob(240);
        bytes memory sHint = blob(176);
        address fresh = address(0xF8E5);
        IDarkKeyRegistry.Point memory p = regPt(44);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(a);
        vault.deposit(1e6, "");

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(a);
        vault.transfer(b, t, hex"01", hint, sHint, "");

        // applyPending is never pausable: with the right count it succeeds, with the wrong one it
        // fails for PendingChanged - never for pause.
        for (uint256 i = 0; i < 3; i++) {
            address x = handler.actor(i);
            uint64 pc = handler.ghost(x).pendingCount;
            vm.prank(x);
            vault.applyPending(pc, "");
        }

        // register is never pausable either.
        vm.prank(fresh);
        registry.register(p, hex"01");
        assertTrue(registry.isRegistered(fresh), "I8 register blocked");

        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ I9

    /// @dev I9: the guardian can only tighten, setCaps respects the hard ceilings, only the owner
    ///      unpauses, renounceOwnership reverts.
    function invariant_I9_adminPowers() public {
        uint256 snap = vm.snapshotState();
        IDarkVault.Caps memory c = vault.caps();

        // NB: `Caps memory x = c` would ALIAS c, so each probe re-reads the live caps.
        IDarkVault.Caps memory looser = vault.caps();
        looser.maxDeposit = c.maxDeposit + 1;
        vm.expectRevert(IDarkVault.NotTightening.selector);
        vm.prank(guard);
        vault.tightenCaps(looser);

        IDarkVault.Caps memory tooBig = vault.caps();
        tooBig.tvlCap = vault.HARD_MAX_TVL() + 1;
        vm.expectRevert(IDarkVault.ExceedsHardCeiling.selector);
        vm.prank(owner);
        vault.setCaps(tooBig);

        address stranger = handler.actor(0);
        vm.expectRevert(IDarkVault.NotGuardian.selector);
        vm.prank(stranger);
        vault.pause();

        if (!vault.paused()) {
            vm.prank(guard);
            vault.pause();
        }
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guard));
        vm.prank(guard);
        vault.unpause();

        vm.expectRevert(IDarkVault.RenounceDisabled.selector);
        vm.prank(owner);
        vault.renounceOwnership();

        vm.revertToState(snap);
    }

    // ----------------------------------------------------------------- I10

    /// @dev I10: only `withdraw` lowers the vault's USDG balance, and USDG can never be recovered.
    function invariant_I10_onlyWithdrawLowersBalance() public {
        assertEq(
            usdg.balanceOf(address(vault)),
            handler.totalDeposited() - handler.totalWithdrawn(),
            "I10 balance moved outside withdraw"
        );
        uint256 snap = vm.snapshotState();
        vm.expectRevert(IDarkVault.CannotRecoverUSDG.selector);
        vm.prank(owner);
        vault.recoverERC20(address(usdg), owner, 1);
        vm.revertToState(snap);
    }

    // ----------------------------------------------------------------- I11

    /// @dev I11: keys are immutable, one per address, canonical, on-curve and never the identity.
    function invariant_I11_registryKeys() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actor(i);
            IDarkKeyRegistry.Point memory k = registry.keyOf(a);
            IDarkKeyRegistry.Point memory expected = regPt(handler.secretOf(a));
            assertEq(k.x, expected.x, "I11 key x changed");
            assertEq(k.y, expected.y, "I11 key y changed");
            assertTrue(DarkGrumpkin.isOnCurve(k.x, k.y), "I11 key off curve / non-canonical");
            assertFalse(DarkGrumpkin.isIdentity(k.x, k.y), "I11 key is the identity");

            IDarkKeyRegistry.Point memory other = regPt(99);
            bytes memory err = abi.encodeWithSelector(IDarkKeyRegistry.AlreadyRegistered.selector, a);
            vm.expectRevert(err);
            vm.prank(a);
            registry.register(other, hex"01");
        }
        vm.revertToState(snap);
    }

    // ----------------------------------------------------------------- I12

    /// @dev I12: every stored vault point is canonical and on-curve, or the (0,0) sentinel.
    function invariant_I12_storedPointsValid() public view {
        for (uint256 i = 0; i < 3; i++) {
            IDarkVault.AccountView memory v = vault.getAccount(handler.actor(i));
            _validPoint(v.available.c.x, v.available.c.y);
            _validPoint(v.available.d.x, v.available.d.y);
            _validPoint(v.pending.c.x, v.pending.c.y);
            _validPoint(v.pending.d.x, v.pending.d.y);
        }
    }

    // ----------------------------------------------------------------- I13

    /// @dev I13: the oracle arms the verifier with the public inputs it derived from its own model,
    ///      so any input the vault took from calldata or read stale makes `verify` return false and
    ///      the call revert. The handler catches that revert instead of letting `fail_on_revert`
    ///      abort the run, so the mismatch shows up here as a failed invariant and not as an opaque
    ///      "call reverted".
    function invariant_I13_publicInputBinding() public view {
        assertEq(handler.bindingFailures(), 0, "I13 a verifier rejected the oracle's public inputs");
        assertEq(
            handler.bindingsConsumed(),
            handler.transfers() + handler.withdrawals(),
            "I13 a proof-bearing call changed state without consuming an armed expectation"
        );
        assertEq(handler.boundChecks(), handler.bindingsConsumed() + handler.bindingFailures(), "I13 arm/consume drift");
        assertEq(transferV.expected(), bytes32(0), "I13 a transfer proof expectation was never consumed");
        assertEq(withdrawV.expected(), bytes32(0), "I13 a withdraw proof expectation was never consumed");
    }

    // ----------------------------------------------------------------- I14

    /// @dev I14: every emitted event was decoded and compared with the post-state in the handler.
    function invariant_I14_eventTruth() public view {
        assertEq(
            handler.eventChecks(),
            handler.deposits() + handler.withdrawals() + handler.transfers() + handler.applies(),
            "I14 a state change emitted no checked event"
        );
    }

    // ----------------------------------------------------------------- I15

    /// @dev I15: the handler's illegal-call probes each got exactly the custom error the spec
    ///      names; everything else in the run succeeded (fail_on_revert = true).
    function invariant_I15_revertsHaveLegalCause() public view {
        assertEq(
            handler.illegalCallsRejected(), handler.illegalCallsAttempted(), "I15 an illegal call was not rejected"
        );
    }

    // -------------------------------------------------------------- helpers

    function _eq4(uint256[4] memory a, uint256[4] memory b, string memory err) private pure {
        for (uint256 i = 0; i < 4; i++) {
            require(a[i] == b[i], err);
        }
    }

    function _validPoint(uint256 x, uint256 y) private pure {
        assertTrue(DarkGrumpkin.isIdentity(x, y) || DarkGrumpkin.isOnCurve(x, y), "I12 invalid stored point");
    }
}
