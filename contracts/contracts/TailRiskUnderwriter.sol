// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TailRiskUnderwriter (pre-build scaffold)
contract TailRiskUnderwriter {
    struct Policy {
        address owner;
        uint256 premiumWei;
        uint256 coverageWei;
        uint8 riskTier;
        bool active;
    }

    uint256 public nextPolicyId;
    mapping(uint256 => Policy) public policies;

    event PolicyIssued(uint256 indexed policyId, address indexed owner, uint256 premiumWei, uint256 coverageWei, uint8 riskTier);
    event ClaimSettled(uint256 indexed policyId, address indexed owner, uint256 payoutWei, bytes32 reasonHash);

    function issuePolicy(uint256 coverageWei, uint8 riskTier) external payable returns (uint256 policyId) {
        require(msg.value > 0, "premium required");
        require(coverageWei > 0, "coverage required");

        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            owner: msg.sender,
            premiumWei: msg.value,
            coverageWei: coverageWei,
            riskTier: riskTier,
            active: true
        });

        emit PolicyIssued(policyId, msg.sender, msg.value, coverageWei, riskTier);
    }

    function settleClaim(uint256 policyId, uint256 payoutWei, bytes32 reasonHash) external {
        Policy storage p = policies[policyId];
        require(p.active, "inactive policy");
        require(payoutWei <= p.coverageWei, "over coverage");

        p.active = false;
        (bool ok, ) = p.owner.call{value: payoutWei}("");
        require(ok, "transfer failed");

        emit ClaimSettled(policyId, p.owner, payoutWei, reasonHash);
    }

    receive() external payable {}
}
