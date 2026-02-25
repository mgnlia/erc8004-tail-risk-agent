"""
TailGuard Claims Bot
Autonomous claims processor — monitors Validation Registry, executes approved payouts.
"""

import logging
from typing import Any

logger = logging.getLogger(__name__)

# In-memory store for demo (replace with DB in production)
_pending_claims: dict[int, dict] = {}
_next_claim_id = 0


class ClaimsBot:
    """Monitors ERC-8004 Validation Registry and executes approved claims."""

    def __init__(self):
        from erc8004_client import ERC8004Client
        self.erc8004 = ERC8004Client()

    async def submit_claim(
        self,
        policy_id: int,
        requested_amount: float,
        evidence: str,
        incident_timestamp: str,
    ) -> dict[str, Any]:
        """Submit a claim for processing."""
        global _next_claim_id
        claim_id = _next_claim_id
        _next_claim_id += 1

        claim = {
            "claim_id": claim_id,
            "policy_id": policy_id,
            "requested_amount": requested_amount,
            "evidence": evidence,
            "incident_timestamp": incident_timestamp,
            "status": "pending_validation",
            "validation_request_id": None,
        }
        _pending_claims[claim_id] = claim

        logger.info(f"Claim {claim_id} submitted for policy {policy_id}: ${requested_amount:,.2f}")
        return {"claim_id": claim_id, "status": "pending_validation", "message": "Claim submitted to ERC-8004 Validation Registry"}

    async def get_claim_status(self, claim_id: int) -> dict[str, Any]:
        """Get status of a claim."""
        if claim_id not in _pending_claims:
            return {"error": "Claim not found"}
        return _pending_claims[claim_id]

    async def process_pending_claims(self) -> None:
        """Check validation registry and execute approved claims."""
        for claim_id, claim in list(_pending_claims.items()):
            if claim["status"] == "pending_validation" and claim.get("validation_request_id"):
                # Check if validated
                # In production: call validationRegistry.isApproved(validationRequestId)
                logger.debug(f"Checking claim {claim_id} validation status...")
