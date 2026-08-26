#!/usr/bin/env bash
set -euo pipefail

# Detect which coding agent is hosting this skill run.
#
# Prints exactly one of: claude-code | codex | other
# With --explain, also prints the deciding signal on stderr.
#
# Detection order (first match wins):
#   1. CROSS_MODEL_REVIEW_HOST override
#   2. process ancestry (the host binary that spawned this shell)
#   3. environment markers
#   4. other

explain=0
for arg in "$@"; do
  case "$arg" in
    --explain) explain=1 ;;
    --help|-h)
      printf '%s\n' "Usage: $0 [--explain]"
      printf '%s\n' "Prints: claude-code | codex | other"
      exit 0
      ;;
    *)
      printf '%s\n' "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

note() {
  [ "$explain" -eq 1 ] && printf '%s\n' "detect-host-agent: $1" >&2
  return 0
}

decide() {
  note "$2"
  printf '%s\n' "$1"
  exit 0
}

# 1. Explicit override.
if [ -n "${CROSS_MODEL_REVIEW_HOST:-}" ]; then
  case "$CROSS_MODEL_REVIEW_HOST" in
    claude-code|codex|other)
      decide "$CROSS_MODEL_REVIEW_HOST" "CROSS_MODEL_REVIEW_HOST override"
      ;;
    *)
      printf '%s\n' "Invalid CROSS_MODEL_REVIEW_HOST: $CROSS_MODEL_REVIEW_HOST" >&2
      exit 2
      ;;
  esac
fi

# 2. Process ancestry. Most reliable: environment variables can leak across
# nested agents, but the parent chain is whatever actually launched this shell.
pid=${PPID:-0}
depth=0
while [ "$pid" -gt 1 ] && [ "$depth" -lt 16 ]; do
  depth=$((depth + 1))
  line=$(ps -o ppid=,comm= -p "$pid" 2>/dev/null || true)
  [ -z "$line" ] && break
  parent=$(printf '%s' "$line" | awk '{print $1}')
  comm=$(printf '%s' "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
  base=$(basename "$comm" 2>/dev/null || printf '%s' "$comm")

  case "$base" in
    codex|codex-*|codex.exe)
      decide codex "ancestor process '$base' (pid $pid)"
      ;;
    ChatGPT|chatgpt|ChatGPT.exe)
      decide codex "ancestor process '$base' (pid $pid)"
      ;;
    claude|claude.exe|claude-vps)
      decide claude-code "ancestor process '$base' (pid $pid)"
      ;;
  esac

  # Node/Bun-hosted agents keep the real identity in argv, not comm.
  case "$base" in
    node|bun|deno|python|python3)
      args=$(ps -o args= -p "$pid" 2>/dev/null || true)
      case "$args" in
        *"/codex"*) decide codex "ancestor argv contains '/codex' (pid $pid)" ;;
        *"/claude"*) decide claude-code "ancestor argv contains '/claude' (pid $pid)" ;;
      esac
      ;;
  esac

  [ "$parent" = "$pid" ] && break
  pid=$parent
done

# 3. Environment markers.
if [ -n "${CODEX_SANDBOX:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}${CODEX_PERMISSION:-}${CODEX_MANAGED_BY_NPM:-}${CODEX_STARTING_DIFF:-}${CODEX_THREAD_ID:-}" ]; then
  decide codex "CODEX_* environment marker"
fi

if [ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}${CLAUDE_CODE_SESSION_ID:-}" ]; then
  decide claude-code "CLAUDECODE/CLAUDE_CODE_* environment marker"
fi

case "${AI_AGENT:-}" in
  codex*) decide codex "AI_AGENT=$AI_AGENT" ;;
  claude*) decide claude-code "AI_AGENT=$AI_AGENT" ;;
esac

decide other "no Claude Code or Codex signal found"
