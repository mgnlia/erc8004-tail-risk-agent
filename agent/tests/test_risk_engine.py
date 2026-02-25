from tail_risk_agent import RiskInput, TailRiskEngine


def test_score_clamped_to_range():
    engine = TailRiskEngine()

    low = engine.score(RiskInput(volatility_30d=-1.0, drawdown_7d=0.0, stablecoin_depeg_risk=0.0))
    high = engine.score(RiskInput(volatility_30d=5.0, drawdown_7d=5.0, stablecoin_depeg_risk=5.0))

    assert 0.0 <= low.score <= 1.0
    assert 0.0 <= high.score <= 1.0


def test_tier_and_premium_mapping():
    engine = TailRiskEngine()

    tier1 = engine.score(RiskInput(volatility_30d=0.1, drawdown_7d=0.1, stablecoin_depeg_risk=0.1))
    tier2 = engine.score(RiskInput(volatility_30d=0.5, drawdown_7d=0.5, stablecoin_depeg_risk=0.5))
    tier3 = engine.score(RiskInput(volatility_30d=0.95, drawdown_7d=0.95, stablecoin_depeg_risk=0.95))

    assert tier1.tier == 1 and tier1.premium_bps == 120
    assert tier2.tier == 2 and tier2.premium_bps == 280
    assert tier3.tier == 3 and tier3.premium_bps == 550


def test_higher_risk_signals_raise_score():
    engine = TailRiskEngine()

    conservative = engine.score(RiskInput(volatility_30d=0.2, drawdown_7d=0.1, stablecoin_depeg_risk=0.05))
    stressed = engine.score(RiskInput(volatility_30d=0.8, drawdown_7d=0.6, stablecoin_depeg_risk=0.4))

    assert stressed.score > conservative.score
