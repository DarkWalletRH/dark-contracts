// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Vm} from "forge-std/Vm.sol";

import {DarkVault} from "../../src/DarkVault.sol";
import {DarkKeyRegistry} from "../../src/DarkKeyRegistry.sol";
import {IDarkVault} from "../../src/interfaces/IDarkVault.sol";
import {IDarkKeyRegistry} from "../../src/interfaces/IDarkKeyRegistry.sol";
import {DarkGrumpkin} from "../../src/libraries/DarkGrumpkin.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {DarkTestVerifier} from "../mocks/DarkTestVerifier.sol";

/// @notice Handler with a plaintext ghost oracle of the confidential state.
///
/// The ghost knows every actor's secret `sk`, its plaintext balance and its accumulated blinding
/// `rho`, and reproduces the on-chain ciphertexts exactly:
///
///     available.C == encG(bal + h*rho)      available.D == encG(rho * sk)
///     pending.C   == encG(pbal + h*prho)    pending.D   == encG(prho * sk)
///
/// where `encG(k)` is `k*G` for k >= 0 and `-(|k|*G)` otherwise, and `h` is a TEST-ONLY discrete
/// log of the second generator (H = h*G) so the ghost can compute `rho*H` with the vault's own
/// fixed-base `mulG`. The vault never uses H, so this changes nothing it executes; see
/// the ghost oracle below.
///
/// Before every proof-bearing call the handler derives the public inputs from the ghost and arms
/// `DarkTestVerifier`, so the vault's proof only verifies if every public input it built from
/// storage/registry/config matches the oracle (I13).
///
/// Every branch that could revert returns early instead: `fail_on_revert = true`.
contract DarkVaultHandler is Test {
    /// @dev TEST-ONLY: H = H_SCALAR * G. Real H is a hash-to-curve point with unknown dlog.
    uint256 internal constant H_SCALAR = 7;
    uint256 internal constant MAX_RHO = 1e6;

    DarkVault public immutable vault;
    DarkKeyRegistry public immutable registryC;
    MockUSDG public immutable usdg;
    DarkTestVerifier public immutable transferV;
    DarkTestVerifier public immutable withdrawV;
    address public immutable guardian;
    address public immutable owner;

    address[3] public actors;
    uint256[3] public secrets;

    struct Ghost {
        uint256 bal;
        int256 rho;
        uint256 pbal;
        int256 prho;
        uint64 nonce;
        uint64 pendingCount;
        uint128 netInflow;
    }

    mapping(address => Ghost) internal _g;

    // ---- run statistics (anti-vacuity) ----
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public transfers;
    uint256 public applies;
    uint256 public capChanges;
    uint256 public illegalCallsAttempted; // I15
    uint256 public illegalCallsRejected; // I15: must stay equal to the attempts
    uint256 public boundChecks; // I13: public-input arrays the oracle armed
    uint256 public bindingsConsumed; // I13: armed arrays a verifier actually accepted
    uint256 public bindingFailures; // I13: armed arrays a verifier REJECTED (must stay 0)
    uint256 public eventChecks; // I14
    uint256 public isolationChecks; // I3 / I4

    uint256 public ghostTotal; // sum of bal + pbal over actors == tvl (I2)
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    constructor(
        DarkVault v,
        DarkKeyRegistry r,
        MockUSDG u,
        DarkTestVerifier tv,
        DarkTestVerifier wv,
        address owner_,
        address guardian_,
        address[3] memory a,
        uint256[3] memory sk
    ) {
        vault = v;
        registryC = r;
        usdg = u;
        transferV = tv;
        withdrawV = wv;
        owner = owner_;
        guardian = guardian_;
        actors = a;
        secrets = sk;
    }

    // ------------------------------------------------------------------ views

    function actor(uint256 seed) public view returns (address) {
        return actors[seed % actors.length];
    }

    function secretOf(address a) public view returns (uint256) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == a) return secrets[i];
        }
        revert("unknown actor");
    }

    function ghost(address a) public view returns (Ghost memory) {
        return _g[a];
    }

    /// @dev Plaintext available balance the oracle says `a` holds (the "decryption" of I2).
    function ghostBalance(address a) public view returns (uint256) {
        return _g[a].bal;
    }

    function ghostPending(address a) public view returns (uint256) {
        return _g[a].pbal;
    }

    /// @notice k*G for a signed k, so the ghost can hold negative blinding sums.
    function encG(int256 k) public view returns (uint256 x, uint256 y) {
        if (k >= 0) return DarkGrumpkin.mulG(uint256(k));
        (x, y) = DarkGrumpkin.mulG(uint256(-k));
        return DarkGrumpkin.neg(x, y);
    }

    /// @notice The ciphertext the oracle expects to find on-chain for `a`.
    function ghostAvailable(address a) public view returns (uint256[4] memory out) {
        Ghost storage g = _g[a];
        (out[0], out[1]) = encG(int256(g.bal) + int256(H_SCALAR) * g.rho);
        (out[2], out[3]) = encG(g.rho * int256(secretOf(a)));
    }

    function ghostPendingCt(address a) public view returns (uint256[4] memory out) {
        Ghost storage g = _g[a];
        (out[0], out[1]) = encG(int256(g.pbal) + int256(H_SCALAR) * g.prho);
        (out[2], out[3]) = encG(g.prho * int256(secretOf(a)));
    }

    // ------------------------------------------------------------- actions

    bool private _booted;

    /// @dev Anti-vacuity: the first call of every sequence runs one real deposit, transfer,
    ///      applyPending, withdraw and one rejected illegal call, so no run can pass the
    ///      invariants on an empty vault. The
    ///      fuzzer's own calls run on top of that state.
    modifier boot() {
        if (!_booted) {
            _booted = true;
            this.deposit(0, type(uint256).max);
            this.transferAction(0, 0, 0, 0);
            this.applyPendingAction(1);
            this.withdrawAction(0, 0, 0);
            this.illegalCall(1);
        }
        _;
    }

    function deposit(uint256 seed, uint256 amount) external boot {
        if (vault.paused()) return;
        address a = actor(seed);
        IDarkVault.Caps memory c = vault.caps();
        uint256 hi = c.maxDeposit;
        uint256 inflowRoom = _room(c.maxAccountInflow, _g[a].netInflow);
        if (inflowRoom < hi) hi = inflowRoom;
        uint256 tvlRoom = _room(c.tvlCap, vault.tvl());
        if (tvlRoom < hi) hi = tvlRoom;
        if (hi < c.minDeposit || c.minDeposit == 0) return;

        amount = bound(amount, c.minDeposit, hi);
        usdg.mint(a, amount);

        _snapshot();
        vm.recordLogs();
        vm.startPrank(a);
        usdg.approve(address(vault), amount);
        vault.deposit(amount, "");
        vm.stopPrank();

        Ghost storage g = _g[a];
        g.bal += amount;
        g.nonce += 1;
        g.netInflow += uint128(amount);
        ghostTotal += amount;
        totalDeposited += amount;
        deposits++;

        // I6: the cap bounds held for this deposit.
        assertGe(amount, c.minDeposit, "I6 deposit below min");
        assertLe(amount, c.maxDeposit, "I6 deposit above max");
        assertLe(uint256(g.netInflow), c.maxAccountInflow, "I6 inflow cap");
        assertLe(vault.tvl(), c.tvlCap, "I6 tvl cap");
        _onlyChanged(a, address(0));
        _checkDepositEvent(a, amount);
    }

    function applyPendingAction(uint256 seed) external boot {
        address a = actor(seed);
        Ghost storage g = _g[a];
        if (g.pendingCount == 0) return;

        _snapshot();
        vm.recordLogs();
        uint64 expectedCount = g.pendingCount;
        vm.prank(a);
        vault.applyPending(expectedCount, "");

        g.bal += g.pbal;
        g.rho += g.prho;
        g.pbal = 0;
        g.prho = 0;
        g.pendingCount = 0;
        g.nonce += 1;
        applies++;

        _onlyChanged(a, a);
        _checkApplyEvent(a, expectedCount);
    }

    function transferAction(uint256 fromSeed, uint256 toSeed, uint256 amount, uint256 rho) external boot {
        if (vault.paused()) return;
        address from = actor(fromSeed);
        // always a different actor
        address to = actors[(fromSeed % actors.length + 1 + (toSeed % (actors.length - 1))) % actors.length];

        IDarkVault.Caps memory c = vault.caps();
        if (c.minTransfer > c.maxTransfer) return;
        if (_g[from].bal < c.minTransfer) return;
        uint256 hi = c.maxTransfer;
        if (_g[from].bal < hi) hi = _g[from].bal;
        if (hi < c.minTransfer) return;
        amount = bound(amount, c.minTransfer, hi);
        rho = bound(rho, 1, MAX_RHO);

        IDarkVault.TransferCt memory t;
        (t.c.x, t.c.y) = encG(int256(amount + H_SCALAR * rho));
        (t.dSender.x, t.dSender.y) = encG(int256(rho * secretOf(from)));
        (t.dRecipient.x, t.dRecipient.y) = encG(int256(rho * secretOf(to)));

        _armTransfer(from, to, t);

        _snapshot();
        vm.recordLogs();
        // I13: the armed public inputs are the ONLY way this succeeds, and a mismatch has to be
        // observable rather than aborting the run, so the revert is caught and counted here.
        vm.prank(from);
        try vault.transfer(to, t, hex"01", _blob(240), _blob(176), "") {
            bindingsConsumed++;
        } catch {
            bindingFailures++;
            transferV.clearExpect();
            return;
        }
        transferV.clearExpect();

        Ghost storage s = _g[from];
        Ghost storage r = _g[to];
        s.bal -= amount;
        s.rho -= int256(rho);
        s.nonce += 1;
        r.pbal += amount;
        r.prho += int256(rho);
        r.pendingCount += 1;
        transfers++;

        // I6: the ghost amount is inside the transfer bounds.
        assertGe(amount, c.minTransfer, "I6 transfer below min");
        assertLe(amount, c.maxTransfer, "I6 transfer above max");
        _onlyChanged(from, to);
        _checkTransferEvent(from, to, t);
    }

    function withdrawAction(uint256 seed, uint256 amount, uint256 toSeed) external boot {
        address a = actor(seed);
        Ghost storage g = _g[a];
        if (g.bal == 0) return;
        amount = bound(amount, 1, g.bal);
        address to = actors[toSeed % actors.length];

        _armWithdraw(a, to, amount);

        _snapshot();
        vm.recordLogs();
        uint256 before = usdg.balanceOf(to);
        vm.prank(a);
        try vault.withdraw(amount, to, hex"01", "") {
            bindingsConsumed++;
        } catch {
            bindingFailures++;
            withdrawV.clearExpect();
            return;
        }
        withdrawV.clearExpect();
        assertEq(usdg.balanceOf(to) - before, amount, "withdraw paid the wrong amount");

        g.bal -= amount;
        g.nonce += 1;
        g.netInflow = amount >= g.netInflow ? 0 : uint128(g.netInflow - amount);
        ghostTotal -= amount;
        totalWithdrawn += amount;
        withdrawals++;

        _onlyChanged(a, address(0));
        _checkWithdrawEvent(a, to, amount);
    }

    function togglePause(uint256 seed) external boot {
        if (vault.paused()) {
            vm.prank(owner);
            vault.unpause();
        } else if (seed % 2 == 0) {
            vm.prank(seed % 4 == 0 ? guardian : owner);
            vault.pause();
        }
    }

    /// @notice The guardian tightens, the owner restores. Both go through the real access control.
    function capsChurn(uint256 seed) external boot {
        IDarkVault.Caps memory c = vault.caps();
        if (seed % 2 == 0) {
            // NB: `Caps memory n = c` would ALIAS c, so the new caps are read fresh.
            IDarkVault.Caps memory n = vault.caps();
            n.maxDeposit = uint64(c.maxDeposit / 2);
            n.maxTransfer = uint64(c.maxTransfer / 2);
            vm.prank(guardian);
            vault.tightenCaps(n);
            // I9: the guardian's write never loosened anything.
            IDarkVault.Caps memory after_ = vault.caps();
            assertLe(after_.maxDeposit, c.maxDeposit, "I9 loosened maxDeposit");
            assertLe(after_.maxTransfer, c.maxTransfer, "I9 loosened maxTransfer");
            assertGe(after_.minDeposit, c.minDeposit, "I9 loosened minDeposit");
            assertGe(after_.minTransfer, c.minTransfer, "I9 loosened minTransfer");
        } else {
            IDarkVault.Caps memory n = IDarkVault.Caps({
                minDeposit: 1e6,
                maxDeposit: 2_500e6,
                maxAccountInflow: 10_000e6,
                minTransfer: 10_000,
                maxTransfer: 2_500e6,
                tvlCap: 250_000e6
            });
            vm.prank(owner);
            vault.setCaps(n);
        }
        capChanges++;
    }

    /// @notice I15: every revert the vault can produce has a legal cause the handler can predict.
    ///         Each probe calls with one illegal input and asserts the exact custom error.
    function illegalCall(uint256 seed) external boot {
        address a = actor(seed);
        address stranger = address(uint160(0xDEAD0000 + (seed % 1000)));
        uint256 k = seed % 6;
        // every argument is evaluated BEFORE vm.expectRevert: a call made while it is armed
        // (mulG hits the modexp precompile) would consume the expectation.
        IDarkVault.TransferCt memory dummy = _dummyCt();
        bytes memory h = _blob(240);
        bytes memory sh = _blob(176);
        illegalCallsAttempted++;

        if (k == 0) {
            vm.expectRevert(abi.encodeWithSelector(IDarkVault.NotRegistered.selector, stranger));
            vm.prank(stranger);
            vault.applyPending(0, "");
        } else if (k == 1) {
            vm.expectRevert(abi.encodeWithSelector(IDarkVault.AmountZero.selector));
            vm.prank(a);
            vault.withdraw(0, a, hex"01", "");
        } else if (k == 2) {
            vm.expectRevert(abi.encodeWithSelector(IDarkVault.ZeroAddress.selector));
            vm.prank(a);
            vault.withdraw(1, address(0), hex"01", "");
        } else if (k == 3) {
            vm.expectRevert(abi.encodeWithSelector(IDarkVault.BadRecipient.selector));
            vm.prank(a);
            vault.withdraw(1, address(vault), hex"01", "");
        } else if (k == 4) {
            uint64 wrong = _g[a].pendingCount + 1;
            vm.expectRevert(
                abi.encodeWithSelector(IDarkVault.PendingChanged.selector, wrong, _g[a].pendingCount)
            );
            vm.prank(a);
            vault.applyPending(wrong, "");
        } else {
            // paused, `whenNotPaused` fires before the self-transfer check: both are legal causes.
            bytes memory err = vault.paused()
                ? abi.encodeWithSelector(Pausable.EnforcedPause.selector)
                : abi.encodeWithSelector(IDarkVault.SelfTransfer.selector);
            vm.expectRevert(err);
            vm.prank(a);
            vault.transfer(a, dummy, hex"01", h, sh, "");
        }
        illegalCallsRejected++;
    }

    // ---------------------------------------------------------------- oracle

    /// @dev Mirrors DarkVault._transferInputs from the GHOST's nonce and available ciphertext.
    function _armTransfer(address from, address to, IDarkVault.TransferCt memory t) private {
        IDarkKeyRegistry.Point memory ps = registryC.keyOf(from);
        IDarkKeyRegistry.Point memory pr = registryC.keyOf(to);
        IDarkVault.Caps memory c = vault.caps();
        uint256[4] memory av = ghostAvailable(from);
        bytes32[] memory pi = new bytes32[](21);
        pi[0] = bytes32(block.chainid);
        pi[1] = bytes32(uint256(uint160(address(vault))));
        pi[2] = bytes32(uint256(uint160(from)));
        pi[3] = bytes32(uint256(uint160(to)));
        pi[4] = bytes32(uint256(_g[from].nonce));
        pi[5] = bytes32(ps.x);
        pi[6] = bytes32(ps.y);
        pi[7] = bytes32(pr.x);
        pi[8] = bytes32(pr.y);
        pi[9] = bytes32(av[0]);
        pi[10] = bytes32(av[1]);
        pi[11] = bytes32(av[2]);
        pi[12] = bytes32(av[3]);
        pi[13] = bytes32(t.c.x);
        pi[14] = bytes32(t.c.y);
        pi[15] = bytes32(t.dSender.x);
        pi[16] = bytes32(t.dSender.y);
        pi[17] = bytes32(t.dRecipient.x);
        pi[18] = bytes32(t.dRecipient.y);
        pi[19] = bytes32(uint256(c.minTransfer));
        pi[20] = bytes32(uint256(c.maxTransfer));
        transferV.expect(pi);
        boundChecks++;
    }

    /// @dev Mirrors DarkVault._withdrawInputs from the GHOST's nonce and available ciphertext.
    function _armWithdraw(address a, address to, uint256 amount) private {
        withdrawV.expect(_withdrawPi(a, to, amount, _g[a].nonce, ghostAvailable(a)));
        boundChecks++;
    }

    /// @notice I7/I8 exit probe: arm the withdraw verifier for the state AFTER `applyPending`,
    ///         which the probe runs first. The probe reverts its state snapshot afterwards, so the
    ///         ghost is never advanced.
    function armExit(address a, address to, uint256 amount) external {
        Ghost storage g = _g[a];
        uint64 n = g.nonce + (g.pendingCount > 0 ? 1 : 0);
        int256 rho = g.rho + g.prho;
        uint256[4] memory av;
        (av[0], av[1]) = encG(int256(g.bal + g.pbal) + int256(H_SCALAR) * rho);
        (av[2], av[3]) = encG(rho * int256(secretOf(a)));
        withdrawV.expect(_withdrawPi(a, to, amount, n, av));
    }

    function _withdrawPi(address a, address to, uint256 amount, uint64 nonce, uint256[4] memory av)
        private
        view
        returns (bytes32[] memory pi)
    {
        IDarkKeyRegistry.Point memory p = registryC.keyOf(a);
        pi = new bytes32[](12);
        pi[0] = bytes32(block.chainid);
        pi[1] = bytes32(uint256(uint160(address(vault))));
        pi[2] = bytes32(uint256(uint160(a)));
        pi[3] = bytes32(uint256(uint160(to)));
        pi[4] = bytes32(uint256(nonce));
        pi[5] = bytes32(p.x);
        pi[6] = bytes32(p.y);
        pi[7] = bytes32(av[0]);
        pi[8] = bytes32(av[1]);
        pi[9] = bytes32(av[2]);
        pi[10] = bytes32(av[3]);
        pi[11] = bytes32(amount);
    }

    // ------------------------------------------------------- isolation (I3/I4)

    bytes32[3] private _availSnap;
    bytes32[3] private _pendSnap;

    function _snapshot() private {
        for (uint256 i = 0; i < actors.length; i++) {
            IDarkVault.AccountView memory v = vault.getAccount(actors[i]);
            _availSnap[i] = keccak256(abi.encode(v.available));
            _pendSnap[i] = keccak256(abi.encode(v.pending, v.pendingCount));
        }
    }

    /// @dev I3: only `sender`'s available may have changed. I4: only `pendingOwner`'s pending may have.
    function _onlyChanged(address sender, address pendingOwner) private {
        for (uint256 i = 0; i < actors.length; i++) {
            IDarkVault.AccountView memory v = vault.getAccount(actors[i]);
            if (actors[i] != sender) {
                assertEq(keccak256(abi.encode(v.available)), _availSnap[i], "I3 foreign available changed");
            }
            if (actors[i] != pendingOwner) {
                assertEq(
                    keccak256(abi.encode(v.pending, v.pendingCount)), _pendSnap[i], "I4 foreign pending changed"
                );
            }
            isolationChecks++;
        }
    }

    // ----------------------------------------------------- event truth (I14)

    function _lastLog(bytes32 topic0) private returns (Vm.Log memory found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].emitter == address(vault) && logs[i - 1].topics[0] == topic0) return logs[i - 1];
        }
        revert("event not emitted");
    }

    function _checkDepositEvent(address a, uint256 amount) private {
        Vm.Log memory l = _lastLog(IDarkVault.Deposited.selector);
        (uint64 nonceAfter, uint256 amt, uint256[4] memory availAfter, uint128 inflowAfter, uint256 tvlAfter) =
            abi.decode(l.data, (uint64, uint256, uint256[4], uint128, uint256));
        IDarkVault.AccountView memory v = vault.getAccount(a);
        assertEq(address(uint160(uint256(l.topics[1]))), a, "I14 account");
        assertEq(nonceAfter, v.nonce, "I14 nonceAfter");
        assertEq(amt, amount, "I14 amount");
        assertEq(availAfter, _flat(v.available), "I14 availableAfter");
        assertEq(inflowAfter, v.netInflow, "I14 netInflowAfter");
        assertEq(tvlAfter, vault.tvl(), "I14 tvlAfter");
        eventChecks++;
    }

    function _checkWithdrawEvent(address a, address to, uint256 amount) private {
        Vm.Log memory l = _lastLog(IDarkVault.Withdrawn.selector);
        (uint64 nonceAfter, uint256 amt, uint256[4] memory availAfter, uint128 inflowAfter, uint256 tvlAfter) =
            abi.decode(l.data, (uint64, uint256, uint256[4], uint128, uint256));
        IDarkVault.AccountView memory v = vault.getAccount(a);
        assertEq(address(uint160(uint256(l.topics[1]))), a, "I14 account");
        assertEq(address(uint160(uint256(l.topics[2]))), to, "I14 to");
        assertEq(nonceAfter, v.nonce, "I14 nonceAfter");
        assertEq(amt, amount, "I14 amount");
        assertEq(availAfter, _flat(v.available), "I14 availableAfter");
        assertEq(inflowAfter, v.netInflow, "I14 netInflowAfter");
        assertEq(tvlAfter, vault.tvl(), "I14 tvlAfter");
        eventChecks++;
    }

    function _checkApplyEvent(address a, uint64 appliedCount) private {
        Vm.Log memory l = _lastLog(IDarkVault.PendingApplied.selector);
        (uint64 nonceAfter, uint64 applied, uint256[4] memory availAfter) =
            abi.decode(l.data, (uint64, uint64, uint256[4]));
        IDarkVault.AccountView memory v = vault.getAccount(a);
        assertEq(address(uint160(uint256(l.topics[1]))), a, "I14 account");
        assertEq(nonceAfter, v.nonce, "I14 nonceAfter");
        assertEq(applied, appliedCount, "I14 appliedCount");
        assertEq(availAfter, _flat(v.available), "I14 availableAfter");
        eventChecks++;
    }

    function _checkTransferEvent(address from, address to, IDarkVault.TransferCt memory t) private {
        Vm.Log memory l = _lastLog(IDarkVault.ConfidentialTransfer.selector);
        (
            uint64 nonceAfter,
            uint256[6] memory ctOut,
            uint256[4] memory fromAvail,
            uint256[4] memory toPending,
            uint64 toCount,
            ,
        ) = abi.decode(l.data, (uint64, uint256[6], uint256[4], uint256[4], uint64, bytes, bytes));
        IDarkVault.AccountView memory sv = vault.getAccount(from);
        IDarkVault.AccountView memory rv = vault.getAccount(to);
        assertEq(address(uint160(uint256(l.topics[1]))), from, "I14 from");
        assertEq(address(uint160(uint256(l.topics[2]))), to, "I14 to");
        assertEq(nonceAfter, sv.nonce, "I14 fromNonceAfter");
        assertEq(ctOut[0], t.c.x, "I14 ct");
        assertEq(ctOut[4], t.dRecipient.x, "I14 ct dRecipient");
        assertEq(fromAvail, _flat(sv.available), "I14 fromAvailableAfter");
        assertEq(toPending, _flat(rv.pending), "I14 toPendingAfter");
        assertEq(toCount, rv.pendingCount, "I14 toPendingCountAfter");
        eventChecks++;
    }

    // --------------------------------------------------------------- helpers

    function _flat(IDarkVault.Ciphertext memory c) private pure returns (uint256[4] memory) {
        return [c.c.x, c.c.y, c.d.x, c.d.y];
    }

    function assertEq(uint256[4] memory a, uint256[4] memory b, string memory err) internal pure {
        for (uint256 i = 0; i < 4; i++) {
            require(a[i] == b[i], err);
        }
    }

    function _room(uint256 cap, uint256 used) private pure returns (uint256) {
        return cap > used ? cap - used : 0;
    }

    function _blob(uint256 len) private pure returns (bytes memory b) {
        b = new bytes(len);
    }

    function _dummyCt() private view returns (IDarkVault.TransferCt memory t) {
        (t.c.x, t.c.y) = DarkGrumpkin.mulG(3);
        (t.dSender.x, t.dSender.y) = DarkGrumpkin.mulG(4);
        (t.dRecipient.x, t.dRecipient.y) = DarkGrumpkin.mulG(5);
    }
}
