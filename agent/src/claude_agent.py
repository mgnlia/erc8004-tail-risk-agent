"""
Claude-powered autonomous agent brain.
Uses Anthropic tool-use to make underwriting and claim decisions.
"""

from __future__ import annotations

import json
from datetime import datetime
from typing import Any, Optional

import anthropic
import structlog

from .config import settings
from .models import (
    ActionType,
    AgentActionLog,
    ClaimDecision,
    ClaimRequest,
    PolicyQuote,
    PolicyRequest,
    RiskMetrics,
)
from .risk_engine import RiskEngine

logger = structlog.get_logger(__name__)


# ── Tool Definitions ───────────────────────────────────────────────────────────

TOOLS: list[dict] = [
    {
        "name": "assess_tail_risk",
        "description": (
            "Compute tail-risk metrics (VaR, CVaR, max drawdown, volatility) "
            "for a given asset using current market data."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "asset": {"type": "string", "description": "Asset symbol (ETH, BTC, etc.)"},
                "lookback_days": {
                    "type": "integer",
                    "description": "Number of days for historical analysis",
                    "default": 30,
                },
            },
            "required": ["asset"],
        },
    },
    {
        "name": "quote_insurance_policy",
        "description": (
            "Generate an actuarial insurance quote for a tail-risk protection policy. "
            "Returns premium, risk score, and approval decision."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "requester": {"type": "string", "description": "Ethereum address of requester"},
                "coverage_asset": {"type": "string", "description": "Asset to insure"},
                "coverage_amount_eth": {"type": "number", "description": "Coverage in ETH"},
                "duration_days": {"type": "integer", "description": "Policy duration in days"},
                "trigger_threshold": {
                    "type": "number",
                    "description": "Price drop % triggering payout (e.g. 0.20 = 20%)",
                },
            },
            "required": [
                "requester",
                "coverage_asset",
                "coverage_amount_eth",
                "duration_days",
                "trigger_threshold",
            ],
        },
    },
    {
        "name": "evaluate_claim",
        "description": (
            "Evaluate an insurance claim. Checks if trigger conditions were met "
            "and computes payout amount."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "policy_id": {"type": "integer", "description": "Policy ID"},
                "claimant": {"type": "string", "description": "Ethereum address of claimant"},
                "trigger_price": {
                    "type": "number",
                    "description": "Current asset price when trigger was hit",
                },
                "original_price": {
                    "type": "number",
                    "description": "Asset price at policy inception",
                },
                "coverage_amount_eth": {"type": "number", "description": "Policy coverage in ETH"},
                "trigger_threshold": {"type": "number", "description": "Policy trigger threshold"},
            },
            "required": [
                "policy_id",
                "claimant",
                "trigger_price",
                "original_price",
                "coverage_amount_eth",
                "trigger_threshold",
            ],
        },
    },
    {
        "name": "get_portfolio_status",
        "description": "Get current portfolio exposure, risk metrics, and agent health.",
        "input_schema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
]


# ── Tool Implementations ───────────────────────────────────────────────────────

