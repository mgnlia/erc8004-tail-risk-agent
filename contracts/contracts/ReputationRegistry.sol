// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ReputationRegistry
 * @dev ERC-8004 compliant Reputation Registry for AI agents.
 *      Allows clients and validators to post feedback signals.
 *      Aggregates scores on-chain for composability.
 *
 *      For the Tail-Risk Agent, reputation signals include:
 *      - Claim payout accuracy (did the agent pay valid claims?)
 *      - Rebalancing effectiveness (did rebalances protect capital?)
 *      - Premium pricing fairness (were premiums actuarially sound?)
 */
contract ReputationRegistry {
    // ─── Types ────────────────────────────────────────────────────────────────

    enum FeedbackType {
        CLAIM_PAYOUT,       // Agent paid a legitimate claim
        REBALANCE,          // Agent executed a protective rebalance
        PREMIUM_PRICING,    // Agent priced a premium
        GENERAL             // General performance feedback
    }

    struct Feedback {
        address reviewer;
        uint256 agentId;
        uint8 score;         // 0-100
        FeedbackType feedbackType;
        string comment;
        uint256 timestamp;
        bytes32 evidenceHash; // hash of off-chain evidence
    }

    struct ReputationSummary {
        uint256 totalFeedback;
        uint256 totalScore;     // sum of all scores
        uint256 claimPayouts;   // # of claim payout feedbacks
        uint256 rebalances;     // # of rebalance feedbacks
        uint256 premiumPricings;
        uint8 latestScore;      // most recent score
    }

    // ─── State ────────────────────────────────────────────────────────────────

    // agentId → list of feedbacks
    mapping(uint256 => Feedback[]) private _feedbacks;

    // agentId → aggregated reputation summary
    mapping(uint256 => ReputationSummary) public reputations;

    // reviewer → agentId → has reviewed (prevent spam)
    mapping(address => mapping(uint256 => uint256)) public lastReviewTimestamp;

    // Minimum time between reviews from same address (1 hour)
    uint256 public constant REVIEW_COOLDOWN = 1 hours;

    // ─── Events ───────────────────────────────────────────────────────────────

    event FeedbackPosted(
        uint256 indexed agentId,
        address indexed reviewer,
        uint8 score,
        FeedbackType feedbackType,
        bytes32 evidenceHash
    );

    event ReputationUpdated(
        uint256 indexed agentId,
        uint256 newAverageScore,
        uint256 totalFeedback
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidScore(uint8 score);
    error ReviewCooldownActive(address reviewer, uint256 cooldownEnds);
    error InvalidAgentId();

    // ─── Core Functions ───────────────────────────────────────────────────────

    /**
     * @notice Post feedback for an agent.
     * @param agentId The ERC-8004 agent token ID.
     * @param score Score from 0-100.
     * @param feedbackType Category of feedback.
     * @param comment Human-readable description.
     * @param evidenceHash Keccak256 hash of off-chain evidence (IPFS CID, tx hash, etc.)
     */
    function postFeedback(
        uint256 agentId,
        uint8 score,
        FeedbackType feedbackType,
        string calldata comment,
        bytes32 evidenceHash
    ) external {
        if (agentId == 0) revert InvalidAgentId();
        if (score > 100) revert InvalidScore(score);

        uint256 cooldownEnd = lastReviewTimestamp[msg.sender][agentId] + REVIEW_COOLDOWN;
        if (block.timestamp < cooldownEnd) {
            revert ReviewCooldownActive(msg.sender, cooldownEnd);
        }

        _feedbacks[agentId].push(Feedback({
            reviewer: msg.sender,
            agentId: agentId,
            score: score,
            feedbackType: feedbackType,
            comment: comment,
            timestamp: block.timestamp,
            evidenceHash: evidenceHash
        }));

        lastReviewTimestamp[msg.sender][agentId] = block.timestamp;

        // Update aggregated reputation
        ReputationSummary storage rep = reputations[agentId];
        rep.totalFeedback++;
        rep.totalScore += score;
        rep.latestScore = score;

        if (feedbackType == FeedbackType.CLAIM_PAYOUT) rep.claimPayouts++;
        else if (feedbackType == FeedbackType.REBALANCE) rep.rebalances++;
        else if (feedbackType == FeedbackType.PREMIUM_PRICING) rep.premiumPricings++;

        uint256 avgScore = rep.totalScore / rep.totalFeedback;

        emit FeedbackPosted(agentId, msg.sender, score, feedbackType, evidenceHash);
        emit ReputationUpdated(agentId, avgScore, rep.totalFeedback);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /**
     * @notice Get the average reputation score for an agent (0-100).
     */
    function getAverageScore(uint256 agentId) external view returns (uint256) {
        ReputationSummary storage rep = reputations[agentId];
        if (rep.totalFeedback == 0) return 0;
        return rep.totalScore / rep.totalFeedback;
    }

    /**
     * @notice Fetch all feedbacks for an agent (paginated).
     */
    function getFeedbacks(
        uint256 agentId,
        uint256 offset,
        uint256 limit
    ) external view returns (Feedback[] memory) {
        Feedback[] storage all = _feedbacks[agentId];
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        uint256 size = end > offset ? end - offset : 0;

        Feedback[] memory result = new Feedback[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = all[offset + i];
        }
        return result;
    }

    /**
     * @notice Get total number of feedbacks for an agent.
     */
    function getFeedbackCount(uint256 agentId) external view returns (uint256) {
        return _feedbacks[agentId].length;
    }

    /**
     * @notice Get a Sharpe-like trust score combining quantity and quality.
     *         score = avg_score × log(1 + total_feedback) / 10
     *         Returns 0-100 normalized.
     */
    function getTrustScore(uint256 agentId) external view returns (uint256) {
        ReputationSummary storage rep = reputations[agentId];
        if (rep.totalFeedback == 0) return 0;

        uint256 avg = rep.totalScore / rep.totalFeedback;
        // Approximate log with integer arithmetic: log2(n) ≈ bit_length - 1
        uint256 logFactor = _log2(rep.totalFeedback + 1);
        uint256 raw = avg * logFactor;

        // Normalize: max avg=100, max logFactor≈17 (for 2^17=131072 feedbacks)
        // raw_max = 1700, normalize to 100
        return raw > 1700 ? 100 : (raw * 100) / 1700;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _log2(uint256 x) internal pure returns (uint256) {
        uint256 result = 0;
        while (x > 1) {
            x >>= 1;
            result++;
        }
        return result;
    }
}
