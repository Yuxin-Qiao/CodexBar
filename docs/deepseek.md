---
summary: "DeepSeek provider data sources: API key balance + platform web session usage summaries."
read_when:
  - Adding or tweaking DeepSeek balance parsing
  - Updating API key handling
  - Documenting new provider behavior
---

# DeepSeek provider

DeepSeek combines two auth surfaces:

1. **API key balance** — `GET https://api.deepseek.com/user/balance` with `Authorization: Bearer <api key>`.
2. **Platform usage summaries** — `GET https://platform.deepseek.com/api/v0/usage/amount` and `/usage/cost` with a **platform.deepseek.com web session** (browser Cookie and/or Authorization header). Bearer API keys return `code: 40003` on these endpoints.

CodexBar always uses the API key for balance. Optional usage dashboards (inline KPI grid + sparkline) require a platform web session, similar to MiniMax PR #1821’s cookie enrichment model.

## Data sources

1. **API key** via `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY`, or DeepSeek token accounts in `~/.codexbar/config.json`.
2. **Balance endpoint** (`api.deepseek.com/user/balance`) — Bearer API key only.
3. **Usage amount/cost endpoints** (`platform.deepseek.com/api/v0/usage/*`) — web session only:
   - Settings → Providers → DeepSeek → **Usage summary source**
   - Env override: `DEEPSEEK_COOKIE` / `DEEPSEEK_PLATFORM_SESSION` (Cookie or `Bearer …` header value)
   - Browser import (Chrome by default) on **user-initiated refresh** (⌘R), then cached for background refreshes

## Usage details

- Menu card shows total balance with paid vs. granted breakdown.
- When **Show optional credits & extra usage** is enabled and a platform session is available, the card also shows:
  - Today / this-month token + cost KPIs
  - 30-day token trend sparkline
  - Cache-hit / cache-miss / output breakdown lines
- Without a platform session, balance still refreshes; usage summaries are omitted (expected).
- DeepSeek does not expose session/weekly quota windows via API.

## Key files

- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekProviderDescriptor.swift` (fetch strategy + web enrichment)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageFetcher.swift` (balance + platform usage HTTP)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekWebEnrichmentResolver.swift` (cookie candidate chain)
- `Sources/CodexBarCore/Providers/DeepSeek/DeepSeekCookieImporter.swift` (browser cookie import)
- `Sources/CodexBar/Providers/DeepSeek/DeepSeekProviderImplementation.swift` (settings UI)
