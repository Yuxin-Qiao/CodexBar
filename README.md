# Codex request-ledger CLI validation (anonymized derivative)

Production revision: `9e48be06431b73a2bb7e4c4db193841287f4ed98`, for [PR #4195](https://github.com/steipete/CodexBar/pull/4195).

A freshly built debug CLI parsed an isolated copy of an existing native Codex rollout. The JSONL records were not edited, renamed, or synthesized before parsing. The file was split immediately before its final typed usage record; the existing suffix was then appended unchanged. Each CLI call ran in a new process, using a contained application home and a contained `CODEX_HOME`. A separate contained home parsed the full original as a cold reference.

The private original, prefix, suffix, raw CLI output, and independent calculation are retained locally. This published receipt is a post-validation anonymized derivative: it exposes Boolean comparisons only. Personal paths, projects, session/thread/turn/response identifiers, log content, usage amounts, and monetary values are withheld. It is not a raw terminal transcript or a screenshot.

## Checks

All four invocations exited successfully, using:

```text
codexbar cost --provider codex --provider-native-only --period all --json --refresh
```

- Prefix followed by unchanged append: reported usage advances.
- Subsequent process/cache reopen: totals and daily projections remain stable.
- Full original in a separate fresh cache: totals and daily projections equal the append result.
- Independent source calculation: validate the first metadata owner, accept that owner's typed records, deduplicate response identities, then sum their input, output, cached-input, and reasoning fields. Every corresponding CLI total matches. The comparison exposed and drove a regression for dual-format observations whose cumulative counters differ.
- Parsing and aggregation happen before producing this Boolean-only receipt. No account API, credential probe, or Keychain access was used.

## Scope and limitation

This proves accounting on a real unmodified native rollout, including append, reopened cache, mixed-format deduplication, and cold-reference agreement. The available original did **not** exhibit a legacy counter reset. Recovery across a counter reset remains covered by explicitly synthetic parser/CLI fixtures; this receipt does not claim a real reset reproduction. Separate checked-in tests cover split thread/session identities, serialized subagent buffers and ordinal boundaries, and revision-5/revision-6 SQLite adoption followed by bounded revision-7 reparse, reopen, pricing preservation, and append.

See [receipt.json](receipt.json). All numerical values in the public PR's regression fixtures are invented.
