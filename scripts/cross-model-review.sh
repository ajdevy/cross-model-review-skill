#!/usr/bin/env bash
set -euo pipefail

# Run a code review with a model from a different family than the host agent.
#
#   host = Claude Code  -> reviewer = codex        (gpt-5.6-terra, reasoning max)
#   host = Codex/ChatGPT-> reviewer = claude-vps   (claude-opus-5, effort max)
#   host = anything else-> reviewer = claude-vps   (claude-opus-5, effort max)
#
# The review text is written to --out and echoed on stdout. Progress and
# routing metadata go to stderr so stdout stays a clean review document.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
detector="$script_dir/detect-host-agent.sh"

codex_model=${CROSS_MODEL_REVIEW_CODEX_MODEL:-gpt-5.6-terra}
codex_effort=${CROSS_MODEL_REVIEW_CODEX_EFFORT:-max}
claude_model=${CROSS_MODEL_REVIEW_CLAUDE_MODEL:-claude-opus-5}
claude_effort=${CROSS_MODEL_REVIEW_CLAUDE_EFFORT:-max}
diff_inline_limit=${CROSS_MODEL_REVIEW_DIFF_LIMIT:-60000}

scope=auto
base=""
commit=""
workdir=$PWD
host_override=""
reviewer_override=""
out_file=""
timeout_secs=${CROSS_MODEL_REVIEW_TIMEOUT:-2400}
print_command=0
dry_run=0
paths=()
extra_instructions=""

usage() {
  cat <<'USAGE'
Usage: cross-model-review.sh [options] [-- extra review instructions]

Scope options:
  --scope <auto|uncommitted|staged|branch|commit|paths|all>
                          What to review (default: auto)
  --base <branch>         Base branch for --scope branch (default: auto-detect)
  --commit <sha>          Commit for --scope commit
  --path <path>           File/dir for --scope paths (repeatable)

Routing options:
  --cwd <dir>             Repository/working directory (default: current dir)
  --host <claude-code|codex|other>
                          Override host-agent detection
  --reviewer <codex|claude-vps>
                          Override reviewer selection

Output options:
  --out <file>            Write the review here (default: temp file)
  --timeout <seconds>     Abort the reviewer after N seconds (default: 2400)
  --print-command         Print the reviewer command and exit
  --dry-run               Print the reviewer command and the full prompt, then exit
  -h, --help              This help

Environment overrides:
  CROSS_MODEL_REVIEW_HOST, CROSS_MODEL_REVIEW_CODEX_MODEL,
  CROSS_MODEL_REVIEW_CODEX_EFFORT, CROSS_MODEL_REVIEW_CLAUDE_MODEL,
  CROSS_MODEL_REVIEW_CLAUDE_EFFORT, CROSS_MODEL_REVIEW_DIFF_LIMIT,
  CROSS_MODEL_REVIEW_TIMEOUT

Exit codes: 0 ok | 2 usage error | 3 reviewer CLI unavailable
            4 reviewer failed or timed out | 5 reviewer returned nothing
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scope) scope=${2:-}; shift 2 ;;
    --base) base=${2:-}; shift 2 ;;
    --commit) commit=${2:-}; shift 2 ;;
    --path) paths[${#paths[@]}]=${2:-}; shift 2 ;;
    --cwd) workdir=${2:-}; shift 2 ;;
    --host) host_override=${2:-}; shift 2 ;;
    --reviewer) reviewer_override=${2:-}; shift 2 ;;
    --out) out_file=${2:-}; shift 2 ;;
    --timeout) timeout_secs=${2:-}; shift 2 ;;
    --print-command) print_command=1; shift ;;
    --dry-run) dry_run=1; print_command=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; extra_instructions="$*"; break ;;
    *) printf '%s\n' "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$workdir" ]; then
  printf '%s\n' "Not a directory: $workdir" >&2
  exit 2
fi
workdir=$(cd "$workdir" && pwd -P)

# ---------------------------------------------------------------- routing ---

if [ -n "$host_override" ]; then
  host=$host_override
else
  host=$("$detector" 2>/dev/null || printf 'other\n')
fi

case "$host" in
  claude-code) reviewer=codex ;;
  codex) reviewer=claude-vps ;;
  other) reviewer=claude-vps ;;
  *)
    printf '%s\n' "Invalid host: $host (expected claude-code, codex, or other)" >&2
    exit 2
    ;;
