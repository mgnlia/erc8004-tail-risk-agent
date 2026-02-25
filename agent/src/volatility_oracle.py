"""
Volatility Oracle — fetches real-time market data and computes
a VIX-proxy (0–10000 bps) for use as the on-chain trigger signal.

Data sources (in priority order):
1. CoinGecko free API — BTC/ETH price data for realized vol computation
2. Fallback: mock data for demo/testing
"""

import asyncio
import logging
import time
from dataclasses import dataclass
from typing import Optional

import httpx
import numpy as np

logger = logging.getLogger(__name__)


@dataclass
class VolatilityReading:
    """A single volatility measurement."""
    value_bps: int          # 0–10000 bps
    realized_vol_pct: float # Annualized realized volatility %
    source: str
    timestamp: float
    assets: list[str]
    regime: str             # "calm", "elevated", "stress", "black_swan"


class VolatilityOracle:
    """
    Computes a composite VIX-proxy from on-chain and off-chain signals.

    VIX-proxy mapping:
      0–2000 bps  → Calm (annualized vol < 20%)
      2000–5000   → Elevated (20–50%)
      5000–7500   → Stress (50–75%)
      7500–10000  → Black Swan (75%+)
    """

    COINGECKO_BASE = "https://api.coingecko.com/api/v3"
    ASSETS = ["bitcoin", "ethereum"]
    LOOKBACK_DAYS = 7

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(timeout=30.0)
        self._last_reading: Optional[VolatilityReading] = None
        self._cache_ttl = 300  # 5 minutes

    async def get_volatility(self) -> VolatilityReading:
        """Get current volatility reading, using cache if fresh."""
        now = time.time()
        if (
            self._last_reading is not None
            and now - self._last_reading.timestamp < self._cache_ttl
        ):
            return self._last_reading

        try:
            reading = await self._fetch_coingecko()
        except Exception as e:
            logger.warning(f"CoinGecko fetch failed: {e}, using fallback")
            reading = self._mock_reading()

        self._last_reading = reading
        return reading

    async def _fetch_coingecko(self) -> VolatilityReading:
        """Fetch price history and compute realized volatility."""
        prices: dict[str, list[float]] = {}

        for asset in self.ASSETS:
            url = f"{self.COINGECKO_BASE}/coins/{asset}/market_chart"
            params = {"vs_currency": "usd", "days": self.LOOKBACK_DAYS, "interval": "daily"}
            resp = await self._client.get(url, params=params)
            resp.raise_for_status()
            data = resp.json()
            prices[asset] = [p[1] for p in data["prices"]]

        # Compute annualized realized volatility for each asset
        vols = []
        for asset, price_series in prices.items():
            if len(price_series) < 2:
                continue
            arr = np.array(price_series)
            log_returns = np.diff(np.log(arr))
            daily_vol = float(np.std(log_returns))
            annualized_vol = daily_vol * np.sqrt(365) * 100  # as percentage
            vols.append(annualized_vol)
            logger.debug(f"{asset} annualized vol: {annualized_vol:.1f}%")

        composite_vol = float(np.mean(vols)) if vols else 50.0

        return self._vol_to_reading(composite_vol, source="coingecko")

    def _vol_to_reading(self, vol_pct: float, source: str) -> VolatilityReading:
        """Convert annualized vol % to a VolatilityReading."""
        # Map vol_pct to 0–10000 bps
        # 0% → 0 bps, 100%+ → 10000 bps (capped)
        value_bps = min(int(vol_pct * 100), 10000)

        if value_bps < 2000:
            regime = "calm"
        elif value_bps < 5000:
            regime = "elevated"
        elif value_bps < 7500:
            regime = "stress"
        else:
            regime = "black_swan"

        return VolatilityReading(
            value_bps=value_bps,
            realized_vol_pct=vol_pct,
            source=source,
            timestamp=time.time(),
            assets=self.ASSETS,
            regime=regime,
        )

    def _mock_reading(self) -> VolatilityReading:
        """Return a mock reading for testing/demo purposes."""
        import random
        # Simulate a realistic crypto volatility (30–80% annualized)
        vol_pct = random.uniform(30.0, 80.0)
        return self._vol_to_reading(vol_pct, source="mock")

    async def close(self) -> None:
        await self._client.aclose()
