// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/IdentityRegistry.sol";
import "../src/ReputationRegistry.sol";
import "../src/TailRiskAgent.sol";

contract Deploy is Script {
    // Sepolia USDC address
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy ERC-8004 Identity Registry
        IdentityRegistry identityRegistry = new IdentityRegistry();
        console.log("IdentityRegistry:", address(identityRegistry));

        // 2. Deploy ERC-8004 Reputation Registry
        ReputationRegistry reputationRegistry = new ReputationRegistry();
        console.log("ReputationRegistry:", address(reputationRegistry));

        // 3. Deploy TailRiskAgent (AI oracle = deployer for now)
        TailRiskAgent tailRiskAgent = new TailRiskAgent(USDC_SEPOLIA, deployer);
        console.log("TailRiskAgent:", address(tailRiskAgent));

        // 4. Register the TailRiskAgent in ERC-8004 Identity Registry
        string memory agentURI = string(abi.encodePacked(
            "data:application/json;base64,",
            // Base64 of minimal registration JSON
            "eyJ0eXBlIjoiaHR0cHM6Ly9laXBzLmV0aGVyZXVtLm9yZy9FSVBTLw=="
        ));
        uint256 agentId = identityRegistry.register(agentURI);
        tailRiskAgent.setErc8004AgentId(agentId);
        console.log("ERC-8004 Agent ID:", agentId);

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Network: Sepolia");
        console.log("Deployer:", deployer);
        console.log("IdentityRegistry:", address(identityRegistry));
        console.log("ReputationRegistry:", address(reputationRegistry));
        console.log("TailRiskAgent:", address(tailRiskAgent));
        console.log("ERC-8004 Agent ID:", agentId);
    }
}
