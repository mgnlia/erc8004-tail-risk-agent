/**
 * API client for the ERC-8004 Tail Risk Agent backend.
 * Falls back to mock data when API is unavailable.
 */

const API_URL = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8080";

export interface VolatilityReading {
  value_bps: number;
  realized_vol_pct: number;
  source: string;
  regime: "calm" | "elevated" | "stress" | "black_swan";
  timestamp: number;
}

export interface VaultStats {
  totalAssets: number;
  totalPolicyCoverage: number;
  availableCapital: number;
  sharePrice: number;
  volatilityIndex: number;
}

export interface TrustScore {
  agentId: number;
  claimAccuracy: number;
  capitalPreservation: number;
  responseTime: number;
  overall: number;
  lastUpdated: number;
  updateCount: number;
}

export interface AgentStatus {
  agentId: number;
  agentName: string;
  running: boolean;
  connected: boolean;
  stats: Record<string, number | boolean>;
  trustScore: number | null;
}

export interface DemoScenario {
  scenario: string;
  description: string;
  timeline: Array<{
    t: number;
    event: string;
    vol_bps: number;
    regime: string;
  }>;
  policies_protected: number;
  total_claims_paid: string;
  agent_response_time_seconds: number;
  trust_score_impact: string;
}

// ── Mock data for demo/offline mode ──────────────────────────────────────────

const MOCK_VOLATILITY: VolatilityReading = {
  value_bps: 3500,
  realized_vol_pct: 35.2,
  source: "demo",
  regime: "elevated",
  timestamp: Date.now() / 1000,
};

const MOCK_VAULT_STATS: VaultStats = {
  totalAssets: 500_000 * 1e6,
  totalPolicyCoverage: 120_000 * 1e6,
  availableCapital: 280_000 * 1e6,
  sharePrice: 1.05 * 1e18,
  volatilityIndex: 3500,
};

const MOCK_TRUST_SCORE: TrustScore = {
  agentId: 1,
  claimAccuracy: 8200,
  capitalPreservation: 8500,
  responseTime: 7800,
  overall: 8170,
  lastUpdated: Math.floor(Date.now() / 1000) - 3600,
  updateCount: 42,
};

const MOCK_AGENT_STATUS: AgentStatus = {
  agentId: 1,
  agentName: "TailRisk-Alpha",
  running: true,
  connected: true,
  stats: {
    cycles: 1247,
    vol_updates: 623,
    claims_assessed: 18,
    claims_paid: 3,
    claims_rejected: 15,
    errors: 0,
  },
  trustScore: 8170,
};

// ── Fetch helpers ─────────────────────────────────────────────────────────────

async function fetchWithFallback<T>(path: string, fallback: T): Promise<T> {
  try {
    const res = await fetch(`${API_URL}${path}`, {
      next: { revalidate: 30 },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return fallback;
    return res.json();
  } catch {
    return fallback;
  }
}

// ── API functions ─────────────────────────────────────────────────────────────

export async function getVolatility(): Promise<VolatilityReading> {
  return fetchWithFallback("/volatility", MOCK_VOLATILITY);
}

export async function getVaultStats(): Promise<VaultStats> {
  return fetchWithFallback("/vault/stats", MOCK_VAULT_STATS);
}

export async function getTrustScore(agentId = 1): Promise<TrustScore> {
  return fetchWithFallback(`/trust-score/${agentId}`, MOCK_TRUST_SCORE);
}

export async function getAgentStatus(): Promise<AgentStatus> {
  return fetchWithFallback("/agent/status", MOCK_AGENT_STATUS);
}

export async function getDemoScenario(): Promise<DemoScenario> {
  return fetchWithFallback("/demo/scenario", {
    scenario: "crypto_market_stress",
    description: "Simulated March 2020-style crypto market event",
    timeline: [
      { t: 0, event: "Normal market conditions", vol_bps: 2800, regime: "elevated" },
      { t: 3600, event: "BTC drops 15%", vol_bps: 5500, regime: "stress" },
      { t: 7200, event: "ETH correlation spike", vol_bps: 7200, regime: "stress" },
      { t: 9000, event: "Black swan threshold crossed", vol_bps: 8100, regime: "black_swan" },
      { t: 9060, event: "Agent detects trigger", vol_bps: 8100, regime: "black_swan" },
      { t: 9120, event: "LLM assesses claim (confidence: 0.94)", vol_bps: 8100, regime: "black_swan" },
      { t: 9180, event: "Claim payment executed on-chain", vol_bps: 8100, regime: "black_swan" },
      { t: 14400, event: "Market stabilizes", vol_bps: 4200, regime: "elevated" },
      { t: 18000, event: "Trust score updated: +120 bps", vol_bps: 3100, regime: "elevated" },
    ],
    policies_protected: 12,
    total_claims_paid: "$180,000 USDC",
    agent_response_time_seconds: 60,
    trust_score_impact: "+120 bps",
  });
}

// ── Formatting helpers ────────────────────────────────────────────────────────

export function formatUSDC(raw: number): string {
  return `$${(raw / 1e6).toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
}

export function formatBps(bps: number): string {
  return `${(bps / 100).toFixed(1)}%`;
}

export function regimeLabel(regime: string): string {
  const labels: Record<string, string> = {
    calm: "Calm",
    elevated: "Elevated",
    stress: "Stress",
    black_swan: "Black Swan 🚨",
  };
  return labels[regime] || regime;
}

export function regimeColor(regime: string): string {
  const colors: Record<string, string> = {
    calm: "text-emerald-400",
    elevated: "text-yellow-400",
    stress: "text-orange-400",
    black_swan: "text-red-400",
  };
  return colors[regime] || "text-slate-400";
}
