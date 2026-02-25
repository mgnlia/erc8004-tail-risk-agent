// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ERC8004ValidationRegistry
 * @notice ERC-8004 Validation Registry — independent validator checks for high-stakes tasks
 * @dev Generic hooks for requesting and recording validator checks.
 *      Supports: stake-secured re-execution, zkML proofs, TEE oracles, trusted judges.
 *      For the Tail-Risk Agent: validators re-verify black-swan event data before claims.
 */
contract ERC8004ValidationRegistry {
    // ─── Types ────────────────────────────────────────────────────────────────

    enum ValidationMethod {
        STAKE_REEXECUTION,  // Stakers re-run the computation
        ZKML_PROOF,         // Zero-knowledge ML proof
        TEE_ORACLE,         // Trusted execution environment attestation
        TRUSTED_JUDGE       // Human/DAO judge
    }

    enum ValidationStatus {
        PENDING,
        IN_PROGRESS,
        VALIDATED,
        REJECTED,
        DISPUTED
    }

    struct ValidationRequest {
        uint256 agentId;
        address requester;
        ValidationMethod method;
        ValidationStatus status;
        bytes taskData;         // Encoded task details (e.g., claim parameters)
        bytes result;           // Encoded result from validator
        uint256 stake;          // Stake required from validators
        uint256 deadline;
        uint256 createdAt;
        address[] validators;
        uint256 validatorCount;
        uint256 approvalCount;
        uint256 rejectionCount;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    uint256 private _nextRequestId;

    // requestId → ValidationRequest
    mapping(uint256 => ValidationRequest) public requests;

    // validator → requestId → has voted
    mapping(address => mapping(uint256 => bool)) public hasVoted;

    // validator → stake deposited
    mapping(address => uint256) public validatorStakes;

    // Minimum stake to participate as validator (0.01 ETH)
    uint256 public constant MIN_VALIDATOR_STAKE = 0.01 ether;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ValidationRequested(
        uint256 indexed requestId,
        uint256 indexed agentId,
        ValidationMethod method,
        uint256 stake,
        uint256 deadline
    );

    event ValidationSubmitted(
        uint256 indexed requestId,
        address indexed validator,
        bool approved,
        bytes result
    );

    event ValidationFinalized(
        uint256 indexed requestId,
        ValidationStatus status,
        uint256 approvals,
        uint256 rejections
    );

    event ValidatorStaked(address indexed validator, uint256 amount);
    event ValidatorUnstaked(address indexed validator, uint256 amount);

    // ─── Validator Staking ────────────────────────────────────────────────────

    function stakeAsValidator() external payable {
        require(msg.value >= MIN_VALIDATOR_STAKE, "Insufficient stake");
        validatorStakes[msg.sender] += msg.value;
        emit ValidatorStaked(msg.sender, msg.value);
    }

    function unstake(uint256 amount) external {
        require(validatorStakes[msg.sender] >= amount, "Insufficient stake");
        validatorStakes[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
        emit ValidatorUnstaked(msg.sender, amount);
    }

    // ─── Validation Requests ──────────────────────────────────────────────────

    /**
     * @notice Request validation for a task (e.g., insurance claim)
     * @param agentId The agent requesting validation
     * @param method Validation method to use
     * @param taskData Encoded task details
     * @param validationStake Required stake per validator
     * @param duration Seconds until deadline
     * @return requestId
     */
    function requestValidation(
        uint256 agentId,
        ValidationMethod method,
        bytes calldata taskData,
        uint256 validationStake,
        uint256 duration
    ) external returns (uint256 requestId) {
        requestId = _nextRequestId++;

        ValidationRequest storage req = requests[requestId];
        req.agentId = agentId;
        req.requester = msg.sender;
        req.method = method;
        req.status = ValidationStatus.PENDING;
        req.taskData = taskData;
        req.stake = validationStake;
        req.deadline = block.timestamp + duration;
        req.createdAt = block.timestamp;

        emit ValidationRequested(requestId, agentId, method, validationStake, req.deadline);
    }

    /**
     * @notice Submit a validation result
     * @param requestId The validation request ID
     * @param approved Whether the validator approves the task result
     * @param result Encoded validation result/proof
     */
    function submitValidation(
        uint256 requestId,
        bool approved,
        bytes calldata result
    ) external {
        ValidationRequest storage req = requests[requestId];
        require(req.status == ValidationStatus.PENDING || req.status == ValidationStatus.IN_PROGRESS, "Not open");
        require(block.timestamp <= req.deadline, "Deadline passed");
        require(!hasVoted[msg.sender][requestId], "Already voted");
        require(
            req.stake == 0 || validatorStakes[msg.sender] >= req.stake,
            "Insufficient validator stake"
        );

        hasVoted[msg.sender][requestId] = true;
        req.validators.push(msg.sender);
        req.validatorCount++;
        req.status = ValidationStatus.IN_PROGRESS;

        if (approved) {
            req.approvalCount++;
        } else {
            req.rejectionCount++;
            req.result = result;
        }

        emit ValidationSubmitted(requestId, msg.sender, approved, result);

        // Auto-finalize if quorum reached (3 validators, simple majority)
        if (req.validatorCount >= 3) {
            _finalize(requestId);
        }
    }

    /**
     * @notice Finalize a validation request (callable by anyone after deadline)
     */
    function finalizeValidation(uint256 requestId) external {
        ValidationRequest storage req = requests[requestId];
        require(
            req.status == ValidationStatus.IN_PROGRESS ||
            (req.status == ValidationStatus.PENDING && block.timestamp > req.deadline),
            "Cannot finalize"
        );
        _finalize(requestId);
    }

    function _finalize(uint256 requestId) internal {
        ValidationRequest storage req = requests[requestId];
        if (req.approvalCount > req.rejectionCount) {
            req.status = ValidationStatus.VALIDATED;
        } else {
            req.status = ValidationStatus.REJECTED;
        }
        emit ValidationFinalized(requestId, req.status, req.approvalCount, req.rejectionCount);
    }

    // ─── View Helpers ─────────────────────────────────────────────────────────

    function getRequest(uint256 requestId)
        external
        view
        returns (ValidationRequest memory)
    {
        return requests[requestId];
    }

    function isValidated(uint256 requestId) external view returns (bool) {
        return requests[requestId].status == ValidationStatus.VALIDATED;
    }

    function totalRequests() external view returns (uint256) {
        return _nextRequestId;
    }
}
