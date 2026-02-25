from dataclasses import dataclass


@dataclass
class RiskInput:
    volatility_30d: float
    drawdown_7d: float
    stablecoin_depeg_risk: float


@dataclass
class RiskOutput:
    score: float
    premium_bps: int
    tier: int


class TailRiskEngine:
    def score(self, x: RiskInput) -> RiskOutput:
        raw = (x.volatility_30d * 0.45) + (x.drawdown_7d * 0.35) + (x.stablecoin_depeg_risk * 0.20)
        score = max(0.0, min(1.0, raw))

        if score < 0.33:
            return RiskOutput(score=score, premium_bps=120, tier=1)
        if score < 0.66:
            return RiskOutput(score=score, premium_bps=280, tier=2)
        return RiskOutput(score=score, premium_bps=550, tier=3)
