// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ValidationRegistry
 * @dev ERC-8004 compliant Validation Registry.
 *      Generic hooks for requesting and recording independent validator checks.
 *
 *      For the Tail-Risk Agent, validation covers:
 *      - Premium pricing decisions (was the price actuarially fair?)
 *      - Rebalancing decisions (was the rebalance justified by risk data?)
 *      - Claim processing (was the claim legitimate?)
 */
contract ValidationRegistry {
    // ─── Types ────────────────────────────────────────────────────────────────

    enum ValidationStatus {
        PENDING,
        VALIDATED,
        REJECTED,
        DISPUTED
    }

    enum ValidationKind {
        PREMIUM_PRICING,
        REBALANCE_DECISION,
        CLAIM_PROCESSING,
        RISK_ASSESSMENT
    }

    struct ValidationRequest {
        uint256 requestId;
        uint256 agentId;
        ValidationKind kind;
        ValidationStatus status;
        address requester;
        address validator;
        bytes32 dataHash;       // hash of the decision data
        string dataURI;         // IPFS URI to full decision data
        uint256 requestedAt;
        uint256 resolvedAt;
        uint8 validationScore;  // 0-100 (set by validator)
        string validatorNote;
        uint256 stakeAmount;    // ETH staked by validator (crypto-economic trust)
    }

    // ─── State ────────────────────────────────────────────────────────────────

    uint256 private _nextRequestId;

    mapping(uint256 => ValidationRequest) public requests;

    // agentId → list of request IDs
    mapping(uint256 => uint256[]) public agentRequests;

    // Registered validators (staked)
    mapping(address => uint256) public validatorStake;

    // Minimum stake to become a validator (0.01 ETH on testnet)
    uint256 public constant MIN_VALIDATOR_STAKE = 0.01 ether;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ValidationRequested(
        uint256 indexed requestId,
        uint256 indexed agentId,
        ValidationKind kind,
        bytes32 dataHash
    );

    event ValidationResolved(
        uint256 indexed requestId,
        uint256 indexed agentId,
        ValidationStatus status,
        uint8 score,
        address validator
    );

    event ValidatorRegistered(address indexed validator, uint256 stake);
    event ValidatorSlashed(address indexed validator, uint256 slashedAmount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InsufficientStake(uint256 required, uint256 provided);
    error RequestNotFound(uint256 requestId);
    error AlreadyResolved(uint256 requestId);
    error NotValidator(address caller);
    error InvalidScore(uint8 score);

    // ─── Validator Registration ───────────────────────────────────────────────

    /**
     * @notice Register as a validator by staking ETH.
     */
    function registerValidator() external payable {
        if (msg.value < MIN_VALIDATOR_STAKE) {
            revert InsufficientStake(MIN_VALIDATOR_STAKE, msg.value);
        }
        validatorStake[msg.sender] += msg.value;
        emit ValidatorRegistered(msg.sender, validatorStake[msg.sender]);
    }

    // ─── Validation Requests ──────────────────────────────────────────────────

    /**
     * @notice Request validation for an agent decision.
     * @param agentId The agent requesting validation.
     * @param kind The type of decision being validated.
     * @param dataHash Keccak256 hash of the decision data.
     * @param dataURI URI to full decision data (IPFS or HTTPS).
     */
    function requestValidation(
        uint256 agentId,
        ValidationKind kind,
        bytes32 dataHash,
        string calldata dataURI
    ) external returns (uint256 requestId) {
        requestId = ++_nextRequestId;

        requests[requestId] = ValidationRequest({
            requestId: requestId,
            agentId: agentId,
            kind: kind,
            status: ValidationStatus.PENDING,
            requester: msg.sender,
            validator: address(0),
            dataHash: dataHash,
            dataURI: dataURI,
            requestedAt: block.timestamp,
            resolvedAt: 0,
            validationScore: 0,
            validatorNote: "",
            stakeAmount: 0
        });

        agentRequests[agentId].push(requestId);

        emit ValidationRequested(requestId, agentId, kind, dataHash);
    }

    /**
     * @notice Resolve a validation request (called by a registered validator).
     * @param requestId The request to resolve.
     * @param status VALIDATED or REJECTED.
     * @param score Quality score 0-100.
     * @param note Human-readable validation note.
     */
    function resolveValidation(
        uint256 requestId,
        ValidationStatus status,
        uint8 score,
        string calldata note
    ) external {
        if (validatorStake[msg.sender] < MIN_VALIDATOR_STAKE) {
            revert NotValidator(msg.sender);
        }
        if (score > 100) revert InvalidScore(score);

        ValidationRequest storage req = requests[requestId];
        if (req.requestId == 0) revert RequestNotFound(requestId);
        if (req.status != ValidationStatus.PENDING) revert AlreadyResolved(requestId);

        req.status = status;
        req.validator = msg.sender;
        req.resolvedAt = block.timestamp;
        req.validationScore = score;
        req.validatorNote = note;
        req.stakeAmount = validatorStake[msg.sender];

        emit ValidationResolved(requestId, req.agentId, status, score, msg.sender);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /**
     * @notice Get all validation request IDs for an agent.
     */
    function getAgentRequests(uint256 agentId) external view returns (uint256[] memory) {
        return agentRequests[agentId];
    }

    /**
     * @notice Get count of validated (approved) requests for an agent.
     */
    function getValidatedCount(uint256 agentId) external view returns (uint256 count) {
        uint256[] storage ids = agentRequests[agentId];
        for (uint256 i = 0; i < ids.length; i++) {
            if (requests[ids[i]].status == ValidationStatus.VALIDATED) {
                count++;
            }
        }
    }

    /**
     * @notice Get average validation score for an agent.
     */
    function getAverageValidationScore(uint256 agentId) external view returns (uint256) {
        uint256[] storage ids = agentRequests[agentId];
        uint256 total = 0;
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            ValidationRequest storage req = requests[ids[i]];
            if (req.status == ValidationStatus.VALIDATED) {
                total += req.validationScore;
                count++;
            }
        }
        return count > 0 ? total / count : 0;
    }

    /**
     * @notice Get total number of validation requests.
     */
    function totalRequests() external view returns (uint256) {
        return _nextRequestId;
    }
}
