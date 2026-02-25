// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC-8004 Identity Registry
/// @notice Minimal on-chain agent identity via ERC-721 + URIStorage
/// @dev Implements the Identity Registry spec from ERC-8004
contract IdentityRegistry is ERC721URIStorage, Ownable {
    // ── State ─────────────────────────────────────────────────────────────

    uint256 private _nextAgentId = 1;

    // agentId => metadata key => value
    mapping(uint256 => mapping(string => bytes)) private _metadata;

    // agentId => agent wallet (for payments)
    mapping(uint256 => address) private _agentWallets;

    // ── Events ────────────────────────────────────────────────────────────

    event AgentRegistered(uint256 indexed agentId, address indexed owner, string agentURI);
    event AgentURIUpdated(uint256 indexed agentId, string newAgentURI);
    event MetadataSet(uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue);
    event AgentWalletChanged(uint256 indexed agentId, address indexed oldWallet, address indexed newWallet);

    // ── Constructor ───────────────────────────────────────────────────────

    constructor() ERC721("ERC-8004 Agent Identity", "AGENT") Ownable(msg.sender) {}

    // ── Registration ──────────────────────────────────────────────────────

    /// @notice Register a new agent — mints an ERC-721 token
    /// @param agentURI URI resolving to the agent registration JSON file
    /// @return agentId The assigned agent ID (token ID)
    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        _agentWallets[agentId] = msg.sender;
        emit AgentRegistered(agentId, msg.sender, agentURI);
    }

    /// @notice Register with initial metadata
    function registerWithMetadata(
        string calldata agentURI,
        string[] calldata keys,
        bytes[] calldata values
    ) external returns (uint256 agentId) {
        require(keys.length == values.length, "Keys/values length mismatch");
        agentId = _nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        _agentWallets[agentId] = msg.sender;
        for (uint256 i = 0; i < keys.length; i++) {
            require(keccak256(bytes(keys[i])) != keccak256(bytes("agentWallet")), "Reserved key");
            _metadata[agentId][keys[i]] = values[i];
            emit MetadataSet(agentId, keys[i], keys[i], values[i]);
        }
        emit AgentRegistered(agentId, msg.sender, agentURI);
    }

    // ── Agent URI ─────────────────────────────────────────────────────────

    /// @notice Update agent URI — only owner or approved operator
    function setAgentURI(uint256 agentId, string calldata newAgentURI) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "Not authorized");
        _setTokenURI(agentId, newAgentURI);
        emit AgentURIUpdated(agentId, newAgentURI);
    }

    // ── Metadata ──────────────────────────────────────────────────────────

    /// @notice Get arbitrary on-chain metadata for an agent
    function getMetadata(uint256 agentId, string memory metadataKey) external view returns (bytes memory) {
        if (keccak256(bytes(metadataKey)) == keccak256(bytes("agentWallet"))) {
            return abi.encode(_agentWallets[agentId]);
        }
        return _metadata[agentId][metadataKey];
    }

    /// @notice Set arbitrary on-chain metadata for an agent
    function setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "Not authorized");
        require(keccak256(bytes(metadataKey)) != keccak256(bytes("agentWallet")), "Reserved: use changeAgentWallet");
        _metadata[agentId][metadataKey] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }

    // ── Agent Wallet ──────────────────────────────────────────────────────

    /// @notice Get the payment wallet for an agent
    function getAgentWallet(uint256 agentId) external view returns (address) {
        return _agentWallets[agentId];
    }

    /// @notice Change the agent's payment wallet — requires proof of control
    /// @dev Caller must be the current agent wallet, not just the token owner
    function changeAgentWallet(uint256 agentId, address newWallet) external {
        require(msg.sender == _agentWallets[agentId], "Only current agent wallet");
        require(newWallet != address(0), "Zero address");
        address old = _agentWallets[agentId];
        _agentWallets[agentId] = newWallet;
        emit AgentWalletChanged(agentId, old, newWallet);
    }

    // ── View ──────────────────────────────────────────────────────────────

    /// @notice Total agents registered
    function totalAgents() external view returns (uint256) {
        return _nextAgentId - 1;
    }

    /// @notice agentURI = tokenURI (alias for ERC-8004 spec compliance)
    function agentURI(uint256 agentId) external view returns (string memory) {
        return tokenURI(agentId);
    }
}
