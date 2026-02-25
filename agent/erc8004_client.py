"""
ERC-8004 On-chain Client
Handles all interactions with the three ERC-8004 registries and TailGuardVault.
"""

import json
import logging
import os
from typing import Any

logger = logging.getLogger(__name__)

# Contract ABIs (minimal — full ABIs in contracts/abis/)
IDENTITY_ABI_MINIMAL = [
    {"name": "register", "type": "function", "inputs": [{"name": "agentURI", "type": "string"}], "outputs": [{"name": "agentId", "type": "uint256"}]},
    {"name": "setAgentURI", "type": "function", "inputs": [{"name": "agentId", "type": "uint256"}, {"name": "newAgentURI", "type": "string"}], "outputs": []},
    {"name": "getAgentWallet", "type": "function", "inputs": [{"name": "agentId", "type": "uint256"}], "outputs": [{"name": "", "type": "address"}]},
]

REPUTATION_ABI_MINIMAL = [
    {"name": "postFeedback", "type": "function", "inputs": [
        {"name": "agentRegistry", "type": "string"}, {"name": "agentId", "type": "uint256"},
        {"name": "score", "type": "int8"}, {"name": "category", "type": "string"},
        {"name": "details", "type": "string"}, {"name": "taskId", "type": "uint256"}
    ], "outputs": [{"name": "feedbackIndex", "type": "uint256"}]},
    {"name": "getReputationScore", "type": "function", "inputs": [
        {"name": "agentRegistry", "type": "string"}, {"name": "agentId", "type": "uint256"}
    ], "outputs": [
        {"name": "score", "type": "int256"}, {"name": "count", "type": "uint256"}, {"name": "averageScore", "type": "int256"}
    ]},
]

VAULT_ABI_MINIMAL = [
    {"name": "updateRiskLevel", "type": "function", "inputs": [
        {"name": "newRiskLevel", "type": "uint256"}, {"name": "_blackSwanActive", "type": "bool"},
        {"name": "newMultiplierBps", "type": "uint256"}
    ], "outputs": []},
    {"name": "executeClaim", "type": "function", "inputs": [{"name": "claimId", "type": "uint256"}], "outputs": []},
    {"name": "rejectClaim", "type": "function", "inputs": [{"name": "claimId", "type": "uint256"}], "outputs": []},
    {"name": "getPoolStats", "type": "function", "inputs": [], "outputs": [
        {"name": "balance", "type": "uint256"}, {"name": "premiumsCollected", "type": "uint256"},
        {"name": "claimsPaid", "type": "uint256"}, {"name": "riskLevel", "type": "uint256"},
        {"name": "blackSwan", "type": "bool"}
    ]},
]


