// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DarkKeyRegistry} from "../src/DarkKeyRegistry.sol";
import {DarkVault} from "../src/DarkVault.sol";
import {IDarkVault} from "../src/interfaces/IDarkVault.sol";
import {IDarkVerifier} from "../src/interfaces/IDarkVerifier.sol";

interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Mainnet (4663): DarkTimelock, the registry and the vault, on the real USDG, with the launch
///         launch beta caps. The verifiers and their libraries are deployed first by
///         scripts/deploy-verifiers.mjs and pinned; this script refuses anything unpinned, exactly as
///         the testnet one does. Differences from testnet are all refusals: wrong chain, a "Safe"
///         that is an EOA, an owner Safe one key can operate, or a USDG that is not the real one.
contract DeployDarkMainnet is Script {
    uint256 public constant MAINNET = 4663;
    /// @dev The only real address the SDK had before this deploy (deployments[4663].usdg).
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    error WrongChain(uint256 got);
    error NotASafe(string role, address at);
    error OwnerSafeThresholdTooLow(uint256 threshold);
    error OwnerSafeTooFewOwners(uint256 owners);
    error SameSafe(address at);
    error UsdgNotReal(address at);
    error UnpinnedVerifier(string name, address supplied, address pinned);
    error VerifierCodehashMismatch(string name, address at, bytes32 got, bytes32 pinned);

    /// @dev Launch beta caps (USDG has 6 decimals). Well under the immutable HARD_MAX_* ceilings; raising
    ///      them later goes through the 48 h timelock, lowering them is instant for the guardian.
    function caps() public pure returns (IDarkVault.Caps memory) {
        return IDarkVault.Caps({
            minDeposit: 1e6,
            maxDeposit: 1_000e6,
            maxAccountInflow: 2_500e6,
            minTransfer: 10_000,
            maxTransfer: 1_000e6,
            tvlCap: 50_000e6
        });
    }

    function run() external returns (DarkVault) {
        return deploy(
            vm.envAddress("DARK_OWNER_SAFE"),
            vm.envAddress("DARK_GUARDIAN_SAFE"),
            [
                vm.envAddress("DARK_REGISTER_VERIFIER"),
                vm.envAddress("DARK_TRANSFER_VERIFIER"),
                vm.envAddress("DARK_WITHDRAW_VERIFIER")
            ],
            vm.envOr("DARK_CODEHASH_PIN", string("deployments/verifier-codehashes.json"))
        );
    }

    /// @param verifiers register, transfer, withdraw — in that order.
    /// @dev Env-free so the test can call it without racing the testnet suite over `DARK_*`.
    function deploy(address ownerSafe, address guardianSafe, address[3] memory verifiers, string memory pinPath)
        public
        returns (DarkVault vault)
    {
        if (block.chainid != MAINNET) revert WrongChain(block.chainid);

        if (ownerSafe == guardianSafe) revert SameSafe(ownerSafe);
        // The owner proposes, executes and cancels on the timelock, so one key must not be enough
        // (2-of-3). The guardian may be 1-of-n: pausing fast is its whole job.
        uint256 ownerThreshold = _threshold("owner", ownerSafe);
        if (ownerThreshold < 2) revert OwnerSafeThresholdTooLow(ownerThreshold);
        // 2-of-2 passes the threshold but one lost key then freezes unpause/setCaps/setGuardian for good
        // (DARK-CB-1 owner-key-loss note): require a spare signer.
        uint256 ownerCount = ISafe(ownerSafe).getOwners().length;
        if (ownerCount < 3) revert OwnerSafeTooFewOwners(ownerCount);
        _threshold("guardian", guardianSafe);

        if (USDG.code.length == 0 || IERC20Decimals(USDG).decimals() != 6) revert UsdgNotReal(USDG);

        string memory pin = vm.readFile(pinPath);
        _pin(pin, "DarkRegisterVerifier", verifiers[0]);
        _pin(pin, "DarkTransferVerifier", verifiers[1]);
        _pin(pin, "DarkWithdrawVerifier", verifiers[2]);
        _pin(pin, "RelationsLib", address(0));
        _pin(pin, "ZKTranscriptLib", address(0));

        vm.startBroadcast();

        address[] memory roles = new address[](1);
        roles[0] = ownerSafe;
        // admin = address(0): nobody can grant itself proposer/executor and skip the 48h delay.
        TimelockController timelock = new TimelockController(48 hours, roles, roles, address(0));
        DarkKeyRegistry registry = new DarkKeyRegistry(IDarkVerifier(verifiers[0]));
        vault = new DarkVault(
            USDG,
            registry,
            IDarkVerifier(verifiers[1]),
            IDarkVerifier(verifiers[2]),
            address(timelock),
            guardianSafe,
            caps()
        );

        vm.stopBroadcast();
    }

    /// @dev A Safe is a contract with a non-zero threshold; an EOA pasted by mistake has no code.
    function _threshold(string memory role, address safe) internal view returns (uint256 t) {
        if (safe.code.length == 0) revert NotASafe(role, safe);
        try ISafe(safe).getThreshold() returns (uint256 got) {
            t = got;
        } catch {
            revert NotASafe(role, safe);
        }
        if (t == 0) revert NotASafe(role, safe);
    }

    /// @dev Same gate as DeployDarkTestnet: `supplied == address(0)` means "just pin the code".
    function _pin(string memory json, string memory name, address supplied) internal view {
        string memory at = string.concat(".", vm.toString(block.chainid), ".", name);
        address pinned = vm.parseJsonAddress(json, string.concat(at, ".address"));
        bytes32 hash = vm.parseJsonBytes32(json, string.concat(at, ".codehash"));
        if (supplied != address(0) && supplied != pinned) revert UnpinnedVerifier(name, supplied, pinned);
        if (pinned.codehash != hash) revert VerifierCodehashMismatch(name, pinned, pinned.codehash, hash);
    }
}
