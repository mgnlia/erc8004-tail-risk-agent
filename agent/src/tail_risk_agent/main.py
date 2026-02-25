from tail_risk_agent.risk_engine import TailRiskEngine, RiskInput


def main() -> None:
    engine = TailRiskEngine()
    sample = RiskInput(volatility_30d=0.62, drawdown_7d=0.28, stablecoin_depeg_risk=0.12)
    out = engine.score(sample)
    print({"tail_risk_score": out.score, "premium_bps": out.premium_bps, "tier": out.tier})


if __name__ == "__main__":
    main()
