// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC8004Validation
 * @notice Interface for the ERC-8004 Validation Registry
 * @dev Based on EIP-8004: Trustless Agents
 *      https://eips.ethereum.org/EIPS/eip-8004
 *
 * The Validation Registry provides generic hooks for requesting and recording
 * independent validator checks (stakers re-running the job, zkML verifiers,
 * TEE oracles, trusted judges).
 */
interface IERC8004Validation {
    enum ValidationStatus {
        Pending,
        InProgress,
        Confirmed,
        Rejected,
        Disputed
    }

    enum ValidationType {
        Reexecution,    // Stakers re-run the task
        ZkML,           // Zero-knowledge ML proof
        TEEOracle,      // Trusted Execution Environment attestation
        TrustedJudge    // Trusted human/committee judge
    }

    struct ValidationRequest {
        uint256 requestId;
        uint256 agentId;
        bytes32 taskId;
        ValidationType validationType;
        bytes taskData;         // Encoded task parameters
        bytes expectedOutput;   // What the agent claims to have produced
        uint256 stake;          // ETH staked by requester
        uint256 deadline;       // Timestamp by which validation must complete
        ValidationStatus status;
        address requester;
    }

    struct ValidationResult {
        uint256 requestId;
        bool isValid;
        bytes proof;            // ZK proof, TEE attestation, or judge signature
        address validator;
        uint256 timestamp;
        bytes metadata;
    }

    /// @notice Emitted when a validation is requested
    event ValidationRequested(
        uint256 indexed requestId,
        uint256 indexed agentId,
        bytes32 indexed taskId,
        ValidationType validationType
    );

    /// @notice Emitted when validation result is recorded
    event ValidationRecorded(
        uint256 indexed requestId,
        bool isValid,
        address validator
    );

    /**
     * @notice Request validation for an agent's task execution
     * @param agentId The agent being validated
     * @param taskId Reference to the specific task
     * @param validationType Type of validation to perform
     * @param taskData Encoded task parameters
     * @param expectedOutput What the agent claims to have produced
     * @param deadline Timestamp by which validation must complete
     * @return requestId The validation request ID
     */
    function requestValidation(
        uint256 agentId,
        bytes32 taskId,
        ValidationType validationType,
        bytes calldata taskData,
        bytes calldata expectedOutput,
        uint256 deadline
    ) external payable returns (uint256 requestId);

    /**
     * @notice Record a validation result
     * @param requestId The validation request ID
     * @param isValid Whether the agent's execution was valid
     * @param proof Cryptographic proof or attestation
     * @param metadata Additional metadata
     */
    function recordValidation(
        uint256 requestId,
        bool isValid,
        bytes calldata proof,
        bytes calldata metadata
    ) external;

    /**
     * @notice Get a validation request
     * @param requestId The request ID
     * @return request The validation request
     */
    function getRequest(
        uint256 requestId
    ) external view returns (ValidationRequest memory request);

    /**
     * @notice Get the validation result for a request
     * @param requestId The request ID
     * @return result The validation result
     */
    function getResult(
        uint256 requestId
    ) external view returns (ValidationResult memory result);

    /**
     * @notice Check if a specific task has been validated
     * @param agentId The agent ID
     * @param taskId The task ID
     * @return isValidated Whether the task has been validated
     * @return isValid The validation outcome
     */
    function isTaskValidated(
        uint256 agentId,
        bytes32 taskId
    ) external view returns (bool isValidated, bool isValid);
}
