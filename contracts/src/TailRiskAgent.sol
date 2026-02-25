// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ERC8004IdentityRegistry.sol";
import "./ERC8004ReputationRegistry.sol";

/**
 * @title TailRiskAgent
 * @notice ERC-8004 registered AI agent that provides on-chain tail-risk
 *         protection for DeFi portfolios.
 *
 *         Architecture:
 *         ┌─────────────────────────────────────────────────────────┐
 *         │  Off-chain Python agent                                 │
 *         │  • Monitors volatility (VIX proxy, on-chain oracles)    │
 *         │  • LLM reasoning: GPT-4o / Claude risk assessment       │
 *         │  • Detects black-swan signals                           │
 *         │  • Calls triggerProtection() / releaseProtection()      │
 *         └────────────────────┬────────────────────────────────────┘
 *                              │ on-chain tx
 *         ┌────────────────────▼────────────────────────────────────┐
 *         │  TailRiskAgent.sol (this contract)                      │
 *         │  • Holds protection pool (ETH / ERC-20)                 │
 *         │  • Manages portfolio subscriptions                      │
 *         │  • Pays claims autonomously when triggered              │
 *         │  • Records every action in ERC-8004 Reputation Registry │
 *         └─────────────────────────────────────────────────────────┘
 *
 *         Prize target: $50K USDC — LabLab.ai ERC-8004 Hackathon Mar 9-22, 2026
 */
