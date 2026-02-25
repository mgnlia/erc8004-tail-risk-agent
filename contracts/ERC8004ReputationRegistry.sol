// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ERC8004ReputationRegistry
 * @notice ERC-8004 Reputation Registry — on-chain feedback signals for AI agents
 * @dev Stores feedback signals from clients. Scoring/aggregation can happen on-chain
 *      (for composability) or off-chain (for sophisticated algorithms).
 *      Enables insurance pools, auditor networks, and specialized scoring services.
 */
contract ERC8004ReputationRegistry {
    struct FeedbackSignal {
        address reviewer;       // Who posted the feedback
        uint256 agentId;        // Agent being reviewed
        string agentRegistry;   // e.g. "eip155:11155111:0x..."
        int8 score;             // -1 (negative), 0 (neutral), +1 (positive)
        string category;        // e.g. "risk_pricing", "claim_payout", "rebalance"
        string details;         // IPFS hash or plain text description
        uint256 taskId;         // Optional: link to specific task/policy
        uint256 timestamp;
        bool verified;          // Set by Validation Registry
    }

    // agentRegistry => agentId => feedback[]
    mapping(string => mapping(uint256 => FeedbackSignal[])) private _feedback;

    // agentRegistry => agentId => cumulative score
    mapping(string => mapping(uint256 => int256)) private _cumulativeScore;

    // agentRegistry => agentId => total feedback count
    mapping(string => mapping(uint256 => uint256)) private _feedbackCount;

    // Authorized validation registries that can mark feedback as verified
    mapping(address => bool) public authorizedValidators;

    address public owner;

    event FeedbackPosted(
        string indexed agentRegistry,
        uint256 indexed agentId,
        address indexed reviewer,
        int8 score,
        string category,
        uint256 feedbackIndex
    );

    event FeedbackVerified(
        string indexed agentRegistry,
        uint256 indexed agentId,
        uint256 feedbackIndex
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Post a feedback signal for an agent
     * @param agentRegistry The agent's registry identifier (namespace:chainId:address)
     * @param agentId The agent's token ID in the registry
     * @param score -1, 0, or +1
     * @param category Task category (e.g. "risk_pricing", "claim_payout")
     * @param details Description or IPFS hash of detailed feedback
     * @param taskId Optional task/policy ID this feedback relates to
     */
    function postFeedback(
        string calldata agentRegistry,
        uint256 agentId,
        int8 score,
        string calldata category,
        string calldata details,
        uint256 taskId
    ) external returns (uint256 feedbackIndex) {
        require(score >= -1 && score <= 1, "Score must be -1, 0, or 1");

        FeedbackSignal memory signal = FeedbackSignal({
            reviewer: msg.sender,
            agentId: agentId,
            agentRegistry: agentRegistry,
            score: score,
            category: category,
            details: details,
            taskId: taskId,
            timestamp: block.timestamp,
            verified: false
        });

        _feedback[agentRegistry][agentId].push(signal);
        feedbackIndex = _feedback[agentRegistry][agentId].length - 1;

        _cumulativeScore[agentRegistry][agentId] += score;
        _feedbackCount[agentRegistry][agentId]++;

        emit FeedbackPosted(agentRegistry, agentId, msg.sender, score, category, feedbackIndex);
    }

    /**
     * @notice Mark feedback as verified (called by authorized validation registry)
     */
    function markVerified(
        string calldata agentRegistry,
        uint256 agentId,
        uint256 feedbackIndex
    ) external {
        require(authorizedValidators[msg.sender], "Not an authorized validator");
        require(feedbackIndex < _feedback[agentRegistry][agentId].length, "Invalid index");
        _feedback[agentRegistry][agentId][feedbackIndex].verified = true;
        emit FeedbackVerified(agentRegistry, agentId, feedbackIndex);
    }

    /**
     * @notice Get all feedback for an agent
     */
    function getFeedback(
        string calldata agentRegistry,
        uint256 agentId
    ) external view returns (FeedbackSignal[] memory) {
        return _feedback[agentRegistry][agentId];
    }

    /**
     * @notice Get feedback at a specific index
     */
    function getFeedbackAt(
        string calldata agentRegistry,
        uint256 agentId,
        uint256 index
    ) external view returns (FeedbackSignal memory) {
        require(index < _feedback[agentRegistry][agentId].length, "Invalid index");
        return _feedback[agentRegistry][agentId][index];
    }

    /**
     * @notice Get on-chain aggregated reputation score
     * @return score Cumulative score (sum of all -1/0/+1 signals)
     * @return count Total number of feedback signals
     * @return averageScore Average score * 1000 (for 3 decimal precision without floats)
     */
    function getReputationScore(
        string calldata agentRegistry,
        uint256 agentId
    ) external view returns (int256 score, uint256 count, int256 averageScore) {
        score = _cumulativeScore[agentRegistry][agentId];
        count = _feedbackCount[agentRegistry][agentId];
        averageScore = count > 0 ? (score * 1000) / int256(count) : int256(0);
    }

    /**
     * @notice Get only verified feedback count and score (higher trust signal)
     */
    function getVerifiedReputation(
        string calldata agentRegistry,
        uint256 agentId
    ) external view returns (int256 verifiedScore, uint256 verifiedCount) {
        FeedbackSignal[] storage signals = _feedback[agentRegistry][agentId];
        for (uint256 i = 0; i < signals.length; i++) {
            if (signals[i].verified) {
                verifiedScore += signals[i].score;
                verifiedCount++;
            }
        }
    }

    function authorizeValidator(address validator) external onlyOwner {
        authorizedValidators[validator] = true;
    }

    function revokeValidator(address validator) external onlyOwner {
        authorizedValidators[validator] = false;
    }
}
