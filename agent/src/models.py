"""Domain models for the ERC-8004 Tail-Risk Agent."""

from __future__ import annotations

from datetime import datetime
from enum import IntEnum
from typing import Optional

from pydantic import BaseModel, Field


# ── Enums ──────────────────────────────────────────────────────────────────────

class ActionType(IntEnum):
    CLAIM_PAYOUT = 0
    POLICY_ISSUANCE = 1
    RISK_ASSESSMENT = 2
    REBALANCE = 3


class ValidationStatus(IntEnum):
    PENDING = 0
    APPROVED = 1
    REJECTED = 2


class PolicyStatus(IntEnum):
    ACTIVE = 0
    EXPIRED = 1
    CLAIMED = 2
    CANCELLED = 3


# ── Market Data ────────────────────────────────────────────────────────────────

class PricePoint(BaseModel):
    timestamp: datetime
    asset: str
    price_usd: float
    volume_24h: float
    market_cap: float
    price_change_24h: float  # percentage


class MarketSnapshot(BaseModel):
    timestamp: datetime
    prices: dict[str, PricePoint]
    fear_greed_index: Optional[int] = None  # 0-100
    total_market_cap_usd: float = 0.0


# ── Risk Models ────────────────────────────────────────────────────────────────

class RiskMetrics(BaseModel):
    agent_id: int
    timestamp: datetime
    var_95: float = Field(description="Value at Risk at 95% confidence")
    cvar_95: float = Field(description="Conditional VaR (Expected Shortfall)")
    max_drawdown: float = Field(description="Maximum portfolio drawdown")
    volatility_30d: float = Field(description="30-day rolling volatility")
    tail_risk_score: float = Field(ge=0, le=100, description="Composite tail risk score 0-100")
    is_high_risk: bool = False


class PolicyRequest(BaseModel):
    requester: str = Field(description="Ethereum address of policy requester")
    coverage_asset: str = Field(description="Asset to insure (e.g. ETH, BTC)")
    coverage_amount_eth: float = Field(gt=0, description="Coverage amount in ETH")
    duration_days: int = Field(ge=1, le=365, description="Policy duration in days")
    trigger_threshold: float = Field(
        ge=0.05, le=0.9,
        description="Price drop % that triggers payout (e.g. 0.20 = 20%)"
    )
    metadata_uri: str = Field(default="", description="IPFS URI for additional data")


class PolicyQuote(BaseModel):
    request: PolicyRequest
    premium_eth: float
    premium_rate: float  # % of coverage
    risk_score: float  # 0-100
    approved: bool
    rejection_reason: Optional[str] = None
    quote_expires_at: datetime
    validation_request_id: Optional[int] = None


class Policy(BaseModel):
    policy_id: int
    requester: str
    coverage_asset: str
    coverage_amount_eth: float
    premium_eth: float
    trigger_threshold: float
    start_date: datetime
    end_date: datetime
    status: PolicyStatus = PolicyStatus.ACTIVE
    tx_hash: Optional[str] = None


# ── Claim Models ───────────────────────────────────────────────────────────────

class ClaimRequest(BaseModel):
    policy_id: int
    claimant: str
    trigger_price: float = Field(description="Price at which trigger was hit")
    evidence_uri: str = Field(default="", description="IPFS URI for price oracle proof")


class ClaimDecision(BaseModel):
    policy_id: int
    approved: bool
    payout_eth: float
    rejection_reason: Optional[str] = None
    tx_hash: Optional[str] = None


# ── Agent State ────────────────────────────────────────────────────────────────

class AgentState(BaseModel):
    agent_id: int
    name: str
    wallet_address: str
    balance_eth: float = 0.0
    total_policies_issued: int = 0
    total_claims_paid: int = 0
    total_premium_collected_eth: float = 0.0
    total_payout_eth: float = 0.0
    current_exposure_eth: float = 0.0
    last_risk_assessment: Optional[datetime] = None
    last_action: Optional[datetime] = None
    reputation_score: Optional[float] = None


# ── API Response Models ────────────────────────────────────────────────────────

class HealthResponse(BaseModel):
    status: str = "ok"
    agent_id: int
    agent_name: str
    chain_id: int
    block_number: Optional[int] = None
    timestamp: datetime = Field(default_factory=datetime.utcnow)


class AgentActionLog(BaseModel):
    action_id: str
    action_type: ActionType
    timestamp: datetime
    input_data: dict
    output_data: dict
    tx_hash: Optional[str] = None
    success: bool
    error: Optional[str] = None