class ERC8004Client:
    """Manages interactions with ERC-8004 registries and TailGuardVault."""

    def __init__(self):
        self.rpc_url = os.getenv("ETHEREUM_RPC_URL", "https://rpc.sepolia.org")
        self.private_key = os.getenv("AGENT_PRIVATE_KEY")
        self.chain_id = int(os.getenv("CHAIN_ID", "11155111"))  # Sepolia

        self.identity_registry = os.getenv("IDENTITY_REGISTRY_ADDRESS")
        self.reputation_registry = os.getenv("REPUTATION_REGISTRY_ADDRESS")
        self.validation_registry = os.getenv("VALIDATION_REGISTRY_ADDRESS")
        self.vault_address = os.getenv("TAILGUARD_VAULT_ADDRESS")

        self.agent_id = int(os.getenv("ERC8004_AGENT_ID", "0"))
        self.agent_registry_str = os.getenv(
            "ERC8004_AGENT_REGISTRY",
            f"eip155:{self.chain_id}:{self.identity_registry or '0x0'}"
        )

        self._web3 = None
        self._initialized = False

    def _get_web3(self):
        """Lazy-initialize Web3 connection."""
        if self._web3 is None:
            try:
                from web3 import Web3
                self._web3 = Web3(Web3.HTTPProvider(self.rpc_url))
                self._initialized = self._web3.is_connected()
                if self._initialized:
                    logger.info(f"✅ Web3 connected to {self.rpc_url}")
                else:
                    logger.warning(f"⚠️ Web3 not connected to {self.rpc_url}")
            except ImportError:
                logger.warning("web3 not installed — running in demo mode")
        return self._web3

    async def update_vault_risk(
        self, risk_level: int, black_swan: bool, multiplier_bps: int
    ) -> dict[str, Any]:
        """Update TailGuardVault risk level on-chain."""
        w3 = self._get_web3()
        if not w3 or not self.private_key or not self.vault_address:
            logger.info(f"[DEMO] updateRiskLevel({risk_level}, {black_swan}, {multiplier_bps})")
            return {"status": "demo", "risk_level": risk_level, "black_swan": black_swan}

        try:
            from web3 import Web3
            vault = w3.eth.contract(
                address=Web3.to_checksum_address(self.vault_address),
                abi=VAULT_ABI_MINIMAL
            )
            account = w3.eth.account.from_key(self.private_key)
            tx = vault.functions.updateRiskLevel(
                risk_level, black_swan, multiplier_bps
            ).build_transaction({
                "from": account.address,
                "nonce": w3.eth.get_transaction_count(account.address),
                "gas": 100000,
                "gasPrice": w3.eth.gas_price,
            })
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
            logger.info(f"updateRiskLevel tx: {tx_hash.hex()}")
            return {"status": "submitted", "tx_hash": tx_hash.hex()}
        except Exception as e:
            logger.error(f"updateRiskLevel failed: {e}")
            return {"status": "error", "error": str(e)}

    async def post_reputation_feedback(
        self, score: int, category: str, details: str, task_id: int = 0
    ) -> dict[str, Any]:
        """Post feedback to ERC-8004 Reputation Registry."""
        w3 = self._get_web3()
        if not w3 or not self.private_key or not self.reputation_registry:
            logger.info(f"[DEMO] postFeedback(score={score}, category={category})")
            return {"status": "demo", "score": score, "category": category}

        try:
            from web3 import Web3
            rep = w3.eth.contract(
                address=Web3.to_checksum_address(self.reputation_registry),
                abi=REPUTATION_ABI_MINIMAL
            )
            account = w3.eth.account.from_key(self.private_key)
            tx = rep.functions.postFeedback(
                self.agent_registry_str, self.agent_id,
                score, category, details, task_id
            ).build_transaction({
                "from": account.address,
                "nonce": w3.eth.get_transaction_count(account.address),
                "gas": 150000,
                "gasPrice": w3.eth.gas_price,
            })
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
            return {"status": "submitted", "tx_hash": tx_hash.hex()}
        except Exception as e:
            logger.error(f"postFeedback failed: {e}")
            return {"status": "error", "error": str(e)}

    async def execute_claim(self, claim_id: int) -> dict[str, Any]:
        """Execute a validated claim payout."""
        w3 = self._get_web3()
        if not w3 or not self.private_key or not self.vault_address:
            logger.info(f"[DEMO] executeClaim({claim_id})")
            return {"status": "demo", "claim_id": claim_id}

        try:
            from web3 import Web3
            vault = w3.eth.contract(
                address=Web3.to_checksum_address(self.vault_address),
                abi=VAULT_ABI_MINIMAL
            )
            account = w3.eth.account.from_key(self.private_key)
            tx = vault.functions.executeClaim(claim_id).build_transaction({
                "from": account.address,
                "nonce": w3.eth.get_transaction_count(account.address),
                "gas": 200000,
                "gasPrice": w3.eth.gas_price,
            })
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
            return {"status": "submitted", "tx_hash": tx_hash.hex(), "claim_id": claim_id}
        except Exception as e:
            logger.error(f"executeClaim failed: {e}")
            return {"status": "error", "error": str(e)}

    async def get_pool_stats(self) -> dict[str, Any]:
        """Get TailGuardVault pool statistics."""
        w3 = self._get_web3()
        if not w3 or not self.vault_address:
            return {
                "status": "demo",
                "pool_balance_usdc": 1_250_000,
                "premiums_collected_usdc": 87_500,
                "claims_paid_usdc": 12_000,
                "risk_level": 25,
                "black_swan_active": False,
                "note": "Demo mode — deploy contracts and set env vars for live data"
            }

        try:
            from web3 import Web3
            vault = w3.eth.contract(
                address=Web3.to_checksum_address(self.vault_address),
                abi=VAULT_ABI_MINIMAL
            )
            stats = vault.functions.getPoolStats().call()
            return {
                "pool_balance_usdc": stats[0] / 1e6,
                "premiums_collected_usdc": stats[1] / 1e6,
                "claims_paid_usdc": stats[2] / 1e6,
                "risk_level": stats[3],
                "black_swan_active": stats[4],
            }
        except Exception as e:
            logger.error(f"getPoolStats failed: {e}")
            return {"status": "error", "error": str(e)}

    async def get_reputation(self) -> dict[str, Any]:
        """Get agent's on-chain reputation score."""
        w3 = self._get_web3()
        if not w3 or not self.reputation_registry:
            return {
                "status": "demo",
                "agent_registry": self.agent_registry_str,
                "agent_id": self.agent_id,
                "cumulative_score": 47,
                "feedback_count": 52,
                "average_score_x1000": 904,
                "note": "Demo mode — deploy contracts for live reputation data"
            }

        try:
            from web3 import Web3
            rep = w3.eth.contract(
                address=Web3.to_checksum_address(self.reputation_registry),
                abi=REPUTATION_ABI_MINIMAL
            )
            score, count, avg = rep.functions.getReputationScore(
                self.agent_registry_str, self.agent_id
            ).call()
            return {
                "agent_registry": self.agent_registry_str,
                "agent_id": self.agent_id,
                "cumulative_score": score,
                "feedback_count": count,
                "average_score_x1000": avg,
            }
        except Exception as e:
            logger.error(f"getReputationScore failed: {e}")
            return {"status": "error", "error": str(e)}
