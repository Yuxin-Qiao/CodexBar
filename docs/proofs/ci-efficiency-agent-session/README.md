# CI efficiency guidance: actual agent handoff evidence

This records a real Codex CLI developer-handoff assessment of [CodexBar PR #4404](https://github.com/steipete/CodexBar/pull/4404) on October 10, 2026. The checkout and reviewed head were `1ea3f1af7c59205fc45a22a879da1071e3a8ba31`; its base was `08f42ab067044e911366e2c4fc2433850b3dafe9`. The agent process completed with exit code 0.

The task asked the agent to apply repository instructions, verify the actual PR and validation state with terminal tools, and decide whether further local checks were justified. Local validation was permitted; the prompt did not prescribe skipping full tests. Publication and merge were delegated to the parent agent. See [the supplied prompt](prompt.txt).

## Observed behavior

The actual [terminal event record](session.jsonl) includes the agent reading `AGENTS.md`, inspecting the current workflow and cache helper, checking the clean checkout and single-file diff, and querying live PR/run state. It executed both production path gates on the actual base/head diff, compared cache-context and gate blobs against the merged base, and matched recorded CI events independently against the live macOS log. All 20 shell commands completed successfully; three private-memory command events are omitted from the public derivative.

The agent explicitly applied [AGENTS.md line 35](https://github.com/steipete/CodexBar/blob/1ea3f1af7c59205fc45a22a879da1071e3a8ba31/AGENTS.md#L35) in its recorded message:

> I’ve locally passed whitespace validation and both production path gates on the actual base/head diff. I won’t repeat the full Swift suite solely for this handoff: `AGENTS.md:35` explicitly discourages that when successful checks already cover unchanged inputs.

Its [final handoff](handoff.md) retained required full-suite evidence and separated prior hosted checks from local checks. It reported that the cache download led to a conservative clean fallback, and made no speedup claim. No tracked file changed and no full Swift build/test, cache cleanup, remote workflow rerun, or publication was initiated by this agent session. This is observable from the command record, not a mocked command runner.

## Existing required validation retained

[Run 38022055294, attempt 1](https://github.com/steipete/CodexBar/actions/runs/38022055294) completed successfully for this PR head before the handoff task. The actual macOS log reports 1,651 discovered selections and 216 first-pass successful groups with two workers. Lint, compatibility compilation, plugin engine goldens, both Linux glibc lanes, and aggregate CI also passed. The production gates required macOS and Linux glibc validation and skipped musl; the agent did not weaken or change those gates.

See [bounded original CI log excerpts](ci-log-excerpts.txt) and [run/job summary](ci-summary.json). Queue and execution durations are reported separately. Both macOS lanes recorded `cleaned: true` with `fallback: "build input paths changed"`; this run establishes successful required checks, not an incremental-build speedup. The document-only PR does not alter cache-context inputs.

## Boundaries and privacy

This proves that one actual agent applied the changed guidance during a real PR handoff after completed CI. It is not a new local full-suite run, a controlled before/after prompt experiment, or a guarantee about all future agents. It does not imply maintainer approval or merge.

The public event record is a consistently sanitized derivative of the retained original CLI JSONL: private local/runner paths, emails, private-memory command events, session identifiers, and usage metadata are removed or normalized. Long outputs explicitly mark excerpting. The agent's statements and command results are actual recorded events; no missing checks are supplied with invented results. [Provenance](provenance.json) lists these transformations and the original-stream hash. The raw private stream is preserved locally.

These proof documents live on a separate fork evidence branch; they do not enlarge the product PR diff or introduce a recurring CI job.
