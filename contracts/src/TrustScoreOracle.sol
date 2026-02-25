// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./IdentityRegistry.sol";

/**
 * @title TrustScoreOracle
 * @notice ERC-8004 compliant trust score system.
 *         Records verifiable on-chain trust scores for agents based on
 *         historical performance, claim accuracy, and capital management.
 *
 *         Scores are in basis points (0–10000 = 0%–100%).
 *         Score components:
 *           - claimAccuracy: How often agent's risk assessments were correct
 *           - capitalPreservation: % of capital preserved during tail events
 *           - responseTime: Latency score for autonomous actions
 *           - overall: Weighted composite score
 */
contract TrustScoreOracle is Ownable {
    // ── Errors ─────────────────────────────────────────────────────────────────
    error NotUpdater();
    error InvalidScore();
    error AgentNotFound();

    // ── Events ─────────────────────────────────────────────────────────────────
    event ScoreUpdated(
        uint256 indexed agentId,
        uint16 claimAccuracy,
        uint16 capitalPreservation,
        uint16 responseTime,
        uint16 overall,
        uint256 timestamp
    );
    event UpdaterSet(address updater, bool authorized);
    event ScoreDecayed(uint256 indexed agentId, uint16 newOverall);

    // ── Structs ────────────────────────────────────────────────────────────────
    struct TrustScore {
        uint16 claimAccuracy;       // bps: 0–10000
        uint16 capitalPreservation; // bps: 0–10000
        uint16 responseTime;        // bps: 0–10000
        uint16 overall;             // bps: 0–10000
        uint256 lastUpdated;
        uint256 updateCount;
    }

    struct ScoreSnapshot {
        uint16 overall;
        uint256 timestamp;
    }

    // ── Constants ──────────────────────────────────────────────────────────────
    uint16 public constant MAX_SCORE = 10000;
    uint256 public constant DECAY_PERIOD = 30 days;
    uint16 public constant DECAY_RATE_BPS = 500; // 5% decay per period

    // Weights for overall score (must sum to 10000)
    uint16 public constant W_CLAIM_ACCURACY = 4000;       // 40%
    uint16 public constant W_CAPITAL_PRESERVATION = 4000; // 40%
    uint16 public constant W_RESPONSE_TIME = 2000;        // 20%

    // ── State ──────────────────────────────────────────────────────────────────
    IdentityRegistry public immutable registry;

    /// @dev Authorized score updaters (oracle operators)
    mapping(address => bool) public updaters;

    /// @dev agentId → current trust score
    mapping(uint256 => TrustScore) private _scores;

    /// @dev agentId → score history (last 10 snapshots)
    mapping(uint256 => ScoreSnapshot[10]) private _history;
    mapping(uint256 => uint8) private _historyIndex;

    // ── Constructor ────────────────────────────────────────────────────────────
    constructor(address registryAddress) Ownable(msg.sender) {
        registry = IdentityRegistry(registryAddress);
        updaters[msg.sender] = true;
    }

    // ── Modifiers ──────────────────────────────────────────────────────────────
    modifier onlyUpdater() {
        if (!updaters[msg.sender]) revert NotUpdater();
        _;
    }

    // ── External Functions ─────────────────────────────────────────────────────

    /**
     * @notice Update trust score for an agent.
     * @param agentId The agent to score.
     * @param claimAccuracy Claim accuracy score in bps.
     * @param capitalPreservation Capital preservation score in bps.
     * @param responseTime Response time score in bps.
     */
    function updateScore(
        uint256 agentId,
        uint16 claimAccuracy,
        uint16 capitalPreservation,
        uint16 responseTime
    ) external onlyUpdater {
        if (claimAccuracy > MAX_SCORE || capitalPreservation > MAX_SCORE || responseTime > MAX_SCORE)
            revert InvalidScore();

        uint16 overall = _computeOverall(claimAccuracy, capitalPreservation, responseTime);

        TrustScore storage score = _scores[agentId];
        score.claimAccuracy = claimAccuracy;
        score.capitalPreservation = capitalPreservation;
        score.responseTime = responseTime;
        score.overall = overall;
        score.lastUpdated = block.timestamp;
        score.updateCount++;

        // Store snapshot in circular buffer
        uint8 idx = _historyIndex[agentId];
        _history[agentId][idx] = ScoreSnapshot({
            overall: overall,
            timestamp: block.timestamp
        });
        _historyIndex[agentId] = (idx + 1) % 10;

        emit ScoreUpdated(agentId, claimAccuracy, capitalPreservation, responseTime, overall, block.timestamp);
    }

    /**
     * @notice Apply time-based decay to a score (callable by anyone).
     *         Decays overall score by DECAY_RATE_BPS per DECAY_PERIOD elapsed.
     */
    function applyDecay(uint256 agentId) external {
        TrustScore storage score = _scores[agentId];
        if (score.lastUpdated == 0) revert AgentNotFound();

        uint256 elapsed = block.timestamp - score.lastUpdated;
        uint256 periods = elapsed / DECAY_PERIOD;
        if (periods == 0) return;

        uint256 decayed = score.overall;
        for (uint256 i = 0; i < periods && decayed > 0; i++) {
            decayed = (decayed * (MAX_SCORE - DECAY_RATE_BPS)) / MAX_SCORE;
        }

        score.overall = uint16(decayed);
        score.lastUpdated = block.timestamp;

        emit ScoreDecayed(agentId, uint16(decayed));
    }

    /**
     * @notice Get the current trust score for an agent.
     */
    function getScore(uint256 agentId) external view returns (TrustScore memory) {
        return _scores[agentId];
    }

    /**
     * @notice Get the current overall score (convenience).
     */
    function getOverallScore(uint256 agentId) external view returns (uint16) {
        return _scores[agentId].overall;
    }

    /**
     * @notice Check if an agent meets a minimum trust threshold.
     */
    function meetsThreshold(uint256 agentId, uint16 minScore) external view returns (bool) {
        return _scores[agentId].overall >= minScore;
    }

    /**
     * @notice Get score history for an agent (up to last 10 snapshots).
     */
    function getHistory(uint256 agentId) external view returns (ScoreSnapshot[10] memory) {
        return _history[agentId];
    }

    /**
     * @notice Authorize or revoke a score updater.
     */
    function setUpdater(address updater, bool authorized) external onlyOwner {
        updaters[updater] = authorized;
        emit UpdaterSet(updater, authorized);
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    function _computeOverall(
        uint16 claimAccuracy,
        uint16 capitalPreservation,
        uint16 responseTime
    ) internal pure returns (uint16) {
        uint256 weighted =
            (uint256(claimAccuracy) * W_CLAIM_ACCURACY +
             uint256(capitalPreservation) * W_CAPITAL_PRESERVATION +
             uint256(responseTime) * W_RESPONSE_TIME) / MAX_SCORE;
        return uint16(weighted);
    }
}