class ToolExecutor:
    def __init__(self, risk_engine: RiskEngine, agent_id: int):
        self.risk_engine = risk_engine
        self.agent_id = agent_id

    def execute(self, tool_name: str, tool_input: dict) -> dict:
        handler = getattr(self, f"_tool_{tool_name}", None)
        if handler is None:
            return {"error": f"Unknown tool: {tool_name}"}
        try:
            return handler(**tool_input)
        except Exception as e:
            logger.error("tool_execution_error", tool=tool_name, error=str(e))
            return {"error": str(e)}

    def _tool_assess_tail_risk(self, asset: str, lookback_days: int = 30) -> dict:
        metrics = self.risk_engine.compute_metrics(self.agent_id, asset)
        return {
            "asset": asset,
            "var_95": metrics.var_95,
            "cvar_95": metrics.cvar_95,
            "max_drawdown": metrics.max_drawdown,
            "volatility_30d": metrics.volatility_30d,
            "tail_risk_score": metrics.tail_risk_score,
            "is_high_risk": metrics.is_high_risk,
            "timestamp": metrics.timestamp.isoformat(),
        }

    def _tool_quote_insurance_policy(
        self,
        requester: str,
        coverage_asset: str,
        coverage_amount_eth: float,
        duration_days: int,
        trigger_threshold: float,
    ) -> dict:
        request = PolicyRequest(
            requester=requester,
            coverage_asset=coverage_asset,
            coverage_amount_eth=coverage_amount_eth,
            duration_days=duration_days,
            trigger_threshold=trigger_threshold,
        )
        quote = self.risk_engine.quote_policy(request, self.agent_id)
        return {
            "approved": quote.approved,
            "premium_eth": quote.premium_eth,
            "premium_rate_pct": round(quote.premium_rate * 100, 4),
            "risk_score": quote.risk_score,
            "rejection_reason": quote.rejection_reason,
            "quote_expires_at": quote.quote_expires_at.isoformat() if quote.quote_expires_at else None,
        }

    def _tool_evaluate_claim(
        self,
        policy_id: int,
        claimant: str,
        trigger_price: float,
        original_price: float,
        coverage_amount_eth: float,
        trigger_threshold: float,
    ) -> dict:
        if original_price <= 0:
            return {"approved": False, "reason": "Invalid original price"}

        actual_drop = (original_price - trigger_price) / original_price
        triggered = actual_drop >= trigger_threshold

        if not triggered:
            return {
                "policy_id": policy_id,
                "approved": False,
                "payout_eth": 0.0,
                "actual_drop_pct": round(actual_drop * 100, 2),
                "required_drop_pct": round(trigger_threshold * 100, 2),
                "reason": f"Price dropped {actual_drop*100:.1f}% but trigger requires {trigger_threshold*100:.1f}%",
            }

        # Proportional payout: more severe drop = higher payout
        excess_drop = actual_drop - trigger_threshold
        payout_ratio = min(1.0, 0.5 + excess_drop * 2.0)  # 50-100% of coverage
        payout_eth = round(coverage_amount_eth * payout_ratio, 6)

        return {
            "policy_id": policy_id,
            "approved": True,
            "payout_eth": payout_eth,
            "payout_ratio": round(payout_ratio, 4),
            "actual_drop_pct": round(actual_drop * 100, 2),
            "required_drop_pct": round(trigger_threshold * 100, 2),
            "claimant": claimant,
        }

    def _tool_get_portfolio_status(self) -> dict:
        return {
            "current_exposure_eth": self.risk_engine.current_exposure_eth,
            "max_exposure_eth": self.risk_engine.max_portfolio_exposure,
            "utilization_pct": round(
                self.risk_engine.current_exposure_eth
                / max(self.risk_engine.max_portfolio_exposure, 1) * 100,
                2,
            ),
            "timestamp": datetime.utcnow().isoformat(),
        }


# ── Claude Agent ───────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are TailRiskAgent, an autonomous AI insurance underwriter operating on-chain via ERC-8004.

Your core responsibilities:
1. **Underwrite** tail-risk protection policies for crypto assets
2. **Price** premiums using actuarial risk models (VaR, CVaR, max drawdown)
3. **Evaluate** claims objectively based on on-chain price data
4. **Manage** portfolio exposure to avoid catastrophic losses

Decision principles:
- Be conservative: when uncertain, charge higher premiums or decline
- Be fair: approve valid claims promptly and fully
- Be transparent: always explain your reasoning
- Be prudent: never exceed portfolio exposure limits

You have access to tools for risk assessment, policy quoting, and claim evaluation.
Always use the appropriate tool before making a decision.
"""


class ClaudeAgent:
    """Autonomous agent that uses Claude to make underwriting decisions."""

    def __init__(self, risk_engine: RiskEngine):
        self.client = anthropic.Anthropic(api_key=settings.anthropic_api_key)
        self.risk_engine = risk_engine
        self.executor = ToolExecutor(risk_engine, settings.agent_id)
        self.action_log: list[AgentActionLog] = []

    async def underwrite_policy(self, request: PolicyRequest) -> PolicyQuote:
        """Use Claude to make an underwriting decision."""
        import uuid

        action_id = str(uuid.uuid4())
        log = logger.bind(action_id=action_id, action="underwrite")

        user_message = f"""
