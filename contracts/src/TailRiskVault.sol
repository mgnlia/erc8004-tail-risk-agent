// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./TrustScoreOracle.sol";

/**
 * @title TailRiskVault
 * @notice ERC-8004 compliant vault for tail-risk insurance underwriting.
 *
 *         Flow:
 *         1. LPs deposit USDC → earn premiums from policy buyers
 *         2. Policy buyers pay premiums → get covered against tail-risk events
 *         3. Agent (AI) monitors on-chain volatility signals
 *         4. When trigger conditions met, agent autonomously pays claims via ERC-8004
 *         5. Trust score gates agent's ability to execute claims
 *
 *         Capital tiers:
 *         - STABLE: Idle capital earning base yield
 *         - DEPLOYED: Capital backing active policies
 *         - RESERVE: Emergency reserve (never deployed)
 */
contract TailRiskVault is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Errors ─────────────────────────────────────────────────────────────────
    error InsufficientTrustScore();
    error PolicyNotActive();
    error PolicyExpired();
    error PolicyAlreadyClaimed();
    error InsufficientCapacity();
    error InvalidPremium();
    error NotPolicyHolder();
    error ClaimNotTriggered();
    error AgentNotAuthorized();
    error ExceedsMaxExposure();
    error ZeroAmount();

    // ── Events ─────────────────────────────────────────────────────────────────
    event Deposited(address indexed lp, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lp, uint256 shares, uint256 amount);
    event PolicyCreated(
        uint256 indexed policyId,
        address indexed holder,
        uint256 coverage,
        uint256 premium,
        uint256 expiry
    );
    event ClaimPaid(uint256 indexed policyId, address indexed holder, uint256 amount);
    event AgentActionExecuted(uint256 indexed agentId, bytes4 action, uint256 policyId);
    event VolatilitySignalUpdated(uint256 vixProxy, uint256 timestamp);
    event EmergencyWithdraw(address indexed to, uint256 amount);

    // ── Structs ────────────────────────────────────────────────────────────────
    enum PolicyStatus { Active, Claimed, Expired, Cancelled }

    struct Policy {
        address holder;
        uint256 coverage;        // Max payout in USDC
        uint256 premium;         // Premium paid (in USDC)
        uint256 createdAt;
        uint256 expiry;
        uint256 triggerThreshold; // VIX-proxy level that triggers claim
        PolicyStatus status;
        uint256 agentId;         // ERC-8004 agent that underwrote this policy
    }

    struct LPPosition {
        uint256 shares;
        uint256 depositedAt;
    }

    // ── Constants ──────────────────────────────────────────────────────────────
    uint16 public constant MIN_TRUST_SCORE = 6000; // 60% minimum trust score
    uint256 public constant RESERVE_RATIO_BPS = 2000; // 20% kept as reserve
    uint256 public constant MAX_EXPOSURE_RATIO_BPS = 5000; // 50% max of vault deployed
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MIN_POLICY_DURATION = 1 days;
    uint256 public constant MAX_POLICY_DURATION = 90 days;

    // ── State ──────────────────────────────────────────────────────────────────
    IERC20 public immutable usdc;
    TrustScoreOracle public immutable trustOracle;

    uint256 public totalShares;
    uint256 public totalAssets;
    uint256 public totalPolicyCoverage; // Total active coverage outstanding

    /// @dev VIX-proxy: on-chain volatility indicator (0–10000 bps, updated by agent)
    uint256 public volatilityIndex;
    uint256 public volatilityUpdatedAt;

    uint256 private _nextPolicyId = 1;

    mapping(address => LPPosition) public lpPositions;
    mapping(uint256 => Policy) public policies;
    mapping(uint256 => bool) public authorizedAgents; // agentId → authorized

    // ── Constructor ────────────────────────────────────────────────────────────
    constructor(
        address _usdc,
        address _trustOracle
    ) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        trustOracle = TrustScoreOracle(_trustOracle);
    }

    // ── LP Functions ───────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC as liquidity provider.
     * @param amount USDC amount to deposit.
     */
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 shares = _computeShares(amount);
        totalShares += shares;
        totalAssets += amount;

        LPPosition storage pos = lpPositions[msg.sender];
        pos.shares += shares;
        pos.depositedAt = block.timestamp;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, shares);
    }

    /**
     * @notice Withdraw USDC by burning shares.
     * @param shares Number of shares to redeem.
     */
    function withdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        LPPosition storage pos = lpPositions[msg.sender];
        require(pos.shares >= shares, "Insufficient shares");

        uint256 amount = _computeAssets(shares);
        uint256 available = _availableCapital();
        require(amount <= available, "Insufficient liquidity");

        pos.shares -= shares;
        totalShares -= shares;
        totalAssets -= amount;

        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, shares, amount);
    }

    // ── Policy Functions ───────────────────────────────────────────────────────

    /**
     * @notice Buy a tail-risk insurance policy.
     * @param coverage Maximum payout if triggered.
     * @param duration Policy duration in seconds.
     * @param triggerThreshold VIX-proxy level (bps) that triggers payout.
     * @param agentId ERC-8004 agent underwriting this policy.
     */
    function buyPolicy(
        uint256 coverage,
        uint256 duration,
        uint256 triggerThreshold,
        uint256 agentId
    ) external nonReentrant returns (uint256 policyId) {
        if (coverage == 0) revert ZeroAmount();
        if (duration < MIN_POLICY_DURATION || duration > MAX_POLICY_DURATION)
            revert InvalidPremium();
        if (!authorizedAgents[agentId]) revert AgentNotAuthorized();

        // Check agent trust score
        if (!trustOracle.meetsThreshold(agentId, MIN_TRUST_SCORE))
            revert InsufficientTrustScore();

        // Check vault capacity
        uint256 maxNewCoverage = (totalAssets * MAX_EXPOSURE_RATIO_BPS) / 10000;
        if (totalPolicyCoverage + coverage > maxNewCoverage)
            revert InsufficientCapacity();

        // Compute premium (simplified: 2–8% of coverage based on duration + volatility)
        uint256 premium = _computePremium(coverage, duration);
        if (premium == 0) revert InvalidPremium();

        policyId = _nextPolicyId++;
        policies[policyId] = Policy({
            holder: msg.sender,
            coverage: coverage,
            premium: premium,
            createdAt: block.timestamp,
            expiry: block.timestamp + duration,
            triggerThreshold: triggerThreshold,
            status: PolicyStatus.Active,
            agentId: agentId
        });

        totalPolicyCoverage += coverage;
        totalAssets += premium; // Premium goes into vault

        usdc.safeTransferFrom(msg.sender, address(this), premium);
        emit PolicyCreated(policyId, msg.sender, coverage, premium, block.timestamp + duration);
    }

    /**
     * @notice ERC-8004 agent action: pay a claim when trigger conditions are met.
     *         Agent must have sufficient trust score to execute.
     * @param agentId The ERC-8004 agent executing this action.
     * @param policyId The policy to pay out.
     */
    function agentPayClaim(uint256 agentId, uint256 policyId)
        external
        nonReentrant
    {
        if (!authorizedAgents[agentId]) revert AgentNotAuthorized();
        if (!trustOracle.meetsThreshold(agentId, MIN_TRUST_SCORE))
            revert InsufficientTrustScore();

        Policy storage policy = policies[policyId];
        if (policy.holder == address(0)) revert PolicyNotActive();
        if (policy.status != PolicyStatus.Active) revert PolicyNotActive();
        if (block.timestamp > policy.expiry) revert PolicyExpired();

        // Verify trigger condition: current volatility must exceed threshold
        if (volatilityIndex < policy.triggerThreshold) revert ClaimNotTriggered();

        policy.status = PolicyStatus.Claimed;
        totalPolicyCoverage -= policy.coverage;
        totalAssets -= policy.coverage;

        usdc.safeTransfer(policy.holder, policy.coverage);

        emit ClaimPaid(policyId, policy.holder, policy.coverage);
        emit AgentActionExecuted(agentId, this.agentPayClaim.selector, policyId);
    }

    /**
     * @notice ERC-8004 agent action: update the on-chain volatility index.
     *         This is the primary oracle feed used for trigger conditions.
     * @param agentId The ERC-8004 agent updating the signal.
     * @param newVolatilityIndex New VIX-proxy value in bps (0–10000).
     */
    function agentUpdateVolatility(uint256 agentId, uint256 newVolatilityIndex)
        external
    {
        if (!authorizedAgents[agentId]) revert AgentNotAuthorized();
        if (!trustOracle.meetsThreshold(agentId, MIN_TRUST_SCORE))
            revert InsufficientTrustScore();
        require(newVolatilityIndex <= 10000, "Invalid volatility index");

        volatilityIndex = newVolatilityIndex;
        volatilityUpdatedAt = block.timestamp;

        emit VolatilitySignalUpdated(newVolatilityIndex, block.timestamp);
        emit AgentActionExecuted(agentId, this.agentUpdateVolatility.selector, 0);
    }

    // ── View Functions ─────────────────────────────────────────────────────────

    /**
     * @notice Get the current share price (assets per share).
     */
    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return PRECISION;
        return (totalAssets * PRECISION) / totalShares;
    }

    /**
     * @notice Get available capital (not locked in policies or reserve).
     */
    function availableCapital() external view returns (uint256) {
        return _availableCapital();
    }

    /**
     * @notice Get LP position value in USDC.
     */
    function positionValue(address lp) external view returns (uint256) {
        LPPosition memory pos = lpPositions[lp];
        if (pos.shares == 0) return 0;
        return _computeAssets(pos.shares);
    }

    // ── Admin Functions ────────────────────────────────────────────────────────

    function authorizeAgent(uint256 agentId, bool authorized) external onlyOwner {
        authorizedAgents[agentId] = authorized;
    }

    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        usdc.safeTransfer(to, amount);
        emit EmergencyWithdraw(to, amount);
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    function _computeShares(uint256 amount) internal view returns (uint256) {
        if (totalShares == 0 || totalAssets == 0) {
            return amount; // 1:1 initial ratio
        }
        return (amount * totalShares) / totalAssets;
    }

    function _computeAssets(uint256 shares) internal view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * totalAssets) / totalShares;
    }

    function _availableCapital() internal view returns (uint256) {
        uint256 reserve = (totalAssets * RESERVE_RATIO_BPS) / 10000;
        uint256 locked = totalPolicyCoverage;
        if (totalAssets <= reserve + locked) return 0;
        return totalAssets - reserve - locked;
    }

    /**
     * @notice Simplified premium calculation.
     *         Base: 2% of coverage per 30 days + volatility surcharge.
     */
    function _computePremium(uint256 coverage, uint256 duration)
        internal
        view
        returns (uint256)
    {
        // Base rate: 2% per 30 days
        uint256 baseRate = (coverage * 200 * duration) / (30 days * 10000);

        // Volatility surcharge: up to 6% extra at max volatility
        uint256 volSurcharge = (coverage * 600 * volatilityIndex) / (10000 * 10000);

        return baseRate + volSurcharge;
    }
}
