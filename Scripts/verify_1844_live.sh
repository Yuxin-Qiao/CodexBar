#!/usr/bin/env bash
# Live verification for CodexBar #1844 / PR #1848
# Usage: ./Scripts/verify_1844_live.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REAL_HOME="$(eval echo "~$(id -un)")"
ARTIFACT="${TMPDIR:-/tmp}/codexbar-1844-verify"
ARTIFACT_HOME="$ARTIFACT/home"
mkdir -p "$ARTIFACT" "$ARTIFACT_HOME/.claude"

CLI="${CODEXBAR_CLI:-$ROOT/.build/release/CodexBarCLI}"
if [[ ! -x "$CLI" ]]; then
  CLI="$ROOT/CodexBar.app/Contents/Helpers/CodexBarCLI"
fi
if [[ ! -x "$CLI" ]]; then
  echo "Building CodexBarCLI..."
  swift build -c release --product CodexBarCLI
  CLI="$ROOT/.build/release/CodexBarCLI"
fi

log() { printf '[verify-1844] %s\n' "$*"; }

login_keychain_path() {
  if [[ -f "$REAL_HOME/Library/Keychains/login.keychain-db" ]]; then
    printf '%s\n' "$REAL_HOME/Library/Keychains/login.keychain-db"
  else
    printf '%s\n' "$REAL_HOME/Library/Keychains/login.keychain"
  fi
}

