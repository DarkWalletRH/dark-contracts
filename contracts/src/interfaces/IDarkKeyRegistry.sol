// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {IDarkVerifier} from "./IDarkVerifier.sol";

interface IDarkKeyRegistry {
    struct Point {
        uint256 x;
        uint256 y;
    }

    event KeyRegistered(address indexed account, uint256 px, uint256 py);

    error AlreadyRegistered(address account);
    error NotRegistered(address account);
    error InvalidPoint();
    error InvalidProof();

    /// @notice caller = the account itself; never pausable.
    function register(Point calldata publicKey, bytes calldata proof) external;

    function keyOf(address account) external view returns (Point memory);

    function isRegistered(address account) external view returns (bool);

    function registerVerifier() external view returns (IDarkVerifier);
}
