// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.21;

// The on-chain half of the public-input binding check: the three deployed verifiers accept the real
// proofs, and reject a flip of EVERY public input -- including chain_id, the contract address,
// the account and the nonce, which have no in-circuit relation and so cannot be tested by
// `nargo test` (every binding public input must have a negative test).
//
// No forge-std: gasleft() and require() are all this needs.
import {HonkVerifier as RegisterVerifier} from "../../verifiers/register/Verifier.sol";
import {HonkVerifier as TransferVerifier} from "../../verifiers/transfer/Verifier.sol";
import {HonkVerifier as WithdrawVerifier} from "../../verifiers/withdraw/Verifier.sol";
import {RegisterFixture, TransferFixture, WithdrawFixture} from "./Fixtures.sol";

interface IVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}

contract VerifiersTest {
    event Measured(string name, uint256 value);

    IVerifier registerV;
    IVerifier transferV;
    IVerifier withdrawV;

    function setUp() public {
        registerV = IVerifier(address(new RegisterVerifier()));
        transferV = IVerifier(address(new TransferVerifier()));
        withdrawV = IVerifier(address(new WithdrawVerifier()));
    }

    function _measure(string memory name, IVerifier v, bytes memory proof, bytes32[] memory pi) private {
        uint256 g0 = gasleft();
        bool ok = v.verify(proof, pi);
        uint256 used = g0 - gasleft();
        require(ok, "verify returned false");
        emit Measured(string.concat(name, ".verify_gas"), used);
        emit Measured(string.concat(name, ".bytecode_bytes"), address(v).code.length);
        emit Measured(string.concat(name, ".public_inputs"), pi.length);
        emit Measured(string.concat(name, ".proof_bytes"), proof.length);
        emit Measured(
            string.concat(name, ".calldata_bytes"), abi.encodeCall(IVerifier.verify, (proof, pi)).length
        );
    }

    /// Every public input must be binding: flip one bit of each in turn, the verifier must
    /// never return true.
    function _flipEach(IVerifier v, bytes memory proof, bytes32[] memory pi) private view {
        for (uint256 i = 0; i < pi.length; i++) {
            bytes32 keep = pi[i];
            pi[i] = bytes32(uint256(keep) ^ 1);
            (bool callOk, bytes memory ret) = address(v).staticcall(
                abi.encodeCall(IVerifier.verify, (proof, pi))
            );
            if (callOk) require(!abi.decode(ret, (bool)), "flipped public input accepted");
            pi[i] = keep;
        }
    }

    function test_Register() public {
        _measure("register", registerV, RegisterFixture.PROOF, RegisterFixture.publicInputs());
    }

    function test_RegisterRejectsEveryFlippedInput() public view {
        _flipEach(registerV, RegisterFixture.PROOF, RegisterFixture.publicInputs());
    }

    function test_Transfer() public {
        _measure("transfer", transferV, TransferFixture.PROOF, TransferFixture.publicInputs());
    }

    function test_TransferRejectsEveryFlippedInput() public view {
        _flipEach(transferV, TransferFixture.PROOF, TransferFixture.publicInputs());
    }

    function test_Withdraw() public {
        _measure("withdraw", withdrawV, WithdrawFixture.PROOF, WithdrawFixture.publicInputs());
    }

    function test_WithdrawRejectsEveryFlippedInput() public view {
        _flipEach(withdrawV, WithdrawFixture.PROOF, WithdrawFixture.publicInputs());
    }

    /// A proof is only good for its own circuit: the transfer proof must not verify under the
    /// withdraw verifier, whatever the public inputs.
    function test_ProofsAreNotInterchangeable() public view {
        (bool ok, bytes memory ret) = address(withdrawV).staticcall(
            abi.encodeCall(IVerifier.verify, (TransferFixture.PROOF, TransferFixture.publicInputs()))
        );
        if (ok) require(!abi.decode(ret, (bool)), "transfer proof accepted by withdraw verifier");
    }
}
