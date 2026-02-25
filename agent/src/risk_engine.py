"""
Risk Engine — LLM-powered reasoning for policy underwriting decisions.

Uses Claude/GPT to:
1. Analyze current market conditions
2. Assess policy risk parameters
3. Recommend premium adjustments
4. Decide whether to trigger claim payments
"""

import logging
from dataclasses import dataclass
from typing import Any

from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.language_models import BaseChatModel

from .config import settings
from .volatility_oracle import VolatilityReading

logger = logging.getLogger(__name__)


@dataclass
class UnderwritingDecision:
    """LLM reasoning output for policy underwriting."""
    should_approve: bool
    risk_score: int          # 0–100 (higher = riskier)
    recommended_premium_bps: int  # Premium as bps of coverage
    reasoning: str
    confidence: float        # 0.0–1.0


@dataclass
class ClaimDecision:
    """LLM reasoning output for claim payment."""
    should_pay: bool
    confidence: float
    reasoning: str
    supporting_signals: list[str]


SYSTEM_PROMPT = """You are an AI risk underwriter for a DeFi tail-risk insurance protocol.
You operate as an ERC-8004 autonomous agent on Ethereum, making on-chain decisions about:
1. Whether to approve insurance policies
2. Whether to trigger claim payments during tail-risk events

Your decisions are executed autonomously via smart contracts. Be conservative and precise.
Always provide structured JSON responses.

Risk Philosophy:
- Tail-risk events: VIX-proxy > 7500 bps (75% annualized vol)
- Black swan events require multiple confirming signals
- Capital preservation is paramount — false positives (paying unwarranted claims) are costly
- False negatives (missing real events) damage trust score and policyholder confidence

Your trust score on-chain reflects your historical accuracy. Maintain it above 6000 bps (60%)."""


class RiskEngine:
    """LLM-powered risk reasoning engine."""

    def __init__(self, llm: BaseChatModel) -> None:
        self.llm = llm

    async def assess_underwriting(
        self,
        coverage: int,
        duration_days: int,
        trigger_threshold_bps: int,
        volatility: VolatilityReading,
        vault_stats: dict[str, Any],
    ) -> UnderwritingDecision:
        """Assess whether to approve a new policy and at what premium."""

        prompt = f"""Assess this tail-risk insurance policy request:

POLICY PARAMETERS:
- Coverage amount: ${coverage / 1e6:,.2f} USDC
- Duration: {duration_days} days
- Trigger threshold: {trigger_threshold_bps / 100:.1f}% annualized vol

CURRENT MARKET CONDITIONS:
- Volatility regime: {volatility.regime}
- Current vol: {volatility.realized_vol_pct:.1f}% (annualized)
- VIX-proxy: {volatility.value_bps} bps

VAULT STATUS:
- Total assets: ${vault_stats.get('totalAssets', 0) / 1e6:,.2f} USDC
- Total coverage outstanding: ${vault_stats.get('totalPolicyCoverage', 0) / 1e6:,.2f} USDC
- Available capital: ${vault_stats.get('availableCapital', 0) / 1e6:,.2f} USDC

Respond with JSON only:
{{
  "should_approve": true/false,
  "risk_score": 0-100,
  "recommended_premium_bps": integer (premium as bps of coverage, e.g. 300 = 3%),
  "reasoning": "brief explanation",
  "confidence": 0.0-1.0
}}"""

        try:
            response = await self.llm.ainvoke([
                SystemMessage(content=SYSTEM_PROMPT),
                HumanMessage(content=prompt),
            ])

            import json
            data = json.loads(response.content.strip())
            return UnderwritingDecision(
                should_approve=data.get("should_approve", True),
                risk_score=int(data.get("risk_score", 50)),
                recommended_premium_bps=int(data.get("recommended_premium_bps", 300)),
                reasoning=data.get("reasoning", ""),
                confidence=float(data.get("confidence", 0.7)),
            )
        except Exception as e:
            logger.error(f"LLM underwriting assessment failed: {e}")
            # Conservative fallback
            return UnderwritingDecision(
                should_approve=True,
                risk_score=50,
                recommended_premium_bps=300,
                reasoning=f"LLM unavailable, using defaults: {e}",
                confidence=0.3,
            )

    async def assess_claim(
        self,
        policy: dict[str, Any],
        volatility: VolatilityReading,
        market_context: dict[str, Any],
    ) -> ClaimDecision:
        """Assess whether to trigger a claim payment."""

        prompt = f"""A tail-risk insurance policy may need to be triggered.

POLICY DETAILS:
- Coverage: ${policy.get('coverage', 0) / 1e6:,.2f} USDC
- Trigger threshold: {policy.get('triggerThreshold', 0) / 100:.1f}% vol
- Status: {policy.get('status', 'unknown')}

CURRENT CONDITIONS:
- Volatility regime: {volatility.regime}
- Current VIX-proxy: {volatility.value_bps} bps ({volatility.realized_vol_pct:.1f}% vol)
- Trigger threshold: {policy.get('triggerThreshold', 0)} bps
- Threshold exceeded: {volatility.value_bps >= policy.get('triggerThreshold', 99999)}

MARKET CONTEXT:
{market_context}

Should the claim be paid? Consider:
1. Is the trigger condition genuinely met (not a data spike)?
2. Does this match a real tail-risk event pattern?
3. Is capital preservation at risk if we pay?

Respond with JSON only:
{{
  "should_pay": true/false,
  "confidence": 0.0-1.0,
  "reasoning": "explanation",
  "supporting_signals": ["signal1", "signal2"]
}}"""

        try:
            response = await self.llm.ainvoke([
                SystemMessage(content=SYSTEM_PROMPT),
                HumanMessage(content=prompt),
            ])

            import json
            data = json.loads(response.content.strip())
            return ClaimDecision(
                should_pay=data.get("should_pay", False),
                confidence=float(data.get("confidence", 0.5)),
                reasoning=data.get("reasoning", ""),
                supporting_signals=data.get("supporting_signals", []),
            )
        except Exception as e:
            logger.error(f"LLM claim assessment failed: {e}")
            # Conservative fallback — don't auto-pay if LLM is down
            return ClaimDecision(
                should_pay=False,
                confidence=0.0,
                reasoning=f"LLM unavailable: {e}. Manual review required.",
                supporting_signals=[],
            )
