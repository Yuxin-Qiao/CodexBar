# Cost history persistence — 2026-10-09

Outcome: reduce disk writes for changing local history while preserving the JSON cache contract, independent provider/window scopes, exact bytes, atomic replacement and cold recovery.

Baseline: upstream 83f0ca80b. Issue #3882 reports 116.7 MB of full cache/memo payloads written for 12 single-row appends against 24,000 retained rows. Existing PRs #4379/#4380 concern catch-up completion/navigation, not persistence. No open overlapping persistence PR found at kickoff.

Context: Alec Context Projects/CodexBar and its project router; preceding contribution audit at /Users/alecgutman/research/codexbar/2026-10-09-feature-health/report.md. Constraints: sanitized synthetic histories, no real account/Keychain probes, preserve active app and other worktrees. AGENTS.md requires make test and make check for a code handoff.

Cause: CostUsageClaudeCacheIO.write streams complete artifacts into a fresh temporary file. Fragment caching reduces encoding, not payload writes. Digest equality is checked only after temporary output has been written.

Experiment: on macOS clone the previous inode into private temporary storage, compare bounded blocks and write changed blocks, then retain the atomic rename. Fall back to full writes when cloning is unavailable. Keep the schema and file layout unchanged. No claim about total disk throughput or every CPU issue.

## Local experiment results

The paired synthetic scanner regression retained 24,000 rows and appended one row 12 times. Full-write fallback submitted 89,073,643 bytes; cloning submitted 34,873,402 bytes: a 60.85% reduction. Both paths produced identical daily, hourly, and quota-slice reports after each append and after evicting memory and cold reloading. The original implementation failed the initial write-budget experiment; the final regression requires at least 50% fewer submitted bytes on a clone-capable volume and equivalent reports.

Elapsed time was 10.76 seconds for full writes and 11.28 seconds for cloning in this single paired run. This is not a CPU improvement claim. The byte counter measures bytes submitted by the writer, not physical APFS writes, total application disk throughput, or NAND wear. The issue reporter's 116.7 MB is a different observation; it is not our baseline.

The 59 focused tests in six suites passed. Coverage includes exact bytes for growth, shifted contents, edits, shrink, empty output, resetting streamed output, forced full-write fallback, read-only source replacement, repeated replacements, cancellation after private output, scope isolation, fragment caching, cache upgrades and memo invalidation.

Independent read-only review found a read-only clone fallback problem in the first prototype; clone eligibility and fallback now handle it, with a regression test. Clone paths normalize the output to mode 0600. Source inodes are pinned while cloning; symlinks are not followed. Final review found no actionable correctness or compatibility blocker. Cloned extended attributes remain inherited, and a same-user regular-file replacement race remains outside this cache-directory threat model.

## Remaining limits and release state

Changes in serialized lengths can shift large suffixes, which the same-offset block comparison must rewrite. The initial 4 MiB target was missed; #3882 is only partially addressed. Full hashing and comparison still occur. Unsupported volumes and Linux use the full-write fallback. No JSON schema or filename changes are introduced.

This is a local implementation on `fix/claude-history-incremental-writes`, not an installed or released app. No live provider, account, Keychain, or app restart probes ran. Missing usage tail #3316 and remote quota failures in the latest #3716 comment remain separate investigations.

Full repository verification: `make check` passed, including script/packaging checks, SwiftFormat and SwiftLint (2,932 files, zero violations). `make test` passed all 148 groups covering 1,643 discovered selections on the first attempt, with zero retries or timeouts (26.4 minutes). The full suite repeated the append measurement at 89,073,644 versus 34,873,404 submitted bytes, preserving the same 60.85% reduction. Final recompilation and the affected 23 tests in two suites passed after correcting SwiftFormat's ambiguous multiple-closure rewrite with an explicitly typed callback. Targeted SwiftLint and SwiftFormat passed on the final test source; production source is unchanged from the full-suite run. Build concurrency is capped at two workers, using the repo's sanitized test environment. Evidence logs live beside the contribution audit.
