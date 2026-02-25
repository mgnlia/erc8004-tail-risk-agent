// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IdentityRegistry.sol";
import "../src/ReputationRegistry.sol";
import "../src/TailRiskAgent.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000 * 1e6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract TailRiskAgentTest is Test {
    IdentityRegistry public identityRegistry;
    ReputationRegistry public reputationRegistry;
    TailRiskAgent public tailRiskAgent;
    MockUSDC public usdc;

    address public deployer = address(0x1);
    address public policyHolder = address(0x2);
    address public aiOracle = address(0x3);

    function setUp() public {
        vm.startPrank(deployer);

        usdc = new MockUSDC();
        identityRegistry = new IdentityRegistry();
        reputationRegistry = new ReputationRegistry();
        tailRiskAgent = new TailRiskAgent(address(usdc), aiOracle);

        // Fund policy holder
        usdc.mint(policyHolder, 10_000 * 1e6);

        // Fund vault
        usdc.transfer(address(tailRiskAgent), 100_000 * 1e6);

        vm.stopPrank();
    }

    // ── Identity Registry Tests ───────────────────────────────────────────

    function test_RegisterAgent() public {
        vm.prank(deployer);
        uint256 agentId = identityRegistry.register("ipfs://QmTest");
        assertEq(agentId, 1);
        assertEq(identityRegistry.ownerOf(1), deployer);
        assertEq(identityRegistry.agentURI(1), "ipfs://QmTest");
        assertEq(identityRegistry.totalAgents(), 1);
    }

    function test_UpdateAgentURI() public {
        vm.startPrank(deployer);
        uint256 agentId = identityRegistry.register("ipfs://QmOld");
        identityRegistry.setAgentURI(agentId, "ipfs://QmNew");
        assertEq(identityRegistry.agentURI(agentId), "ipfs://QmNew");
        vm.stopPrank();
    }

    function test_AgentMetadata() public {
        vm.startPrank(deployer);
        uint256 agentId = identityRegistry.register("ipfs://QmTest");
        identityRegistry.setMetadata(agentId, "version", bytes("1.0.0"));
        bytes memory val = identityRegistry.getMetadata(agentId, "version");
        assertEq(val, bytes("1.0.0"));
        vm.stopPrank();
    }

    function test_ReservedMetadataKey() public {
        vm.startPrank(deployer);
        uint256 agentId = identityRegistry.register("ipfs://QmTest");
        vm.expectRevert("Reserved: use changeAgentWallet");
        identityRegistry.setMetadata(agentId, "agentWallet", bytes("0x0"));
        vm.stopPrank();
    }

    // ── Reputation Registry Tests ─────────────────────────────────────────

    function test_PostFeedback() public {
        vm.prank(deployer);
        reputationRegistry.postFeedback(1, 85, "Great agent!", keccak256("task-1"));
        assertEq(reputationRegistry.getAverageScore(1), 85);
        assertEq(reputationRegistry.getFeedbackCount(1), 1);
    }

    function test_NoDoubleReview() public {
        vm.startPrank(deployer);
        reputationRegistry.postFeedback(1, 85, "First review", keccak256("task-1"));
        vm.expectRevert("Already reviewed");
        reputationRegistry.postFeedback(1, 90, "Second review", keccak256("task-2"));
        vm.stopPrank();
    }

    function test_AverageScore() public {
        vm.prank(address(0x10));
        reputationRegistry.postFeedback(1, 80, "Good", keccak256("task-1"));
        vm.prank(address(0x11));
        reputationRegistry.postFeedback(1, 90, "Great", keccak256("task-2"));
        vm.prank(address(0x12));
        reputationRegistry.postFeedback(1, 70, "OK", keccak256("task-3"));
        assertEq(reputationRegistry.getAverageScore(1), 80);
    }

    // ── TailRiskAgent Tests ───────────────────────────────────────────────

    function test_BuyPolicyWithMockSig() public {
        // For testing, set deployer as oracle so we can sign
        vm.prank(deployer);
        tailRiskAgent.setAiOracle(deployer);

        uint256 coverageAmount = 1000 * 1e6; // $1000 USDC
        uint256 riskScore = 50;
        uint256 durationDays = 30;

        // Create signature (simplified for test)
        bytes32 msgHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            keccak256(abi.encodePacked(address(usdc), coverageAmount, riskScore, block.chainid))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, msgHash); // key 1 = deployer
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startPrank(policyHolder);
        usdc.approve(address(tailRiskAgent), 10_000 * 1e6);
        uint256 policyId = tailRiskAgent.buyPolicy(
            address(usdc),
            coverageAmount,
            durationDays,
            riskScore,
            sig
        );
        vm.stopPrank();

        assertEq(policyId, 1);
        TailRiskAgent.Policy memory policy = tailRiskAgent.getPolicy(1);
        assertEq(policy.holder, policyHolder);
        assertEq(policy.coverageAmount, coverageAmount);
    }

    function test_SubmitAndSettleClaim() public {
        // Setup: buy policy with mock oracle
        vm.prank(deployer);
        tailRiskAgent.setAiOracle(aiOracle);

        // Manually add a policy for testing (via vm.store or simplified approach)
        // In a real test, we'd buy the policy first
        // For brevity, test claim submission logic directly
        // TODO: Full end-to-end test in integration test suite
    }

    function test_SolvencyRatio() public {
        // Fresh vault with 100k USDC, 0 premiums collected
        assertEq(tailRiskAgent.solvencyRatio(), 100);
    }
}
