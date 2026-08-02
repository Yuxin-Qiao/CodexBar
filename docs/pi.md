---
summary: "Pi coding agent local session cost usage: source paths, provider attribution, and pricing behavior."
read_when:
  - Reviewing pi or OMP local session cost scanning
  - Changing pi provider attribution or pricing
  - Adjusting the pi session cache schema
---

# Pi local session costs

CodexBar scans [Pi](https://github.com/earendil-works/pi) and OMP session JSONL files so coding-agent usage that
flows through those harnesses shows up in the existing local cost history without needing web or CLI access.
The scanner lives in `Sources/CodexBarCore/PiSessionCostScanner.swift` with its cache in
`Sources/CodexBarCore/PiSessionCostCache.swift`.

## Source paths

- `~/.pi/agent/sessions/**/*.jsonl`
- `~/.omp/agent/sessions/**/*.jsonl`
- Cache: `~/Library/Caches/CodexBar/cost-usage/pi-sessions-v9.json`

Files are JSONL with a `type` field (`session`, `model_change`, `message`, `compaction`, `branch_summary`, ...).
Only sessions from the configured window are scanned, with a 60s minimum refresh interval; appended file tails are
re-parsed incrementally and matching assistant entry IDs are counted once across pi and OMP roots.

## Provider attribution

Pi assistant messages carry a `provider` field. CodexBar maps supported providers onto existing CodexBar providers:

| Pi provider | CodexBar provider |
| --- | --- |
| `anthropic` | Claude |
| `openai-codex` | Codex |
| `openai` | OpenAI |
| `deepseek` | DeepSeek |
| `google` | Gemini |
| `google-vertex` | Vertex AI |
| `xai` | xAI |
| `openrouter` | OpenRouter |
| `kimi-coding` | Kimi |
| `minimax`, `minimax-cn` | MiniMax |
| `moonshotai`, `moonshotai-cn` | Moonshot |
| `qwen-token-plan`, `qwen-token-plan-cn` | Qwen Cloud |
| `zai`, `zai-coding-cn` | z.ai |
| `opencode` | OpenCode |
| `opencode-go` | OpenCode Go |
| `github-copilot` | Copilot |
| `mistral` | Mistral |
| `groq` | Groq |
| `amazon-bedrock` | Bedrock |
| `azure-openai-responses` | Azure OpenAI |
| `xiaomi`, `xiaomi-token-plan-*` | MiMo |

Unmapped providers (`nvidia`, `cerebras`, `together`, `fireworks`, `huggingface`, `cloudflare-*`,
`vercel-ai-gateway`, `ant-ling`, `radius`, ...) are ignored rather than miscounted.

## Pricing

Pi records an exact per-message cost in `usage.cost.total`. CodexBar prefers that reported cost and falls back to
models.dev catalog rates only when the session omits cost or reports a zero total. Unknown models stay unpriced.
When a message's `responseModel` is present (for example OpenRouter `auto` routing), it is used as the model for
pricing and breakdowns instead of the requested model name.

Usage recorded on tool results, compactions, and branch summaries is attributed to the session's current provider
under the `Tools/summaries` model bucket, matching pi's own session totals.

## Merge behavior

`CostUsageFetcher.loadTokenSnapshot` merges the pi report into providers that both map from pi and support the local
token snapshot pipeline (Codex, Claude, Vertex AI, Bedrock). Other mapped providers keep their pi buckets in the
shared pi cache for future enablement but do not merge yet.

## Key files

- `Sources/CodexBarCore/PiSessionCostScanner.swift`
- `Sources/CodexBarCore/PiSessionCostCache.swift`
- `Sources/CodexBarCore/CostUsageFetcher.swift`
- `Tests/CodexBarTests/PiSessionCostScannerTests.swift`
