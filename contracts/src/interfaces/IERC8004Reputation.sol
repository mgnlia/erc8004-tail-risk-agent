// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC8004Reputation
 * @notice Interface for the ERC-8004 Reputation Registry
 * @dev Based on EIP-8004: Trustless Agents
 *      https://eips.ethereum.org/EIPS/eip-8004
 *
 * The Reputation Registry provides a standard interface for posting and fetching
 * feedback signals. Scoring and aggregation occur both on-chain (for composability)
 * and off-chain (for sophisticated algorithms).
 */
interface IERC8004Reputation {
    /// @notice Feedback signal posted for an agent
    struct FeedbackSignal {
        uint256 agentId;        // The agent being reviewed
        address reviewer;       // Who submitted the feedback
        uint8 score;            // 0-100 score
        string[] tags;          // Descriptive tags (e.g. "accurate", "fast", "reliable")
        bytes metadata;         // Additional structured metadata
        uint256 timestamp;      // When feedback was posted
        bytes32 taskId;         // Optional: reference to specific task
    }

    /// @notice Aggregated reputation score for an agent
    struct ReputationScore {
        uint256 agentId;
        uint256 totalFeedback;
        uint256 aggregateScore;  // Weighted average * 100 (0-10000)
        uint256 lastUpdated;
    }

    /// @notice Emitted when feedback is posted
    event FeedbackPosted(
        uint256 indexed agentId,
        address indexed reviewer,
        uint8 score,
        bytes32 taskId
    );

    /// @notice Emitted when aggregate score is updated
    event ScoreUpdated(uint256 indexed agentId, uint256 newScore, uint256 totalFeedback);

    /**
     * @notice Post feedback for an agent
     * @param agentId The agent being reviewed
     * @param score Score from 0-100
     * @param tags Descriptive tags
     * @param metadata Additional structured metadata
     * @param taskId Optional task reference (bytes32(0) if none)
     */
    function postFeedback(
        uint256 agentId,
        uint8 score,
        string[] calldata tags,
        bytes calldata metadata,
        bytes32 taskId
    ) external;

    /**
     * @notice Get feedback for an agent
     * @param agentId The agent's ID
     * @param offset Pagination offset
     * @param limit Max results to return
     * @return feedback Array of feedback signals
     */
    function getFeedback(
        uint256 agentId,
        uint256 offset,
        uint256 limit
    ) external view returns (FeedbackSignal[] memory feedback);

    /**
     * @notice Get the aggregated reputation score for an agent
     * @param agentId The agent's ID
     * @return score The aggregated reputation score
     */
    function getScore(uint256 agentId) external view returns (ReputationScore memory score);

    /**
     * @notice Get scores for multiple agents (batch)
     * @param agentIds Array of agent IDs
     * @return scores Array of reputation scores
     */
    function getScores(
        uint256[] calldata agentIds
    ) external view returns (ReputationScore[] memory scores);
}
