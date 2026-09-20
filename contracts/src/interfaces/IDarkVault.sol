// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {IDarkVerifier} from "./IDarkVerifier.sol";
import {IDarkKeyRegistry} from "./IDarkKeyRegistry.sol";

interface IDarkVault {
    struct Point {
        uint256 x;
        uint256 y;
    } // (0,0) = identity

    struct Ciphertext {
        Point c;
        Point d;
    } // C = v*G + rho*H, D = rho*P

    struct TransferCt {
        Point c;
        Point dSender;
        Point dRecipient;
    }

    struct Caps {
        uint64 minDeposit;
        uint64 maxDeposit;
        uint64 maxAccountInflow;
        uint64 minTransfer;
        uint64 maxTransfer;
        uint64 tvlCap;
    }

    struct AccountView {
        Ciphertext available;
        Ciphertext pending;
        uint64 nonce;
        uint64 pendingCount;
        uint128 netInflow;
        bytes aeBalance;
    }

    // ---- account owner ----
    function deposit(uint256 amount, bytes calldata aeBalance) external;
    /// @notice Folds `pending` into `available`.
    /// @param expectedPendingCount A LOWER bound: "apply at least the N transfers I accounted for".
    ///        Reverts `PendingChanged` only if the account holds fewer than N, which can only happen
    ///        if the caller read stale state. Transfers that land after the caller built `aeBalance`
    ///        fold in too; the extra makes `aeBalance` under-report, and the client detects that
    ///        (it always checks `value·G == C − s·D`) and replays. An exact match here would let
    ///        anyone grief the call by sending one more `minTransfer`.
    function applyPending(uint64 expectedPendingCount, bytes calldata aeBalance) external;
    function transfer(
        address to,
        TransferCt calldata ct,
        bytes calldata proof,
        bytes calldata hint,
        bytes calldata senderHint,
        bytes calldata aeBalance
    ) external;
    function withdraw(uint256 amount, address to, bytes calldata proof, bytes calldata aeBalance) external;

    // ---- admin ----
    function setCaps(Caps calldata newCaps) external;
    function tightenCaps(Caps calldata newCaps) external;
    function setGuardian(address guardian) external;
    function pause() external;
    function unpause() external;
    function recoverERC20(address token, address to, uint256 amount) external;

    // ---- views ----
    function getAccount(address account) external view returns (AccountView memory);
    function caps() external view returns (Caps memory);
    function tvl() external view returns (uint256);
    function usdg() external view returns (address);
    function registry() external view returns (IDarkKeyRegistry);
    function transferVerifier() external view returns (IDarkVerifier);
    function withdrawVerifier() external view returns (IDarkVerifier);
    function guardian() external view returns (address);
    function SPEC_VERSION() external pure returns (bytes32);
    function HARD_MAX_TVL() external pure returns (uint64);
    function HARD_MAX_TRANSFER() external pure returns (uint64);
    function HARD_MAX_DEPOSIT() external pure returns (uint64);
    function HARD_MAX_ACCOUNT_INFLOW() external pure returns (uint64);

    // ---- events ----
    event Deposited(
        address indexed account,
        uint64 nonceAfter,
        uint256 amount,
        uint256[4] availableAfter,
        uint128 netInflowAfter,
        uint256 tvlAfter
    );
    event PendingApplied(address indexed account, uint64 nonceAfter, uint64 appliedCount, uint256[4] availableAfter);
    event ConfidentialTransfer(
        address indexed from,
        address indexed to,
        uint64 fromNonceAfter,
        uint256[6] transferCt,
        uint256[4] fromAvailableAfter,
        uint256[4] toPendingAfter,
        uint64 toPendingCountAfter,
        bytes hint,
        bytes senderHint
    );
    event Withdrawn(
        address indexed account,
        address indexed to,
        uint64 nonceAfter,
        uint256 amount,
        uint256[4] availableAfter,
        uint128 netInflowAfter,
        uint256 tvlAfter
    );
    event CapsUpdated(Caps oldCaps, Caps newCaps, address indexed by);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    error NotRegistered(address account);
    error RecipientNotRegistered(address to);
    error SelfTransfer();
    error InvalidPoint();
    error InvalidProof();
    error AmountZero();
    error AmountTooLarge();
    error BelowMinDeposit(uint256 amount, uint256 min);
    error ExceedsDepositCap(uint256 amount, uint256 cap);
    error ExceedsAccountInflowCap(uint256 inflowAfter, uint256 cap);
    error ExceedsTvlCap(uint256 tvlAfter, uint256 cap);
    error UnexpectedTransferAmount(uint256 expected, uint256 received);
    error PendingChanged(uint64 expected, uint64 actual); // actual < expected: the caller read stale state
    error BadBlobLength(uint256 got, uint256 expected);
    error ExceedsHardCeiling();
    error NotTightening();
    error NotGuardian();
    error ZeroAddress();
    error CannotRecoverUSDG();
    error RenounceDisabled();
    error BadRecipient();
}
