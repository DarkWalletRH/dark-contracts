// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDarkVerifier} from "../../src/interfaces/IDarkVerifier.sol";

/// @notice Stand-in for the generated Honk verifiers, in two modes.
///         - unarmed (`expected == 0`): accepts any inputs while `result` is true (unit tests).
///         - armed by the handler's ghost oracle: accepts only the exact public-input array the
///           oracle derived from its own plaintext model of the state. A vault that passes any
///           public input from calldata instead of storage, or that reads a stale nonce/available,
///           produces a different array and the "proof" is rejected (I13).
///         `verify` is `view` in `IDarkVerifier`, so the array is recorded by the arming caller,
///         not here.
contract DarkTestVerifier is IDarkVerifier {
    bool public result = true;
    bytes32 public expected;

    function setResult(bool r) external {
        result = r;
    }

    function expect(bytes32[] calldata publicInputs) external {
        expected = keccak256(abi.encode(publicInputs));
    }

    function clearExpect() external {
        expected = bytes32(0);
    }

    function verify(bytes calldata, bytes32[] calldata publicInputs) external view returns (bool) {
        if (!result) return false;
        return expected == bytes32(0) || expected == keccak256(abi.encode(publicInputs));
    }
}