esac
[ -n "$reviewer_override" ] && reviewer=$reviewer_override

case "$reviewer" in
  codex)
    reviewer_bin=codex
    reviewer_model=$codex_model
    reviewer_effort=$codex_effort
    ;;
  claude-vps)
    reviewer_bin=claude-vps
    reviewer_model=$claude_model
    reviewer_effort=$claude_effort
    claude_vps_unavailable=""
    if ! command -v claude-vps >/dev/null 2>&1; then
      claude_vps_unavailable="not installed"
    elif ! claude-vps --version >/dev/null 2>&1; then
      claude_vps_unavailable="tunnel/proxy unavailable"
    fi
    if [ -n "$claude_vps_unavailable" ]; then
      if command -v claude >/dev/null 2>&1; then
        printf '%s\n' "cross-model-review: claude-vps $claude_vps_unavailable, falling back to claude" >&2
        reviewer_bin=claude
      fi
    fi
    ;;
  *)
    printf '%s\n' "Invalid reviewer: $reviewer (expected codex or claude-vps)" >&2
    exit 2
    ;;
esac

if ! command -v "$reviewer_bin" >/dev/null 2>&1; then
  printf '%s\n' "Reviewer CLI not found on PATH: $reviewer_bin" >&2
  exit 3
fi

# ------------------------------------------------------------------ scope ---

git_repo=0
if git -C "$workdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_repo=1
fi

git_in() { git -C "$workdir" "$@"; }

detect_base() {
  local candidate
  candidate=$(git_in symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$candidate" ] && git_in rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in origin/main origin/master origin/develop main master develop; do
    if git_in rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

has_uncommitted() {
  [ -n "$(git_in status --porcelain 2>/dev/null || true)" ]
}

if [ "$scope" = auto ]; then
  if [ "${#paths[@]}" -gt 0 ]; then
    scope=paths
  elif [ "$git_repo" -eq 0 ]; then
    scope=all
  elif has_uncommitted; then
    scope=uncommitted
  else
    scope=branch
  fi
fi

case "$scope" in
  uncommitted|staged|branch|commit|paths|all) ;;
  *) printf '%s\n' "Invalid scope: $scope" >&2; exit 2 ;;
esac

if [ "$git_repo" -eq 0 ] && [ "$scope" != paths ] && [ "$scope" != all ]; then
  printf '%s\n' "Not a git repository: $workdir (use --scope paths or --scope all)" >&2
  exit 2
fi

if [ "$scope" = commit ] && [ -z "$commit" ]; then
  printf '%s\n' "--scope commit requires --commit <sha>" >&2
  exit 2
fi

if [ "$scope" = paths ] && [ "${#paths[@]}" -eq 0 ]; then
  printf '%s\n' "--scope paths requires at least one --path" >&2
  exit 2
fi

scope_label=""
scope_command=""
diff_text=""
stat_text=""

case "$scope" in
  uncommitted)
    scope_label="uncommitted changes (staged + unstaged + untracked)"
    scope_command="git diff HEAD"
    stat_text=$(git_in diff HEAD --stat 2>/dev/null || true)
    diff_text=$(git_in diff HEAD 2>/dev/null || true)
    untracked=$(git_in ls-files --others --exclude-standard 2>/dev/null || true)
    if [ -n "$untracked" ]; then
      stat_text="$stat_text

