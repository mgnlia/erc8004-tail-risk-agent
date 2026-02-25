"""Blockchain interface — ERC-8004 on-chain interactions via Web3."""

import json
import logging
from pathlib import Path
from typing import Any

from eth_account import Account
from web3 import Web3
from web3.contract import Contract
from web3.middleware import ExtraDataToPOAMiddleware

from .config import settings

logger = logging.getLogger(__name__)

# ── Minimal ABIs (generated from Foundry compilation) ─────────────────────────

IDENTITY_REGISTRY_ABI = [
    {"type": "function", "name": "register", "inputs": [{"name": "uri", "type": "string"}], "outputs": [{"name": "agentId", "type": "uint256"}], "stateMutability": "nonpayable"},
    {"type": "function", "name": "agentURI", "inputs": [{"name": "agentId", "type": "uint256"}], "outputs": [{"name": "", "type": "string"}], "stateMutability": "view"},
    {"type": "function", "name": "setOperator", "inputs": [{"name": "agentId", "type": "uint256"}, {"name": "operator", "type": "address"}], "outputs": [], "stateMutability": "nonpayable"},
    {"type": "function", "name": "totalAgents", "inputs": [], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
    {"type": "event", "name": "AgentRegistered", "inputs": [{"name": "agentId", "type": "uint256", "indexed": True}, {"name": "owner", "type": "address", "indexed": True}, {"name": "agentURI", "type": "string"}]},
]

TRUST_ORACLE_ABI = [
    {"type": "function", "name": "getScore", "inputs": [{"name": "agentId", "type": "uint256"}], "outputs": [{"components": [{"name": "claimAccuracy", "type": "uint16"}, {"name": "capitalPreservation", "type": "uint16"}, {"name": "responseTime", "type": "uint16"}, {"name": "overall", "type": "uint16"}, {"name": "lastUpdated", "type": "uint256"}, {"name": "updateCount", "type": "uint256"}], "name": "", "type": "tuple"}], "stateMutability": "view"},
    {"type": "function", "name": "getOverallScore", "inputs": [{"name": "agentId", "type": "uint256"}], "outputs": [{"name": "", "type": "uint16"}], "stateMutability": "view"},
    {"type": "function", "name": "meetsThreshold", "inputs": [{"name": "agentId", "type": "uint256"}, {"name": "minScore", "type": "uint16"}], "outputs": [{"name": "", "type": "bool"}], "stateMutability": "view"},
    {"type": "function", "name": "updateScore", "inputs": [{"name": "agentId", "type": "uint256"}, {"name": "claimAccuracy", "type": "uint16"}, {"name": "capitalPreservation", "type": "uint16"}, {"name": "responseTime", "type": "uint16"}], "outputs": [], "stateMutability": "nonpayable"},
]

TAIL_RISK_VAULT_ABI = [
    {"type": "function", "name": "deposit", "inputs": [{"name": "amount", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
    {"type": "function", "name": "withdraw", "inputs": [{"name": "shares", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
    {"type": "function", "name": "buyPolicy", "inputs": [{"name": "coverage", "type": "uint256"}, {"name": "duration", "type": "uint256"}, {"name": "triggerThreshold", "type": "uint256"}, {"name": "agentId", "type": "uint256"}], "outputs": [{"name": "policyId", "type": "uint256"}], "stateMutability": "nonpayable"},
    {"type": "function", "name": "agentPayClaim", "inputs": [{"name": "agentId", "type": "uint256"}, {"name": "policyId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
    {"type": "function", "name": "agentUpdateVolatility", "inputs": [{"name": "agentId", "type": "uint256"}, {"name": "newVolatilityIndex", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
    {"type": "function", "name": "volatilityIndex", "inputs": [], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
    {"type": "function", "name": "totalAssets", "inputs": [], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
    {"type": "function", "name": "totalPolicyCoverage", "inputs": [], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
    {"type": "function", "name": "availableCapital", "inputs": [], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
    {"type": "function", "name": "sharePrice", "inputs": [], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
    {"type": "function", "name": "policies", "inputs": [{"name": "", "type": "uint256"}], "outputs": [{"name": "holder", "type": "address"}, {"name": "coverage", "type": "uint256"}, {"name": "premium", "type": "uint256"}, {"name": "createdAt", "type": "uint256"}, {"name": "expiry", "type": "uint256"}, {"name": "triggerThreshold", "type": "uint256"}, {"name": "status", "type": "uint8"}, {"name": "agentId", "type": "uint256"}], "stateMutability": "view"},
    {"type": "event", "name": "ClaimPaid", "inputs": [{"name": "policyId", "type": "uint256", "indexed": True}, {"name": "holder", "type": "address", "indexed": True}, {"name": "amount", "type": "uint256"}]},
    {"type": "event", "name": "PolicyCreated", "inputs": [{"name": "policyId", "type": "uint256", "indexed": True}, {"name": "holder", "type": "address", "indexed": True}, {"name": "coverage", "type": "uint256"}, {"name": "premium", "type": "uint256"}, {"name": "expiry", "type": "uint256"}]},
    {"type": "event", "name": "AgentActionExecuted", "inputs": [{"name": "agentId", "type": "uint256", "indexed": True}, {"name": "action", "type": "bytes4"}, {"name": "policyId", "type": "uint256"}]},
]


class BlockchainClient:
    """Web3 client for ERC-8004 contract interactions."""

    def __init__(self) -> None:
        self.w3 = Web3(Web3.HTTPProvider(settings.rpc_url))
        # POA middleware for testnets
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)

        self.account = Account.from_key(settings.private_key) if settings.private_key else None

        self._registry: Contract | None = None
        self._oracle: Contract | None = None
        self._vault: Contract | None = None

        logger.info(
            "BlockchainClient initialized",
            extra={"rpc": settings.rpc_url, "chain_id": settings.chain_id}
        )

    @property
    def registry(self) -> Contract:
        if self._registry is None:
            self._registry = self.w3.eth.contract(
                address=Web3.to_checksum_address(settings.identity_registry_address),
                abi=IDENTITY_REGISTRY_ABI,
            )
        return self._registry

    @property
    def oracle(self) -> Contract:
        if self._oracle is None:
            self._oracle = self.w3.eth.contract(
                address=Web3.to_checksum_address(settings.trust_oracle_address),
                abi=TRUST_ORACLE_ABI,
            )
        return self._oracle

    @property
    def vault(self) -> Contract:
        if self._vault is None:
            self._vault = self.w3.eth.contract(
                address=Web3.to_checksum_address(settings.tail_risk_vault_address),
                abi=TAIL_RISK_VAULT_ABI,
            )
        return self._vault

    def is_connected(self) -> bool:
        return self.w3.is_connected()

    def get_block_number(self) -> int:
        return self.w3.eth.block_number

    def get_trust_score(self, agent_id: int) -> dict[str, Any]:
        """Get current trust score for an agent."""
        score = self.oracle.functions.getScore(agent_id).call()
        return {
            "claimAccuracy": score[0],
            "capitalPreservation": score[1],
            "responseTime": score[2],
            "overall": score[3],
            "lastUpdated": score[4],
            "updateCount": score[5],
        }

    def meets_threshold(self, agent_id: int, min_score: int) -> bool:
        """Check if agent meets minimum trust threshold."""
        return self.oracle.functions.meetsThreshold(agent_id, min_score).call()

    def get_volatility_index(self) -> int:
        """Get current on-chain volatility index."""
        return self.vault.functions.volatilityIndex().call()

    def get_vault_stats(self) -> dict[str, Any]:
        """Get vault statistics."""
        return {
            "totalAssets": self.vault.functions.totalAssets().call(),
            "totalPolicyCoverage": self.vault.functions.totalPolicyCoverage().call(),
            "availableCapital": self.vault.functions.availableCapital().call(),
            "sharePrice": self.vault.functions.sharePrice().call(),
            "volatilityIndex": self.vault.functions.volatilityIndex().call(),
        }

    def get_policy(self, policy_id: int) -> dict[str, Any]:
        """Get policy details."""
        result = self.vault.functions.policies(policy_id).call()
        return {
            "holder": result[0],
            "coverage": result[1],
            "premium": result[2],
            "createdAt": result[3],
            "expiry": result[4],
            "triggerThreshold": result[5],
            "status": result[6],
            "agentId": result[7],
        }

    def _send_transaction(self, fn, gas: int = 300_000) -> str:
        """Sign and send a transaction, return tx hash."""
        if self.account is None:
            raise ValueError("No private key configured")

        nonce = self.w3.eth.get_transaction_count(self.account.address)
        gas_price = self.w3.eth.gas_price

        tx = fn.build_transaction({
            "from": self.account.address,
            "nonce": nonce,
            "gas": gas,
            "gasPrice": gas_price,
            "chainId": settings.chain_id,
        })

        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)

        if receipt["status"] != 1:
            raise RuntimeError(f"Transaction failed: {tx_hash.hex()}")

        logger.info(f"Transaction confirmed: {tx_hash.hex()}")
        return tx_hash.hex()

    def update_volatility(self, agent_id: int, volatility_bps: int) -> str:
        """ERC-8004 agent action: update on-chain volatility index."""
        fn = self.vault.functions.agentUpdateVolatility(agent_id, volatility_bps)
        return self._send_transaction(fn)

    def pay_claim(self, agent_id: int, policy_id: int) -> str:
        """ERC-8004 agent action: pay an insurance claim."""
        fn = self.vault.functions.agentPayClaim(agent_id, policy_id)
        return self._send_transaction(fn, gas=500_000)

    def update_trust_score(
        self,
        agent_id: int,
        claim_accuracy: int,
        capital_preservation: int,
        response_time: int,
    ) -> str:
        """Update trust score for an agent."""
        fn = self.oracle.functions.updateScore(
            agent_id, claim_accuracy, capital_preservation, response_time
        )
        return self._send_transaction(fn)
