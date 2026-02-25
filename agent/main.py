"""
TailGuard — ERC-8004 Tail-Risk Protection Agent
FastAPI server: exposes agent API, orchestrates risk monitoring, pricing, rebalancing, claims
"""

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, BackgroundTasks, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from risk_engine import RiskEngine
from llm_pricer import LLMPricer
from rebalancer import Rebalancer
from claims_bot import ClaimsBot
from erc8004_client import ERC8004Client

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ─── Lifespan ────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize agent components on startup."""
    logger.info("🛡️ TailGuard Agent starting up...")

    app.state.risk_engine = RiskEngine()
    app.state.pricer = LLMPricer()
    app.state.rebalancer = Rebalancer()
    app.state.claims_bot = ClaimsBot()
    app.state.erc8004 = ERC8004Client()

    # Start background monitoring loop
    app.state.monitor_task = asyncio.create_task(monitor_loop(app))
    logger.info("✅ TailGuard Agent live — monitoring DeFi risk signals")

    yield

    # Shutdown
    app.state.monitor_task.cancel()
    logger.info("TailGuard Agent shutting down")


async def monitor_loop(app: FastAPI):
    """Background loop: poll risk signals every 60 seconds."""
    while True:
        try:
            risk = await app.state.risk_engine.get_current_risk()
            app.state.latest_risk = risk

            if risk["risk_level"] >= 80:
                logger.warning(f"🚨 BLACK SWAN ALERT: risk_level={risk['risk_level']}")
                await app.state.rebalancer.trigger_defensive_rebalance(risk)
                await app.state.erc8004.update_vault_risk(
                    risk["risk_level"], black_swan=True,
                    multiplier_bps=int(10000 * risk["premium_multiplier"])
                )
            elif risk["risk_level"] >= 60:
                logger.warning(f"⚠️  High risk: risk_level={risk['risk_level']}")
                await app.state.erc8004.update_vault_risk(
                    risk["risk_level"], black_swan=False,
                    multiplier_bps=int(10000 * risk["premium_multiplier"])
                )

            # Check pending claims
            await app.state.claims_bot.process_pending_claims()

        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error(f"Monitor loop error: {e}")

        await asyncio.sleep(60)


# ─── App ─────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="TailGuard — ERC-8004 Tail-Risk Protection Agent",
    description="AI-powered on-chain insurance underwriter using ERC-8004",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─── Models ──────────────────────────────────────────────────────────────────

class PremiumQuoteRequest(BaseModel):
    coverage_amount: float          # USD value to cover
    risk_category: str              # "defi-protocol", "stablecoin-depeg", "bridge"
    protocol_address: str | None = None
    duration_days: int = 30


class PremiumQuoteResponse(BaseModel):
    coverage_amount: float
    premium_amount: float
    premium_rate_bps: int           # Basis points per period
    risk_level: int                 # 0-100
    risk_factors: list[str]
    quote_valid_until: str
    reasoning: str                  # LLM explanation


class RiskSignalResponse(BaseModel):
    risk_level: int
    black_swan_active: bool
    signals: dict
    premium_multiplier: float
    timestamp: str
    recommendation: str


class ClaimRequest(BaseModel):
    policy_id: int
    requested_amount: float
    evidence_description: str
    incident_timestamp: str


# ─── Routes ──────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "agent": "TailGuard",
        "version": "1.0.0",
        "erc8004_standard": "EIP-8004",
        "network": os.getenv("ETHEREUM_NETWORK", "sepolia"),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/agent-card")
async def agent_card():
    """ERC-8004 Agent Registration File — served at well-known endpoint."""
    base_url = os.getenv("AGENT_BASE_URL", "https://tailguard-agent.vercel.app")
    return {
        "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
        "name": "TailGuard",
        "description": (
            "Trustless on-chain insurance underwriter for DeFi tail-risk protection. "
            "Monitors volatility signals, prices risk premiums algorithmically via LLM reasoning, "
            "auto-rebalances portfolios during black-swan events, and executes claims autonomously "
            "via ERC-8004 Validation Registry."
        ),
        "image": f"{base_url}/logo.png",
        "services": [
            {"name": "web", "endpoint": base_url},
            {"name": "A2A", "endpoint": f"{base_url}/.well-known/agent-card.json", "version": "0.3.0"},
        ],
        "x402Support": False,
        "active": True,
        "registrations": [
            {
                "agentId": int(os.getenv("ERC8004_AGENT_ID", "0")),
                "agentRegistry": os.getenv("ERC8004_AGENT_REGISTRY", "eip155:11155111:0x0"),
            }
        ],
        "supportedTrust": ["reputation", "crypto-economic"],
    }


@app.get("/.well-known/agent-registration.json")
async def well_known_agent_registration():
    """ERC-8004 endpoint domain verification file."""
    return {
        "registrations": [
            {
                "agentId": int(os.getenv("ERC8004_AGENT_ID", "0")),
                "agentRegistry": os.getenv("ERC8004_AGENT_REGISTRY", "eip155:11155111:0x0"),
            }
        ]
    }


@app.get("/risk", response_model=RiskSignalResponse)
async def get_risk_signals(request: "FastAPI"):
    """Get current DeFi risk signals and agent assessment."""
    try:
        risk = await app.state.risk_engine.get_current_risk()
        return RiskSignalResponse(
            risk_level=risk["risk_level"],
            black_swan_active=risk.get("black_swan_active", False),
            signals=risk["signals"],
            premium_multiplier=risk["premium_multiplier"],
            timestamp=datetime.now(timezone.utc).isoformat(),
            recommendation=risk["recommendation"],
        )
    except AttributeError:
        # App not fully initialized yet
        risk = await RiskEngine().get_current_risk()
        return RiskSignalResponse(
            risk_level=risk["risk_level"],
            black_swan_active=False,
            signals=risk["signals"],
            premium_multiplier=risk["premium_multiplier"],
            timestamp=datetime.now(timezone.utc).isoformat(),
            recommendation=risk["recommendation"],
        )


@app.post("/quote", response_model=PremiumQuoteResponse)
async def get_premium_quote(req: PremiumQuoteRequest):
    """
    Get an AI-priced insurance premium quote.
    LLM analyzes current risk signals + historical DeFi incident data.
    """
    pricer = app.state.pricer
    risk_engine = app.state.risk_engine

    current_risk = await risk_engine.get_current_risk()
    quote = await pricer.price_premium(
        coverage_amount=req.coverage_amount,
        risk_category=req.risk_category,
        protocol_address=req.protocol_address,
        duration_days=req.duration_days,
        current_risk=current_risk,
    )

    return PremiumQuoteResponse(**quote)


@app.post("/claims/submit")
async def submit_claim(req: ClaimRequest, background_tasks: BackgroundTasks):
    """
    Submit a claim for review. Agent will:
    1. Verify the incident on-chain
    2. Submit to ERC-8004 Validation Registry
    3. Execute payout if validated
    """
    claims_bot = app.state.claims_bot
    result = await claims_bot.submit_claim(
        policy_id=req.policy_id,
        requested_amount=req.requested_amount,
        evidence=req.evidence_description,
        incident_timestamp=req.incident_timestamp,
    )
    return result


@app.get("/claims/{claim_id}")
async def get_claim_status(claim_id: int):
    """Get status of a submitted claim."""
    claims_bot = app.state.claims_bot
    return await claims_bot.get_claim_status(claim_id)


@app.get("/pool/stats")
async def get_pool_stats():
    """Get insurance pool statistics."""
    erc8004 = app.state.erc8004
    return await erc8004.get_pool_stats()


@app.get("/agent/reputation")
async def get_agent_reputation():
    """Get agent's on-chain reputation from ERC-8004 Reputation Registry."""
    erc8004 = app.state.erc8004
    return await erc8004.get_reputation()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