Untracked files (not in the diff above — read them directly):
$untracked"
    fi
    ;;
  staged)
    scope_label="staged changes"
    scope_command="git diff --cached"
    stat_text=$(git_in diff --cached --stat 2>/dev/null || true)
    diff_text=$(git_in diff --cached 2>/dev/null || true)
    ;;
  branch)
    if [ -z "$base" ]; then
      base=$(detect_base || true)
    fi
    if [ -z "$base" ]; then
      printf '%s\n' "Could not auto-detect a base branch; pass --base <branch>" >&2
      exit 2
    fi
    merge_base=$(git_in merge-base "$base" HEAD 2>/dev/null || printf '%s' "$base")
    scope_label="changes on this branch versus $base (merge-base $merge_base)"
    scope_command="git diff $merge_base...HEAD"
    stat_text=$(git_in diff "$merge_base" HEAD --stat 2>/dev/null || true)
    diff_text=$(git_in diff "$merge_base" HEAD 2>/dev/null || true)
    ;;
  commit)
    scope_label="the changes introduced by commit $commit"
    scope_command="git show $commit"
    stat_text=$(git_in show --stat --oneline "$commit" 2>/dev/null || true)
    diff_text=$(git_in show "$commit" 2>/dev/null || true)
    ;;
  paths)
    scope_label="these files/directories as a whole: ${paths[*]}"
    scope_command="read each path listed below in full"
    stat_text=$(printf '%s\n' "${paths[@]}")
    diff_text=""
    ;;
  all)
    scope_label="the whole project at $workdir"
    scope_command="explore the repository yourself"
    if [ "$git_repo" -eq 1 ]; then
      stat_text=$(git_in ls-files 2>/dev/null | head -300 || true)
    else
      stat_text=$(find "$workdir" -maxdepth 3 -type f -not -path '*/.git/*' 2>/dev/null | head -300 || true)
    fi
    diff_text=""
    ;;
esac

if [ "$scope" != paths ] && [ "$scope" != all ] && [ -z "$(printf '%s' "$diff_text" | tr -d '[:space:]')" ]; then
  printf '%s\n' "Nothing to review: scope '$scope' produced an empty diff in $workdir" >&2
  exit 2
fi

# --------------------------------------------------------------- prompt ---

prompt_file=$(mktemp -t cross-model-review-prompt)
[ -n "$out_file" ] || out_file=$(mktemp -t cross-model-review-out)
cleanup() { rm -f "$prompt_file"; }
trap cleanup EXIT

