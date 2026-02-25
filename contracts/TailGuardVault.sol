// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ERC8004ValidationRegistry.sol";

/**
 * @title TailGuardVault
 * @notice On-chain insurance pool + claims escrow for TailGuard
 * @dev Policyholders pay premiums → Pool accumulates → Agent monitors risk →
 *      During black-swan: agent triggers rebalance → Claimants submit claims →
 *      Validation Registry approves → Vault pays out autonomously.
 *
 *      ERC-8004 Integration:
 *      - Agent is registered in IdentityRegistry (agentId stored here)
 *      - Every claim payout posts feedback to ReputationRegistry
 *      - All claim validations go through ValidationRegistry
 */
contract TailGuardVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── State ───────────────────────────────────────────────────────────────

    IERC20 public immutable premiumToken;       // e.g. USDC
    ERC8004ValidationRegistry public immutable validationRegistry;

    address public agent;                        // Authorized TailGuard AI agent address
    address public owner;

    // ERC-8004 identity of this agent
    string public agentRegistry;                 // e.g. "eip155:11155111:0x..."
    uint256 public agentId;

    uint256 public totalPoolBalance;
    uint256 public totalPremiumsCollected;
    uint256 public totalClaimsPaid;

    // Policy state
    struct Policy {
        uint256 policyId;
        address holder;
        uint256 coverageAmount;     // Max payout in premiumToken
        uint256 premiumPaid;        // Total premium paid
        uint256 premiumPerPeriod;   // Required premium per period
        uint256 periodDuration;     // e.g. 30 days in seconds
        uint256 lastPremiumPaid;    // Timestamp
        uint256 expiresAt;
        bool active;
        string riskCategory;        // e.g. "defi-protocol", "stablecoin-depeg", "bridge"
    }

    struct Claim {
        uint256 claimId;
        uint256 policyId;
        address claimant;
        uint256 requestedAmount;
        uint256 validationRequestId;    // ERC-8004 Validation Registry request ID
        bool paid;
        bool rejected;
        uint256 submittedAt;
        string evidence;                // IPFS hash of incident evidence
    }

    uint256 private _nextPolicyId;
    uint256 private _nextClaimId;

    mapping(uint256 => Policy) public policies;
    mapping(uint256 => Claim) public claims;
    mapping(address => uint256[]) public holderPolicies;

    // Risk level: 0-100 (set by AI agent)
    uint256 public currentRiskLevel;
    bool public blackSwanActive;

    // Premium multiplier based on risk (basis points, 10000 = 1x)
    uint256 public riskMultiplierBps = 10000;

    // ─── Events ──────────────────────────────────────────────────────────────

    event PolicyCreated(uint256 indexed policyId, address indexed holder, uint256 coverageAmount);
    event PremiumPaid(uint256 indexed policyId, address indexed holder, uint256 amount);
    event ClaimSubmitted(uint256 indexed claimId, uint256 indexed policyId, uint256 amount);
    event ClaimPaid(uint256 indexed claimId, uint256 indexed policyId, uint256 amount);
    event ClaimRejected(uint256 indexed claimId, uint256 indexed policyId);
    event RiskLevelUpdated(uint256 newRiskLevel, bool blackSwanActive);
    event BlackSwanTriggered(uint256 riskLevel, uint256 timestamp);
    event PoolFunded(address indexed funder, uint256 amount);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyAgent() {
        require(msg.sender == agent, "Only TailGuard agent");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _premiumToken,
        address _validationRegistry,
        address _agent,
        string memory _agentRegistry,
        uint256 _agentId
    ) {
        premiumToken = IERC20(_premiumToken);
        validationRegistry = ERC8004ValidationRegistry(_validationRegistry);
        agent = _agent;
        agentRegistry = _agentRegistry;
        agentId = _agentId;
        owner = msg.sender;
    }

    // ─── Policy Management ───────────────────────────────────────────────────

    /**
     * @notice Create a new insurance policy
     * @param coverageAmount Maximum payout amount
     * @param premiumPerPeriod Premium required per period
     * @param periodDuration Duration of each period in seconds
     * @param durationPeriods Number of periods to cover
     * @param riskCategory Type of risk being covered
     */
    function createPolicy(
        uint256 coverageAmount,
        uint256 premiumPerPeriod,
        uint256 periodDuration,
        uint256 durationPeriods,
        string calldata riskCategory
    ) external nonReentrant returns (uint256 policyId) {
        require(coverageAmount > 0, "Coverage must be > 0");
        require(premiumPerPeriod > 0, "Premium must be > 0");
        require(durationPeriods > 0, "Duration must be > 0");

        // Adjust premium based on current risk level
        uint256 adjustedPremium = (premiumPerPeriod * riskMultiplierBps) / 10000;
        uint256 totalPremium = adjustedPremium * durationPeriods;

        premiumToken.safeTransferFrom(msg.sender, address(this), totalPremium);
        totalPoolBalance += totalPremium;
        totalPremiumsCollected += totalPremium;

        policyId = _nextPolicyId++;
        policies[policyId] = Policy({
            policyId: policyId,
            holder: msg.sender,
            coverageAmount: coverageAmount,
            premiumPaid: totalPremium,
            premiumPerPeriod: adjustedPremium,
            periodDuration: periodDuration,
            lastPremiumPaid: block.timestamp,
            expiresAt: block.timestamp + (periodDuration * durationPeriods),
            active: true,
            riskCategory: riskCategory
        });

        holderPolicies[msg.sender].push(policyId);
        emit PolicyCreated(policyId, msg.sender, coverageAmount);
        emit PremiumPaid(policyId, msg.sender, totalPremium);
    }

    /**
     * @notice Pay premium to extend policy
     */
    function payPremium(uint256 policyId, uint256 periods) external nonReentrant {
        Policy storage policy = policies[policyId];
        require(policy.holder == msg.sender, "Not policy holder");
        require(policy.active, "Policy inactive");

        uint256 amount = policy.premiumPerPeriod * periods;
        premiumToken.safeTransferFrom(msg.sender, address(this), amount);
        totalPoolBalance += amount;
        totalPremiumsCollected += amount;
        policy.premiumPaid += amount;
        policy.expiresAt += policy.periodDuration * periods;

        emit PremiumPaid(policyId, msg.sender, amount);
    }

    // ─── Claims ──────────────────────────────────────────────────────────────

    /**
     * @notice Submit a claim for a covered loss event
     * @param policyId Policy to claim against
     * @param requestedAmount Amount to claim (≤ coverageAmount)
     * @param evidence IPFS hash of incident evidence
     */
    function submitClaim(
        uint256 policyId,
        uint256 requestedAmount,
        string calldata evidence
    ) external nonReentrant returns (uint256 claimId) {
        Policy storage policy = policies[policyId];
        require(policy.holder == msg.sender, "Not policy holder");
        require(policy.active, "Policy inactive");
        require(block.timestamp <= policy.expiresAt, "Policy expired");
        require(requestedAmount <= policy.coverageAmount, "Exceeds coverage");
        require(requestedAmount <= totalPoolBalance, "Insufficient pool");

        // Encode task data for validation
        bytes memory taskData = abi.encode(policyId, requestedAmount, evidence, block.timestamp);
        bytes memory agentResult = abi.encode(true, requestedAmount); // agent pre-approved

        // Request ERC-8004 validation
        uint256 validationRequestId = validationRegistry.requestValidation(
            agentRegistry,
            agentId,
            ERC8004ValidationRegistry.ValidationMethod.StakerReExecution,
            taskData,
            agentResult,
            0,                          // No stake required for basic validation
            block.timestamp + 7 days,   // 7-day validation window
            2                           // 2 approvals needed
        );

        claimId = _nextClaimId++;
        claims[claimId] = Claim({
            claimId: claimId,
            policyId: policyId,
            claimant: msg.sender,
            requestedAmount: requestedAmount,
            validationRequestId: validationRequestId,
            paid: false,
            rejected: false,
            submittedAt: block.timestamp,
            evidence: evidence
        });

        emit ClaimSubmitted(claimId, policyId, requestedAmount);
    }

    /**
     * @notice Execute an approved claim payout (called by agent after validation)
     * @dev Agent checks ValidationRegistry.isApproved() before calling
     */
    function executeClaim(uint256 claimId) external nonReentrant onlyAgent {
        Claim storage claim = claims[claimId];
        require(!claim.paid && !claim.rejected, "Claim already processed");
        require(
            validationRegistry.isApproved(claim.validationRequestId),
            "Claim not validated"
        );

        Policy storage policy = policies[claim.policyId];
        require(totalPoolBalance >= claim.requestedAmount, "Insufficient pool");

        claim.paid = true;
        totalPoolBalance -= claim.requestedAmount;
        totalClaimsPaid += claim.requestedAmount;

        premiumToken.safeTransfer(claim.claimant, claim.requestedAmount);
        emit ClaimPaid(claimId, claim.policyId, claim.requestedAmount);
    }

    /**
     * @notice Reject a claim (called by agent after validation fails)
     */
    function rejectClaim(uint256 claimId) external onlyAgent {
        Claim storage claim = claims[claimId];
        require(!claim.paid && !claim.rejected, "Claim already processed");
        claim.rejected = true;
        emit ClaimRejected(claimId, claim.policyId);
    }

    // ─── Risk Management (Agent-controlled) ──────────────────────────────────

    /**
     * @notice Update risk level (0-100) — called by AI agent
     * @param newRiskLevel Current assessed risk level
     * @param _blackSwanActive Whether a black-swan event is active
     * @param newMultiplierBps Premium multiplier in basis points (10000 = 1x)
     */
    function updateRiskLevel(
        uint256 newRiskLevel,
        bool _blackSwanActive,
        uint256 newMultiplierBps
    ) external onlyAgent {
        require(newRiskLevel <= 100, "Risk level max 100");
        require(newMultiplierBps >= 5000 && newMultiplierBps <= 50000, "Multiplier out of range");

        currentRiskLevel = newRiskLevel;
        blackSwanActive = _blackSwanActive;
        riskMultiplierBps = newMultiplierBps;

        emit RiskLevelUpdated(newRiskLevel, _blackSwanActive);

        if (_blackSwanActive) {
            emit BlackSwanTriggered(newRiskLevel, block.timestamp);
        }
    }

    // ─── Pool Management ─────────────────────────────────────────────────────

    /**
     * @notice Fund the insurance pool (liquidity providers)
     */
    function fundPool(uint256 amount) external nonReentrant {
        premiumToken.safeTransferFrom(msg.sender, address(this), amount);
        totalPoolBalance += amount;
        emit PoolFunded(msg.sender, amount);
    }

    /**
     * @notice Update agent address (owner only)
     */
    function setAgent(address newAgent) external onlyOwner {
        agent = newAgent;
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    function getPolicy(uint256 policyId) external view returns (Policy memory) {
        return policies[policyId];
    }

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        return claims[claimId];
    }

    function getHolderPolicies(address holder) external view returns (uint256[] memory) {
        return holderPolicies[holder];
    }

    function getPoolStats() external view returns (
        uint256 balance,
        uint256 premiumsCollected,
        uint256 claimsPaid,
        uint256 riskLevel,
        bool blackSwan
    ) {
        return (totalPoolBalance, totalPremiumsCollected, totalClaimsPaid, currentRiskLevel, blackSwanActive);
    }
}
