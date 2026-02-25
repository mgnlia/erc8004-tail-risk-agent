"""
FastAPI server — exposes agent status, vault stats, and manual controls.
Powers the frontend dashboard.
"""

import asyncio
import logging
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from .config import settings

logger = logging.getLogger(__name__)

# ── Global state (initialized in lifespan) ────────────────────────────────────
_blockchain = None
_vol_oracle = None
_risk_engine = None
_agent_loop = None
_loop_task = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize and tear down agent components."""
    global _blockchain, _vol_oracle, _risk_engine, _agent_loop, _loop_task

    logger.info("Initializing agent components...")

    from .blockchain import BlockchainClient
    from .volatility_oracle import VolatilityOracle
    from .risk_engine import RiskEngine
    from .agent_loop import AgentLoop

    _blockchain = BlockchainClient()
    _vol_oracle = VolatilityOracle()

    # Initialize LLM
    try:
        if settings.anthropic_api_key:
            from langchain_anthropic import ChatAnthropic
            llm = ChatAnthropic(
                model=settings.llm_model,
                api_key=settings.anthropic_api_key,
                temperature=settings.llm_temperature,
            )
        elif settings.openai_api_key:
            from langchain_openai import ChatOpenAI
            llm = ChatOpenAI(
                model="gpt-4o",
                api_key=settings.openai_api_key,
                temperature=settings.llm_temperature,
            )
        else:
            raise ValueError("No LLM API key configured")

        _risk_engine = RiskEngine(llm)
        _agent_loop = AgentLoop(_blockchain, _vol_oracle, _risk_engine)

        # Start agent loop in background
        _loop_task = asyncio.create_task(_agent_loop.start())
        logger.info("Agent loop started")

    except Exception as e:
        logger.warning(f"Agent loop not started (demo mode): {e}")

    yield

    # Cleanup
    if _agent_loop:
        await _agent_loop.stop()
    if _loop_task:
        _loop_task.cancel()
    if _vol_oracle:
        await _vol_oracle.close()

    logger.info("Agent components shut down")


# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="ERC-8004 Tail Risk Agent API",
    version="0.1.0",
    description="Autonomous AI insurance underwriter on Ethereum",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.api_cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Models ────────────────────────────────────────────────────────────────────

class VolatilityResponse(BaseModel):
    value_bps: int
    realized_vol_pct: float
    source: str
    regime: str
    timestamp: float


class VaultStatsResponse(BaseModel):
    totalAssets: int
    totalPolicyCoverage: int
    availableCapital: int
    sharePrice: int
    volatilityIndex: int


class TrustScoreResponse(BaseModel):
    agentId: int
    claimAccuracy: int
    capitalPreservation: int
    responseTime: int
    overall: int
    lastUpdated: int
    updateCount: int


class AgentStatusResponse(BaseModel):
    agentId: int
    agentName: str
    running: bool
    connected: bool
    stats: dict[str, Any]
    trustScore: int | None = None


class ManualVolUpdateRequest(BaseModel):
    volatility_bps: int


class ManualClaimRequest(BaseModel):
    policy_id: int


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "agent": settings.agent_name, "version": "0.1.0"}


@app.get("/agent/status", response_model=AgentStatusResponse)
async def get_agent_status():
    """Get current agent status and stats."""
    connected = _blockchain.is_connected() if _blockchain else False
    stats = _agent_loop.get_stats() if _agent_loop else {}

    trust_score = None
    if _blockchain and connected and settings.trust_oracle_address:
        try:
            trust_score = _blockchain.oracle.functions.getOverallScore(
                settings.agent_id
            ).call()
        except Exception:
            pass

    return AgentStatusResponse(
        agentId=settings.agent_id,
        agentName=settings.agent_name,
        running=_agent_loop._running if _agent_loop else False,
        connected=connected,
        stats=stats,
        trustScore=trust_score,
    )


@app.get("/volatility", response_model=VolatilityResponse)
async def get_volatility():
    """Get current off-chain volatility reading."""
    if _vol_oracle is None:
        raise HTTPException(status_code=503, detail="Volatility oracle not initialized")

    reading = await _vol_oracle.get_volatility()
    return VolatilityResponse(
        value_bps=reading.value_bps,
        realized_vol_pct=reading.realized_vol_pct,
        source=reading.source,
        regime=reading.regime,
        timestamp=reading.timestamp,
    )


@app.get("/vault/stats", response_model=VaultStatsResponse)
async def get_vault_stats():
    """Get on-chain vault statistics."""
    if _blockchain is None:
        raise HTTPException(status_code=503, detail="Blockchain client not initialized")

    if not settings.tail_risk_vault_address:
        # Return mock data for demo
        return VaultStatsResponse(
            totalAssets=500_000_000_000,  # 500K USDC (6 decimals)
            totalPolicyCoverage=120_000_000_000,
            availableCapital=280_000_000_000,
            sharePrice=1_050_000_000_000_000_000,  # 1.05 USDC per share
            volatilityIndex=3500,
        )

    try:
        stats = _blockchain.get_vault_stats()
        return VaultStatsResponse(**stats)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/trust-score/{agent_id}", response_model=TrustScoreResponse)
async def get_trust_score(agent_id: int):
    """Get trust score for an agent."""
    if _blockchain is None:
        raise HTTPException(status_code=503, detail="Blockchain client not initialized")

    if not settings.trust_oracle_address:
        # Return mock data for demo
        return TrustScoreResponse(
            agentId=agent_id,
            claimAccuracy=8200,
            capitalPreservation=8500,
            responseTime=7800,
            overall=8170,
            lastUpdated=1740000000,
            updateCount=42,
        )

    try:
        score = _blockchain.get_trust_score(agent_id)
        return TrustScoreResponse(agentId=agent_id, **score)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/policy/{policy_id}")
async def get_policy(policy_id: int):
    """Get policy details."""
    if _blockchain is None:
        raise HTTPException(status_code=503, detail="Blockchain client not initialized")

    if not settings.tail_risk_vault_address:
        raise HTTPException(status_code=404, detail="No vault deployed (demo mode)")

    try:
        return _blockchain.get_policy(policy_id)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/agent/update-volatility")
async def manual_update_volatility(req: ManualVolUpdateRequest):
    """Manually trigger an on-chain volatility update (admin)."""
    if _blockchain is None:
        raise HTTPException(status_code=503, detail="Blockchain client not initialized")

    if not 0 <= req.volatility_bps <= 10000:
        raise HTTPException(status_code=400, detail="volatility_bps must be 0–10000")

    try:
        tx_hash = _blockchain.update_volatility(settings.agent_id, req.volatility_bps)
        return {"tx_hash": tx_hash, "volatility_bps": req.volatility_bps}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/agent/pay-claim")
async def manual_pay_claim(req: ManualClaimRequest):
    """Manually trigger a claim payment (admin)."""
    if _blockchain is None:
        raise HTTPException(status_code=503, detail="Blockchain client not initialized")

    try:
        tx_hash = _blockchain.pay_claim(settings.agent_id, req.policy_id)
        return {"tx_hash": tx_hash, "policy_id": req.policy_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/demo/scenario")
async def get_demo_scenario():
    """Return a demo scenario for frontend visualization."""
    return {
        "scenario": "crypto_market_stress",
        "description": "Simulated March 2020-style crypto market event",
        "timeline": [
            {"t": 0, "event": "Normal market conditions", "vol_bps": 2800, "regime": "elevated"},
            {"t": 3600, "event": "BTC drops 15% in 1 hour", "vol_bps": 5500, "regime": "stress"},
            {"t": 7200, "event": "ETH correlation spike", "vol_bps": 7200, "regime": "stress"},
            {"t": 9000, "event": "Black swan threshold crossed", "vol_bps": 8100, "regime": "black_swan"},
            {"t": 9060, "event": "Agent detects trigger condition", "vol_bps": 8100, "regime": "black_swan"},
            {"t": 9120, "event": "LLM assesses claim validity (confidence: 0.94)", "vol_bps": 8100, "regime": "black_swan"},
            {"t": 9180, "event": "Claim payment executed on-chain", "vol_bps": 8100, "regime": "black_swan"},
            {"t": 14400, "event": "Market stabilizes", "vol_bps": 4200, "regime": "elevated"},
            {"t": 18000, "event": "Trust score updated: 8170 bps", "vol_bps": 3100, "regime": "elevated"},
        ],
        "policies_protected": 12,
        "total_claims_paid": "$ 180,000 USDC",
        "agent_response_time_seconds": 60,
        "trust_score_impact": "+120 bps",
    }
