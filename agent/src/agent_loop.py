"""
ERC-8004 Agent Loop — autonomous monitoring and execution.

Runs continuously:
1. Fetch volatility data every VOLATILITY_UPDATE_INTERVAL seconds
2. Push updated volatility to on-chain oracle
3. Scan active policies for trigger conditions
4. Use LLM to decide whether to pay claims
5. Execute claim payments autonomously via ERC-8004
6. Update trust score based on outcomes
"""

import asyncio
import logging
import time
from typing import Any

from .blockchain import BlockchainClient
from .config import settings
from .risk_engine import RiskEngine
from .volatility_oracle import VolatilityOracle, VolatilityReading

logger = logging.getLogger(__name__)


class AgentLoop:
    """Main ERC-8004 agent execution loop."""

    def __init__(
        self,
        blockchain: BlockchainClient,
        vol_oracle: VolatilityOracle,
        risk_engine: RiskEngine,
    ) -> None:
        self.blockchain = blockchain
        self.vol_oracle = vol_oracle
        self.risk_engine = risk_engine

        self._running = False
        self._last_vol_update = 0.0
        self._cycle_count = 0
        self._stats: dict[str, Any] = {
            "cycles": 0,
            "vol_updates": 0,
            "claims_assessed": 0,
            "claims_paid": 0,
            "claims_rejected": 0,
            "errors": 0,
        }

    async def start(self) -> None:
        """Start the agent loop."""
        logger.info(
            f"Starting ERC-8004 agent loop",
            extra={
                "agent_id": settings.agent_id,
                "auto_claim": settings.auto_claim_enabled,
                "poll_interval": settings.poll_interval_seconds,
            }
        )
        self._running = True
        await self._run()

    async def stop(self) -> None:
        """Stop the agent loop."""
        logger.info("Stopping agent loop")
        self._running = False

    async def _run(self) -> None:
        """Main loop."""
        while self._running:
            try:
                await self._cycle()
            except Exception as e:
                logger.error(f"Agent cycle error: {e}", exc_info=True)
                self._stats["errors"] += 1

            await asyncio.sleep(settings.poll_interval_seconds)

    async def _cycle(self) -> None:
        """Single monitoring cycle."""
        self._cycle_count += 1
        self._stats["cycles"] = self._cycle_count
        logger.debug(f"Agent cycle #{self._cycle_count}")

        # 1. Check trust score — if too low, skip autonomous actions
        trust_score = self.blockchain.oracle.functions.getOverallScore(
            settings.agent_id
        ).call()

        if trust_score < settings.min_trust_score:
            logger.warning(
                f"Trust score {trust_score} below minimum {settings.min_trust_score} — skipping"
            )
            return

        # 2. Update volatility if interval elapsed
        now = time.time()
        if now - self._last_vol_update >= settings.volatility_update_interval:
            await self._update_volatility()

        # 3. Scan policies and assess claims
        if settings.auto_claim_enabled:
            await self._scan_policies()

    async def _update_volatility(self) -> None:
        """Fetch real-time volatility and push to chain."""
        try:
            reading = await self.vol_oracle.get_volatility()
            logger.info(
                f"Volatility update: {reading.value_bps} bps ({reading.regime})",
                extra={"source": reading.source, "vol_pct": reading.realized_vol_pct}
            )

            tx_hash = self.blockchain.update_volatility(
                settings.agent_id, reading.value_bps
            )
            self._last_vol_update = time.time()
            self._stats["vol_updates"] += 1

            logger.info(f"Volatility updated on-chain: {tx_hash}")

        except Exception as e:
            logger.error(f"Volatility update failed: {e}")
            raise

    async def _scan_policies(self) -> None:
        """Scan active policies and trigger claims if conditions are met."""
        # Get current volatility
        current_vol = self.blockchain.get_volatility_index()
        vol_reading = await self.vol_oracle.get_volatility()

        # Scan policies 1–100 (in production, use event logs)
        # TODO: Replace with event-log based scanning for production
        for policy_id in range(1, 101):
            try:
                policy = self.blockchain.get_policy(policy_id)

                # Skip if not active (status=0) or no holder
                if policy["holder"] == "0x" + "0" * 40:
                    break  # No more policies
                if policy["status"] != 0:  # 0 = Active
                    continue

                # Check if trigger condition is met
                if current_vol < policy["triggerThreshold"]:
                    continue

                # LLM assessment
                self._stats["claims_assessed"] += 1
                decision = await self.risk_engine.assess_claim(
                    policy=policy,
                    volatility=vol_reading,
                    market_context={
                        "chain_vol_bps": current_vol,
                        "oracle_vol_bps": vol_reading.value_bps,
                        "regime": vol_reading.regime,
                    },
                )

                logger.info(
                    f"Claim assessment for policy {policy_id}",
                    extra={
                        "should_pay": decision.should_pay,
                        "confidence": decision.confidence,
                        "reasoning": decision.reasoning[:100],
                    }
                )

                if decision.should_pay and decision.confidence >= 0.7:
                    await self._execute_claim(policy_id, decision)

            except Exception as e:
                if "revert" not in str(e).lower():
                    logger.error(f"Policy scan error for ID {policy_id}: {e}")

    async def _execute_claim(self, policy_id: int, decision: Any) -> None:
        """Execute a claim payment on-chain."""
        try:
            logger.info(
                f"Executing claim payment for policy {policy_id}",
                extra={"confidence": decision.confidence}
            )
            tx_hash = self.blockchain.pay_claim(settings.agent_id, policy_id)
            self._stats["claims_paid"] += 1
            logger.info(f"Claim paid for policy {policy_id}: {tx_hash}")

        except Exception as e:
            self._stats["claims_rejected"] += 1
            logger.error(f"Claim execution failed for policy {policy_id}: {e}")

    def get_stats(self) -> dict[str, Any]:
        """Get agent loop statistics."""
        return {
            **self._stats,
            "running": self._running,
            "last_vol_update": self._last_vol_update,
        }
