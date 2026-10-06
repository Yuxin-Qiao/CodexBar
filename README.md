# PR #4295: anonymized native runtime evidence

The same copied real history reproduced seven unavailable mixed-source request totals before the fix. The freshly built patched app rendered all seven as lower bounds. Unknown-only counts remained an em dash, and known-only counts remained exact. Daily tokens and costs were unchanged.

- Tested fix: `70a822973104cd7f6bba01686eb7fe1d74ad619f`
- Compared production model and renderer: `6a26b2e9b1b60471970deb6fe663f9e5f284e2ce`
- [Anonymized runtime transcript](runtime-transcript.md)
- [Verification results and public source hashes](verification.json)
- [Anonymized local native launcher](SpendRequestRuntimeProof.swift)

## Provenance and limits

Two separate macOS native bundles were built and run. The patched production model/renderer matched the fix commit, and the baseline production model/renderer matched the base commit. Both used the same temporary debug entrypoint before account/settings startup. The launcher ran production `CostUsageFetcher`, `OpenCodexUsageStore`, `SpendDashboardModel`, and `SpendDashboardCurrencySection`; it did not construct replacement daily rows or redraw the ledger.

The OpenCodex log and one non-forked native Codex session were copied read-only to an isolated input directory. Scans were allowed to finish before collecting proof. The known daily counts were independently checked by request ID deduplication in the same seven-day UTC window. Three native UI cases were captured: mixed sources, unknown-only, and exact-only. The visible table and its accessibility labels were checked. All 22 local verification checks passed, including unchanged input copies and unchanged daily token/cost values.

This is a bounded representative native-history sample, not a full native-history audit. It does not verify account refresh, release distribution, or installation replacement. The existing installed application was not changed. The PR head is unchanged; this evidence branch contains only public proof artifacts.

## Redaction

These files are explicitly anonymized derivatives. Dates and sources use consistent aliases. Actual request counts, tokens, monetary amounts, account/session identifiers, process IDs, private paths, raw history, and input-file fingerprints are withheld. The symbolic `N_A` aliases do not disclose or fabricate numeric values. Original screenshots, local receipts, and copied history remain local. No original screenshot is uploaded.

The launcher is provided for inspecting the production calls and isolation. Its public derivative uses generic source labels and takes the proof clock from `CODEXBAR_REQUEST_PROOF_NOW` instead of embedding the sample date. No private logs are included. It is not compiled into the submitted product patch.

## Launcher wiring and reproduction

On the tested fix checkout, temporarily add this launcher under `Sources/CodexBar` and invoke `SpendRequestRuntimeProof.runIfRequested()` in the `#if DEBUG` section of `CodexBarEntryPoint.main()`, before normal app startup. Create separate copied inputs and output caches under a disposable proof root:

- `inputs/codex/sessions/` and `inputs/codex/archived_sessions/`
- `inputs/opencodex/usage.jsonl`
- `patched/`, `baseline/`, an isolated `home/`, and `tmp/`

Build with `CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh debug`. Launch the freshly built executable with `CODEXBAR_REQUEST_PROOF_ROOT` pointing to the proof root, `CODEXBAR_REQUEST_PROOF_VARIANT=patched`, `CODEXBAR_REQUEST_PROOF_NOW` set to a Unix-seconds cutoff matching the copied inputs, and `CFFIXED_USER_HOME` and `TMPDIR` pointing to contained directories. Do not use credentials or live account probes. The local receipt may contain private values; do not publish it without redaction.

For the baseline comparison, restore the two production model/renderer files from the base commit while keeping the same launcher and copied inputs, build a separate bundle, and launch with variant `baseline`. Confirm the three cases in the native UI, compare the underlying daily token/cost values, and restore all production sources afterward.
