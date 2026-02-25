# ERC-8004 Tail-Risk Protection Agent

Pre-build monorepo for the LabLab ERC-8004 AI Trading Agents challenge.

## What this project is
A tail-risk protection system with three components:
- **Solidity contracts** for policy issuance and claim settlement primitives
- **Python risk agent** for scoring volatility stress and pricing coverage tiers
- **Next.js frontend** for quote/portfolio/claims UX

This is **pre-build scaffolding** for the Mar 9–22 sprint window.

## Repository structure
- `contracts/` — Hardhat + Solidity starter contracts and tests
- `agent/` — Python package (`tail_risk_agent`) + unit tests
- `frontend/` — Next.js app scaffold
- `docs/` — architecture notes

## Quick start

### Python agent (local smoke + tests)
```bash
cd agent
python -m pip install -e ".[dev]"
python -m tail_risk_agent.main
pytest
```

### Contracts
```bash
cd contracts
npm install
npm run build
npm test
```

### Frontend
```bash
cd frontend
npm install
npm run dev
```

## Current status
✅ Pre-build scaffold complete and implementation-ready for sprint kickoff.
