# Performance and stability follow-up

These measurements use synthetic history on a 24 GiB, 60 Hz Apple Silicon Mac
with ten logical processors. They use the native SwiftPM debug build, not a
release or installed application. They measure scheduling and model construction,
not display presentation, task quality, or cross-provider ability.

## Findings and changes

- Menu/share summaries previously built session evidence and runtime profiles
  despite displaying only billing aggregates. They now omit those details while
  preserving costs, tokens, models, projects, charts, and coverage.
- Observation compared entire equivalent dashboard models on the main actor,
  including retained raw turns. It now tracks an immutable snapshot by reference.
  Regression coverage verifies that the page still receives model updates.
- A selected native source with partial history and no eligible timed turns could
  disappear from the score's partial-history warning. The warning now includes
  every selected native source, while excluding hidden/imported/other-provider
  sources.

## Measurements

The large fixture has 2,000 sessions, 100,000 completed timed turns, and eight
model configurations. Model measurements discard two warmups and retain eleven
observations. Full-controller measurements include initial publication and two
refreshes of unchanged history.

| Measurement | Observed result |
| --- | --- |
| Full controller completion, first confirmation run | 1,191–1,236 ms |
| Main-actor enqueue, first confirmation run | 0.032–0.247 ms |
| Main-actor heartbeat P95, first confirmation, target 4 ms | 5.031–5.041 ms |
| Main-actor heartbeat maximum, first confirmation | 5.109 ms |
| Earlier unchanged refresh, final heartbeat gap | 29.1–34.1 ms |
| Second confirmation with concurrent compilation, controller completion | 1,428–3,817 ms |
| Second confirmation, heartbeat P95 / maximum | Up to 8.373 / 33.015 ms |
| Second confirmation, final publication heartbeat gap | 4.08–6.23 ms |
| Final menu/share summary model, median | 0.614 ms |
| Final menu/share summary model, maximum | 0.725 ms |

The heartbeat's 4 ms sleep target is approximate; operating-system scheduling
adds delay. Post-change measurements with concurrent compilation still had
scheduling outliers up to 33.0 ms, away from publication. The observation is
consistent with system contention; it does not establish the cause of every
outlier. These
results do not promise that every frame meets a 60 Hz or 120 Hz deadline.

The lightweight and full models are different construction paths in the same
build. This comparison demonstrates omitted work; it is not an apples-to-apples
benchmark against CodexBar before the feature. Whole-dashboard timings include
existing billing/chart work and must not be presented as rating-only overhead.

## Resource and stability boundaries

Rendering reads prepared summaries and adds no history scans, network/model
grading calls, or polling timers. The projection worker retains one active build
and one replaceable pending request. Invalidation rejects stale publication and
clears pending work; an already running pure build drains to completion.

The measurement process reported maximum resident size of approximately
338–369 MiB, including the Swift test runner, aggregate test bundle, and fixture.
Its reported peak memory footprint was approximately 87–90 MiB, with zero swaps.
Those are distinct process counters, not the feature's incremental retained
memory or an installed application's footprint. Repeated synthetic input arrays
share storage; real histories can have different allocation patterns.

The broad focused run passed 515 tests across 33 suites, including menu totals,
refresh/cancellation, latest-pending work, source hiding, stop/reopen, and stale
publication. A final focused run passed 77 tests including the provider
architecture checks. The final full-suite outcome is recorded separately in the
audit receipt; focused tests are not a substitute for the full run. The final
official run selected 1,644 selections in 148 groups: 147 groups passed, one
Widget rendering/OCR group failed with `.nilError` in both headline parameter
cases, and there were no timeouts or retries. That Widget test is unchanged from
the audited upstream base. The full run is not reported as passing.

No release build, actual scrolling frame trace, 120 Hz display, 8 GiB device,
real-account scan, or long-running installed-app memory test was performed.
