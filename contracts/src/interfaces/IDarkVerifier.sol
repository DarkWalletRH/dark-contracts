// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

/// @notice Matches the generated bb Honk verifier ABI (§6.5).
interface IDarkVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
