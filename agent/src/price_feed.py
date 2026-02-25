"""
Price feed service — fetches real-time and historical prices from CoinGecko.
Falls back to synthetic data when API is unavailable.
"""

from __future__ import annotations

import math
import random
from datetime import datetime, timedelta
from typing import Optional

import httpx
import structlog

from .config import settings
from .models import MarketSnapshot, PricePoint

logger = structlog.get_logger(__name__)

COINGECKO_BASE = "https://api.coingecko.com/api/v3"
COINGECKO_PRO_BASE = "https://pro-api.coingecko.com/api/v3"

ASSET_IDS = {
    "ETH": "ethereum",
    "BTC": "bitcoin",
    "SOL": "solana",
    "AVAX": "avalanche-2",
    "MATIC": "matic-network",
    "LINK": "chainlink",
}


class PriceFeed:
    """Fetches and caches market prices."""

    def __init__(self):
        self._cache: dict[str, PricePoint] = {}
        self._last_fetch: Optional[datetime] = None
        self._cache_ttl_seconds = 60
        base = COINGECKO_PRO_BASE if settings.coingecko_api_key else COINGECKO_BASE
        self._base_url = base
        self._headers = {}
        if settings.coingecko_api_key:
            self._headers["x-cg-pro-api-key"] = settings.coingecko_api_key

    async def get_snapshot(self) -> MarketSnapshot:
        """Get current market snapshot for all tracked assets."""
        # Use cache if fresh
        if (
            self._last_fetch
            and (datetime.utcnow() - self._last_fetch).seconds < self._cache_ttl_seconds
            and self._cache
        ):
            return MarketSnapshot(
                timestamp=self._last_fetch,
                prices=self._cache,
            )

        try:
            prices = await self._fetch_coingecko()
        except Exception as e:
            logger.warning("coingecko_fetch_failed", error=str(e))
            prices = self._synthetic_prices()

        self._cache = prices
        self._last_fetch = datetime.utcnow()

        return MarketSnapshot(
            timestamp=self._last_fetch,
            prices=prices,
        )

    async def get_historical(
        self,
        asset: str,
        days: int = 30,
    ) -> list[tuple[datetime, float]]:
        """Get historical daily prices for an asset."""
        coin_id = ASSET_IDS.get(asset.upper())
        if not coin_id:
            return self._synthetic_history(asset, days)

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.get(
                    f"{self._base_url}/coins/{coin_id}/market_chart",
                    params={"vs_currency": "usd", "days": days, "interval": "daily"},
                    headers=self._headers,
                )
                resp.raise_for_status()
                data = resp.json()
                prices = data.get("prices", [])
                return [
                    (datetime.fromtimestamp(ts / 1000), price)
                    for ts, price in prices
                ]
        except Exception as e:
            logger.warning("historical_fetch_failed", asset=asset, error=str(e))
            return self._synthetic_history(asset, days)

    async def _fetch_coingecko(self) -> dict[str, PricePoint]:
        """Fetch current prices from CoinGecko."""
        coin_ids = ",".join(ASSET_IDS.values())
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.get(
                f"{self._base_url}/coins/markets",
                params={
                    "vs_currency": "usd",
                    "ids": coin_ids,
                    "order": "market_cap_desc",
                    "sparkline": "false",
                    "price_change_percentage": "24h",
                },
                headers=self._headers,
            )
            resp.raise_for_status()
            data = resp.json()

        id_to_symbol = {v: k for k, v in ASSET_IDS.items()}
        prices = {}
        now = datetime.utcnow()

        for coin in data:
            symbol = id_to_symbol.get(coin["id"])
            if symbol:
                prices[symbol] = PricePoint(
                    timestamp=now,
                    asset=symbol,
                    price_usd=coin.get("current_price", 0),
                    volume_24h=coin.get("total_volume", 0),
                    market_cap=coin.get("market_cap", 0),
                    price_change_24h=coin.get("price_change_percentage_24h", 0),
                )

        return prices

    def _synthetic_prices(self) -> dict[str, PricePoint]:
        """Generate synthetic prices for testing."""
        now = datetime.utcnow()
        base_prices = {
            "ETH": 2800.0,
            "BTC": 65000.0,
            "SOL": 145.0,
            "AVAX": 38.0,
            "MATIC": 0.85,
            "LINK": 14.0,
        }
        prices = {}
        for symbol, base in base_prices.items():
            noise = random.gauss(0, 0.01)
            price = base * (1 + noise)
            prices[symbol] = PricePoint(
                timestamp=now,
                asset=symbol,
                price_usd=round(price, 2),
                volume_24h=base * 1e6 * random.uniform(0.5, 2.0),
                market_cap=base * 1e9 * random.uniform(0.9, 1.1),
                price_change_24h=round(noise * 100, 2),
            )
        return prices

    def _synthetic_history(
        self, asset: str, days: int
    ) -> list[tuple[datetime, float]]:
        """Generate synthetic price history using GBM."""
        base_prices = {"ETH": 2800.0, "BTC": 65000.0}
        start_price = base_prices.get(asset.upper(), 100.0)

        # Geometric Brownian Motion
        mu = 0.0002   # daily drift
        sigma = 0.03  # daily volatility

        history = []
        price = start_price
        now = datetime.utcnow()

        for i in range(days, 0, -1):
            ts = now - timedelta(days=i)
            history.append((ts, round(price, 2)))
            z = random.gauss(0, 1)
            price *= math.exp((mu - 0.5 * sigma**2) + sigma * z)

        return history
