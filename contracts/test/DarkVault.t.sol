// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DarkBase} from "./DarkBase.t.sol";
import {stdError} from "forge-std/StdError.sol";
import {IDarkVault} from "../src/interfaces/IDarkVault.sol";
import {IDarkVerifier} from "../src/interfaces/IDarkVerifier.sol";
import {DarkVault} from "../src/DarkVault.sol";
import {DarkGrumpkin} from "../src/libraries/DarkGrumpkin.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract FeeUSDG is ERC20 {
    constructor() ERC20("Fee USDG", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function transferFrom(address from, address to, uint256 a) public override returns (bool) {
        _spendAllowance(from, msg.sender, a);
        _transfer(from, to, a - 1); // 1 micro-unit fee
        _burn(from, 1);
        return true;
    }
}

contract DarkVaultTest is DarkBase {
    address carol = address(0xCA201);

    // --------------------------------------------------------------- deposit

    function test_depositHappyPathAndEvent() public {
        uint256 amount = 100e6;
        fund(alice, amount);
        (uint256 gx, uint256 gy) = DarkGrumpkin.mulG(amount);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IDarkVault.Deposited(alice, 1, amount, [gx, gy, uint256(0), uint256(0)], uint128(amount), amount);
        vm.prank(alice);
        vault.deposit(amount, AE);

        IDarkVault.AccountView memory a = vault.getAccount(alice);
        assertEq(a.available.c.x, gx);
        assertEq(a.available.c.y, gy);
        assertEq(a.nonce, 1);
        assertEq(a.netInflow, amount);
        assertEq(a.aeBalance, AE);
        assertEq(vault.tvl(), amount);
        assertEq(usdg.balanceOf(address(vault)), amount);
    }

    function test_depositIsHomomorphic() public {
        deposit(alice, 10e6);
        deposit(alice, 15e6);
        (uint256 gx, uint256 gy) = DarkGrumpkin.mulG(25e6);
        assertEq(available(alice)[0], gx);
        assertEq(available(alice)[1], gy);
        assertEq(vault.getAccount(alice).nonce, 2);
    }

    function test_depositRevertsUnregistered() public {
        fund(carol, 10e6);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.NotRegistered.selector, carol));
        vm.prank(carol);
        vault.deposit(10e6, "");
    }

    function test_depositRevertsBadAeLength() public {
        fund(alice, 10e6);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.BadBlobLength.selector, 3, 56));
        vm.prank(alice);
        vault.deposit(10e6, hex"010203");
    }

    function test_depositRevertsBelowMin() public {
        fund(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.BelowMinDeposit.selector, 1, 1e6));
        vm.prank(alice);
        vault.deposit(1, "");
    }

    function test_depositRevertsAboveMax() public {
        fund(alice, 3_000e6);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.ExceedsDepositCap.selector, 3_000e6, 2_500e6));
        vm.prank(alice);
        vault.deposit(3_000e6, "");
    }

    function test_depositRevertsInflowCap() public {
        for (uint256 i = 0; i < 4; i++) {
            deposit(alice, 2_500e6);
        }
        fund(alice, 1e6);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.ExceedsAccountInflowCap.selector, 10_001e6, 10_000e6));
        vm.prank(alice);
        vault.deposit(1e6, "");
    }

    function test_depositRevertsTvlCap() public {
        IDarkVault.Caps memory c = defaultCaps();
        c.tvlCap = 50e6;
        vm.prank(owner);
        vault.setCaps(c);
        fund(alice, 60e6);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.ExceedsTvlCap.selector, 60e6, 50e6));
        vm.prank(alice);
        vault.deposit(60e6, "");
    }

    function test_depositRevertsWhenPaused() public {
        fund(alice, 10e6);
        vm.prank(guard);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vault.deposit(10e6, "");
    }

    function test_depositRevertsOnFeeOnTransferToken() public {
        FeeUSDG fee = new FeeUSDG();
        DarkVault v = new DarkVault(address(fee), registry, transferV, withdrawV, owner, guard, defaultCaps());
        fee.mint(alice, 10e6);
        vm.startPrank(alice);
        fee.approve(address(v), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.UnexpectedTransferAmount.selector, 10e6, 10e6 - 1));
        v.deposit(10e6, "");
        vm.stopPrank();
    }

    // ----------------------------------------------------------- applyPending

    function test_applyPendingHappyPath() public {
        transferTo(bob, 7);
        uint256[4] memory p = pending(bob);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IDarkVault.PendingApplied(bob, 1, 1, p);
        vm.prank(bob);
        vault.applyPending(1, AE);

        assertEq(available(bob)[0], p[0]);
        assertEq(pending(bob)[0], 0);
        assertEq(vault.getAccount(bob).pendingCount, 0);
        assertEq(vault.getAccount(bob).nonce, 1);
    }

    /// @dev Stale-read guard: fewer pending than the caller accounted for still reverts (M14).
    function test_applyPendingWrongCountReverts() public {
        transferTo(bob, 7);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.PendingChanged.selector, 2, 1));
        vm.prank(bob);
        vault.applyPending(2, "");
    }

    /// @dev Anti-griefing: `expectedPendingCount` is a lower bound, so a transfer that lands after
    ///      the caller read state folds in instead of reverting the call. The event reports the
    ///      count actually applied, not the one asked for.
    function test_applyPendingFoldsInLateArrivals() public {
        transferTo(bob, 7); // bob reads pendingCount == 1 and builds his aeBalance
        transferTo(bob, 9); // griefer lands one more before bob's tx does
        uint256[4] memory p = pending(bob);
        assertEq(vault.getAccount(bob).pendingCount, 2);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IDarkVault.PendingApplied(bob, 1, 2, p);
        vm.prank(bob);
        vault.applyPending(1, AE);

        assertEq(available(bob)[0], p[0], "both transfers folded in");
        assertEq(vault.getAccount(bob).pendingCount, 0);
    }

    function test_applyPendingWorksWhilePaused() public {
        transferTo(bob, 7);
        vm.prank(guard);
        vault.pause();
        vm.prank(bob);
        vault.applyPending(1, "");
        assertEq(vault.getAccount(bob).pendingCount, 0);
    }

    // -------------------------------------------------------------- transfer

    function test_transferHappyPathEventAndBinding() public {
        deposit(alice, 100e6);
        IDarkVault.TransferCt memory t = ct(31);
        uint256[4] memory availBefore = available(alice);

        (uint256 sx, uint256 sy) = DarkGrumpkin.sub(availBefore[0], availBefore[1], t.c.x, t.c.y);
        (uint256 sdx, uint256 sdy) = DarkGrumpkin.sub(availBefore[2], availBefore[3], t.dSender.x, t.dSender.y);

        vm.expectCall(address(transferV), abi.encodeCall(IDarkVerifier.verify, (hex"aa", transferInputs(t))));
        vm.expectEmit(true, true, false, true, address(vault));
        emit IDarkVault.ConfidentialTransfer(
            alice,
            bob,
            2,
            [t.c.x, t.c.y, t.dSender.x, t.dSender.y, t.dRecipient.x, t.dRecipient.y],
            [sx, sy, sdx, sdy],
            [t.c.x, t.c.y, t.dRecipient.x, t.dRecipient.y],
            1,
            blob(240),
            blob(176)
        );
        vm.prank(alice);
        vault.transfer(bob, t, hex"aa", blob(240), blob(176), "");

        assertEq(available(alice)[0], sx);
        assertEq(pending(bob)[0], t.c.x);
        assertEq(vault.getAccount(bob).pendingCount, 1);
        assertEq(vault.getAccount(bob).nonce, 0, "recipient nonce untouched");
        assertEq(vault.getAccount(alice).nonce, 2);
    }

    function test_transferRevertPaths() public {
        deposit(alice, 100e6);
        IDarkVault.TransferCt memory t = ct(31);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.NotRegistered.selector, carol));
        vault.transfer(bob, t, hex"aa", blob(240), blob(176), "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.RecipientNotRegistered.selector, carol));
        vault.transfer(carol, t, hex"aa", blob(240), blob(176), "");

        vm.prank(alice);
        vm.expectRevert(IDarkVault.SelfTransfer.selector);
        vault.transfer(alice, t, hex"aa", blob(240), blob(176), "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.BadBlobLength.selector, 239, 240));
        vault.transfer(bob, t, hex"aa", blob(239), blob(176), "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.BadBlobLength.selector, 175, 176));
        vault.transfer(bob, t, hex"aa", blob(240), blob(175), "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDarkVault.BadBlobLength.selector, 55, 56));
        vault.transfer(bob, t, hex"aa", blob(240), blob(176), blob(55));
    }

    function test_transferRejectsBadPoints() public {
        deposit(alice, 100e6);
        IDarkVault.TransferCt memory t = ct(31);

        IDarkVault.TransferCt memory identity = t;
        identity.c = IDarkVault.Point(0, 0);
        vm.prank(alice);
        vm.expectRevert(IDarkVault.InvalidPoint.selector);
        vault.transfer(bob, identity, hex"aa", blob(240), blob(176), "");

        IDarkVault.TransferCt memory offCurve = ct(31);
        offCurve.dSender = IDarkVault.Point(t.dSender.x, t.dSender.y + 1);
        vm.prank(alice);
        vm.expectRevert(IDarkVault.InvalidPoint.selector);
        vault.transfer(bob, offCurve, hex"aa", blob(240), blob(176), "");

        IDarkVault.TransferCt memory nonCanonical = ct(31);
        nonCanonical.dRecipient = IDarkVault.Point(t.dRecipient.x + DarkGrumpkin.P, t.dRecipient.y);
        vm.prank(alice);
        vm.expectRevert(IDarkVault.InvalidPoint.selector);
        vault.transfer(bob, nonCanonical, hex"aa", blob(240), blob(176), "");
    }

    function test_transferRevertsBadProofAndWhenPaused() public {
        deposit(alice, 100e6);
        IDarkVault.TransferCt memory t = ct(31);

        transferV.setResult(false);
        vm.prank(alice);
        vm.expectRevert(IDarkVault.InvalidProof.selector);
        vault.transfer(bob, t, hex"aa", blob(240), blob(176), "");
        transferV.setResult(true);

        vm.prank(guard);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.transfer(bob, t, hex"aa", blob(240), blob(176), "");
    }

    // -------------------------------------------------------------- withdraw

    function test_withdrawHappyPathEventAndBinding() public {
        deposit(alice, 100e6);
        uint256 amount = 40e6;
        (uint256 gx, uint256 gy) = DarkGrumpkin.mulG(amount);
        uint256[4] memory a = available(alice);
        (uint256 nx, uint256 ny) = DarkGrumpkin.sub(a[0], a[1], gx, gy);

        vm.expectCall(address(withdrawV), abi.encodeCall(IDarkVerifier.verify, (hex"bb", withdrawInputs(alice, bob, amount))));
        vm.expectEmit(true, true, false, true, address(vault));
        emit IDarkVault.Withdrawn(alice, bob, 2, amount, [nx, ny, uint256(0), uint256(0)], uint128(60e6), 60e6);
        vm.prank(alice);
        vault.withdraw(amount, bob, hex"bb", AE);

        assertEq(usdg.balanceOf(bob), amount);
        assertEq(vault.tvl(), 60e6);
        assertEq(vault.getAccount(alice).netInflow, 60e6);
        assertEq(available(alice)[0], nx);
    }

    function test_withdrawWorksWhilePausedAndWithCapsAtZero() public {
        deposit(alice, 100e6);
        vm.prank(guard);
        vault.pause();
        IDarkVault.Caps memory c = vault.caps();
        c.maxDeposit = 0;
        c.maxTransfer = 0;
        c.maxAccountInflow = 0;
        c.tvlCap = 0;
        vm.prank(guard);
        vault.tightenCaps(c);

        vm.prank(alice);
        vault.withdraw(100e6, alice, hex"bb", "");
        assertEq(usdg.balanceOf(alice), 100e6);
        assertEq(vault.tvl(), 0);
        assertEq(vault.getAccount(alice).netInflow, 0, "netInflow floors at 0");
    }

    function test_withdrawRevertPaths() public {
        deposit(alice, 100e6);

        vm.startPrank(alice);
        vm.expectRevert(IDarkVault.AmountZero.selector);
        vault.withdraw(0, alice, hex"bb", "");

        vm.expectRevert(IDarkVault.AmountTooLarge.selector);
        vault.withdraw(1 << 48, alice, hex"bb", "");

        vm.expectRevert(IDarkVault.ZeroAddress.selector);
        vault.withdraw(1e6, address(0), hex"bb", "");

        vm.expectRevert(IDarkVault.BadRecipient.selector);
        vault.withdraw(1e6, address(vault), hex"bb", "");

        vm.expectRevert(abi.encodeWithSelector(IDarkVault.BadBlobLength.selector, 1, 56));
        vault.withdraw(1e6, alice, hex"bb", hex"01");
        vm.stopPrank();

        withdrawV.setResult(false);
        vm.expectRevert(IDarkVault.InvalidProof.selector);
        vm.prank(alice);
        vault.withdraw(1e6, alice, hex"bb", "");

        vm.expectRevert(abi.encodeWithSelector(IDarkVault.NotRegistered.selector, carol));
        vm.prank(carol);
        vault.withdraw(1e6, carol, hex"bb", "");
    }

    function test_withdrawMoreThanTvlReverts() public {
        deposit(alice, 10e6);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        vault.withdraw(20e6, alice, hex"bb", "");
    }

    // ----------------------------------------------------------------- admin

    function test_setCapsOnlyOwnerAndCeilings() public {
        IDarkVault.Caps memory c = defaultCaps();
        c.maxDeposit = 1e6;

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guard));
        vm.prank(guard);
        vault.setCaps(c);

        vm.prank(owner);
        vault.setCaps(c);
        assertEq(vault.caps().maxDeposit, 1e6);

        c.maxDeposit = vault.HARD_MAX_DEPOSIT() + 1;
        vm.expectRevert(IDarkVault.ExceedsHardCeiling.selector);
        vm.prank(owner);
        vault.setCaps(c);

        c = defaultCaps();
        c.tvlCap = vault.HARD_MAX_TVL() + 1;
        vm.expectRevert(IDarkVault.ExceedsHardCeiling.selector);
        vm.prank(owner);
        vault.setCaps(c);

        c = defaultCaps();
        c.minTransfer = 0;
        vm.expectRevert(IDarkVault.ExceedsHardCeiling.selector);
        vm.prank(owner);
        vault.setCaps(c);
    }

    function test_tightenCapsOnlyTightens() public {
        IDarkVault.Caps memory c = defaultCaps();
        c.maxDeposit = 10e6;

        vm.expectRevert(IDarkVault.NotGuardian.selector);
        vm.prank(alice);
        vault.tightenCaps(c);

        vm.expectEmit(false, false, true, true, address(vault));
        emit IDarkVault.CapsUpdated(defaultCaps(), c, guard);
        vm.prank(guard);
        vault.tightenCaps(c);
        assertEq(vault.caps().maxDeposit, 10e6);

        c.maxDeposit = 20e6; // loosening
        vm.expectRevert(IDarkVault.NotTightening.selector);
        vm.prank(guard);
        vault.tightenCaps(c);

        c = vault.caps();
        c.minTransfer = c.minTransfer - 1; // loosening a min
        vm.expectRevert(IDarkVault.NotTightening.selector);
        vm.prank(guard);
        vault.tightenCaps(c);
    }

    function test_pauseRolesAndUnpauseOwnerOnly() public {
        vm.expectRevert(IDarkVault.NotGuardian.selector);
        vm.prank(alice);
        vault.pause();

        vm.prank(guard);
        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guard));
        vm.prank(guard);
        vault.unpause();

        vm.prank(owner);
        vault.unpause();

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_setGuardian() public {
        vm.expectRevert(IDarkVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.setGuardian(address(0));

        vm.expectEmit(true, true, false, false, address(vault));
        emit IDarkVault.GuardianUpdated(guard, alice);
        vm.prank(owner);
        vault.setGuardian(alice);
        assertEq(vault.guardian(), alice);
    }

    function test_recoverERC20() public {
        MockUSDG other = new MockUSDG();
        other.mint(address(vault), 5e6);

        vm.expectRevert(IDarkVault.CannotRecoverUSDG.selector);
        vm.prank(owner);
        vault.recoverERC20(address(usdg), owner, 1);

        vm.expectRevert(IDarkVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.recoverERC20(address(other), address(0), 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.recoverERC20(address(other), alice, 1);

        vm.prank(owner);
        vault.recoverERC20(address(other), owner, 5e6);
        assertEq(other.balanceOf(owner), 5e6);
    }

    function test_renounceOwnershipDisabled() public {
        vm.expectRevert(IDarkVault.RenounceDisabled.selector);
        vm.prank(owner);
        vault.renounceOwnership();
    }

    function test_constructorRejectsBadWiring() public {
        IDarkVault.Caps memory c = defaultCaps();
        c.tvlCap = vault.HARD_MAX_TVL() + 1;
        vm.expectRevert(IDarkVault.ExceedsHardCeiling.selector);
        new DarkVault(address(usdg), registry, transferV, withdrawV, owner, guard, c);

        vm.expectRevert(bytes("verifiers equal"));
        new DarkVault(address(usdg), registry, transferV, transferV, owner, guard, defaultCaps());

        vm.expectRevert(IDarkVault.ZeroAddress.selector);
        new DarkVault(address(usdg), registry, transferV, withdrawV, owner, address(0), defaultCaps());
    }

    function test_specVersionAndViews() public view {
        assertEq(vault.SPEC_VERSION(), keccak256("DARK-CB-1"));
        assertEq(vault.usdg(), address(usdg));
        assertEq(address(vault.registry()), address(registry));
        assertEq(address(vault.transferVerifier()), address(transferV));
        assertEq(address(vault.withdrawVerifier()), address(withdrawV));
        assertEq(vault.HARD_MAX_TVL(), 250_000e6);
        assertEq(vault.HARD_MAX_TRANSFER(), 2_500e6);
        assertEq(vault.HARD_MAX_DEPOSIT(), 2_500e6);
        assertEq(vault.HARD_MAX_ACCOUNT_INFLOW(), 10_000e6);
    }

    // ------------------------------------------------------------- internals

    function transferTo(address to, uint256 seed) internal {
        deposit(alice, 100e6);
        IDarkVault.TransferCt memory t = ct(seed);
        vm.prank(alice);
        vault.transfer(to, t, hex"aa", blob(240), blob(176), "");
    }

    function transferInputs(IDarkVault.TransferCt memory t) internal view returns (bytes32[] memory pi) {
        IDarkVault.AccountView memory s = vault.getAccount(alice);
        pi = new bytes32[](21);
        pi[0] = bytes32(block.chainid);
        pi[1] = bytes32(uint256(uint160(address(vault))));
        pi[2] = bytes32(uint256(uint160(alice)));
        pi[3] = bytes32(uint256(uint160(bob)));
        pi[4] = bytes32(uint256(s.nonce));
        pi[5] = bytes32(registry.keyOf(alice).x);
        pi[6] = bytes32(registry.keyOf(alice).y);
        pi[7] = bytes32(registry.keyOf(bob).x);
        pi[8] = bytes32(registry.keyOf(bob).y);
        pi[9] = bytes32(s.available.c.x);
        pi[10] = bytes32(s.available.c.y);
        pi[11] = bytes32(s.available.d.x);
        pi[12] = bytes32(s.available.d.y);
        pi[13] = bytes32(t.c.x);
        pi[14] = bytes32(t.c.y);
        pi[15] = bytes32(t.dSender.x);
        pi[16] = bytes32(t.dSender.y);
        pi[17] = bytes32(t.dRecipient.x);
        pi[18] = bytes32(t.dRecipient.y);
        pi[19] = bytes32(uint256(vault.caps().minTransfer));
        pi[20] = bytes32(uint256(vault.caps().maxTransfer));
    }

    function withdrawInputs(address account, address to, uint256 amount) internal view returns (bytes32[] memory pi) {
        IDarkVault.AccountView memory a = vault.getAccount(account);
        pi = new bytes32[](12);
        pi[0] = bytes32(block.chainid);
        pi[1] = bytes32(uint256(uint160(address(vault))));
        pi[2] = bytes32(uint256(uint160(account)));
        pi[3] = bytes32(uint256(uint160(to)));
        pi[4] = bytes32(uint256(a.nonce));
        pi[5] = bytes32(registry.keyOf(account).x);
        pi[6] = bytes32(registry.keyOf(account).y);
        pi[7] = bytes32(a.available.c.x);
        pi[8] = bytes32(a.available.c.y);
        pi[9] = bytes32(a.available.d.x);
        pi[10] = bytes32(a.available.d.y);
        pi[11] = bytes32(amount);
    }
}
