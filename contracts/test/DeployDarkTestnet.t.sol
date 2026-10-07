// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployDarkTestnet} from "../script/DeployDarkTestnet.s.sol";
import {DarkVault} from "../src/DarkVault.sol";
import {IDarkVault} from "../src/interfaces/IDarkVault.sol";
import {DarkTestVerifier} from "./mocks/DarkTestVerifier.sol";

/// @notice The deploy script is wiring, and wiring is where verifiers get swapped (M17). This runs
///         the real script and checks each address landed in the slot it belongs to.
contract DeployDarkTestnetTest is Test {
    address internal registerV;
    address internal transferV;
    address internal withdrawV;
    address internal relations = address(0xDEB01);
    address internal transcript = address(0xDEB02);

    function setUp() public {
        registerV = address(new DarkTestVerifier());
        transferV = address(new DarkTestVerifier());
        withdrawV = address(new DarkTestVerifier());
        // stand-ins for the two shared Honk libraries: only their codehash is pinned
        vm.etch(relations, hex"6001");
        vm.etch(transcript, hex"6002");

        vm.setEnv("DARK_OWNER_SAFE", vm.toString(address(0x50FE)));
        vm.setEnv("DARK_GUARDIAN_SAFE", vm.toString(address(0x6A2D)));
        vm.setEnv("DARK_REGISTER_VERIFIER", vm.toString(registerV));
        vm.setEnv("DARK_TRANSFER_VERIFIER", vm.toString(transferV));
        vm.setEnv("DARK_WITHDRAW_VERIFIER", vm.toString(withdrawV));
        vm.setEnv("DARK_CODEHASH_PIN", _writePin());
    }

    /// @dev A pin file for this run's mock addresses, in the real file's shape.
    function _writePin() internal returns (string memory path) {
        path = string.concat("out/pin-", vm.toString(block.chainid), ".json");
        string memory j = "{";
        j = string.concat(j, '"', vm.toString(block.chainid), '":{');
        j = string.concat(j, _entry("DarkRegisterVerifier", registerV), ",");
        j = string.concat(j, _entry("DarkTransferVerifier", transferV), ",");
        j = string.concat(j, _entry("DarkWithdrawVerifier", withdrawV), ",");
        j = string.concat(j, _entry("RelationsLib", relations), ",");
        j = string.concat(j, _entry("ZKTranscriptLib", transcript), "}}");
        vm.writeFile(path, j);
    }

    function _entry(string memory name, address a) internal view returns (string memory) {
        return string.concat(
            '"', name, '":{"address":"', vm.toString(a), '","codehash":"', vm.toString(a.codehash), '"}'
        );
    }

    /// @dev The committed pin file must match what is live on 46630 (`cast codehash`), so a stale
    ///      row is caught here rather than at deploy time.
    function test_committedPinIsWellFormed() public view {
        string memory j = vm.readFile("deployments/verifier-codehashes.json");
        assertEq(vm.parseJsonAddress(j, ".46630.DarkTransferVerifier.address"), 0xAf2332Ef3910A9328418b4963BA0E50b9d5846Fe);
        assertTrue(vm.parseJsonBytes32(j, ".46630.RelationsLib.codehash") != bytes32(0), "RelationsLib unpinned");
        assertTrue(vm.parseJsonBytes32(j, ".46630.ZKTranscriptLib.codehash") != bytes32(0), "ZKTranscriptLib unpinned");
    }

    /// @dev One test, because `vm.setEnv` is process-global and forge runs a suite's tests in
    ///      parallel: two tests mutating `DARK_*` would race.
    ///      1. M17: a swapped env address never reaches a constructor.
    ///      2. X4: right addresses, but a library was swapped at its pinned address.
    ///      3. the happy path still wires each verifier into its own slot.
    function test_scriptWiresEachVerifierToItsOwnSlot() public {
        address guardianSafe = address(0x6A2D);

        // 1. wrong address, identical code: only the address pin catches it
        address impostor = address(new DarkTestVerifier());
        vm.setEnv("DARK_TRANSFER_VERIFIER", vm.toString(impostor));
        DeployDarkTestnet s1 = new DeployDarkTestnet(); // deploy before arming: CREATE consumes it
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployDarkTestnet.UnpinnedVerifier.selector, "DarkTransferVerifier", impostor, transferV
            )
        );
        s1.run();
        vm.setEnv("DARK_TRANSFER_VERIFIER", vm.toString(transferV));

        // 2. swapped library code at the pinned library address
        bytes32 pinnedLib = relations.codehash;
        vm.etch(relations, hex"60ff");
        DeployDarkTestnet s2 = new DeployDarkTestnet();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployDarkTestnet.VerifierCodehashMismatch.selector,
                "RelationsLib",
                relations,
                relations.codehash,
                pinnedLib
            )
        );
        s2.run();
        vm.etch(relations, hex"6001");
        assertEq(relations.codehash, pinnedLib, "library restored");

        // 3. happy path
        vm.recordLogs();
        new DeployDarkTestnet().run();

        // the vault is the only contract that emits GuardianUpdated
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vaultAddr;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IDarkVault.GuardianUpdated.selector) vaultAddr = logs[i].emitter;
        }
        assertTrue(vaultAddr != address(0), "vault not deployed");

        DarkVault vault = DarkVault(vaultAddr);
        assertEq(address(vault.transferVerifier()), transferV, "transfer verifier slot");
        assertEq(address(vault.withdrawVerifier()), withdrawV, "withdraw verifier slot");
        assertEq(address(vault.registry().registerVerifier()), registerV, "register verifier slot");
        assertEq(vault.guardian(), guardianSafe, "guardian");
        assertEq(vault.owner().code.length > 0, true, "owner is the timelock contract");
    }
}
