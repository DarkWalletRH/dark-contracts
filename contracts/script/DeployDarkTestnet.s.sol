// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DarkKeyRegistry} from "../src/DarkKeyRegistry.sol";
import {DarkVault} from "../src/DarkVault.sol";
import {IDarkVault} from "../src/interfaces/IDarkVault.sol";
import {IDarkVerifier} from "../src/interfaces/IDarkVerifier.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

/// @notice Deploys MockUSDG, DarkTimelock (an OZ TimelockController instance), the registry and the
///         vault. Verifier addresses come from env and are pinned against
///         deployments/verifier-codehashes.json before they are wired (§18b.4, §19 X4).
contract DeployDarkTestnet is Script {
    error UnpinnedVerifier(string name, address supplied, address pinned);
    error VerifierCodehashMismatch(string name, address at, bytes32 got, bytes32 pinned);

    function run() external {
        address ownerSafe = vm.envAddress("DARK_OWNER_SAFE");
        address guardianSafe = vm.envAddress("DARK_GUARDIAN_SAFE");
        IDarkVerifier registerVerifier = IDarkVerifier(vm.envAddress("DARK_REGISTER_VERIFIER"));
        IDarkVerifier transferVerifier = IDarkVerifier(vm.envAddress("DARK_TRANSFER_VERIFIER"));
        IDarkVerifier withdrawVerifier = IDarkVerifier(vm.envAddress("DARK_WITHDRAW_VERIFIER"));

        // Provenance gate: wrong env address (M17) or swapped code at a pinned address (X4).
        string memory pin = vm.readFile(vm.envOr("DARK_CODEHASH_PIN", string("deployments/verifier-codehashes.json")));
        _pin(pin, "DarkRegisterVerifier", address(registerVerifier));
        _pin(pin, "DarkTransferVerifier", address(transferVerifier));
        _pin(pin, "DarkWithdrawVerifier", address(withdrawVerifier));
        // The libraries are linked into the verifiers by address: their code is not covered by the
        // verifiers' own codehash, so pin it separately.
        _pin(pin, "RelationsLib", address(0));
        _pin(pin, "ZKTranscriptLib", address(0));

        vm.startBroadcast();

        MockUSDG usdg = new MockUSDG();

        address[] memory roles = new address[](1);
        roles[0] = ownerSafe;
        // admin = address(0): nobody can grant itself proposer/executor and skip the 48h delay.
        TimelockController timelock = new TimelockController(48 hours, roles, roles, address(0));

        DarkKeyRegistry registry = new DarkKeyRegistry(registerVerifier);

        // Testnet caps sit at the hard ceilings so the same bytecode paths are exercised (§6.5).
        IDarkVault.Caps memory caps = IDarkVault.Caps({
            minDeposit: 1,
            maxDeposit: 2_500e6,
            maxAccountInflow: 10_000e6,
            minTransfer: 10_000,
            maxTransfer: 2_500e6,
            tvlCap: 250_000e6
        });

        new DarkVault(
            address(usdg), registry, transferVerifier, withdrawVerifier, address(timelock), guardianSafe, caps
        );

        vm.stopBroadcast();
    }

    /// @dev `supplied == address(0)` means "no env address for this one, just pin the code".
    function _pin(string memory json, string memory name, address supplied) internal view {
        string memory at = string.concat(".", vm.toString(block.chainid), ".", name);
        address pinned = vm.parseJsonAddress(json, string.concat(at, ".address"));
        bytes32 hash = vm.parseJsonBytes32(json, string.concat(at, ".codehash"));
        if (supplied != address(0) && supplied != pinned) revert UnpinnedVerifier(name, supplied, pinned);
        if (pinned.codehash != hash) revert VerifierCodehashMismatch(name, pinned, pinned.codehash, hash);
    }
}
