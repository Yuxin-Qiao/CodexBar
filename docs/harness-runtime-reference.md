---
summary: "Scope, scoring rules, and verification for experimental inline harness runtime references."
read_when:
  - Reviewing the score beside a provider in Usage & Spend
  - Checking sample coverage or reproducing the native harness previews
---

# Harness runtime reference

Usage & Spend shows the runtime reference and four colored observations beside
the existing provider name. Clicking the score or information control opens a
scrollable popover with measured values, eligible sample counts, thresholds,
and the rule version. There is no new settings page or navigation tab.

The score is explicitly experimental. **Task performance is not evaluated**:
completed turns do not prove that a task was correct, accepted, or reliable.
The thresholds have not been calibrated against matched tasks or user ratings.
They describe observations from the selected local history, not a capability
leaderboard or a recommendation to switch providers.

## Eligible observations

Only native Codex completed turns with validated timing currently supply these
observations. Other providers and imported OpenCodex history have a clickable
unavailable explanation instead of an invented score. Failures, abandoned
attempts, and task acceptance are not recorded in the score's denominator.

Completion dates follow the selected chart range, day, and reporting time zone.
Hidden sources are excluded. Provider values combine original eligible samples
across selected sources and model/effort configurations; they do not average
configuration medians or rates. Billing keeps its existing request dates, prices,
and totals. Timing can span a different date from the requests that paid for it.

Each dimension needs at least five eligible samples. Cache and first-token
coverage can be smaller than the total timed-turn count. Missing measurements
and insufficient samples remain unavailable. A total out of 100 is shown only
when all four dimensions are rated; missing dimensions are neither assigned zero
nor given redistributed weight. Five samples are a display threshold, not a
statistical confidence guarantee. Partial history remains visibly marked.

## Experimental rules

The rule version is `runtime-experience-v3`. Within the thresholds below, points
are interpolated linearly, clamped to the dimension's range, and rounded to the
nearest integer. The total sums the four rounded values.

| Observation | Maximum | Full points | Zero points | Meaning |
| --- | ---: | --- | --- | --- |
| Cache reuse | 35 | At least 90% | 0% | Cached input divided by total input, weighted by input tokens across eligible turns |
| First token | 25 | At most 1 second | At least 10 seconds | Median model-first-token latency; this token may be reasoning before visible text |
| Whole-turn output | 20 | At least 20 tokens/second | 0 tokens/second | Summed output divided by summed turn time, including reasoning, tools, and waits |
| Turn duration | 20 | At most 30 seconds | At least 300 seconds | Median completed-turn duration, including reasoning, tools, and waits |

Cache samples require valid input/cache counts with positive input. Invalid or
zero-input measurements do not become a perfect cache result. First-token timing
must belong to the measured turn. Per-dimension descriptive bands use at least
85% of available points for the upper band and at least 60% for the middle band.

Whole-turn output is not model streaming speed. Token units can differ across
models, and output and duration are related measures. More demanding tasks can
take longer and involve more tools. Workload, source coverage, model, reasoning
effort, and configuration therefore affect these values. Scores cannot establish
a fair cross-provider comparison without a shared task and acceptance protocol.

## Loading and privacy

Profiles and provider breakdowns are prepared once in the dashboard projection,
away from the main actor. The worker permits one active projection and one
replaceable pending request. A revision check rejects superseded results,
including across stop/reopen and source replacement. Hiding sources clears the
previous displayed model. Updated observations close an obsolete score popover.

Rendering does not scan logs, make model or network grading calls, or add polling
timers. The score popover uses aggregate values and static explanations. Existing
privacy and provider/source boundaries remain in effect. Long amounts move below
the identity when they cannot fit beside it; wide layouts keep amounts on the
right. These changes do not establish a measured 120 Hz or low-memory guarantee.

## Verification

Use the repository's isolated test environment:

```sh
source Scripts/test_environment.sh
swift test --build-system native --jobs 4 -Xswiftc -gnone \
  --filter 'SpendAgentProfileTests|SpendDashboardProjectionTests|CostUsageTurnPerformanceDetailsTests'
make check
make test
```

For native component renders, set `CODEXBAR_AGENT_PROFILE_UI_PROOF_DIR` after
sourcing the test environment, then run `SpendAgentProfileTests` alone. Run the
projection concurrency tests separately: synchronous native rendering occupies
the main actor and can invalidate their short wait deadlines. The synthetic
renderer covers English/Chinese, light/dark, 360/520/980 pt provider layouts,
ordinary and long amounts, unavailable and insufficient samples, the popover,
and the overall page. It does not launch the installed app or read real accounts.

Representative renders and their receipt are in the PR's synthetic proof bundle
at `.github/pr-proof/harness-runtime-reference`.
Task feedback persistence, task acceptance rates, standardized benchmark imports,
and an active benchmark runner are outside this implementation.