A new insurance policy request has been submitted:

- Requester: {request.requester}
- Asset to insure: {request.coverage_asset}
- Coverage amount: {request.coverage_amount_eth} ETH
- Duration: {request.duration_days} days
- Trigger threshold: {request.trigger_threshold * 100:.1f}% price drop

Please:
1. Assess the current tail risk for {request.coverage_asset}
2. Generate a policy quote
3. Provide your underwriting decision with reasoning
"""

        messages = [{"role": "user", "content": user_message}]
        result = self._run_agentic_loop(messages)

        log.info("underwriting_complete", approved=result.get("approved", False))

        # Parse Claude's final response into a PolicyQuote
        # The tool calls will have already computed the actual quote
        quote = self.risk_engine.quote_policy(request, settings.agent_id)

        self.action_log.append(
            AgentActionLog(
                action_id=action_id,
                action_type=ActionType.POLICY_ISSUANCE,
                timestamp=datetime.utcnow(),
                input_data=request.model_dump(),
                output_data=quote.model_dump(),
                success=quote.approved,
            )
        )

        return quote

    async def evaluate_claim(
        self,
        claim: ClaimRequest,
        original_price: float,
        coverage_amount_eth: float,
        trigger_threshold: float,
    ) -> ClaimDecision:
        """Use Claude to evaluate an insurance claim."""
        import uuid

        action_id = str(uuid.uuid4())

        user_message = f"""
An insurance claim has been submitted:

- Policy ID: {claim.policy_id}
- Claimant: {claim.claimant}
- Trigger price: ${claim.trigger_price:,.2f}
- Original price at inception: ${original_price:,.2f}
- Coverage amount: {coverage_amount_eth} ETH
- Trigger threshold: {trigger_threshold * 100:.1f}% drop

Please evaluate this claim and determine if it should be approved.
"""

        messages = [{"role": "user", "content": user_message}]
        self._run_agentic_loop(messages)

        # Compute the actual decision
        actual_drop = (original_price - claim.trigger_price) / original_price
        triggered = actual_drop >= trigger_threshold

        if triggered:
            excess = actual_drop - trigger_threshold
            payout_ratio = min(1.0, 0.5 + excess * 2.0)
            payout_eth = round(coverage_amount_eth * payout_ratio, 6)
        else:
            payout_eth = 0.0

        decision = ClaimDecision(
            policy_id=claim.policy_id,
            approved=triggered,
            payout_eth=payout_eth,
            rejection_reason=(
                None
                if triggered
                else f"Price drop {actual_drop*100:.1f}% < trigger {trigger_threshold*100:.1f}%"
            ),
        )

        self.action_log.append(
            AgentActionLog(
                action_id=action_id,
                action_type=ActionType.CLAIM_PAYOUT,
                timestamp=datetime.utcnow(),
                input_data=claim.model_dump(),
                output_data=decision.model_dump(),
                success=True,
            )
        )

        return decision

    def _run_agentic_loop(self, messages: list[dict]) -> dict:
        """Run Claude agentic loop with tool use."""
        max_iterations = 5
        final_result = {}

        for _ in range(max_iterations):
            response = self.client.messages.create(
                model="claude-opus-4-5",
                max_tokens=2048,
                system=SYSTEM_PROMPT,
                tools=TOOLS,
                messages=messages,
            )

            # Add assistant response to messages
            messages.append({"role": "assistant", "content": response.content})

            if response.stop_reason == "end_turn":
                # Extract text response
                for block in response.content:
                    if hasattr(block, "text"):
                        final_result["reasoning"] = block.text
                break

            if response.stop_reason == "tool_use":
                # Execute tools
                tool_results = []
                for block in response.content:
                    if block.type == "tool_use":
                        logger.info("tool_call", tool=block.name, input=block.input)
                        result = self.executor.execute(block.name, block.input)
                        tool_results.append({
                            "type": "tool_result",
                            "tool_use_id": block.id,
                            "content": json.dumps(result),
                        })
                        final_result.update(result)

                messages.append({"role": "user", "content": tool_results})

        return final_result
