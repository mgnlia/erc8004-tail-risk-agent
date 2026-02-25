// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ERC8004ReputationRegistry
 * @notice ERC-8004 compliant Reputation Registry.
 *         Clients post feedback signals after interacting with an agent.
 *         On-chain aggregation provides a composable reputation score;
 *         off-chain services may use the raw events for richer scoring.
 *
 *         Spec: https://eips.ethereum.org/EIPS/eip-8004
 */
contract ERC8004ReputationRegistry {
    // ─── Types ────────────────────────────────────────────────────────────────

    struct Feedback {
        address reviewer;
        uint256 agentId;
        uint8   score;       // 1–100
        string  comment;
        uint256 timestamp;
        bytes32 taskId;      // optional: link to a specific task/job
    }

    // ─── State ────────────────────────────────────────────────────────────────

    /// agentId → list of feedback
    mapping(uint256 => Feedback[]) private _feedback;

    /// agentId → cumulative score sum (for average)
    mapping(uint256 => uint256) public scoreSum;

    /// agentId → total feedback count
    mapping(uint256 => uint256) public feedbackCount;

    // ─── Events ───────────────────────────────────────────────────────────────

    event FeedbackPosted(
        uint256 indexed agentId,
        address indexed reviewer,
        uint8   score,
        bytes32 taskId,
        uint256 timestamp
    );

    // ─── Write ────────────────────────────────────────────────────────────────

    /**
     * @notice Post feedback for an agent.
     * @param agentId   The ERC-8004 agent token ID.
     * @param score     Quality score 1–100.
     * @param comment   Free-text comment (stored on-chain for composability).
     * @param taskId    Optional reference to the job/task this feedback is for.
     */
    function postFeedback(
        uint256 agentId,
        uint8   score,
        string  calldata comment,
        bytes32 taskId
    ) external {
        require(score >= 1 && score <= 100, "ERC8004Rep: score out of range");

        _feedback[agentId].push(Feedback({
            reviewer:  msg.sender,
            agentId:   agentId,
            score:     score,
            comment:   comment,
            timestamp: block.timestamp,
            taskId:    taskId
        }));

        scoreSum[agentId]     += score;
        feedbackCount[agentId] += 1;

        emit FeedbackPosted(agentId, msg.sender, score, taskId, block.timestamp);
    }

    // ─── Read ─────────────────────────────────────────────────────────────────

    /// @notice On-chain average score for an agent (0 if no feedback).
    function averageScore(uint256 agentId) external view returns (uint256) {
        uint256 count = feedbackCount[agentId];
        if (count == 0) return 0;
        return scoreSum[agentId] / count;
    }

    /// @notice Retrieve all feedback entries for an agent.
    function getFeedback(uint256 agentId) external view returns (Feedback[] memory) {
        return _feedback[agentId];
    }

    /// @notice Retrieve the latest N feedback entries.
    function getLatestFeedback(uint256 agentId, uint256 n)
        external
        view
        returns (Feedback[] memory result)
    {
        Feedback[] storage all = _feedback[agentId];
        uint256 total = all.length;
        uint256 count = n < total ? n : total;
        result = new Feedback[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = all[total - count + i];
        }
    }
}
