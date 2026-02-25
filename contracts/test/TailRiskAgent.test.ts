import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("ERC-8004 Tail-Risk Agent Contracts", function () {
  // ─── Fixtures ──────────────────────────────────────────────────────────────

  async function deployFixture() {
    const [owner, agent, validator, user1, user2] = await ethers.getSigners();

    const IdentityRegistry = await ethers.getContractFactory("IdentityRegistry");
    const identityRegistry = await IdentityRegistry.deploy();

    const ReputationRegistry = await ethers.getContractFactory("ReputationRegistry");
    const reputationRegistry = await ReputationRegistry.deploy();

    const ValidationRegistry = await ethers.getContractFactory("ValidationRegistry");
    const validationRegistry = await ValidationRegistry.deploy();

    const AgentWallet = await ethers.getContractFactory("AgentWallet");
    const agentWallet = await AgentWallet.deploy(agent.address);

    return {
      identityRegistry,
      reputationRegistry,
      validationRegistry,
      agentWallet,
      owner,
      agent,
      validator,
      user1,
      user2,
    };
  }

  // ─── IdentityRegistry Tests ────────────────────────────────────────────────

  describe("IdentityRegistry", function () {
    it("Should register an agent and mint ERC-721 token", async function () {
      const { identityRegistry, owner } = await loadFixture(deployFixture);

      const agentURI = "ipfs://QmTestAgentRegistrationFile";
      await expect(identityRegistry.register(agentURI))
        .to.emit(identityRegistry, "AgentRegistered")
        .withArgs(1, owner.address, agentURI);

      expect(await identityRegistry.totalAgents()).to.equal(1);
      expect(await identityRegistry.ownerOf(1)).to.equal(owner.address);
      expect(await identityRegistry.agentURI(1)).to.equal(agentURI);
    });

    it("Should increment agentId for each registration", async function () {
      const { identityRegistry, owner, user1 } = await loadFixture(deployFixture);

      await identityRegistry.register("ipfs://agent1");
      await identityRegistry.connect(user1).register("ipfs://agent2");

      expect(await identityRegistry.totalAgents()).to.equal(2);
      expect(await identityRegistry.ownerOf(1)).to.equal(owner.address);
      expect(await identityRegistry.ownerOf(2)).to.equal(user1.address);
    });

    it("Should allow owner to update agentURI", async function () {
      const { identityRegistry, owner } = await loadFixture(deployFixture);

      await identityRegistry.register("ipfs://old");
      await expect(identityRegistry.setAgentURI(1, "ipfs://new"))
        .to.emit(identityRegistry, "AgentURIUpdated")
        .withArgs(1, "ipfs://new");

      expect(await identityRegistry.agentURI(1)).to.equal("ipfs://new");
    });

    it("Should allow operator to update agentURI", async function () {
      const { identityRegistry, owner, user1 } = await loadFixture(deployFixture);

      await identityRegistry.register("ipfs://old");
      await identityRegistry.setOperator(1, user1.address);
      await identityRegistry.connect(user1).setAgentURI(1, "ipfs://updated");

      expect(await identityRegistry.agentURI(1)).to.equal("ipfs://updated");
    });

    it("Should reject unauthorized URI updates", async function () {
      const { identityRegistry, user1 } = await loadFixture(deployFixture);

      await identityRegistry.register("ipfs://agent");
      await expect(
        identityRegistry.connect(user1).setAgentURI(1, "ipfs://hack")
      ).to.be.revertedWithCustomError(identityRegistry, "NotAuthorized");
    });

    it("Should set and get on-chain metadata", async function () {
      const { identityRegistry, owner } = await loadFixture(deployFixture);

      await identityRegistry.register("ipfs://agent");
      const key = "riskScore";
      const value = ethers.toUtf8Bytes("85");

      await identityRegistry.setMetadata(1, key, value);
      const stored = await identityRegistry.getMetadata(1, key);
      expect(ethers.toUtf8String(stored)).to.equal("85");
    });

    it("Should reject setting reserved 'agentWallet' key via setMetadata", async function () {
      const { identityRegistry } = await loadFixture(deployFixture);

      await identityRegistry.register("ipfs://agent");
      await expect(
        identityRegistry.setMetadata(1, "agentWallet", ethers.toUtf8Bytes("0x1234"))
      ).to.be.revertedWithCustomError(identityRegistry, "ReservedKey");
    });

    it("Should default agentWallet to owner address", async function () {
      const { identityRegistry, owner } = await loadFixture(deployFixture);

      await identityRegistry.register("ipfs://agent");
      expect(await identityRegistry.agentWallets(1)).to.equal(owner.address);
    });
  });

  // ─── ReputationRegistry Tests ──────────────────────────────────────────────

  describe("ReputationRegistry", function () {
    it("Should post feedback and update reputation", async function () {
      const { reputationRegistry, user1 } = await loadFixture(deployFixture);

      await expect(
        reputationRegistry.connect(user1).postFeedback(
          1,
          90,
          0, // CLAIM_PAYOUT
          "Excellent claim processing",
          ethers.ZeroHash
        )
      ).to.emit(reputationRegistry, "FeedbackPosted");

      const rep = await reputationRegistry.reputations(1);
      expect(rep.totalFeedback).to.equal(1);
      expect(rep.latestScore).to.equal(90);
    });

    it("Should calculate average score correctly", async function () {
      const { reputationRegistry, user1, user2 } = await loadFixture(deployFixture);

      await reputationRegistry.connect(user1).postFeedback(1, 80, 0, "Good", ethers.ZeroHash);
      // user2 posts after cooldown (skip for test - just use different agentId trick)
      await reputationRegistry.connect(user2).postFeedback(1, 60, 1, "Ok", ethers.ZeroHash);

      const avg = await reputationRegistry.getAverageScore(1);
      expect(avg).to.equal(70); // (80 + 60) / 2
    });

    it("Should return 0 for agents with no feedback", async function () {
      const { reputationRegistry } = await loadFixture(deployFixture);
      expect(await reputationRegistry.getAverageScore(999)).to.equal(0);
    });

    it("Should enforce review cooldown", async function () {
      const { reputationRegistry, user1 } = await loadFixture(deployFixture);

      await reputationRegistry.connect(user1).postFeedback(1, 80, 0, "First", ethers.ZeroHash);
      await expect(
        reputationRegistry.connect(user1).postFeedback(1, 90, 0, "Second", ethers.ZeroHash)
      ).to.be.revertedWithCustomError(reputationRegistry, "ReviewCooldownActive");
    });

    it("Should reject scores above 100", async function () {
      const { reputationRegistry, user1 } = await loadFixture(deployFixture);
      await expect(
        reputationRegistry.connect(user1).postFeedback(1, 101, 0, "Bad", ethers.ZeroHash)
      ).to.be.revertedWithCustomError(reputationRegistry, "InvalidScore");
    });

    it("Should compute trust score", async function () {
      const { reputationRegistry, user1, user2 } = await loadFixture(deployFixture);

      await reputationRegistry.connect(user1).postFeedback(1, 90, 0, "Great", ethers.ZeroHash);
      await reputationRegistry.connect(user2).postFeedback(1, 80, 1, "Good", ethers.ZeroHash);

      const trustScore = await reputationRegistry.getTrustScore(1);
      expect(trustScore).to.be.gt(0);
      expect(trustScore).to.be.lte(100);
    });
  });

  // ─── ValidationRegistry Tests ──────────────────────────────────────────────

  describe("ValidationRegistry", function () {
    it("Should request validation and emit event", async function () {
      const { validationRegistry, owner } = await loadFixture(deployFixture);

      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("premium_pricing_data"));
      await expect(
        validationRegistry.requestValidation(1, 0, dataHash, "ipfs://data")
      )
        .to.emit(validationRegistry, "ValidationRequested")
        .withArgs(1, 1, 0, dataHash);
    });

    it("Should register a validator with sufficient stake", async function () {
      const { validationRegistry, validator } = await loadFixture(deployFixture);

      await expect(
        validationRegistry.connect(validator).registerValidator({
          value: ethers.parseEther("0.01"),
        })
      )
        .to.emit(validationRegistry, "ValidatorRegistered")
        .withArgs(validator.address, ethers.parseEther("0.01"));
    });

    it("Should reject validator with insufficient stake", async function () {
      const { validationRegistry, validator } = await loadFixture(deployFixture);

      await expect(
        validationRegistry.connect(validator).registerValidator({
          value: ethers.parseEther("0.001"),
        })
      ).to.be.revertedWithCustomError(validationRegistry, "InsufficientStake");
    });

    it("Should resolve validation request", async function () {
      const { validationRegistry, owner, validator } = await loadFixture(deployFixture);

      // Register validator
      await validationRegistry.connect(validator).registerValidator({
        value: ethers.parseEther("0.01"),
      });

      // Request validation
      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("data"));
      await validationRegistry.requestValidation(1, 0, dataHash, "");

      // Resolve
      await expect(
        validationRegistry.connect(validator).resolveValidation(1, 1, 95, "Pricing looks fair")
      )
        .to.emit(validationRegistry, "ValidationResolved")
        .withArgs(1, 1, 1, 95, validator.address);
    });

    it("Should reject double-resolution", async function () {
      const { validationRegistry, validator } = await loadFixture(deployFixture);

      await validationRegistry.connect(validator).registerValidator({
        value: ethers.parseEther("0.01"),
      });

      const dataHash = ethers.keccak256(ethers.toUtf8Bytes("data"));
      await validationRegistry.requestValidation(1, 0, dataHash, "");
      await validationRegistry.connect(validator).resolveValidation(1, 1, 90, "Good");

      await expect(
        validationRegistry.connect(validator).resolveValidation(1, 1, 80, "Again")
      ).to.be.revertedWithCustomError(validationRegistry, "AlreadyResolved");
    });

    it("Should track agent request history", async function () {
      const { validationRegistry } = await loadFixture(deployFixture);

      const h1 = ethers.keccak256(ethers.toUtf8Bytes("data1"));
      const h2 = ethers.keccak256(ethers.toUtf8Bytes("data2"));
      await validationRegistry.requestValidation(1, 0, h1, "");
      await validationRegistry.requestValidation(1, 1, h2, "");

      const agentReqs = await validationRegistry.getAgentRequests(1);
      expect(agentReqs.length).to.equal(2);
    });
  });

  // ─── AgentWallet Tests ─────────────────────────────────────────────────────

  describe("AgentWallet", function () {
    it("Should validate EIP-1271 signatures from authorized signer", async function () {
      const { agentWallet, agent } = await loadFixture(deployFixture);

      const message = "test message";
      const hash = ethers.hashMessage(message);
      const signature = await agent.signMessage(message);

      const result = await agentWallet.isValidSignature(hash, signature);
      expect(result).to.equal("0x1626ba7e"); // MAGIC_VALUE
    });

    it("Should reject signatures from unauthorized signers", async function () {
      const { agentWallet, user1 } = await loadFixture(deployFixture);

      const message = "test";
      const hash = ethers.hashMessage(message);
      const signature = await user1.signMessage(message);

      const result = await agentWallet.isValidSignature(hash, signature);
      expect(result).to.equal("0xffffffff"); // INVALID_VALUE
    });

    it("Should allow owner to authorize new signers", async function () {
      const { agentWallet, owner, user1 } = await loadFixture(deployFixture);

      await agentWallet.connect(owner).setSigner(user1.address, true);
      expect(await agentWallet.authorizedSigners(user1.address)).to.equal(true);
    });

    it("Should receive ETH", async function () {
      const { agentWallet, owner } = await loadFixture(deployFixture);

      await owner.sendTransaction({
        to: await agentWallet.getAddress(),
        value: ethers.parseEther("1"),
      });

      const balance = await ethers.provider.getBalance(await agentWallet.getAddress());
      expect(balance).to.equal(ethers.parseEther("1"));
    });
  });
});
