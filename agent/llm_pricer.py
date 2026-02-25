"""
TailGuard LLM Pricer
Uses GPT-4o to reason about DeFi risk and price insurance premiums algorithmically.

Pricing model:
  base_rate_bps = BASE_RATES[risk_category]
  adjusted_rate = base_rate * risk_multiplier * duration_factor
  premium = coverage_amount * adjusted_rate / 10000
"""

import logging
import os
from datetime import datetime, timezone, timedelta
from typing import Any

logger = logging.getLogger(__name__)

# Base annual premium rates by category (basis points)
BASE_ANNUAL_RATES_BPS = {
    "defi-protocol": 200,       # 2% annual — smart contract exploit risk
    "stablecoin-depeg": 50,     # 0.5% annual — stablecoin peg risk
    "bridge": 300,              # 3% annual — bridge hack risk (highest historical loss)
    "liquidation": 150,         # 1.5% annual — liquidation cascade risk
    "oracle-manipulation": 250, # 2.5% annual — oracle attack risk
    "governance-attack": 100,   # 1% annual — governance attack risk
    "general": 175,             # 1.75% annual — general DeFi risk
}

# Historical DeFi incident data for LLM context
HISTORICAL_INCIDENTS = """
Major DeFi incidents for context:
- Ronin Bridge (Mar 2022): $625M stolen, bridge hack
- Wormhole (Feb 2022): $320M, bridge exploit
- Nomad Bridge (Aug 2022): $190M, bridge exploit  
- Euler Finance (Mar 2023): $197M, flash loan attack
- Curve Finance (Jul 2023): $70M, reentrancy via Vyper bug
- Mango Markets (Oct 2022): $117M, oracle manipulation
- Beanstalk (Apr 2022): $182M, governance flash loan
- Tornado Cash (Aug 2022): $1B TVL frozen, regulatory
- USDC depeg (Mar 2023): 8.7% depeg during SVB crisis
- 3AC collapse (Jun 2022): $2B+ liquidation cascade
"""


