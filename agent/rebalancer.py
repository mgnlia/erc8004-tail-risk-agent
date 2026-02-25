"""
TailGuard Rebalancer
Autonomous portfolio rebalancing during black-swan events.
Moves exposure from volatile assets to stablecoins via DEX aggregators.
"""

import logging
import os
from typing import Any

logger = logging.getLogger(__name__)


class Rebalancer:
    """
    Autonomous rebalancer — shifts portfolio to stable assets during black-swan events.
    
    In production: integrates with 1inch/Paraswap aggregator APIs to execute swaps.
    Demo mode: logs intended actions without executing.
    """

    STABLE_TARGETS = ["USDC", "USDT", "DAI"]
    RISK_THRESHOLDS = {
        "defensive": 60,    # Start reducing volatile exposure
        "emergency": 80,    # Full flight to safety
    }

    async def trigger_defensive_rebalance(self, risk: dict[str, Any]) -> dict[str, Any]:
        """
        Execute defensive portfolio rebalancing.
        Called when risk_level >= 60.
        """
        risk_level = risk["risk_level"]
        signals = risk.get("signals", {})

        if risk_level >= self.RISK_THRESHOLDS["emergency"]:
            allocation = {"USDC": 0.70, "USDT": 0.20, "DAI": 0.10, "ETH": 0.00}
            action = "EMERGENCY: Full flight to stablecoins"
        elif risk_level >= self.RISK_THRESHOLDS["defensive"]:
            allocation = {"USDC": 0.40, "USDT": 0.20, "DAI": 0.10, "ETH": 0.30}
            action = "DEFENSIVE: Reducing volatile exposure 70%"
        else:
            allocation = {"USDC": 0.20, "USDT": 0.10, "DAI": 0.05, "ETH": 0.65}
            action = "CAUTIOUS: Slight defensive tilt"

        rebalance_plan = {
            "triggered_at_risk_level": risk_level,
            "action": action,
            "target_allocation": allocation,
            "top_risk_signals": [
                f"{k}: {v['score']}/100"
                for k, v in sorted(
                    signals.items(), key=lambda x: x[1]["score"], reverse=True
                )[:3]
            ],
            "status": "demo" if not os.getenv("AGENT_PRIVATE_KEY") else "executing",
        }

        logger.warning(f"🔄 REBALANCE TRIGGERED: {action} (risk={risk_level})")

        if os.getenv("AGENT_PRIVATE_KEY"):
            await self._execute_swaps(allocation)

        return rebalance_plan

    async def _execute_swaps(self, target_allocation: dict[str, float]) -> None:
        """
        Execute swaps via 1inch Aggregator API.
        TODO: Implement full swap execution for production.
        """
        # 1inch API: https://api.1inch.dev/swap/v6.0/1/swap
        logger.info(f"[TODO] Execute swaps to reach target: {target_allocation}")
        # Implementation for Mar 9-22 sprint
