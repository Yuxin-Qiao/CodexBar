# Verification: Claude MCP-only keychain guard (#1844)

Verification artifact for [PR #1848](https://github.com/steipete/CodexBar/pull/1848).

| Field | Value |
|-------|-------|
| Branch | `cursor/fix-claude-oauth-background-refresh-1114` |
| Date | 2026-07-03 |
| Platform | macOS arm64 |
| Claude Code CLI | 2.1.193 |

## Scope

This documents **Phase 1** behavior: CodexBar must fail closed when `Claude Code-credentials` contains only `mcpOAuth`, and must not invoke delegated `claude /status` refresh from background paths (which can launch the default browser via `/usr/bin/open`).

Phase 1 does **not** implement discovery of a new Claude Code primary OAuth storage location. That remains follow-up on #1844.

## Automated verification (macOS integration tests)

Command:

```bash
./Scripts/verify_1844_live.sh
# Phase 1 only (default when Keychain fixture install is unavailable):
swift test --filter 'mcp O auth|delegated retry experimental|load with auto refresh expired claude CLI owner throws mcp'
```

Result: **5/5 tests passed** on macOS release-linked binaries.

| Check | Result |
|-------|--------|
| Background `onlyOnUserAction` suppresses delegated refresh with `securityCLIExperimental` reader | Pass |
| Delegated refresh coordinator skips CLI touch when keychain payload is MCP-only | Pass |
| Expired Claude CLI-owned credentials fail fast with `mcpOAuthOnlyKeychain` | Pass |
| Parser rejects MCP-only keychain shape | Pass |

Representative log lines:

```text
Claude keychain security CLI output is MCP OAuth only; falling back
Claude OAuth delegated refresh skipped: Claude keychain has MCP OAuth state only
Claude OAuth credentials expired; Claude keychain has MCP OAuth state only
```

## Optional Keychain fixture E2E

`./Scripts/verify_1844_live.sh` Phase 2:

1. Runs integration tests (Phase 1).
2. Installs a temporary `Claude Code-credentials` entry (`account=codexbar-verify-1844`) trusted for `CodexBarCLI` and `/usr/bin/security`.
3. Uses an **isolated** `HOME` under `$TMPDIR/codexbar-1844-verify/home` so the script never reads or writes `~/.claude/.credentials.json`.
4. **Preflight:** verifies the unpinned `security find-generic-password -s "Claude Code-credentials"` read returns the MCP fixture (skips when another keychain item takes precedence).
5. Runs a background `CodexBarCLI usage --provider claude --source oauth` probe.

This step requires approving a macOS Keychain write prompt once. Unattended automation cannot complete that step.

Expected when the fixture is the item returned by security:

- `MCP OAuth state only` / `mcpOAuthOnly` diagnostics in stderr
- No `/usr/bin/open` or default-browser child processes during the probe
- No `Claude OAuth delegated refresh touch` log line
- No background `delegating refresh to Claude CLI` without the MCP-only guard

## Assessment

Integration tests cover the production code paths changed in PR #1848 and demonstrate the guard described in #1844.

Phase 2 adds a deterministic, isolated live replay when the fixture is readable. A full reporter-environment replay (existing corrupted keychain on Claude Code 2.1.x plus menu Refresh UI proof) is optional supplementary evidence, not required to validate the Phase 1 code paths.
