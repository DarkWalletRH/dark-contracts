// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {IDarkKeyRegistry} from "./interfaces/IDarkKeyRegistry.sol";
import {IDarkVerifier} from "./interfaces/IDarkVerifier.sol";
import {DarkGrumpkin} from "./libraries/DarkGrumpkin.sol";

/// @notice address -> Grumpkin public key, proof-of-knowledge verified. Immutable, no owner, never pausable (§6.5).
contract DarkKeyRegistry is IDarkKeyRegistry {
    IDarkVerifier private immutable _registerVerifier;

    /// @dev `y != 0` means registered: the group order is prime, so no curve point has y == 0.
    mapping(address => Point) private _keys;

    constructor(IDarkVerifier registerVerifier_) {
        require(address(registerVerifier_).code.length > 0, "verifier has no code");
        _registerVerifier = registerVerifier_;
    }

    /// @inheritdoc IDarkKeyRegistry
    function register(Point calldata publicKey, bytes calldata proof) external {
        if (_keys[msg.sender].y != 0) revert AlreadyRegistered(msg.sender);
        if (!DarkGrumpkin.isOnCurve(publicKey.x, publicKey.y)) revert InvalidPoint();

        // Bound to chain, registry and caller so a proof cannot be replayed elsewhere (§6.4/§7.1).
        bytes32[] memory pi = new bytes32[](5);
        pi[0] = bytes32(block.chainid);
        pi[1] = bytes32(uint256(uint160(address(this))));
        pi[2] = bytes32(uint256(uint160(msg.sender)));
        pi[3] = bytes32(publicKey.x);
        pi[4] = bytes32(publicKey.y);
        if (!_registerVerifier.verify(proof, pi)) revert InvalidProof();

        _keys[msg.sender] = publicKey;
        emit KeyRegistered(msg.sender, publicKey.x, publicKey.y);
    }

    function keyOf(address account) external view returns (Point memory key) {
        key = _keys[account];
        if (key.y == 0) revert NotRegistered(account);
    }

    function isRegistered(address account) external view returns (bool) {
        return _keys[account].y != 0;
    }

    function registerVerifier() external view returns (IDarkVerifier) {
        return _registerVerifier;
    }
}
