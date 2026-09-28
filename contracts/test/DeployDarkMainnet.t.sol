// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployDarkMainnet} from "../script/DeployDarkMainnet.s.sol";
import {DarkVault} from "../src/DarkVault.sol";
import {IDarkVault} from "../src/interfaces/IDarkVault.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {DarkTestVerifier} from "./mocks/DarkTestVerifier.sol";

contract FakeSafe {
    uint256 public getThreshold;
    address[] internal owners;

    constructor(uint256 t, uint256 n) {
        getThreshold = t;
        for (uint256 i = 0; i < n; i++) {
            owners.push(address(uint160(0x5000 + i)));
        }
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }
}

/// @notice The mainnet script's refusals, and its wiring on the happy path. Calls `deploy()` directly
///         (no `vm.setEnv`), so it cannot race the testnet deploy suite over the process-wide env.
contract DeployDarkMainnetTest is Test {
    DeployDarkMainnet internal s;
    address[3] internal verifiers;
    string internal pin;
    address internal owner2of3;
    address internal guardian1of2;

    function setUp() public {
        vm.chainId(4663);
        s = new DeployDarkMainnet();
        vm.etch(s.USDG(), address(new MockUSDG()).code);
        for (uint256 i = 0; i < 3; i++) {
            verifiers[i] = address(new DarkTestVerifier());
        }
        owner2of3 = address(new FakeSafe(2, 3));
        guardian1of2 = address(new FakeSafe(1, 2));
        vm.etch(address(0xDEB01), hex"6001");
        vm.etch(address(0xDEB02), hex"6002");
        pin = "out/pin-mainnet-test.json";
        vm.writeFile(
            pin,
            string.concat(
                '{"4663":{',
                _entry("DarkRegisterVerifier", verifiers[0]),
                ",",
                _entry("DarkTransferVerifier", verifiers[1]),
                ",",
                _entry("DarkWithdrawVerifier", verifiers[2]),
                ",",
                _entry("RelationsLib", address(0xDEB01)),
                ",",
                _entry("ZKTranscriptLib", address(0xDEB02)),
                "}}"
            )
        );
    }

    function _entry(string memory name, address a) internal view returns (string memory) {
        return
            string.concat('"', name, '":{"address":"', vm.toString(a), '","codehash":"', vm.toString(a.codehash), '"}');
    }

    function test_refusesWrongChain() public {
        vm.chainId(46630);
        vm.expectRevert(abi.encodeWithSelector(DeployDarkMainnet.WrongChain.selector, 46630));
        s.deploy(owner2of3, guardian1of2, verifiers, pin);
    }

    function test_refusesAnEoaAsASafe() public {
        address eoa = makeAddr("pasted-eoa");
        vm.expectRevert(abi.encodeWithSelector(DeployDarkMainnet.NotASafe.selector, "guardian", eoa));
        s.deploy(owner2of3, eoa, verifiers, pin);
    }

    function test_refusesAOneKeyOwnerSafe() public {
        vm.expectRevert(abi.encodeWithSelector(DeployDarkMainnet.OwnerSafeThresholdTooLow.selector, 1));
        s.deploy(guardian1of2, owner2of3, verifiers, pin);
    }

    function test_refusesATwoOfTwoOwnerSafe() public {
        address owner2of2 = address(new FakeSafe(2, 2));
        vm.expectRevert(abi.encodeWithSelector(DeployDarkMainnet.OwnerSafeTooFewOwners.selector, 2));
        s.deploy(owner2of2, guardian1of2, verifiers, pin);
    }

    function test_refusesTheSameSafeForBothRoles() public {
        vm.expectRevert(abi.encodeWithSelector(DeployDarkMainnet.SameSafe.selector, owner2of3));
        s.deploy(owner2of3, owner2of3, verifiers, pin);
    }

    function test_refusesAnUnpinnedVerifier() public {
        address[3] memory swapped = verifiers;
        swapped[1] = address(new DarkTestVerifier());
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployDarkMainnet.UnpinnedVerifier.selector, "DarkTransferVerifier", swapped[1], verifiers[1]
            )
        );
        s.deploy(owner2of3, guardian1of2, swapped, pin);
    }

    function test_wiresRolesCapsAndVerifiers() public {
        DarkVault vault = s.deploy(owner2of3, guardian1of2, verifiers, pin);

        assertEq(vault.usdg(), s.USDG(), "real USDG");
        assertEq(address(vault.registry().registerVerifier()), verifiers[0], "register slot");
        assertEq(address(vault.transferVerifier()), verifiers[1], "transfer slot");
        assertEq(address(vault.withdrawVerifier()), verifiers[2], "withdraw slot");
        assertEq(vault.guardian(), guardian1of2, "guardian Safe");

        TimelockController tl = TimelockController(payable(vault.owner()));
        assertEq(tl.getMinDelay(), 48 hours, "48 h delay");
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), owner2of3), "owner Safe proposes");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), owner2of3), "owner Safe executes");
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(this)), "no admin besides the timelock");

        IDarkVault.Caps memory c = vault.caps();
        assertEq(c.maxDeposit, 1_000e6);
        assertEq(c.maxAccountInflow, 2_500e6);
        assertEq(c.maxTransfer, 1_000e6);
        assertEq(c.tvlCap, 50_000e6);
        assertEq(c.minDeposit, 1e6);
        assertEq(c.minTransfer, 10_000);
    }
}
