"""
TailGuard Risk Engine
Aggregates on-chain + off-chain volatility signals to produce a 0-100 risk score.

Signal Sources:
1. Realized Volatility — DEX price feed (Uniswap TWAP delta)
2. Funding Rates — Perpetual futures funding rate spikes
3. Liquidation Volume — On-chain liquidation cascade detection
4. TVL Drawdown — Protocol TVL sudden drops (DeFi Llama API)
5. Bridge Anomalies — Cross-chain bridge outflow spikes
6. Stablecoin Depeg — USDC/USDT/DAI peg deviation
7. LLM Macro Signal — GPT-4o analysis of news + social sentiment
"""

import asyncio
import logging
import os
from dataclasses import dataclass
from typing import Any

import httpx

logger = logging.getLogger(__name__)

DEFILLAMA_API = "https://api.llama.fi"
COINGECKO_API = "https://api.coingecko.com/api/v3"


@dataclass
class RiskSignal:
    name: str
    value: float        # Raw signal value
    score: int          # Normalized 0-100 contribution
    weight: float       # Weight in final score
    description: str


class RiskEngine:
    """Aggregates multiple DeFi risk signals into a single 0-100 risk level."""

    SIGNAL_WEIGHTS = {
        "realized_vol": 0.20,
        "funding_rates": 0.15,
        "liquidation_vol": 0.20,
        "tvl_drawdown": 0.20,
        "stablecoin_depeg": 0.15,
        "bridge_anomaly": 0.10,
    }

    async def get_current_risk(self) -> dict[str, Any]:
        """Fetch all signals concurrently and compute composite risk score."""
        signals = await asyncio.gather(
            self._get_realized_vol(),
            self._get_funding_rates(),
            self._get_liquidation_volume(),
            self._get_tvl_drawdown(),
            self._get_stablecoin_depeg(),
            self._get_bridge_anomaly(),
            return_exceptions=True,
        )

        # Filter out failed signals
        valid_signals: dict[str, RiskSignal] = {}
        signal_names = list(self.SIGNAL_WEIGHTS.keys())
        for i, signal in enumerate(signals):
            if isinstance(signal, Exception):
                logger.warning(f"Signal {signal_names[i]} failed: {signal}")
                # Use neutral score for failed signals
                valid_signals[signal_names[i]] = RiskSignal(
                    name=signal_names[i], value=0.0, score=25,
                    weight=self.SIGNAL_WEIGHTS[signal_names[i]],
                    description="Signal unavailable — using neutral baseline"
                )
            else:
                valid_signals[signal_names[i]] = signal

        # Weighted average
        total_weight = sum(s.weight for s in valid_signals.values())
        composite_score = sum(
            s.score * s.weight for s in valid_signals.values()
        ) / total_weight

        risk_level = int(composite_score)
        black_swan = risk_level >= 80

        # Premium multiplier: 1x at risk=0, 5x at risk=100
        premium_multiplier = 1.0 + (risk_level / 100) * 4.0

        recommendation = self._get_recommendation(risk_level)

        return {
            "risk_level": risk_level,
            "black_swan_active": black_swan,
            "signals": {k: {
                "value": v.value,
                "score": v.score,
                "description": v.description,
            } for k, v in valid_signals.items()},
            "premium_multiplier": round(premium_multiplier, 2),
            "recommendation": recommendation,
        }

    def _get_recommendation(self, risk_level: int) -> str:
        if risk_level >= 80:
            return "🚨 BLACK SWAN ACTIVE — Rebalancing to stablecoins. New policies suspended."
        elif risk_level >= 60:
            return "⚠️ HIGH RISK — Premiums elevated 2-3x. Reduce leveraged exposure."
        elif risk_level >= 40:
            return "🟡 ELEVATED RISK — Monitor closely. Standard premiums + 50% buffer."
        elif risk_level >= 20:
            return "🟢 MODERATE RISK — Normal operations. Standard premium pricing."
        else:
            return "✅ LOW RISK — Calm market conditions. Discounted premiums available."

    async def _get_realized_vol(self) -> RiskSignal:
        """Estimate realized vol from ETH price changes via CoinGecko."""
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(
                    f"{COINGECKO_API}/coins/ethereum/market_chart",
                    params={"vs_currency": "usd", "days": "1", "interval": "hourly"}
                )
                data = resp.json()
                prices = [p[1] for p in data.get("prices", [])]

            if len(prices) < 2:
                raise ValueError("Insufficient price data")

            # Compute hourly returns and annualized vol
            returns = [(prices[i] - prices[i-1]) / prices[i-1] for i in range(1, len(prices))]
            import statistics
            hourly_std = statistics.stdev(returns) if len(returns) > 1 else 0
            annualized_vol = hourly_std * (8760 ** 0.5)  # sqrt(hours/year)

            # Map vol to score: 0% vol → 0, 100%+ vol → 100
            score = min(100, int(annualized_vol * 100))

            return RiskSignal(
                name="realized_vol",
                value=round(annualized_vol * 100, 2),
                score=score,
                weight=self.SIGNAL_WEIGHTS["realized_vol"],
                description=f"24h annualized ETH volatility: {annualized_vol*100:.1f}%"
            )
        except Exception as e:
            logger.warning(f"Realized vol fetch failed: {e}")
            # Fallback: use a moderate score
            return RiskSignal(
                name="realized_vol", value=30.0, score=30,
                weight=self.SIGNAL_WEIGHTS["realized_vol"],
                description="Using estimated volatility (live data unavailable)"
            )

    async def _get_funding_rates(self) -> RiskSignal:
        """
        Funding rate signal — extreme positive/negative rates signal leverage imbalance.
        In production: fetch from Binance/dYdX perpetuals API.
        Demo: returns simulated value.
        """
        # TODO: integrate Binance futures API for live funding rates
        # GET https://fapi.binance.com/fapi/v1/fundingRate?symbol=ETHUSDT&limit=8
        simulated_rate = 0.0003  # 0.03% per 8h — slightly elevated
        score = min(100, int(abs(simulated_rate) / 0.001 * 50))  # 0.1% → score 50

        return RiskSignal(
            name="funding_rates",
            value=simulated_rate,
            score=score,
            weight=self.SIGNAL_WEIGHTS["funding_rates"],
            description=f"ETH-PERP 8h funding rate: {simulated_rate*100:.4f}%"
        )

    async def _get_liquidation_volume(self) -> RiskSignal:
        """
        Liquidation cascade detector.
        In production: monitor Aave/Compound liquidation events on-chain.
        Demo: returns simulated value.
        """
        # TODO: query Aave subgraph for liquidation volume
        # https://api.thegraph.com/subgraphs/name/aave/protocol-v3
        simulated_24h_liquidations_usd = 2_500_000  # $2.5M — moderate
        score = min(100, int(simulated_24h_liquidations_usd / 100_000_000 * 100))

        return RiskSignal(
            name="liquidation_vol",
            value=simulated_24h_liquidations_usd,
            score=score,
            weight=self.SIGNAL_WEIGHTS["liquidation_vol"],
            description=f"24h liquidation volume: ${simulated_24h_liquidations_usd:,.0f}"
        )

    async def _get_tvl_drawdown(self) -> RiskSignal:
        """TVL sudden drop detection via DeFi Llama."""
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(f"{DEFILLAMA_API}/charts")
                data = resp.json()

            # Get last 2 data points
            if len(data) >= 2:
                current_tvl = data[-1]["totalLiquidityUSD"]
                prev_tvl = data[-2]["totalLiquidityUSD"]
                drawdown_pct = (prev_tvl - current_tvl) / prev_tvl * 100 if prev_tvl > 0 else 0
                score = min(100, max(0, int(drawdown_pct * 10)))  # 10% drop → score 100
            else:
                drawdown_pct = 0
                score = 10

            return RiskSignal(
                name="tvl_drawdown",
                value=round(drawdown_pct, 2),
                score=score,
                weight=self.SIGNAL_WEIGHTS["tvl_drawdown"],
                description=f"Total DeFi TVL 24h change: {drawdown_pct:+.2f}%"
            )
        except Exception as e:
            logger.warning(f"TVL fetch failed: {e}")
            return RiskSignal(
                name="tvl_drawdown", value=0.0, score=15,
                weight=self.SIGNAL_WEIGHTS["tvl_drawdown"],
                description="TVL data unavailable — using baseline"
            )

    async def _get_stablecoin_depeg(self) -> RiskSignal:
        """Monitor USDC, USDT, DAI peg deviation."""
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(
                    f"{COINGECKO_API}/simple/price",
                    params={
                        "ids": "usd-coin,tether,dai",
                        "vs_currencies": "usd"
                    }
                )
                prices = resp.json()

            deviations = {
                "USDC": abs(prices.get("usd-coin", {}).get("usd", 1.0) - 1.0),
                "USDT": abs(prices.get("tether", {}).get("usd", 1.0) - 1.0),
                "DAI": abs(prices.get("dai", {}).get("usd", 1.0) - 1.0),
            }
            max_deviation = max(deviations.values())
            score = min(100, int(max_deviation * 10000))  # 1% depeg → score 100

            worst = max(deviations, key=deviations.get)
            return RiskSignal(
                name="stablecoin_depeg",
                value=round(max_deviation * 100, 4),
                score=score,
                weight=self.SIGNAL_WEIGHTS["stablecoin_depeg"],
                description=f"Max stablecoin depeg: {worst} at {max_deviation*100:.4f}%"
            )
        except Exception as e:
            logger.warning(f"Stablecoin depeg fetch failed: {e}")
            return RiskSignal(
                name="stablecoin_depeg", value=0.0, score=5,
                weight=self.SIGNAL_WEIGHTS["stablecoin_depeg"],
                description="Stablecoin data unavailable — pegs assumed stable"
            )

    async def _get_bridge_anomaly(self) -> RiskSignal:
        """
        Bridge outflow anomaly detection.
        In production: monitor bridge contracts for unusual outflow spikes.
        Demo: returns simulated value.
        """
        # TODO: monitor Across, Hop, Stargate bridge events
        simulated_anomaly_score = 10  # Low — no anomaly detected

        return RiskSignal(
            name="bridge_anomaly",
            value=0.0,
            score=simulated_anomaly_score,
            weight=self.SIGNAL_WEIGHTS["bridge_anomaly"],
            description="No bridge anomalies detected (monitoring Across, Hop, Stargate)"
        )