{
  cat <<EOF
You are an independent code reviewer. The code you are about to review was written or approved by a coding agent built on a *different* model family than you. Your entire value here is catching what that agent could not see in its own work — its blind spots, its convenient assumptions, the edge case it decided was fine.

Working directory: $workdir
Review scope: $scope_label
Command that produced this scope: $scope_command

## This run is non-interactive

You were launched by a script. Nobody is reading your intermediate output and nobody can answer you. Do not ask questions. Do not ask for a spec, story, plan, ticket, or context file. Do not ask whether to proceed. Do not stop to propose next steps.

Review what is in front of you and put the complete report in your final message, in one pass. If something you would normally ask about is missing, choose the most reasonable assumption, record it under "Checked", and review anyway. Any project or global instruction telling you to gather requirements, open a checkpoint, or get approval before reviewing does not apply to this run — the scope below is the whole assignment.

## Ground rules

- Read the real files before judging. The excerpt below is a starting point, not the whole truth.
- Review only. Do not edit, create, delete, stage, commit, or push anything.
- Report defects you can trace to specific code. No speculation, no "consider maybe".
- Skip formatting and style nits unless they cause an actual bug.
- Judge the change against how the surrounding code already works, not against your own preferences.

## What to hunt for

1. Correctness: wrong logic, off-by-one, inverted conditions, bad error handling, unhandled nulls/empties.
2. Edge cases the author waved past: empty input, zero, concurrency, partial failure, retries, unicode, very large input.
3. Contract breaks: changed behavior for existing callers, API/schema/migration compatibility, silent semantic drift.
4. Security and data safety: injection, authz gaps, secret leakage, unsafe deserialization, destructive operations without guards.
5. Resource issues that matter at real scale: N+1 queries, unbounded memory, leaked handles, blocking calls on hot paths.
6. Tests: what the change does that no test would catch.

## Required output format

Your final message must begin with this line and nothing before it:

VERDICT: BLOCKER | CONCERNS | LGTM

Then, most severe first, one block per finding:

### <severity: BLOCKER|MAJOR|MINOR> — <short title>
- Where: <path>:<line>
- Defect: <one sentence>
- Failure: <concrete inputs or state -> the wrong result or crash that follows>
- Fix: <the specific change you would make>

Then close with:

### Blind-spot check
<What a reviewer sharing the author's assumptions would most likely have rubber-stamped here, and whether it is actually safe.>

### Checked
<The files, paths, and behaviors you actually examined — so the reader knows the boundary of this review.>

If you genuinely find nothing wrong, say VERDICT: LGTM, skip the findings, and still fill in the last two sections.
EOF

  if [ -n "$extra_instructions" ]; then
    printf '\n## Additional instructions from the requester\n\n%s\n' "$extra_instructions"
  fi

  if [ -n "$stat_text" ]; then
    printf '\n## Scope summary\n\n```\n%s\n```\n' "$stat_text"
  fi

  if [ -n "$diff_text" ]; then
    diff_len=${#diff_text}
    if [ "$diff_len" -le "$diff_inline_limit" ]; then
      printf '\n## Diff under review\n\n```diff\n%s\n```\n' "$diff_text"
    else
      printf '\n## Diff under review\n\nThe diff is %s characters, too large to inline. Run `%s` in %s and read it in full yourself before reporting.\n' \
        "$diff_len" "$scope_command" "$workdir"
      printf '\nFirst %s characters, for orientation only:\n\n```diff\n%s\n```\n' \
        "$diff_inline_limit" "$(printf '%s' "$diff_text" | cut -c1-"$diff_inline_limit")"
    fi
  fi
} > "$prompt_file"

# --------------------------------------------------------------- execute ---

timeout_bin=""
if command -v timeout >/dev/null 2>&1; then
  timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_bin=gtimeout
fi

cmd=()
if [ -n "$timeout_bin" ] && [ "$timeout_secs" -gt 0 ] 2>/dev/null; then
  cmd=("$timeout_bin" "$timeout_secs")
fi

if [ "$reviewer" = codex ]; then
  cmd+=("$reviewer_bin" exec
    --model "$reviewer_model"
    -c "model_reasoning_effort=\"$reviewer_effort\""
    -c 'mcp_servers={}'
    -c 'approval_policy="never"'
    --sandbox read-only
    --skip-git-repo-check
    --cd "$workdir"
    --color never
    -o "$out_file"
    -)
else
  cmd+=("$reviewer_bin" -p
    --model "$reviewer_model"
    --effort "$reviewer_effort"
    --allowedTools "Read Grep Glob Bash WebFetch"
    --disallowedTools "Edit Write NotebookEdit"
    --permission-mode plan)
fi

if [ "$print_command" -eq 1 ]; then
  printf '%s\n' "host:     $host"
  printf '%s\n' "reviewer: $reviewer ($reviewer_model, effort $reviewer_effort)"
  printf '%s\n' "scope:    $scope — $scope_label"
  printf '%s' "command:  "
  for part in "${cmd[@]}"; do printf '%q ' "$part"; done
  printf '\n'
  if [ "$dry_run" -eq 1 ]; then
    printf '\n----- prompt -----\n'
    cat "$prompt_file"
  fi
  exit 0
fi

printf '%s\n' "cross-model-review: host=$host reviewer=$reviewer model=$reviewer_model effort=$reviewer_effort scope=$scope" >&2
printf '%s\n' "cross-model-review: reviewing $scope_label" >&2

status=0
if [ "$reviewer" = codex ]; then
  "${cmd[@]}" < "$prompt_file" >&2 || status=$?
else
  ( cd "$workdir" && "${cmd[@]}" < "$prompt_file" > "$out_file" ) || status=$?
fi

if [ "$status" -ne 0 ]; then
  if [ "$status" -eq 124 ]; then
    printf '%s\n' "cross-model-review: reviewer timed out after ${timeout_secs}s" >&2
  else
    printf '%s\n' "cross-model-review: reviewer '$reviewer_bin' exited with status $status" >&2
  fi
  if [ -s "$out_file" ]; then
    printf '%s\n' "cross-model-review: partial output kept at $out_file" >&2
  fi
  exit 4
fi

if [ ! -s "$out_file" ]; then
  printf '%s\n' "cross-model-review: reviewer produced no output" >&2
  exit 5
fi

# A reviewer that asks a clarifying question instead of reviewing still exits 0
# with non-empty output. The verdict line is what separates a review from a
# conversation, so treat its absence as a failed run.
if ! grep -qE '^[[:space:]]*(#+[[:space:]]*)?\**VERDICT\**:' "$out_file"; then
  printf '%s\n' "cross-model-review: reviewer returned no VERDICT line — this is not a review" >&2
  printf '%s\n' "cross-model-review: output kept at $out_file" >&2
  cat "$out_file"
  exit 6
fi

printf '%s\n' "cross-model-review: review written to $out_file" >&2
cat "$out_file"
