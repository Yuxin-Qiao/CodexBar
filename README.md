# PR #4247: existing desktop-history production-path proof

Verified production revision: `19087ebd1571f2d27c1ac98ad2a9d8bcc38e0aa2`.

This proof uses copies of existing local desktop history, not generated usage fixtures or directly constructed classified breakdowns. The public receipts deliberately withhold personal titles, paths, session/account IDs, endpoints, token counts, and amounts. Original inputs, captures, results, unsuccessful attempts, and complete logs remain local.

## Scope and provenance

A read-only SQLite backup and desktop-state/session-index copies were taken along with the existing rollout corpus. The final bounded sample contains eight unchanged historical rollout files. It covers explicit independent chats, assigned projects, and an unassigned ordinary directory. Four rollups have usage in the seven-day window: two remain Projects and two become Independent chats. Saved-title and neutral-label behavior is fed by the copied desktop metadata.

The final sample excludes one fork whose parent was absent from the sample. An earlier attempt correctly refused complete coverage for that missing dependency. A full-corpus attempt was stopped; this is a representative sample, not an all-history audit.

The SQLite backup was converted from WAL to DELETE journal mode for reliable read-only access in the native test host. A logical database dump comparison confirms identical records; desktop state and session index were restored byte-for-byte, and every selected history file matches its original copy. No credentials were copied. A copy of the existing local pricing catalog supplies non-null price estimates; network pricing refresh and Pi merging are disabled.

## Executed checks

1. An empty isolated accounting ledger is scanned by production `CostUsageFetcher.loadTokenSnapshot`, including the changed read-view membership derivation and desktop/SQLite metadata ingestion. Coverage must be established and non-partial.
2. A separate test process uses production `loadCachedCodexTokenSnapshotResult` with complete-history gating. Its scan work recorder reports zero file scan attempts. Classification, names, paths, source identities, row token/cost values, and the checked daily accounting fields match the fresh scan.
3. Only the copied desktop state's independent markers are temporarily removed. The same cached ledger falls back to Projects. Each rollup's accounting, source paths, and dashboard row identity remain unchanged; restoring state reproduces classification.
4. Production `ProjectRow.displayIdentity` hides all paths and uses numbered project/chat labels with privacy enabled; disabling privacy restores the original identities. Native `NSHostingView` renders of the scanned Projects, Chats, and privacy views also complete and are retained privately. This is display-projection/render proof, not a new mouse-interaction recording or installed-app verification.

Daily accounting comparisons cover date, input/output/cached/reasoning/total tokens and cost. They do not assert whole-snapshot byte equality: the fresh and cached paths may project ancillary pricing-status fields differently. No billing correctness claim is made.

See `scan.json`, `reload.json`, `input-integrity.json`, and `validation-transcript.txt` for anonymized results. The parameterized executed harness is included; it has no personal input data. It can be placed temporarily in the current revision's test target and skipped unless explicitly enabled.

## Reproduction

Prepare `private/copied-home/{sessions,archived_sessions,.codex-global-state.json,session_index.jsonl,state_5.sqlite}` from read-only copies, and seed only `private/cache/model-pricing/models-dev-v1.json` if using an existing catalog. Do not seed an accounting ledger. Create `public/` beside `private/`.

Source the repository's `Scripts/test_environment.sh` from Bash. Set `CODEXBAR_REAL_HISTORY_PROOF_DIR` to the isolated proof root and `CODEXBAR_REAL_HISTORY_PROOF_MODE=scan`, then run the included XCTest filter using the repository's Swift test environment. Run again in a separate process with mode `reload`. This execution used `swift test --build-system native --jobs 4 -Xswiftc -gnone`; the reload used `--skip-build`.

For local build cost only, the test target's source list was temporarily restricted to this harness. Production sources and module dependencies were unchanged, and the original manifest was restored afterward. No product branch changes are required for this evidence.