class LLMPricer:
    """AI-powered insurance premium pricer using LLM reasoning."""

    def __init__(self):
        self.api_key = os.getenv("OPENAI_API_KEY")
        self.model = os.getenv("LLM_MODEL", "gpt-4o")

    async def price_premium(
        self,
        coverage_amount: float,
        risk_category: str,
        protocol_address: str | None,
        duration_days: int,
        current_risk: dict[str, Any],
    ) -> dict[str, Any]:
        """
        Price an insurance premium using LLM reasoning + quantitative model.
        Returns quote dict matching PremiumQuoteResponse schema.
        """
        # Quantitative base calculation
        base_rate_bps = BASE_ANNUAL_RATES_BPS.get(risk_category, BASE_ANNUAL_RATES_BPS["general"])
        duration_factor = duration_days / 365.0

        # Apply risk multiplier from current market conditions
        risk_multiplier = current_risk.get("premium_multiplier", 1.0)
        adjusted_rate_bps = int(base_rate_bps * risk_multiplier)

        # Duration discount: longer policies get slight discount
        if duration_days >= 180:
            adjusted_rate_bps = int(adjusted_rate_bps * 0.85)
        elif duration_days >= 90:
            adjusted_rate_bps = int(adjusted_rate_bps * 0.92)

        premium_amount = coverage_amount * adjusted_rate_bps / 10000 * duration_factor

        # Get LLM reasoning
        reasoning = await self._get_llm_reasoning(
            coverage_amount=coverage_amount,
            risk_category=risk_category,
            protocol_address=protocol_address,
            duration_days=duration_days,
            current_risk=current_risk,
            base_rate_bps=base_rate_bps,
            adjusted_rate_bps=adjusted_rate_bps,
            premium_amount=premium_amount,
        )

        # Extract risk factors
        risk_factors = self._identify_risk_factors(risk_category, current_risk)

        quote_valid_until = (
            datetime.now(timezone.utc) + timedelta(hours=1)
        ).isoformat()

        return {
            "coverage_amount": coverage_amount,
            "premium_amount": round(premium_amount, 2),
            "premium_rate_bps": adjusted_rate_bps,
            "risk_level": current_risk["risk_level"],
            "risk_factors": risk_factors,
            "quote_valid_until": quote_valid_until,
            "reasoning": reasoning,
        }

    async def _get_llm_reasoning(self, **kwargs) -> str:
        """Get LLM explanation for the pricing decision."""
        if not self.api_key:
            return self._fallback_reasoning(**kwargs)

        try:
            import openai
            client = openai.AsyncOpenAI(api_key=self.api_key)

            prompt = f"""You are TailGuard, an on-chain DeFi insurance underwriter.
Provide a concise 2-3 sentence explanation for this premium quote.

Coverage: ${kwargs['coverage_amount']:,.0f} for {kwargs['risk_category']} risk
Duration: {kwargs['duration_days']} days
Current DeFi Risk Level: {kwargs['current_risk']['risk_level']}/100
Base Rate: {kwargs['base_rate_bps']} bps/year
Adjusted Rate: {kwargs['adjusted_rate_bps']} bps/year  
Premium: ${kwargs['premium_amount']:.2f}
Risk Multiplier: {kwargs['current_risk']['premium_multiplier']}x

Active risk signals:
{self._format_signals(kwargs['current_risk']['signals'])}

{HISTORICAL_INCIDENTS}

Explain: (1) why this rate is appropriate given current conditions, (2) what specific risks justify the pricing, (3) any hedging recommendations.
Keep it under 100 words."""

            response = await client.chat.completions.create(
                model=self.model,
                messages=[{"role": "user", "content": prompt}],
                max_tokens=200,
                temperature=0.3,
            )
            return response.choices[0].message.content.strip()

        except Exception as e:
            logger.warning(f"LLM pricing call failed: {e}")
            return self._fallback_reasoning(**kwargs)

    def _fallback_reasoning(self, **kwargs) -> str:
        risk_level = kwargs['current_risk']['risk_level']
        category = kwargs['risk_category']
        multiplier = kwargs['current_risk']['premium_multiplier']

        if risk_level >= 60:
            context = f"elevated market stress (risk level {risk_level}/100)"
        elif risk_level >= 30:
            context = f"moderate market conditions (risk level {risk_level}/100)"
        else:
            context = f"calm market conditions (risk level {risk_level}/100)"

        return (
            f"Premium priced at {kwargs['adjusted_rate_bps']} bps/year based on {context}. "
            f"The {category} risk category carries a {kwargs['base_rate_bps']} bps base rate, "
            f"adjusted {multiplier:.1f}x for current on-chain volatility signals. "
            f"This rate reflects historical {category} incident frequency and current DeFi liquidity conditions."
        )

    def _format_signals(self, signals: dict) -> str:
        lines = []
        for name, data in signals.items():
            lines.append(f"  - {name}: score={data['score']}/100 — {data['description']}")
        return "\n".join(lines)

    def _identify_risk_factors(self, risk_category: str, current_risk: dict) -> list[str]:
        factors = []

        # Category-specific factors
        category_factors = {
            "defi-protocol": ["Smart contract exploit risk", "Flash loan attack vector"],
            "stablecoin-depeg": ["Collateral backing uncertainty", "Regulatory intervention risk"],
            "bridge": ["Cross-chain message validation", "Validator key compromise"],
            "liquidation": ["Leverage cascade risk", "Oracle price manipulation"],
            "oracle-manipulation": ["Price feed manipulation", "Sandwich attack exposure"],
            "governance-attack": ["Flash loan governance", "Voter apathy risk"],
        }
        factors.extend(category_factors.get(risk_category, ["General DeFi protocol risk"]))

        # Signal-based factors
        signals = current_risk.get("signals", {})
        if signals.get("realized_vol", {}).get("score", 0) > 50:
            factors.append("Elevated realized volatility")
        if signals.get("liquidation_vol", {}).get("score", 0) > 40:
            factors.append("Active liquidation cascades")
        if signals.get("stablecoin_depeg", {}).get("score", 0) > 20:
            factors.append("Stablecoin peg stress detected")
        if signals.get("bridge_anomaly", {}).get("score", 0) > 30:
            factors.append("Bridge outflow anomaly")

        return factors[:5]  # Cap at 5 factors
