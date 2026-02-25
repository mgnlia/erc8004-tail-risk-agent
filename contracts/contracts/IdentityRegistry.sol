// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IdentityRegistry
 * @dev ERC-8004 compliant Identity Registry for autonomous AI agents.
 *      Each agent receives an ERC-721 token (agentId) pointing to its
 *      Agent Registration File (agentURI) — a JSON document describing
 *      the agent's capabilities, endpoints, and trust model.
 *
 *      Implements ERC-8004 §Identity Registry specification.
 */
contract IdentityRegistry is ERC721URIStorage, Ownable {
    // ─── State ────────────────────────────────────────────────────────────────

    uint256 private _nextAgentId;

    // agentId → operator address (can update agentURI)
    mapping(uint256 => address) public operators;

    // agentId → metadataKey → metadataValue (on-chain metadata)
    mapping(uint256 => mapping(string => bytes)) private _metadata;

    // Reserved key per ERC-8004 spec — must NOT be set via setMetadata()
    string private constant AGENT_WALLET_KEY = "agentWallet";

    // agentId → agentWallet (payment address)
    mapping(uint256 => address) public agentWallets;

    // ─── Events ───────────────────────────────────────────────────────────────

    event AgentRegistered(
        uint256 indexed agentId,
        address indexed owner,
        string agentURI
    );

    event AgentURIUpdated(uint256 indexed agentId, string newURI);

    event OperatorSet(
        uint256 indexed agentId,
        address indexed operator
    );

    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );

    event AgentWalletUpdated(
        uint256 indexed agentId,
        address indexed newWallet,
        bytes proof
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotAuthorized(uint256 agentId, address caller);
    error ReservedKey(string key);
    error AgentNotExists(uint256 agentId);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() ERC721("ERC-8004 Agent Identity", "AGENT") Ownable(msg.sender) {
        _nextAgentId = 1; // start at 1, 0 is reserved
    }

    // ─── Registration ─────────────────────────────────────────────────────────

    /**
     * @notice Register a new agent and mint an ERC-721 identity token.
     * @param agentURI URI pointing to the Agent Registration File (JSON).
     * @return agentId The newly minted token ID.
     */
    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        agentWallets[agentId] = msg.sender; // default wallet = owner
        emit AgentRegistered(agentId, msg.sender, agentURI);
    }

    /**
     * @notice Register with additional on-chain metadata.
     */
    function register(
        string calldata agentURI,
        string[] calldata keys,
        bytes[] calldata values
    ) external returns (uint256 agentId) {
        require(keys.length == values.length, "Keys/values length mismatch");
        agentId = _nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        agentWallets[agentId] = msg.sender;

        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(AGENT_WALLET_KEY))) {
                revert ReservedKey(AGENT_WALLET_KEY);
            }
            _metadata[agentId][keys[i]] = values[i];
            emit MetadataSet(agentId, keys[i], keys[i], values[i]);
        }

        emit AgentRegistered(agentId, msg.sender, agentURI);
    }

    // ─── URI Management ───────────────────────────────────────────────────────

    /**
     * @notice Update the agent's registration file URI.
     * @dev Only callable by token owner or authorized operator.
     */
    function setAgentURI(uint256 agentId, string calldata newURI) external {
        _requireAuthorized(agentId);
        _setTokenURI(agentId, newURI);
        emit AgentURIUpdated(agentId, newURI);
    }

    // ─── Operator Management ──────────────────────────────────────────────────

    /**
     * @notice Delegate management rights (e.g., URI updates) to an operator.
     */
    function setOperator(uint256 agentId, address operator) external {
        if (ownerOf(agentId) != msg.sender) revert NotAuthorized(agentId, msg.sender);
        operators[agentId] = operator;
        emit OperatorSet(agentId, operator);
    }

    // ─── Metadata ─────────────────────────────────────────────────────────────

    /**
     * @notice Get on-chain metadata for an agent.
     */
    function getMetadata(
        uint256 agentId,
        string memory metadataKey
    ) external view returns (bytes memory) {
        if (!_exists(agentId)) revert AgentNotExists(agentId);
        return _metadata[agentId][metadataKey];
    }

    /**
     * @notice Set on-chain metadata for an agent.
     * @dev The key "agentWallet" is reserved — use updateAgentWallet() instead.
     */
    function setMetadata(
        uint256 agentId,
        string memory metadataKey,
        bytes memory metadataValue
    ) external {
        _requireAuthorized(agentId);
        if (keccak256(bytes(metadataKey)) == keccak256(bytes(AGENT_WALLET_KEY))) {
            revert ReservedKey(AGENT_WALLET_KEY);
        }
        _metadata[agentId][metadataKey] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }

    // ─── Agent Wallet ─────────────────────────────────────────────────────────

    /**
     * @notice Update the agent's payment wallet address.
     * @dev Requires a proof of control (signed message from new wallet).
     *      In production, proof should be validated on-chain. For hackathon
     *      purposes, we accept any non-zero proof bytes.
     */
    function updateAgentWallet(
        uint256 agentId,
        address newWallet,
        bytes calldata proof
    ) external {
        _requireAuthorized(agentId);
        require(newWallet != address(0), "Invalid wallet address");
        require(proof.length > 0, "Proof required");
        agentWallets[agentId] = newWallet;
        emit AgentWalletUpdated(agentId, newWallet, proof);
    }

    // ─── View Helpers ─────────────────────────────────────────────────────────

    function totalAgents() external view returns (uint256) {
        return _nextAgentId - 1;
    }

    function agentURI(uint256 agentId) external view returns (string memory) {
        return tokenURI(agentId);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _requireAuthorized(uint256 agentId) internal view {
        address owner = ownerOf(agentId);
        if (msg.sender != owner && msg.sender != operators[agentId]) {
            revert NotAuthorized(agentId, msg.sender);
        }
    }

    function _exists(uint256 agentId) internal view returns (bool) {
        return agentId > 0 && agentId < _nextAgentId;
    }
}
