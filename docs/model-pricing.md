---
summary: "models.dev pricing metadata pipeline, custom-pricing overlay, cache, lookup rules, and token-cost units."
read_when:
  - Updating models.dev pricing metadata support
  - Debugging model-pricing cache refresh or lookup behavior
  - Routing provider cost calculations through shared pricing metadata
  - Adding or documenting custom-pricing.json overlays
---

# Model pricing metadata

CodexBar uses models.dev as an additive pricing source alongside bundled fallback rates.

## Source and cache

- Source API: `https://models.dev/api.json`
- No API key is required.
- Local cache: `~/Library/Caches/CodexBar/model-pricing/models-dev-v1.json`
- TTL: 24 hours

The pipeline lets future scanner code read the last valid cache synchronously with `ModelsDevPricingPipeline.lookup` and refresh stale metadata separately with `ModelsDevPricingPipeline.refreshIfNeeded`. If a refresh fails, the last valid cache remains usable.

## Lookup rules

Pricing is scoped by provider id and model id. This prevents two providers with the same model id or display name from sharing pricing accidentally.

Local cost scanners preserve that scope when selecting a catalog:

- Bare Codex/OpenAI model IDs use provider id `openai`; approved provider-qualified routes stay on their route, and unknown prefixes remain unpriced.
- Recognizable bare Claude-session model families use their first-party vendor catalog, including Anthropic, OpenAI, Google, Moonshot/Kimi, MiniMax, and DeepSeek.
- Other bare Claude-session IDs are priced only when exactly one selected first-party catalog matches. Ambiguous cross-vendor matches remain unpriced.
- Provider-qualified Claude-session IDs stay on an approved explicit route and never fall through to another vendor.
- Vertex AI Claude logs: models.dev provider id `google-vertex-anthropic`

## Units

models.dev publishes costs as USD per 1M tokens. CodexBar converts those to USD per token in the metadata layer:

```text
perToken = modelsDevCost / 1_000_000
```

When models.dev includes `cost.context_over_200k`, CodexBar parses those values as the above-200k-token pricing lane and converts them with the same per-1M-token rule.

## Custom pricing overlay

Exact-match list-price overrides live at:

```text
~/Library/Application Support/CodexBar/custom-pricing.json
```

Values are USD per million tokens. Resolution order is **overlay > models.dev > builtin**. Changing the file invalidates the Codex pricing fingerprint so the next scan reloads rates.

Keys are case-insensitive and may be a bare model id (`gpt-5.4`) or `provider/model` (`openai/gpt-5.4`). Only an exact normalized key matches; there is no prefix or family glob.

```json
{
  "gpt-5.4": {
    "input": 1.25,
    "output": 10,
    "cacheRead": 0.125,
    "cacheWrite": 1.25
  },
  "openai/gpt-5.4-mini": {
    "input": 0,
    "output": 0
  }
}
```

Field rules:

- `0` is a free rate for that token class.
- A missing field stays unknown. CodexBar does not fill it from models.dev or bundled tables, so a partial overlay row is unpriced rather than a mix of overlay and catalog rates.
- Negative and non-finite numbers are ignored.
- Alternate spellings `cache_read`, `cache_write`, `cacheCreation`, and `cache_creation` are accepted for cache fields.

Tests never read this file from the developer Application Support directory; they use fixtures or an empty overlay.
