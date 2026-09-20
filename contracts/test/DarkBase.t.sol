// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DarkKeyRegistry} from "../src/DarkKeyRegistry.sol";
import {DarkVault} from "../src/DarkVault.sol";
import {IDarkVault} from "../src/interfaces/IDarkVault.sol";
import {IDarkKeyRegistry} from "../src/interfaces/IDarkKeyRegistry.sol";
import {DarkGrumpkin} from "../src/libraries/DarkGrumpkin.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {DarkTestVerifier} from "./mocks/DarkTestVerifier.sol";

/// @dev Shared fixture: MockUSDG, three verifier mocks, registry, vault, two registered accounts.
contract DarkBase is Test {
    MockUSDG internal usdg;
    DarkKeyRegistry internal registry;
    DarkVault internal vault;
    DarkTestVerifier internal registerV;
    DarkTestVerifier internal transferV;
    DarkTestVerifier internal withdrawV;

    address internal owner = address(0xB0B5);
    address internal guard = address(0x6A2D);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    bytes internal constant AE = hex"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f3031323334353637";

    function setUp() public virtual {
        usdg = new MockUSDG();
        registerV = new DarkTestVerifier();
        transferV = new DarkTestVerifier();
        withdrawV = new DarkTestVerifier();
        registry = new DarkKeyRegistry(registerV);
        vault = new DarkVault(address(usdg), registry, transferV, withdrawV, owner, guard, defaultCaps());
        register(alice, 11);
        register(bob, 22);
    }

    function defaultCaps() internal pure returns (IDarkVault.Caps memory) {
        return IDarkVault.Caps({
            minDeposit: 1e6,
            maxDeposit: 2_500e6,
            maxAccountInflow: 10_000e6,
            minTransfer: 10_000,
            maxTransfer: 2_500e6,
            tvlCap: 250_000e6
        });
    }

    function pt(uint256 k) internal view returns (IDarkVault.Point memory p) {
        (p.x, p.y) = DarkGrumpkin.mulG(k);
    }

    function regPt(uint256 k) internal view returns (IDarkKeyRegistry.Point memory p) {
        (p.x, p.y) = DarkGrumpkin.mulG(k);
    }

    /// @dev The point is computed BEFORE the prank: DarkGrumpkin calls precompile 0x05, which would
    ///      otherwise consume the prank.
    function register(address who, uint256 k) internal {
        IDarkKeyRegistry.Point memory p = regPt(k);
        vm.prank(who);
        registry.register(p, hex"01");
    }

    function fund(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(vault), amount);
    }

    function deposit(address who, uint256 amount) internal {
        fund(who, amount);
        vm.prank(who);
        vault.deposit(amount, "");
    }

    function ct(uint256 k) internal view returns (IDarkVault.TransferCt memory t) {
        t.c = pt(k);
        t.dSender = pt(k + 1);
        t.dRecipient = pt(k + 2);
    }

    function blob(uint256 len) internal pure returns (bytes memory b) {
        b = new bytes(len);
    }

    function available(address who) internal view returns (uint256[4] memory a) {
        IDarkVault.AccountView memory v = vault.getAccount(who);
        a = [v.available.c.x, v.available.c.y, v.available.d.x, v.available.d.y];
    }

    function pending(address who) internal view returns (uint256[4] memory a) {
        IDarkVault.AccountView memory v = vault.getAccount(who);
        a = [v.pending.c.x, v.pending.c.y, v.pending.d.x, v.pending.d.y];
    }
}
