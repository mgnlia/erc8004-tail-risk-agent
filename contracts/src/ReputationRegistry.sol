// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ERC-8004 Reputation Registry
/// @notice Standard interface for posting and fetching agent feedback signals
/// @dev On-chain aggregation for composability; off-chain scoring for sophistication
contract ReputationRegistry {
    // ── Types ─────────────────────────────────────────────────────────────

    struct Feedback {
        uint256 agentId;       // ERC-8004 agent ID
        address reviewer;      // Address posting feedback
        uint8 score;           // 0-100 score
        string comment;        // Optional comment
        bytes32 taskHash;      // Hash of the task that was reviewed
        uint256 timestamp;
        bool isVerified;       // True if verified by a validation hook
    }

    // ── State ─────────────────────────────────────────────────────────────

    // agentId => list of feedback
    mapping(uint256 => Feedback[]) private _feedbacks;

    // agentId => cumulative score sum
    mapping(uint256 => uint256) private _scoreSum;

    // agentId => feedback count
    mapping(uint256 => uint256) private _feedbackCount;

    // agentId => reviewer => has reviewed (prevent spam)
    mapping(uint256 => mapping(address => bool)) private _hasReviewed;

    // ── Events ────────────────────────────────────────────────────────────

    event FeedbackPosted(
        uint256 indexed agentId,
        address indexed reviewer,
        uint8 score,
        bytes32 taskHash,
        uint256 feedbackIndex
    );

    // ── Post Feedback ─────────────────────────────────────────────────────

    /// @notice Post feedback for an agent after task completion
    /// @param agentId The ERC-8004 agent ID
    /// @param score Score from 0-100
    /// @param comment Optional text comment
    /// @param taskHash Hash identifying the task (prevents duplicate feedback)
    function postFeedback(
        uint256 agentId,
        uint8 score,
        string calldata comment,
        bytes32 taskHash
    ) external {
        require(score <= 100, "Score must be 0-100");
        require(!_hasReviewed[agentId][msg.sender], "Already reviewed");

        Feedback memory fb = Feedback({
            agentId: agentId,
            reviewer: msg.sender,
            score: score,
            comment: comment,
            taskHash: taskHash,
            timestamp: block.timestamp,
            isVerified: false
        });

        uint256 idx = _feedbacks[agentId].length;
        _feedbacks[agentId].push(fb);
        _scoreSum[agentId] += score;
        _feedbackCount[agentId]++;
        _hasReviewed[agentId][msg.sender] = true;

        emit FeedbackPosted(agentId, msg.sender, score, taskHash, idx);
    }

    // ── Query ─────────────────────────────────────────────────────────────

    /// @notice Get the on-chain average reputation score (0-100)
    function getAverageScore(uint256 agentId) external view returns (uint256) {
        uint256 count = _feedbackCount[agentId];
        if (count == 0) return 0;
        return _scoreSum[agentId] / count;
    }

    /// @notice Get total feedback count for an agent
    function getFeedbackCount(uint256 agentId) external view returns (uint256) {
        return _feedbackCount[agentId];
    }

    /// @notice Get a specific feedback entry
    function getFeedback(uint256 agentId, uint256 index) external view returns (Feedback memory) {
        require(index < _feedbacks[agentId].length, "Index out of bounds");
        return _feedbacks[agentId][index];
    }

    /// @notice Get all feedbacks for an agent (paginated)
    function getFeedbacks(
        uint256 agentId,
        uint256 offset,
        uint256 limit
    ) external view returns (Feedback[] memory results) {
        uint256 total = _feedbacks[agentId].length;
        if (offset >= total) return new Feedback[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        results = new Feedback[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            results[i - offset] = _feedbacks[agentId][i];
        }
    }

    /// @notice Check if an address has reviewed an agent
    function hasReviewed(uint256 agentId, address reviewer) external view returns (bool) {
        return _hasReviewed[agentId][reviewer];
    }
}
