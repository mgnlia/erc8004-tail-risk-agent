// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ERC8004IdentityRegistry
 * @notice ERC-8004 compliant Identity Registry for AI agents.
 *         Each agent is minted as an ERC-721 token whose URI resolves to
 *         the agent's registration file (JSON).
 *
 *         Spec: https://eips.ethereum.org/EIPS/eip-8004
 */
contract ERC8004IdentityRegistry is ERC721URIStorage, Ownable {
    // ─── State ────────────────────────────────────────────────────────────────

    uint256 private _nextAgentId;

    /// @notice Extra on-chain key/value metadata per agent
    mapping(uint256 => mapping(string => bytes)) private _metadata;

    /// @notice Reserved key — stores the agent's payment wallet address
    string public constant AGENT_WALLET_KEY = "agentWallet";

    // ─── Events ───────────────────────────────────────────────────────────────

    event AgentRegistered(uint256 indexed agentId, address indexed owner, string agentURI);
    event AgentURIUpdated(uint256 indexed agentId, string newURI);
    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() ERC721("ERC8004 Agent Identity", "AGENT") Ownable(msg.sender) {}

    // ─── Registration ─────────────────────────────────────────────────────────

    /**
     * @notice Register a new agent. Mints an ERC-721 token to the caller.
     * @param agentURI  URI pointing to the agent's registration JSON file.
     * @return agentId  The newly assigned agent token ID.
     */
    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);

        // Default payment wallet = owner address
        _metadata[agentId][AGENT_WALLET_KEY] = abi.encode(msg.sender);

        emit AgentRegistered(agentId, msg.sender, agentURI);
    }

    /**
     * @notice Update the agent's registration URI.
     * @dev Only the token owner or approved operator may call this.
     */
    function setAgentURI(uint256 agentId, string calldata newURI) external {
        require(
            _isAuthorized(ownerOf(agentId), msg.sender, agentId),
            "ERC8004: caller not owner nor approved"
        );
        _setTokenURI(agentId, newURI);
        emit AgentURIUpdated(agentId, newURI);
    }

    // ─── Metadata ─────────────────────────────────────────────────────────────

    /// @notice Read extra on-chain metadata for an agent.
    function getMetadata(uint256 agentId, string memory metadataKey)
        external
        view
        returns (bytes memory)
    {
        return _metadata[agentId][metadataKey];
    }

    /**
     * @notice Write extra on-chain metadata for an agent.
     * @dev The reserved key "agentWallet" cannot be set here; use setAgentWallet().
     */
    function setMetadata(
        uint256 agentId,
        string memory metadataKey,
        bytes memory metadataValue
    ) external {
        require(
            _isAuthorized(ownerOf(agentId), msg.sender, agentId),
            "ERC8004: caller not owner nor approved"
        );
        require(
            keccak256(bytes(metadataKey)) != keccak256(bytes(AGENT_WALLET_KEY)),
            "ERC8004: agentWallet is reserved"
        );
        _metadata[agentId][metadataKey] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }

    /**
     * @notice Change the agent's payment wallet.
     * @dev Owner proves control by signing the transaction.
     */
    function setAgentWallet(uint256 agentId, address newWallet) external {
        require(ownerOf(agentId) == msg.sender, "ERC8004: caller is not agent owner");
        _metadata[agentId][AGENT_WALLET_KEY] = abi.encode(newWallet);
        emit MetadataSet(
            agentId,
            AGENT_WALLET_KEY,
            AGENT_WALLET_KEY,
            abi.encode(newWallet)
        );
    }

    /// @notice Convenience: decode and return the agent's payment wallet.
    function getAgentWallet(uint256 agentId) external view returns (address) {
        bytes memory raw = _metadata[agentId][AGENT_WALLET_KEY];
        if (raw.length == 0) return ownerOf(agentId);
        return abi.decode(raw, (address));
    }

    /// @notice Total agents registered so far.
    function totalAgents() external view returns (uint256) {
        return _nextAgentId;
    }
}
