// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/MockUSDC.sol";
import "../src/IdentityRegistry.sol";
import "../src/TrustScoreOracle.sol";
import "../src/TailRiskVault.sol";

contract TailRiskVaultTest is Test {
    MockUSDC usdc;
    IdentityRegistry registry;
    TrustScoreOracle oracle;
    TailRiskVault vault;

    address alice = makeAddr("alice");   // LP
    address bob = makeAddr("bob");       // Policy buyer
    address charlie = makeAddr("charlie"); // Agent operator

    uint256 agentId;

    uint256 constant INITIAL_BALANCE = 100_000e6; // 100K USDC

    function setUp() public {
        // Deploy contracts
        usdc = new MockUSDC();
        registry = new IdentityRegistry();
        oracle = new TrustScoreOracle(address(registry));
        vault = new TailRiskVault(address(usdc), address(oracle));

        // Register agent
        agentId = registry.register("ipfs://QmTestAgent");

        // Set good trust score
        oracle.updateScore(agentId, 8000, 8500, 7500);

        // Authorize agent in vault
        vault.authorizeAgent(agentId, true);

        // Fund test users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);

        // Approve vault
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ── Deposit Tests ──────────────────────────────────────────────────────────

    function test_Deposit() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        assertEq(vault.totalAssets(), 10_000e6);
        assertEq(vault.totalShares(), 10_000e6);
        (uint256 shares,) = vault.lpPositions(alice);
        assertEq(shares, 10_000e6);
    }

    function test_DepositZero_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(TailRiskVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    function test_SharePriceStable() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        assertEq(vault.sharePrice(), 1e18); // 1:1 initially
    }

    // ── Withdraw Tests ─────────────────────────────────────────────────────────

    function test_WithdrawFull() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        (uint256 shares,) = vault.lpPositions(alice);

        vm.prank(alice);
        vault.withdraw(shares);

        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE);
        assertEq(vault.totalAssets(), 0);
    }

    // ── Policy Tests ───────────────────────────────────────────────────────────

    function test_BuyPolicy() public {
        // Fund vault first
        vm.prank(alice);
        vault.deposit(50_000e6);

        // Set volatility
        vault.agentUpdateVolatility(agentId, 3000); // 30% vol

        vm.prank(bob);
        uint256 policyId = vault.buyPolicy(
            10_000e6,   // 10K coverage
            30 days,    // 30 day policy
            5000,       // trigger at 50% vol
            agentId
        );

        assertEq(policyId, 1);
        (
            address holder,
            uint256 coverage,
            ,,,
            uint256 triggerThreshold,
            TailRiskVault.PolicyStatus status,
            uint256 pid
        ) = vault.policies(policyId);

        assertEq(holder, bob);
        assertEq(coverage, 10_000e6);
        assertEq(triggerThreshold, 5000);
        assertEq(uint8(status), uint8(TailRiskVault.PolicyStatus.Active));
        assertEq(pid, agentId);
    }

    function test_BuyPolicy_InsufficientCapacity_Reverts() public {
        // Don't fund vault — no capacity
        vm.prank(bob);
        vm.expectRevert(TailRiskVault.InsufficientCapacity.selector);
        vault.buyPolicy(10_000e6, 30 days, 5000, agentId);
    }

    function test_BuyPolicy_UnauthorizedAgent_Reverts() public {
        vm.prank(alice);
        vault.deposit(50_000e6);

        vm.prank(bob);
        vm.expectRevert(TailRiskVault.AgentNotAuthorized.selector);
        vault.buyPolicy(10_000e6, 30 days, 5000, 999); // invalid agentId
    }

    // ── Claim Tests ────────────────────────────────────────────────────────────

    function test_AgentPayClaim_Success() public {
        // Setup
        vm.prank(alice);
        vault.deposit(50_000e6);

        vault.agentUpdateVolatility(agentId, 3000);

        vm.prank(bob);
        uint256 policyId = vault.buyPolicy(10_000e6, 30 days, 5000, agentId);

        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        // Spike volatility above trigger
        vault.agentUpdateVolatility(agentId, 7000); // 70% vol > 50% trigger

        // Agent pays claim
        vault.agentPayClaim(agentId, policyId);

        assertEq(usdc.balanceOf(bob), bobBalanceBefore + 10_000e6);
        (, , , , , , TailRiskVault.PolicyStatus status, ) = vault.policies(policyId);
        assertEq(uint8(status), uint8(TailRiskVault.PolicyStatus.Claimed));
    }

    function test_AgentPayClaim_NotTriggered_Reverts() public {
        vm.prank(alice);
        vault.deposit(50_000e6);

        vault.agentUpdateVolatility(agentId, 3000);

        vm.prank(bob);
        uint256 policyId = vault.buyPolicy(10_000e6, 30 days, 5000, agentId);

        // Volatility still below trigger (3000 < 5000)
        vm.expectRevert(TailRiskVault.ClaimNotTriggered.selector);
        vault.agentPayClaim(agentId, policyId);
    }

    function test_AgentPayClaim_Expired_Reverts() public {
        vm.prank(alice);
        vault.deposit(50_000e6);

        vault.agentUpdateVolatility(agentId, 3000);

        vm.prank(bob);
        uint256 policyId = vault.buyPolicy(10_000e6, 30 days, 5000, agentId);

        // Fast-forward past expiry
        vm.warp(block.timestamp + 31 days);

        vault.agentUpdateVolatility(agentId, 7000);

        vm.expectRevert(TailRiskVault.PolicyExpired.selector);
        vault.agentPayClaim(agentId, policyId);
    }

    // ── Trust Score Tests ──────────────────────────────────────────────────────

    function test_LowTrustScore_BlocksClaim() public {
        vm.prank(alice);
        vault.deposit(50_000e6);

        vault.agentUpdateVolatility(agentId, 3000);

        vm.prank(bob);
        uint256 policyId = vault.buyPolicy(10_000e6, 30 days, 5000, agentId);

        // Drop trust score below minimum
        oracle.updateScore(agentId, 1000, 1000, 1000); // ~10% overall

        vault.agentUpdateVolatility(agentId, 7000);

        vm.expectRevert(TailRiskVault.InsufficientTrustScore.selector);
        vault.agentPayClaim(agentId, policyId);
    }

    // ── Volatility Tests ───────────────────────────────────────────────────────

    function test_UpdateVolatility() public {
        vault.agentUpdateVolatility(agentId, 5000);
        assertEq(vault.volatilityIndex(), 5000);
        assertGt(vault.volatilityUpdatedAt(), 0);
    }

    function test_UpdateVolatility_InvalidRange_Reverts() public {
        vm.expectRevert("Invalid volatility index");
        vault.agentUpdateVolatility(agentId, 10001);
    }

    // ── Fuzz Tests ─────────────────────────────────────────────────────────────

    function testFuzz_DepositWithdraw(uint256 amount) public {
        amount = bound(amount, 1e6, 50_000e6); // 1 USDC to 50K USDC
        usdc.mint(alice, amount);

        vm.prank(alice);
        usdc.approve(address(vault), amount);

        vm.prank(alice);
        vault.deposit(amount);

        (uint256 shares,) = vault.lpPositions(alice);

        vm.prank(alice);
        vault.withdraw(shares);

        // Should get back same amount (no fees in this test)
        assertApproxEqAbs(usdc.balanceOf(alice), INITIAL_BALANCE + amount, 1);
    }
}