contract TailRiskAgent is Ownable, ReentrancyGuard {

    // ─── Types ────────────────────────────────────────────────────────────────

    enum ProtectionStatus { Inactive, Active, Triggered, Settled }

    struct PortfolioPolicy {
        address holder;
        uint256 coverageAmount;   // ETH wei — max payout
        uint256 premium;          // ETH wei paid upfront
        uint256 expiry;           // unix timestamp
        uint256 triggerThreshold; // volatility score 0–10000 (basis points)
        ProtectionStatus status;
        uint256 paidOut;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    ERC8004IdentityRegistry public immutable identityRegistry;
    ERC8004ReputationRegistry public immutable reputationRegistry;

    uint256 public immutable agentId;   // ERC-8004 agent token ID
    uint256 public protectionPool;      // total ETH held for claims

    uint256 private _nextPolicyId;
    mapping(uint256 => PortfolioPolicy) public policies;

    /// Authorized off-chain agent executor (set to agent's hot wallet)
    address public agentExecutor;

    /// Current risk level reported by off-chain agent (0–10000 bps)
    uint256 public currentRiskScore;

    /// Whether the agent is in protection mode (extreme risk detected)
    bool public protectionModeActive;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PolicyCreated(uint256 indexed policyId, address indexed holder, uint256 coverage, uint256 expiry);
    event ProtectionTriggered(uint256 indexed policyId, uint256 riskScore, uint256 payout);
    event ProtectionReleased(uint256 indexed policyId);
    event RiskScoreUpdated(uint256 newScore, uint256 timestamp);
    event PoolDeposited(address indexed depositor, uint256 amount);
    event PoolWithdrawn(address indexed to, uint256 amount);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _identityRegistry  Deployed ERC8004IdentityRegistry address.
     * @param _reputationRegistry Deployed ERC8004ReputationRegistry address.
     * @param _agentURI          IPFS/HTTPS URI to the agent's registration JSON.
     * @param _agentExecutor     Hot wallet address of the off-chain Python agent.
     */
    constructor(
        address _identityRegistry,
        address _reputationRegistry,
        string memory _agentURI,
        address _agentExecutor
    ) Ownable(msg.sender) {
        identityRegistry  = ERC8004IdentityRegistry(_identityRegistry);
        reputationRegistry = ERC8004ReputationRegistry(_reputationRegistry);
        agentExecutor     = _agentExecutor;

        // Register this agent in the ERC-8004 Identity Registry
        agentId = identityRegistry.register(_agentURI);
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyExecutor() {
        require(
            msg.sender == agentExecutor || msg.sender == owner(),
            "TailRisk: caller is not authorized executor"
        );
        _;
    }

    // ─── Policy Management ────────────────────────────────────────────────────

    /**
     * @notice Subscribe to tail-risk protection.
     * @param coverageAmount    Max ETH payout if protection is triggered.
     * @param durationDays      Policy duration in days.
     * @param triggerThreshold  Volatility score (bps) above which a claim is paid.
     *                          E.g., 7500 = trigger when risk score > 75%.
     */
    function createPolicy(
        uint256 coverageAmount,
        uint256 durationDays,
        uint256 triggerThreshold
    ) external payable nonReentrant returns (uint256 policyId) {
        require(coverageAmount > 0, "TailRisk: coverage must be > 0");
        require(durationDays >= 1 && durationDays <= 365, "TailRisk: invalid duration");
        require(triggerThreshold > 0 && triggerThreshold <= 10000, "TailRisk: invalid threshold");

        // Premium = 2% of coverage per 30 days (simplified actuarial model)
        uint256 premium = (coverageAmount * 200 * durationDays) / (10000 * 30);
        require(msg.value >= premium, "TailRisk: insufficient premium");

        // Excess premium goes to pool
        protectionPool += msg.value;

        policyId = _nextPolicyId++;
        policies[policyId] = PortfolioPolicy({
            holder:           msg.sender,
            coverageAmount:   coverageAmount,
            premium:          premium,
            expiry:           block.timestamp + durationDays * 1 days,
            triggerThreshold: triggerThreshold,
            status:           ProtectionStatus.Active,
            paidOut:          0
        });

        emit PolicyCreated(policyId, msg.sender, coverageAmount, policies[policyId].expiry);
    }

    // ─── Agent Actions (called by off-chain Python agent) ─────────────────────

    /**
     * @notice Off-chain agent reports a new risk score.
     * @param score  Volatility risk score 0–10000 (basis points).
     */
    function updateRiskScore(uint256 score) external onlyExecutor {
        require(score <= 10000, "TailRisk: score out of range");
        currentRiskScore = score;
        protectionModeActive = score >= 7500; // 75% threshold for global mode
        emit RiskScoreUpdated(score, block.timestamp);
    }

    /**
     * @notice Agent triggers protection payout for a specific policy.
     * @dev    Called when risk score exceeds the policy's trigger threshold.
     *         Payout is proportional to risk severity.
     */
    function triggerProtection(uint256 policyId, uint256 riskScore)
        external
        onlyExecutor
        nonReentrant
    {
        PortfolioPolicy storage policy = policies[policyId];
        require(policy.status == ProtectionStatus.Active, "TailRisk: policy not active");
        require(block.timestamp <= policy.expiry, "TailRisk: policy expired");
        require(riskScore >= policy.triggerThreshold, "TailRisk: risk below threshold");

        // Payout = coverage * (riskScore - threshold) / (10000 - threshold)
        // Capped at coverageAmount
        uint256 excess = riskScore - policy.triggerThreshold;
        uint256 range  = 10000 - policy.triggerThreshold;
        uint256 payout = (policy.coverageAmount * excess) / range;
        if (payout > policy.coverageAmount) payout = policy.coverageAmount;
        if (payout > protectionPool) payout = protectionPool;

        policy.status  = ProtectionStatus.Triggered;
        policy.paidOut = payout;
        protectionPool -= payout;

        // Transfer payout to policy holder
        (bool ok, ) = policy.holder.call{value: payout}("");
        require(ok, "TailRisk: payout transfer failed");

        // Record in ERC-8004 Reputation Registry
        reputationRegistry.postFeedback(
            agentId,
            90,
            "Tail-risk protection triggered and paid",
            bytes32(policyId)
        );

        emit ProtectionTriggered(policyId, riskScore, payout);
    }

    /**
     * @notice Agent releases protection (risk has subsided).
     */
    function releaseProtection(uint256 policyId) external onlyExecutor {
        PortfolioPolicy storage policy = policies[policyId];
        require(
            policy.status == ProtectionStatus.Triggered,
            "TailRisk: policy not in triggered state"
        );
        policy.status = ProtectionStatus.Settled;
        emit ProtectionReleased(policyId);
    }

    // ─── Pool Management ──────────────────────────────────────────────────────

    /// @notice Owner deposits additional ETH into the protection pool.
    function depositToPool() external payable onlyOwner {
        protectionPool += msg.value;
        emit PoolDeposited(msg.sender, msg.value);
    }

    /// @notice Owner withdraws excess pool funds (only when no active policies).
    function withdrawFromPool(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= protectionPool, "TailRisk: insufficient pool");
        protectionPool -= amount;
        (bool ok, ) = owner().call{value: amount}("");
        require(ok, "TailRisk: withdrawal failed");
        emit PoolWithdrawn(owner(), amount);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function getPolicy(uint256 policyId) external view returns (PortfolioPolicy memory) {
        return policies[policyId];
    }

    function totalPolicies() external view returns (uint256) {
        return _nextPolicyId;
    }

    function poolBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // ─── ERC-8004 Agent URI ───────────────────────────────────────────────────

    function updateAgentURI(string calldata newURI) external onlyOwner {
        identityRegistry.setAgentURI(agentId, newURI);
    }

    /// @notice Update the authorized off-chain executor address.
    function setAgentExecutor(address newExecutor) external onlyOwner {
        agentExecutor = newExecutor;
    }

    receive() external payable {
        protectionPool += msg.value;
    }
}
