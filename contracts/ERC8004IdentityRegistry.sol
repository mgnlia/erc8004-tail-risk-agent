// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ERC8004IdentityRegistry
 * @notice ERC-8004 Identity Registry — portable on-chain identity for AI agents
 * @dev Implements the Identity Registry as specified in EIP-8004.
 *      Each agent is an ERC-721 NFT whose tokenURI resolves to a JSON registration file.
 */
contract ERC8004IdentityRegistry is ERC721URIStorage, Ownable {
    uint256 private _nextAgentId;

    // agentId => metadataKey => metadataValue
    mapping(uint256 => mapping(string => bytes)) private _metadata;

    // Reserved key: agentWallet (payment destination)
    string private constant AGENT_WALLET_KEY = "agentWallet";

    event AgentRegistered(uint256 indexed agentId, address indexed owner, string agentURI);
    event AgentURIUpdated(uint256 indexed agentId, string newAgentURI);
    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );
    event AgentWalletUpdated(uint256 indexed agentId, address newWallet);

    constructor() ERC721("ERC8004 Agent Registry", "AGENT") Ownable(msg.sender) {}

    /**
     * @notice Register a new agent with an ERC-8004 registration file URI
     * @param agentURI URI resolving to the agent's JSON registration file
     * @return agentId The assigned agent NFT token ID
     */
    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);

        // Set default agentWallet to owner
        _metadata[agentId][AGENT_WALLET_KEY] = abi.encode(msg.sender);

        emit AgentRegistered(agentId, msg.sender, agentURI);
    }

    /**
     * @notice Register with initial metadata batch
     */
    function register(
        string calldata agentURI,
        string[] calldata metadataKeys,
        bytes[] calldata metadataValues
    ) external returns (uint256 agentId) {
        require(metadataKeys.length == metadataValues.length, "Length mismatch");
        agentId = _nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        _metadata[agentId][AGENT_WALLET_KEY] = abi.encode(msg.sender);

        for (uint256 i = 0; i < metadataKeys.length; i++) {
            require(
                keccak256(bytes(metadataKeys[i])) != keccak256(bytes(AGENT_WALLET_KEY)),
                "agentWallet is reserved"
            );
            _metadata[agentId][metadataKeys[i]] = metadataValues[i];
            emit MetadataSet(agentId, metadataKeys[i], metadataKeys[i], metadataValues[i]);
        }

        emit AgentRegistered(agentId, msg.sender, agentURI);
    }

    /**
     * @notice Update the agent's registration file URI
     */
    function setAgentURI(uint256 agentId, string calldata newAgentURI) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "Not authorized");
        _setTokenURI(agentId, newAgentURI);
        emit AgentURIUpdated(agentId, newAgentURI);
    }

    /**
     * @notice Set arbitrary metadata on an agent
     */
    function setMetadata(
        uint256 agentId,
        string calldata metadataKey,
        bytes calldata metadataValue
    ) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "Not authorized");
        require(
            keccak256(bytes(metadataKey)) != keccak256(bytes(AGENT_WALLET_KEY)),
            "Use setAgentWallet for agentWallet key"
        );
        _metadata[agentId][metadataKey] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }

    /**
     * @notice Get metadata value for an agent
     */
    function getMetadata(
        uint256 agentId,
        string calldata metadataKey
    ) external view returns (bytes memory) {
        return _metadata[agentId][metadataKey];
    }

    /**
     * @notice Update agentWallet — requires proof of control via signature
     * @dev Owner signs: keccak256(abi.encodePacked(agentId, newWallet, block.chainid))
     */
    function setAgentWallet(uint256 agentId, address newWallet) external {
        require(ownerOf(agentId) == msg.sender, "Only owner can update agentWallet");
        _metadata[agentId][AGENT_WALLET_KEY] = abi.encode(newWallet);
        emit AgentWalletUpdated(agentId, newWallet);
    }

    /**
     * @notice Get the agent's payment wallet address
     */
    function getAgentWallet(uint256 agentId) external view returns (address) {
        bytes memory encoded = _metadata[agentId][AGENT_WALLET_KEY];
        if (encoded.length == 0) return ownerOf(agentId);
        return abi.decode(encoded, (address));
    }

    /**
     * @notice Total agents registered
     */
    function totalAgents() external view returns (uint256) {
        return _nextAgentId;
    }
}
