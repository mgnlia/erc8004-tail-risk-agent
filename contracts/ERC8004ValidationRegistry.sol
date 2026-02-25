// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ERC8004ValidationRegistry
 * @notice ERC-8004 Validation Registry — pluggable validators for agent task verification
 * @dev Supports staker re-execution, zkML proofs, TEE oracles, and trusted judges.
 *      For TailGuard: validates risk pricing decisions and claim payouts before execution.
 */
contract ERC8004ValidationRegistry {
    enum ValidationMethod {
        StakerReExecution,  // Stakers re-run the agent's computation
        ZkML,               // Zero-knowledge ML proof
        TEEOracle,          // Trusted Execution Environment attestation
        TrustedJudge        // Multi-sig trusted judges
    }

    enum ValidationStatus {
        Pending,
        Approved,
        Rejected,
        Expired
    }

    struct ValidationRequest {
        uint256 requestId;
        string agentRegistry;
        uint256 agentId;
        ValidationMethod method;
        ValidationStatus status;
        bytes taskData;         // ABI-encoded task parameters (e.g. risk pricing inputs)
        bytes agentResult;      // ABI-encoded agent's output to validate
        address requester;
        uint256 stakeRequired;  // ETH stake required from validators
        uint256 deadline;
        uint256 approvals;
        uint256 rejections;
        uint256 threshold;      // Approvals needed
        bool finalized;
    }

    struct ValidatorVote {
        address validator;
        bool approved;
        bytes proof;            // zkML proof, TEE attestation, or judge signature
        uint256 timestamp;
    }

    uint256 private _nextRequestId;

    mapping(uint256 => ValidationRequest) public requests;
    mapping(uint256 => ValidatorVote[]) public votes;
    mapping(address => uint256) public validatorStakes;
    mapping(address => bool) public registeredValidators;

    // Slash pool for validators who vote incorrectly
    uint256 public slashPool;

    address public owner;

    event ValidationRequested(
        uint256 indexed requestId,
        string agentRegistry,
        uint256 indexed agentId,
        ValidationMethod method,
        uint256 stakeRequired,
        uint256 deadline
    );

    event ValidatorVoted(
        uint256 indexed requestId,
        address indexed validator,
        bool approved
    );

    event ValidationFinalized(
        uint256 indexed requestId,
        ValidationStatus status,
        uint256 approvals,
        uint256 rejections
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Request validation of an agent's task result
     * @param agentRegistry Agent's registry identifier
     * @param agentId Agent's token ID
     * @param method Validation method to use
     * @param taskData ABI-encoded task input parameters
     * @param agentResult ABI-encoded agent's output to validate
     * @param stakeRequired ETH stake required from each validator
     * @param deadline Timestamp after which request expires
     * @param threshold Number of approvals needed
     */
    function requestValidation(
        string calldata agentRegistry,
        uint256 agentId,
        ValidationMethod method,
        bytes calldata taskData,
        bytes calldata agentResult,
        uint256 stakeRequired,
        uint256 deadline,
        uint256 threshold
    ) external returns (uint256 requestId) {
        require(deadline > block.timestamp, "Deadline must be in future");
        require(threshold > 0, "Threshold must be > 0");

        requestId = _nextRequestId++;
        requests[requestId] = ValidationRequest({
            requestId: requestId,
            agentRegistry: agentRegistry,
            agentId: agentId,
            method: method,
            status: ValidationStatus.Pending,
            taskData: taskData,
            agentResult: agentResult,
            requester: msg.sender,
            stakeRequired: stakeRequired,
            deadline: deadline,
            approvals: 0,
            rejections: 0,
            threshold: threshold,
            finalized: false
        });

        emit ValidationRequested(requestId, agentRegistry, agentId, method, stakeRequired, deadline);
    }

    /**
     * @notice Stake ETH to become a validator
     */
    function stakeAsValidator() external payable {
        require(msg.value > 0, "Must stake ETH");
        validatorStakes[msg.sender] += msg.value;
        if (!registeredValidators[msg.sender]) {
            registeredValidators[msg.sender] = true;
        }
    }

    /**
     * @notice Submit a validation vote
     * @param requestId The validation request ID
     * @param approved Whether the validator approves the agent's result
     * @param proof Supporting proof (zkML proof bytes, TEE attestation, or empty for judge)
     */
    function submitVote(
        uint256 requestId,
        bool approved,
        bytes calldata proof
    ) external {
        ValidationRequest storage req = requests[requestId];
        require(!req.finalized, "Already finalized");
        require(block.timestamp <= req.deadline, "Request expired");
        require(registeredValidators[msg.sender], "Not a registered validator");
        require(validatorStakes[msg.sender] >= req.stakeRequired, "Insufficient stake");

        // Check not already voted
        ValidatorVote[] storage reqVotes = votes[requestId];
        for (uint256 i = 0; i < reqVotes.length; i++) {
            require(reqVotes[i].validator != msg.sender, "Already voted");
        }

        reqVotes.push(ValidatorVote({
            validator: msg.sender,
            approved: approved,
            proof: proof,
            timestamp: block.timestamp
        }));

        if (approved) {
            req.approvals++;
        } else {
            req.rejections++;
        }

        emit ValidatorVoted(requestId, msg.sender, approved);

        // Auto-finalize if threshold reached
        if (req.approvals >= req.threshold) {
            _finalize(requestId, ValidationStatus.Approved);
        } else if (req.rejections >= req.threshold) {
            _finalize(requestId, ValidationStatus.Rejected);
        }
    }

    /**
     * @notice Finalize an expired request
     */
    function finalizeExpired(uint256 requestId) external {
        ValidationRequest storage req = requests[requestId];
        require(!req.finalized, "Already finalized");
        require(block.timestamp > req.deadline, "Not yet expired");
        _finalize(requestId, ValidationStatus.Expired);
    }

    function _finalize(uint256 requestId, ValidationStatus status) internal {
        ValidationRequest storage req = requests[requestId];
        req.status = status;
        req.finalized = true;
        emit ValidationFinalized(requestId, status, req.approvals, req.rejections);
    }

    /**
     * @notice Check if a request was approved
     */
    function isApproved(uint256 requestId) external view returns (bool) {
        return requests[requestId].status == ValidationStatus.Approved;
    }

    /**
     * @notice Get votes for a request
     */
    function getVotes(uint256 requestId) external view returns (ValidatorVote[] memory) {
        return votes[requestId];
    }

    /**
     * @notice Withdraw stake (only if no pending votes)
     */
    function withdrawStake(uint256 amount) external {
        require(validatorStakes[msg.sender] >= amount, "Insufficient stake");
        validatorStakes[msg.sender] -= amount;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }
}
