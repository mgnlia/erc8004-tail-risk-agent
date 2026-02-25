// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC8004Identity
 * @notice Interface for the ERC-8004 Identity Registry
 * @dev Based on EIP-8004: Trustless Agents
 *      https://eips.ethereum.org/EIPS/eip-8004
 *
 * The Identity Registry uses ERC-721 with URIStorage extension for agent registration.
 * Each agent is uniquely identified by:
 *   - agentRegistry: {namespace}:{chainId}:{identityRegistry}
 *   - agentId: The ERC-721 tokenId
 */
interface IERC8004Identity {
    /// @notice Emitted when an agent is registered
    event AgentRegistered(uint256 indexed agentId, address indexed owner, string agentURI);

    /// @notice Emitted when agent URI is updated
    event AgentURIUpdated(uint256 indexed agentId, string newURI);

    /// @notice Emitted when agent metadata is set
    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );

    /**
     * @notice Register a new agent
     * @param agentURI URI pointing to the agent registration file (JSON)
     * @return agentId The assigned ERC-721 token ID
     */
    function register(string calldata agentURI) external returns (uint256 agentId);

    /**
     * @notice Register with initial metadata
     * @param agentURI URI pointing to the agent registration file
     * @param metadata Array of (key, value) metadata pairs
     * @return agentId The assigned ERC-721 token ID
     */
    function register(
        string calldata agentURI,
        bytes[] calldata metadata
    ) external returns (uint256 agentId);

    /**
     * @notice Update the agent's URI
     * @param agentId The agent's token ID
     * @param newURI New URI for the agent registration file
     */
    function setAgentURI(uint256 agentId, string calldata newURI) external;

    /**
     * @notice Get agent metadata by key
     * @param agentId The agent's token ID
     * @param metadataKey The metadata key to retrieve
     * @return The metadata value as bytes
     */
    function getMetadata(
        uint256 agentId,
        string memory metadataKey
    ) external view returns (bytes memory);

    /**
     * @notice Set agent metadata
     * @dev The key "agentWallet" is reserved and cannot be set via this function
     * @param agentId The agent's token ID
     * @param metadataKey The metadata key
     * @param metadataValue The metadata value as bytes
     */
    function setMetadata(
        uint256 agentId,
        string memory metadataKey,
        bytes memory metadataValue
    ) external;

    /**
     * @notice Get the agent wallet address (where agent receives payments)
     * @param agentId The agent's token ID
     * @return The agent's wallet address
     */
    function getAgentWallet(uint256 agentId) external view returns (address);

    /**
     * @notice Set the agent wallet address
     * @param agentId The agent's token ID
     * @param wallet New wallet address
     */
    function setAgentWallet(uint256 agentId, address wallet) external;
}