list_claude_keychain_accounts() {
  local keychain path="$1"
  [[ -f "$path" ]] || return 0
  security dump-keychain "$path" 2>/dev/null \
    | awk '
      /"svce"<blob>="Claude Code-credentials"/ { in_item=1; next }
      in_item && /"acct"<blob>=/ {
        line=$0
        sub(/.*<blob>="/, "", line)
        sub(/".*/, "", line)
        print line
        in_item=0
      }
    '
}

log "Phase 1: macOS integration tests"
swift test --filter 'mcp O auth|delegated retry experimental|load with auto refresh expired claude CLI owner throws mcp' \
  2>&1 | tee "$ARTIFACT/integration-tests.log"
log "Phase 1 passed"

KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="codexbar-verify-1844"
KEYCHAIN_PATH="$(login_keychain_path)"
CREDS_FIXTURE="$ARTIFACT_HOME/.claude/.credentials.json"
CONFIG="$ARTIFACT/config.json"
MCP_PAYLOAD='{"mcpOAuth":{"plugin:slack:slack":{"accessToken":""},"craft":{"accessToken":""}}}'
EXPIRED_PAYLOAD='{"claudeAiOauth":{"accessToken":"verify-expired-redacted","expiresAt":1000,"scopes":["user:profile"],"refreshToken":"verify-refresh-redacted"}}'

cleanup() {
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Phase 2: optional Keychain fixture E2E"
log "Uses isolated HOME at $ARTIFACT_HOME (does not modify $REAL_HOME/.claude)."
log "Approve the macOS Keychain prompt if shown (required once to install the test fixture)."

EXISTING_ACCOUNTS=()
while IFS= read -r account; do
  EXISTING_ACCOUNTS+=("$account")
done < <(list_claude_keychain_accounts "$KEYCHAIN_PATH" || true)
if ((${#EXISTING_ACCOUNTS[@]} > 0)); then
  log "Existing $KEYCHAIN_SERVICE accounts before fixture install:"
  for account in "${EXISTING_ACCOUNTS[@]}"; do
    log "  - ${account:-<empty>}"
  done
  log "Background reads are unpinned; Phase 2 requires the MCP fixture to be the item returned by security."
fi

security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
if ! security add-generic-password \
  -a "$KEYCHAIN_ACCOUNT" \
  -s "$KEYCHAIN_SERVICE" \
  -w "$MCP_PAYLOAD" \
  -T "$CLI" \
  -T /usr/bin/security \
  -U 2>"$ARTIFACT/keychain-install.err"; then
  log "Phase 2 skipped: could not install Keychain fixture (see $ARTIFACT/keychain-install.err)"
  log "Phase 1 integration results remain valid for review."
  exit 0
fi

if ! READ_PAYLOAD="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>"$ARTIFACT/keychain-read.err")"; then
  log "Phase 2 skipped: fixture not readable via unpinned security lookup"
  log "See $ARTIFACT/keychain-read.err"
  exit 0
fi
if ! printf '%s' "$READ_PAYLOAD" | rg -q 'mcpOAuth'; then
  log "Phase 2 skipped: unpinned keychain read did not return the MCP fixture payload"
  log "Another $KEYCHAIN_SERVICE entry may take precedence on this machine."
  log "Captured payload prefix: $(printf '%.80s' "$READ_PAYLOAD")"
  exit 0
fi
log "Keychain preflight OK: unpinned read returned MCP-only fixture payload"

printf '%s\n' "$EXPIRED_PAYLOAD" >"$CREDS_FIXTURE"
chmod 600 "$CREDS_FIXTURE"
printf '%s\n' '{"version":1,"providers":[{"id":"claude","enabled":true}]}' >"$CONFIG"

PROC_LOG="$ARTIFACT/e2e-proc.log"
: >"$PROC_LOG"
log "Running background Claude OAuth CLI probe (HOME=$ARTIFACT_HOME)"
(
  HOME="$ARTIFACT_HOME" CODEXBAR_CONFIG="$CONFIG" CODEXBAR_DEBUG_CLAUDE_OAUTH_FLOW=1 \
    "$CLI" usage --provider claude --source oauth --format json --json-output --log-level debug \
      >"$ARTIFACT/e2e-stdout.json" 2>"$ARTIFACT/e2e-stderr.jsonl"
) &
PID=$!
while kill -0 "$PID" 2>/dev/null; do
  { date -u +%H:%M:%S; pgrep -P "$PID" -l 2>/dev/null || true
    pgrep -fl '/usr/bin/open|firefox|claude' 2>/dev/null | rg -v 'CodexBarCLI|verify_1844' || true
  } >>"$PROC_LOG"
  sleep 0.05
done
wait "$PID" || true

{
  echo "# CodexBar #1844 E2E verification"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "claude: $(claude --version 2>/dev/null || echo n/a)"
  echo "home: $ARTIFACT_HOME"
  echo "keychain: $KEYCHAIN_PATH"
  echo
  echo "## stdout"
  cat "$ARTIFACT/e2e-stdout.json"
  echo
  echo "## stderr (filtered)"
  rg -i 'mcp|delegated|expired|oauth|touch|open|only prompt|security cli' "$ARTIFACT/e2e-stderr.jsonl" || true
  echo
  echo "## child processes"
  cat "$PROC_LOG"
} | tee "$ARTIFACT/E2E-REPORT.md"

if rg -q '/usr/bin/open|firefox' "$PROC_LOG" 2>/dev/null; then
  log "Phase 2 failed: browser or open helper launched"
  exit 1
fi
if rg -q 'delegated refresh touch' "$ARTIFACT/e2e-stderr.jsonl" 2>/dev/null; then
  log "Phase 2 failed: delegated CLI touch ran"
  exit 1
fi
if rg -qi 'delegating refresh to Claude CLI' "$ARTIFACT/e2e-stderr.jsonl" 2>/dev/null \
  && ! rg -qi 'delegated refresh skipped|MCP OAuth state only' "$ARTIFACT/e2e-stderr.jsonl" 2>/dev/null; then
  log "Phase 2 failed: background path attempted delegated CLI refresh without MCP-only guard"
  exit 1
fi
if ! rg -qi 'MCP OAuth state only|mcp oauth only|mcpOAuthOnly' \
  "$ARTIFACT/e2e-stderr.jsonl" "$ARTIFACT/e2e-stdout.json" 2>/dev/null; then
  log "Phase 2 failed: expected MCP-only keychain fail-closed messaging not found"
  exit 1
fi

log "Phase 2 passed: background probe failed closed on MCP-only keychain without open or delegated CLI touch"
log "Report: $ARTIFACT/E2E-REPORT.md"
