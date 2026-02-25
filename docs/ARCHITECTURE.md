# ERC-8004 Tail-Risk Protection Agent — Pre-Build Architecture

## Goal
Build an AI-assisted protection layer that monitors market stress and supports automated underwriting / claims decisions for tail-risk insurance flows.

## System components

### 1) Smart contracts (`contracts/`)
- Policy underwriting and lifecycle primitives
- Claim submission and payout pathways
- ERC-8004-aligned identity/reputation/validation registries (starter artifacts)

### 2) Agent service (`agent/`)
- Lightweight deterministic risk engine (current pre-build)
- Inputs: volatility, drawdown, depeg-risk proxy
- Outputs: normalized risk score, premium bps, tier
- Will evolve into full LLM + on-chain signal orchestrator during sprint

### 3) Frontend (`frontend/`)
- Next.js dashboard shell for:
  - quote simulation
  - policy state view
  - claims status

## Current pre-build boundaries (Feb 25)
- Contract, agent, and frontend scaffolds are in place
- Python unit tests exist for risk scoring tier behavior
- Next sprint tasks: wire contracts ↔ agent ↔ UI, add integration tests, deploy stack

## Sprint implementation targets (Mar 9–22)
1. Contract integration + deployment scripts for target testnet
2. Agent API endpoints and transaction execution hooks
3. Frontend wallet + quote/policy/claim interactions
4. End-to-end demo path and submission assets
