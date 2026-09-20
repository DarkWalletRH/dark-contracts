// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDarkVault} from "./interfaces/IDarkVault.sol";
import {IDarkVerifier} from "./interfaces/IDarkVerifier.sol";
import {IDarkKeyRegistry} from "./interfaces/IDarkKeyRegistry.sol";
import {DarkGrumpkin} from "./libraries/DarkGrumpkin.sol";

/// @notice USDG <-> encrypted balances (§6.5). No proxy, no delegatecall, no verifier/registry/token setter.
///         `withdraw`, `applyPending` and registration are never pausable; exit is never blocked.
contract DarkVault is IDarkVault, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant HARD_MAX_TVL = 250_000e6;
    uint64 public constant HARD_MAX_TRANSFER = 2_500e6;
    uint64 public constant HARD_MAX_DEPOSIT = 2_500e6;
    uint64 public constant HARD_MAX_ACCOUNT_INFLOW = 10_000e6;

    uint256 private constant AE_LEN = 56;
    uint256 private constant HINT_LEN = 240;
    uint256 private constant SENDER_HINT_LEN = 176;
    uint256 private constant MAX_AMOUNT = 1 << 48;

    address private immutable _usdg;
    IDarkKeyRegistry private immutable _registry;
    IDarkVerifier private immutable _transferVerifier;
    IDarkVerifier private immutable _withdrawVerifier;

    address private _guardian;
    Caps private _caps;
    uint256 private _tvl;

    struct Account {
        Ciphertext available;
        Ciphertext pending;
        uint64 nonce;
        uint64 pendingCount;
        uint128 netInflow;
        bytes aeBalance;
    }

    mapping(address => Account) private _accounts;

    constructor(
        address usdg_,
        IDarkKeyRegistry registry_,
        IDarkVerifier transferVerifier_,
        IDarkVerifier withdrawVerifier_,
        address owner_,
        address guardian_,
        Caps memory initialCaps
    ) Ownable(owner_) {
        require(IERC20Metadata(usdg_).decimals() == 6, "usdg decimals");
        if (block.chainid == 4663) require(usdg_ == 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, "usdg address");
        require(transferVerifier_ != withdrawVerifier_, "verifiers equal");
        require(address(transferVerifier_).code.length > 0 && address(withdrawVerifier_).code.length > 0, "no code");
        require(address(registry_).code.length > 0, "no registry");
        if (guardian_ == address(0)) revert ZeroAddress();

        _checkCeilings(initialCaps);
        _usdg = usdg_;
        _registry = registry_;
        _transferVerifier = transferVerifier_;
        _withdrawVerifier = withdrawVerifier_;
        _guardian = guardian_;
        _caps = initialCaps;
        emit GuardianUpdated(address(0), guardian_);
        emit CapsUpdated(Caps(0, 0, 0, 0, 0, 0), initialCaps, msg.sender);
    }

    // ---------------------------------------------------------------- account

    /// @inheritdoc IDarkVault
    function deposit(uint256 amount, bytes calldata aeBalance) external nonReentrant whenNotPaused {
        Account storage a = _accounts[msg.sender];
        _requireRegistered(msg.sender);
        _checkAe(aeBalance);

        Caps memory c = _caps;
        if (amount < c.minDeposit) revert BelowMinDeposit(amount, c.minDeposit);
        if (amount > c.maxDeposit) revert ExceedsDepositCap(amount, c.maxDeposit);
        uint256 inflowAfter = uint256(a.netInflow) + amount;
        if (inflowAfter > c.maxAccountInflow) revert ExceedsAccountInflowCap(inflowAfter, c.maxAccountInflow);
        uint256 tvlAfter = _tvl + amount;
        if (tvlAfter > c.tvlCap) revert ExceedsTvlCap(tvlAfter, c.tvlCap);
        if (amount >= MAX_AMOUNT) revert AmountTooLarge();

        // Interaction first, deliberately: the shared nonReentrant guard stops a token hook from
        // re-entering any account function mid-deposit, and the delta guard catches fee-on-transfer.
        IERC20 token = IERC20(_usdg);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert UnexpectedTransferAmount(amount, received);

        (uint256 gx, uint256 gy) = DarkGrumpkin.mulG(amount);
        (a.available.c.x, a.available.c.y) = DarkGrumpkin.add(a.available.c.x, a.available.c.y, gx, gy);
        a.netInflow = uint128(inflowAfter);
        _tvl = tvlAfter;
        a.nonce += 1;
        a.aeBalance = aeBalance;

        emit Deposited(msg.sender, a.nonce, amount, _ct(a.available), a.netInflow, tvlAfter);
    }

    /// @inheritdoc IDarkVault
    function applyPending(uint64 expectedPendingCount, bytes calldata aeBalance) external nonReentrant {
        Account storage a = _accounts[msg.sender];
        _requireRegistered(msg.sender);
        // Monotone bound, not equality: an exact match lets anyone grief the call by landing one
        // more minTransfer between the read and the tx. Later arrivals fold in - the ciphertext is
        // an accumulator, so the sum is exact whatever the count; only `aeBalance` under-reports,
        // and the client always re-derives it from the ciphertext before believing it.
        uint64 applied = a.pendingCount;
        if (applied < expectedPendingCount) revert PendingChanged(expectedPendingCount, applied);
        _checkAe(aeBalance);

        (a.available.c.x, a.available.c.y) =
            DarkGrumpkin.add(a.available.c.x, a.available.c.y, a.pending.c.x, a.pending.c.y);
        (a.available.d.x, a.available.d.y) =
            DarkGrumpkin.add(a.available.d.x, a.available.d.y, a.pending.d.x, a.pending.d.y);
        delete a.pending;
        a.pendingCount = 0;
        a.nonce += 1;
        a.aeBalance = aeBalance;

        emit PendingApplied(msg.sender, a.nonce, applied, _ct(a.available));
    }

    /// @inheritdoc IDarkVault
    function transfer(
        address to,
        TransferCt calldata ct,
        bytes calldata proof,
        bytes calldata hint,
        bytes calldata senderHint,
        bytes calldata aeBalance
    ) external nonReentrant whenNotPaused {
        _requireRegistered(msg.sender);
        if (!_registry.isRegistered(to)) revert RecipientNotRegistered(to);
        if (to == msg.sender) revert SelfTransfer();
        if (hint.length != HINT_LEN) revert BadBlobLength(hint.length, HINT_LEN);
        if (senderHint.length != SENDER_HINT_LEN) revert BadBlobLength(senderHint.length, SENDER_HINT_LEN);
        _checkAe(aeBalance);
        _requirePoint(ct.c);
        _requirePoint(ct.dSender);
        _requirePoint(ct.dRecipient);

        Account storage s = _accounts[msg.sender];
        if (!_transferVerifier.verify(proof, _transferInputs(to, ct, s))) revert InvalidProof();

        (s.available.c.x, s.available.c.y) = DarkGrumpkin.sub(s.available.c.x, s.available.c.y, ct.c.x, ct.c.y);
        (s.available.d.x, s.available.d.y) =
            DarkGrumpkin.sub(s.available.d.x, s.available.d.y, ct.dSender.x, ct.dSender.y);

        Account storage r = _accounts[to];
        (r.pending.c.x, r.pending.c.y) = DarkGrumpkin.add(r.pending.c.x, r.pending.c.y, ct.c.x, ct.c.y);
        (r.pending.d.x, r.pending.d.y) =
            DarkGrumpkin.add(r.pending.d.x, r.pending.d.y, ct.dRecipient.x, ct.dRecipient.y);
        r.pendingCount += 1;
        s.nonce += 1;
        s.aeBalance = aeBalance;

        emit ConfidentialTransfer(
            msg.sender,
            to,
            s.nonce,
            [ct.c.x, ct.c.y, ct.dSender.x, ct.dSender.y, ct.dRecipient.x, ct.dRecipient.y],
            _ct(s.available),
            _ct(r.pending),
            r.pendingCount,
            hint,
            senderHint
        );
    }

    /// @inheritdoc IDarkVault
    function withdraw(uint256 amount, address to, bytes calldata proof, bytes calldata aeBalance)
        external
        nonReentrant
    {
        Account storage a = _accounts[msg.sender];
        _requireRegistered(msg.sender);
        if (amount == 0) revert AmountZero();
        if (amount >= MAX_AMOUNT) revert AmountTooLarge();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert BadRecipient();
        _checkAe(aeBalance);

        if (!_withdrawVerifier.verify(proof, _withdrawInputs(msg.sender, to, amount, a))) revert InvalidProof();

        (uint256 gx, uint256 gy) = DarkGrumpkin.mulG(amount);
        (a.available.c.x, a.available.c.y) = DarkGrumpkin.sub(a.available.c.x, a.available.c.y, gx, gy);
        uint256 tvlAfter = _tvl - amount; // checked: an underflow means the ghost accounting is broken
        _tvl = tvlAfter;
        a.netInflow = amount >= a.netInflow ? 0 : uint128(a.netInflow - amount);
        a.nonce += 1;
        a.aeBalance = aeBalance;

        emit Withdrawn(msg.sender, to, a.nonce, amount, _ct(a.available), a.netInflow, tvlAfter);
        IERC20(_usdg).safeTransfer(to, amount); // CEI
    }

    // ------------------------------------------------------------------ admin

    function setCaps(Caps calldata newCaps) external onlyOwner {
        _checkCeilings(newCaps);
        emit CapsUpdated(_caps, newCaps, msg.sender);
        _caps = newCaps;
    }

    function tightenCaps(Caps calldata newCaps) external {
        if (msg.sender != _guardian && msg.sender != owner()) revert NotGuardian();
        Caps memory c = _caps;
        bool ok = newCaps.maxDeposit <= c.maxDeposit && newCaps.maxAccountInflow <= c.maxAccountInflow
            && newCaps.maxTransfer <= c.maxTransfer && newCaps.tvlCap <= c.tvlCap && newCaps.minDeposit >= c.minDeposit
            && newCaps.minTransfer >= c.minTransfer;
        if (!ok) revert NotTightening();
        emit CapsUpdated(c, newCaps, msg.sender);
        _caps = newCaps;
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        emit GuardianUpdated(_guardian, guardian_);
        _guardian = guardian_;
    }

    /// @notice Blocks `deposit` and `transfer` only.
    function pause() external {
        if (msg.sender != _guardian && msg.sender != owner()) revert NotGuardian();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == _usdg) revert CannotRecoverUSDG();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------ views

    function getAccount(address account) external view returns (AccountView memory) {
        Account storage a = _accounts[account];
        return AccountView(a.available, a.pending, a.nonce, a.pendingCount, a.netInflow, a.aeBalance);
    }

    function caps() external view returns (Caps memory) {
        return _caps;
    }

    function tvl() external view returns (uint256) {
        return _tvl;
    }

    function usdg() external view returns (address) {
        return _usdg;
    }

    function registry() external view returns (IDarkKeyRegistry) {
        return _registry;
    }

    function transferVerifier() external view returns (IDarkVerifier) {
        return _transferVerifier;
    }

    function withdrawVerifier() external view returns (IDarkVerifier) {
        return _withdrawVerifier;
    }

    function guardian() external view returns (address) {
        return _guardian;
    }

    function SPEC_VERSION() external pure returns (bytes32) {
        return keccak256("DARK-CB-1");
    }

    // -------------------------------------------------------------- internals

    /// @dev Public-input order (canonical, mirrored by the SDK; see README "Spec questions").
    ///      [chainId, vault, sender, to, senderNonce, Ps, Pr, senderAvailable(C,D), ct(C,Ds,Dr), minTransfer, maxTransfer]
    function _transferInputs(address to, TransferCt calldata ct, Account storage s)
        private
        view
        returns (bytes32[] memory pi)
    {
        IDarkKeyRegistry.Point memory ps = _registry.keyOf(msg.sender);
        IDarkKeyRegistry.Point memory pr = _registry.keyOf(to);
        pi = new bytes32[](21);
        pi[0] = bytes32(block.chainid);
        pi[1] = bytes32(uint256(uint160(address(this))));
        pi[2] = bytes32(uint256(uint160(msg.sender)));
        pi[3] = bytes32(uint256(uint160(to)));
        pi[4] = bytes32(uint256(s.nonce));
        pi[5] = bytes32(ps.x);
        pi[6] = bytes32(ps.y);
        pi[7] = bytes32(pr.x);
        pi[8] = bytes32(pr.y);
        pi[9] = bytes32(s.available.c.x);
        pi[10] = bytes32(s.available.c.y);
        pi[11] = bytes32(s.available.d.x);
        pi[12] = bytes32(s.available.d.y);
        pi[13] = bytes32(ct.c.x);
        pi[14] = bytes32(ct.c.y);
        pi[15] = bytes32(ct.dSender.x);
        pi[16] = bytes32(ct.dSender.y);
        pi[17] = bytes32(ct.dRecipient.x);
        pi[18] = bytes32(ct.dRecipient.y);
        pi[19] = bytes32(uint256(_caps.minTransfer));
        pi[20] = bytes32(uint256(_caps.maxTransfer));
    }

    /// @dev [chainId, vault, account, to, nonce, P, available(C,D), amount]
    function _withdrawInputs(address account, address to, uint256 amount, Account storage a)
        private
        view
        returns (bytes32[] memory pi)
    {
        IDarkKeyRegistry.Point memory p = _registry.keyOf(account);
        pi = new bytes32[](12);
        pi[0] = bytes32(block.chainid);
        pi[1] = bytes32(uint256(uint160(address(this))));
        pi[2] = bytes32(uint256(uint160(account)));
        pi[3] = bytes32(uint256(uint160(to)));
        pi[4] = bytes32(uint256(a.nonce));
        pi[5] = bytes32(p.x);
        pi[6] = bytes32(p.y);
        pi[7] = bytes32(a.available.c.x);
        pi[8] = bytes32(a.available.c.y);
        pi[9] = bytes32(a.available.d.x);
        pi[10] = bytes32(a.available.d.y);
        pi[11] = bytes32(amount);
    }

    function _requireRegistered(address account) private view {
        if (!_registry.isRegistered(account)) revert NotRegistered(account);
    }

    function _checkAe(bytes calldata ae) private pure {
        if (ae.length != 0 && ae.length != AE_LEN) revert BadBlobLength(ae.length, AE_LEN);
    }

    function _requirePoint(Point calldata p) private pure {
        if (!DarkGrumpkin.isOnCurve(p.x, p.y)) revert InvalidPoint(); // canonical, on-curve, not the identity
    }

    function _checkCeilings(Caps memory c) private pure {
        if (
            c.maxDeposit > HARD_MAX_DEPOSIT || c.maxAccountInflow > HARD_MAX_ACCOUNT_INFLOW
                || c.maxTransfer > HARD_MAX_TRANSFER || c.tvlCap > HARD_MAX_TVL
        ) revert ExceedsHardCeiling();
        if (c.minTransfer < 1) revert ExceedsHardCeiling();
    }

    function _ct(Ciphertext storage c) private view returns (uint256[4] memory) {
        return [c.c.x, c.c.y, c.d.x, c.d.y];
    }
}
