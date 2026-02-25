// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentWallet
 * @dev EIP-1271 smart contract wallet for the Tail-Risk Protection Agent.
 *      Allows the AI agent to sign transactions on-chain, enabling:
 *      - Autonomous claim payments
 *      - Rebalancing approvals
 *      - Premium collection
 *
 *      Implements EIP-1271 isValidSignature() for smart contract signature validation.
 */
contract AgentWallet is EIP712, Ownable {
    using ECDSA for bytes32;

    // ─── EIP-1271 Magic Values ────────────────────────────────────────────────

    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;
    bytes4 private constant INVALID_VALUE = 0xffffffff;

    // ─── Types ────────────────────────────────────────────────────────────────

    struct AgentAction {
        address target;
        uint256 value;
        bytes data;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 private constant AGENT_ACTION_TYPEHASH = keccak256(
        "AgentAction(address target,uint256 value,bytes data,uint256 nonce,uint256 deadline)"
    );

    // ─── State ────────────────────────────────────────────────────────────────

    uint256 public nonce;

    // Authorized signers (the AI agent's hot key)
    mapping(address => bool) public authorizedSigners;

    // Spending limits per target contract
    mapping(address => uint256) public dailyLimit;
    mapping(address => uint256) public dailySpent;
    mapping(address => uint256) public lastSpendDay;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ActionExecuted(
        address indexed target,
        uint256 value,
        bytes data,
        uint256 nonce
    );

    event SignerAuthorized(address indexed signer, bool authorized);
    event DailyLimitSet(address indexed target, uint256 limit);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error DeadlineExpired(uint256 deadline, uint256 current);
    error InvalidNonce(uint256 expected, uint256 provided);
    error DailyLimitExceeded(address target, uint256 limit, uint256 spent);
    error UnauthorizedSigner(address signer);
    error ExecutionFailed(bytes returnData);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address agentSigner) EIP712("AgentWallet", "1") Ownable(msg.sender) {
        authorizedSigners[agentSigner] = true;
        emit SignerAuthorized(agentSigner, true);
    }

    // ─── EIP-1271 ─────────────────────────────────────────────────────────────

    /**
     * @notice Validate a signature against this wallet's authorized signers.
     * @dev Implements EIP-1271 for smart contract signature validation.
     */
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) external view returns (bytes4) {
        address signer = hash.recover(signature);
        if (authorizedSigners[signer]) {
            return MAGIC_VALUE;
        }
        return INVALID_VALUE;
    }

    // ─── Action Execution ─────────────────────────────────────────────────────

    /**
     * @notice Execute an agent action (signed by authorized signer).
     * @param action The action to execute.
     * @param signature EIP-712 signature from an authorized signer.
     */
    function execute(
        AgentAction calldata action,
        bytes calldata signature
    ) external returns (bytes memory returnData) {
        // Validate deadline
        if (block.timestamp > action.deadline) {
            revert DeadlineExpired(action.deadline, block.timestamp);
        }

        // Validate nonce
        if (action.nonce != nonce) {
            revert InvalidNonce(nonce, action.nonce);
        }

        // Validate signature
        bytes32 structHash = keccak256(abi.encode(
            AGENT_ACTION_TYPEHASH,
            action.target,
            action.value,
            keccak256(action.data),
            action.nonce,
            action.deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);

        if (!authorizedSigners[signer]) {
            revert UnauthorizedSigner(signer);
        }

        // Check daily spending limit
        if (action.value > 0 && dailyLimit[action.target] > 0) {
            uint256 today = block.timestamp / 1 days;
            if (lastSpendDay[action.target] < today) {
                dailySpent[action.target] = 0;
                lastSpendDay[action.target] = today;
            }
            if (dailySpent[action.target] + action.value > dailyLimit[action.target]) {
                revert DailyLimitExceeded(
                    action.target,
                    dailyLimit[action.target],
                    dailySpent[action.target]
                );
            }
            dailySpent[action.target] += action.value;
        }

        nonce++;

        // Execute the action
        bool success;
        (success, returnData) = action.target.call{value: action.value}(action.data);
        if (!success) revert ExecutionFailed(returnData);

        emit ActionExecuted(action.target, action.value, action.data, action.nonce);
    }

    // ─── Owner Management ─────────────────────────────────────────────────────

    function setSigner(address signer, bool authorized) external onlyOwner {
        authorizedSigners[signer] = authorized;
        emit SignerAuthorized(signer, authorized);
    }

    function setDailyLimit(address target, uint256 limit) external onlyOwner {
        dailyLimit[target] = limit;
        emit DailyLimitSet(target, limit);
    }

    // Allow receiving ETH
    receive() external payable {}
    fallback() external payable {}
}
