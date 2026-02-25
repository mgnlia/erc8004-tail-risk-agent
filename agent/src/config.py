"""Configuration management for the Tail Risk Agent."""

from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ── LLM ───────────────────────────────────────────────────────────────────
    openai_api_key: str = Field(default="", description="OpenAI API key")
    anthropic_api_key: str = Field(default="", description="Anthropic API key")
    llm_model: str = Field(default="claude-3-5-sonnet-20241022", description="LLM model ID")
    llm_temperature: float = Field(default=0.1, description="LLM temperature")

    # ── Blockchain ─────────────────────────────────────────────────────────────
    rpc_url: str = Field(
        default="http://127.0.0.1:8545",
        description="Ethereum RPC URL"
    )
    private_key: str = Field(default="", description="Agent wallet private key")
    chain_id: int = Field(default=1337, description="Chain ID")

    # Contract addresses (set after deployment)
    identity_registry_address: str = Field(default="", description="IdentityRegistry contract")
    trust_oracle_address: str = Field(default="", description="TrustScoreOracle contract")
    tail_risk_vault_address: str = Field(default="", description="TailRiskVault contract")
    usdc_address: str = Field(default="", description="USDC contract address")

    # ── Agent ──────────────────────────────────────────────────────────────────
    agent_id: int = Field(default=1, description="ERC-8004 agent ID")
    agent_name: str = Field(default="TailRisk-Alpha", description="Agent display name")
    min_trust_score: int = Field(default=6000, description="Min trust score to act (bps)")

    # ── Monitoring ─────────────────────────────────────────────────────────────
    poll_interval_seconds: int = Field(default=60, description="Monitoring loop interval")
    volatility_update_interval: int = Field(default=300, description="Vol update interval (s)")
    max_volatility_age_seconds: int = Field(default=600, description="Max age for vol data")

    # ── Risk Parameters ────────────────────────────────────────────────────────
    black_swan_threshold_bps: int = Field(
        default=7500,
        description="VIX-proxy level (bps) that triggers black-swan mode"
    )
    auto_claim_enabled: bool = Field(default=True, description="Enable autonomous claim payments")

    # ── API Server ─────────────────────────────────────────────────────────────
    api_host: str = Field(default="0.0.0.0", description="API server host")
    api_port: int = Field(default=8080, description="API server port")
    api_cors_origins: list[str] = Field(
        default=["*"],
        description="CORS allowed origins"
    )


settings = Settings()
