// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ValidationRegistry.sol";

/**
 * @title TailRiskVault
 * @dev Insurance vault for the Tail-Risk Protection Agent.
 *
 *      Lifecycle:
 *      1. Liquidity providers deposit USDC → earn premium yield
 *      2. Clients pay premiums to get protection
 *      3. When a black-swan event is detected, agent triggers rebalancing
 *      4. If client suffers loss, they submit a claim
 *      5. Agent validates the claim and pays out from the vault
 *
 *      All decisions are posted to ERC-8004 ValidationRegistry for auditability.
 */
contract TailRiskVault is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ─── Types ────────────────────────────────────────────────────────────────

    struct Policy {
        uint256 policyId;
        address holder;
        uint256 premium;        // USDC paid
        uint256 coverage;       // max USDC payout
        uint256 startTime;
        uint256 endTime;
        uint256 riskScore;      // 0-100 at time of purchase
        bool active;
        bool claimed;
    }

    struct Claim {
        uint256 claimId;
        uint256 policyId;
        address claimant;
        uint256 requestedAmount;
        uint256 approvedAmount;
        bool processed;
        bool approved;
        bytes32 evidenceHash;
        uint256 validationRequestId; // ERC-8004 validation request
    }

    // ─── State ────────────────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    ValidationRegistry public immutable validationRegistry;

    uint256 private _nextPolicyId;
    uint256 private _nextClaimId;

    mapping(uint256 => Policy) public policies;
    mapping(uint256 => Claim) public claims;
    mapping(address => uint256[]) public holderPolicies;

    // Liquidity provider balances
    mapping(address => uint256) public lpShares;
    uint256 public totalShares;
    uint256 public totalLiquidity;

    // Protocol parameters (set by agent)
    uint256 public baseRateBps = 50;        // 0.5% base premium rate
    uint256 public maxCoverageRatio = 8000; // 80% of vault can be covered
    uint256 public agentId;                 // ERC-8004 agent ID

    // Circuit breakers
    uint256 public maxClaimsPerDay = 10;
    uint256 public claimsToday;
    uint256 public lastClaimDay;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PolicyPurchased(
        uint256 indexed policyId,
        address indexed holder,
        uint256 premium,
        uint256 coverage,
        uint256 riskScore
    );

    event ClaimSubmitted(
        uint256 indexed claimId,
        uint256 indexed policyId,
        uint256 requestedAmount
    );

    event ClaimProcessed(
        uint256 indexed claimId,
        uint256 indexed policyId,
        bool approved,
        uint256 paidAmount
    );

    event LiquidityAdded(address indexed provider, uint256 amount, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 shares, uint256 amount);
    event RiskScoreUpdated(uint256 newScore);
    event BaseRateUpdated(uint256 newRateBps);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InsufficientLiquidity(uint256 available, uint256 required);
    error PolicyNotActive(uint256 policyId);
    error PolicyExpired(uint256 policyId);
    error AlreadyClaimed(uint256 policyId);
    error ClaimLimitReached();
    error NotPolicyHolder(address caller, uint256 policyId);
    error InsufficientShares(address provider, uint256 shares);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _usdc,
        address _validationRegistry,
        uint256 _agentId
    ) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        validationRegistry = ValidationRegistry(_validationRegistry);
        agentId = _agentId;
        _nextPolicyId = 1;
        _nextClaimId = 1;
    }

    // ─── Liquidity Management ─────────────────────────────────────────────────

    /**
     * @notice Add liquidity to the vault (earn premium yield).
     */
    function addLiquidity(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares;
        if (totalShares == 0) {
            shares = amount;
        } else {
            shares = (amount * totalShares) / totalLiquidity;
        }

        lpShares[msg.sender] += shares;
        totalShares += shares;
        totalLiquidity += amount;

        emit LiquidityAdded(msg.sender, amount, shares);
    }

    /**
     * @notice Remove liquidity from the vault.
     */
    function removeLiquidity(uint256 shares) external nonReentrant {
        if (lpShares[msg.sender] < shares) {
            revert InsufficientShares(msg.sender, shares);
        }

        uint256 amount = (shares * totalLiquidity) / totalShares;

        lpShares[msg.sender] -= shares;
        totalShares -= shares;
        totalLiquidity -= amount;

        usdc.safeTransfer(msg.sender, amount);
        emit LiquidityRemoved(msg.sender, shares, amount);
    }

    // ─── Policy Management ────────────────────────────────────────────────────

    /**
     * @notice Purchase a tail-risk protection policy.
     * @param coverage Maximum USDC payout if a claim is approved.
     * @param duration Policy duration in seconds.
     * @param riskScore Current risk score (0-100) from the agent.
     */
    function purchasePolicy(
        uint256 coverage,
        uint256 duration,
        uint256 riskScore
    ) external nonReentrant returns (uint256 policyId) {
        require(coverage > 0, "Coverage must be > 0");
        require(duration >= 1 days, "Min duration: 1 day");
        require(riskScore <= 100, "Invalid risk score");

        // Check vault can cover this policy
        uint256 maxCoverage = (totalLiquidity * maxCoverageRatio) / 10000;
        if (coverage > maxCoverage) {
            revert InsufficientLiquidity(maxCoverage, coverage);
        }

        // Calculate premium: base_rate × risk_multiplier × coverage
        uint256 premium = _calculatePremium(coverage, duration, riskScore);

        usdc.safeTransferFrom(msg.sender, address(this), premium);
        totalLiquidity += premium; // premiums go to vault

        policyId = _nextPolicyId++;
        policies[policyId] = Policy({
            policyId: policyId,
            holder: msg.sender,
            premium: premium,
            coverage: coverage,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            riskScore: riskScore,
            active: true,
            claimed: false
        });

        holderPolicies[msg.sender].push(policyId);

        // Post validation request to ERC-8004
        bytes32 dataHash = keccak256(abi.encode(policyId, coverage, premium, riskScore));
        validationRegistry.requestValidation(
            agentId,
            ValidationRegistry.ValidationKind.PREMIUM_PRICING,
            dataHash,
            ""
        );

        emit PolicyPurchased(policyId, msg.sender, premium, coverage, riskScore);
    }

    // ─── Claim Processing ─────────────────────────────────────────────────────

    /**
     * @notice Submit a claim for a policy.
     * @param policyId The policy to claim against.
     * @param requestedAmount Amount of USDC to claim.
     * @param evidenceHash Hash of loss evidence (tx hashes, price data, etc.)
     */
    function submitClaim(
        uint256 policyId,
        uint256 requestedAmount,
        bytes32 evidenceHash
    ) external nonReentrant returns (uint256 claimId) {
        Policy storage policy = policies[policyId];

        if (policy.holder != msg.sender) revert NotPolicyHolder(msg.sender, policyId);
        if (!policy.active) revert PolicyNotActive(policyId);
        if (block.timestamp > policy.endTime) revert PolicyExpired(policyId);
        if (policy.claimed) revert AlreadyClaimed(policyId);

        // Circuit breaker
        uint256 today = block.timestamp / 1 days;
        if (lastClaimDay < today) {
            claimsToday = 0;
            lastClaimDay = today;
        }
        if (claimsToday >= maxClaimsPerDay) revert ClaimLimitReached();

        claimId = _nextClaimId++;

        // Post to ERC-8004 ValidationRegistry
        bytes32 dataHash = keccak256(abi.encode(policyId, requestedAmount, evidenceHash));
        uint256 validationRequestId = validationRegistry.requestValidation(
            agentId,
            ValidationRegistry.ValidationKind.CLAIM_PROCESSING,
            dataHash,
            ""
        );

        claims[claimId] = Claim({
            claimId: claimId,
            policyId: policyId,
            claimant: msg.sender,
            requestedAmount: requestedAmount,
            approvedAmount: 0,
            processed: false,
            approved: false,
            evidenceHash: evidenceHash,
            validationRequestId: validationRequestId
        });

        claimsToday++;
        emit ClaimSubmitted(claimId, policyId, requestedAmount);
    }

    /**
     * @notice Process a claim (called by the agent after LLM validation).
     * @param claimId The claim to process.
     * @param approved Whether to approve the claim.
     * @param approvedAmount Amount to pay (≤ policy coverage).
     */
    function processClaim(
        uint256 claimId,
        bool approved,
        uint256 approvedAmount
    ) external onlyOwner nonReentrant {
        Claim storage claim = claims[claimId];
        require(!claim.processed, "Already processed");

        Policy storage policy = policies[claim.policyId];
        require(approvedAmount <= policy.coverage, "Exceeds coverage");

        claim.processed = true;
        claim.approved = approved;
        claim.approvedAmount = approvedAmount;
        policy.claimed = true;
        policy.active = false;

        if (approved && approvedAmount > 0) {
            totalLiquidity -= approvedAmount;
            usdc.safeTransfer(claim.claimant, approvedAmount);
        }

        emit ClaimProcessed(claimId, claim.policyId, approved, approvedAmount);
    }

    // ─── Agent Parameter Updates ──────────────────────────────────────────────

    function setBaseRate(uint256 rateBps) external onlyOwner {
        require(rateBps <= 1000, "Max 10%");
        baseRateBps = rateBps;
        emit BaseRateUpdated(rateBps);
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

    function getLPValue(address provider) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (lpShares[provider] * totalLiquidity) / totalShares;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /**
     * @dev Calculate premium using: base_rate × risk_multiplier × coverage × duration_factor
     *      risk_multiplier = 1 + (riskScore / 100)  → 1x to 2x
     *      duration_factor = duration / 365 days
     */
    function _calculatePremium(
        uint256 coverage,
        uint256 duration,
        uint256 riskScore
    ) internal view returns (uint256) {
        // base = coverage × baseRateBps / 10000
        uint256 base = (coverage * baseRateBps) / 10000;

        // risk multiplier: 100% to 200% based on risk score
        uint256 riskMultiplier = 10000 + (riskScore * 100); // 10000-20000 (bps)
        uint256 riskAdjusted = (base * riskMultiplier) / 10000;

        // duration factor: pro-rated to annual
        uint256 durationFactor = (duration * 10000) / 365 days;
        return (riskAdjusted * durationFactor) / 10000;
    }
}
