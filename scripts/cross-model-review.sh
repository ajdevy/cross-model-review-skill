#!/usr/bin/env bash
set -euo pipefail

# Run a code review with a model from a different family than the host agent.
#
#   host = Claude Code  -> reviewer = codex        (gpt-5.6-luna)
#   host = Codex/ChatGPT-> claude-vps -> claude
#   host = anything else-> no candidates; SKIPPED until --host says which
#                          family wrote the code
#
# There is no same-family last resort. When no opposite-family CLI is
# reachable the run is SKIPPED and reported as not reviewed.
#
# The review text is written to --out and echoed on stdout. Progress and
# routing metadata go to stderr and are appended to the output document.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
detector="$script_dir/detect-host-agent.sh"

codex_model=${CROSS_MODEL_REVIEW_CODEX_MODEL:-gpt-5.6-luna}
# "sonnet" is the CLI alias for the latest Sonnet, so this follows releases
# instead of pinning a version that goes stale.
claude_model=${CROSS_MODEL_REVIEW_CLAUDE_MODEL:-sonnet}
diff_inline_limit=${CROSS_MODEL_REVIEW_DIFF_LIMIT:-60000}

scope=auto
base=""
commit=""
workdir=$PWD
host_override=""
reviewer_override=""
out_file=""
timeout_secs=${CROSS_MODEL_REVIEW_TIMEOUT:-2400}
criticality=${CROSS_MODEL_REVIEW_CRITICALITY:-normal}
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
  --reviewer <codex|claude-vps|claude>
                          Override reviewer selection
  --criticality <normal|infrastructure|security|critical>
                          Select the review effort (default: normal)

Output options:
  --out <file>            Write the review here (default: temp file)
  --timeout <seconds>     Abort the reviewer after N seconds (default: 2400)
  --print-command         Print the reviewer command and exit
  --dry-run               Print the reviewer command and the full prompt, then exit
  -h, --help              This help

Environment overrides:
  CROSS_MODEL_REVIEW_HOST, CROSS_MODEL_REVIEW_CODEX_MODEL,
  CROSS_MODEL_REVIEW_CODEX_EFFORT, CROSS_MODEL_REVIEW_CLAUDE_MODEL,
  CROSS_MODEL_REVIEW_CLAUDE_EFFORT, CROSS_MODEL_REVIEW_CRITICALITY,
  CROSS_MODEL_REVIEW_DIFF_LIMIT, CROSS_MODEL_REVIEW_TIMEOUT

Exit codes: 0 review completed or deliberately skipped | 2 usage error
            3 review router unavailable | 4 reviewer failed or timed out
            5 reviewer returned nothing | 6 reviewer returned no VERDICT line
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
    --criticality) criticality=${2:-}; shift 2 ;;
    --out) out_file=${2:-}; shift 2 ;;
    --timeout) timeout_secs=${2:-}; shift 2 ;;
    --print-command) print_command=1; shift ;;
    --dry-run) dry_run=1; print_command=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; extra_instructions="$*"; break ;;
    *) printf '%s\n' "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$criticality" in
  normal) default_effort=high ;;
  infrastructure|security) default_effort=xhigh ;;
  critical) default_effort=max ;;
  *)
    printf '%s\n' "Invalid criticality: $criticality (expected normal, infrastructure, security, or critical)" >&2
    exit 2
    ;;
esac

codex_effort=${CROSS_MODEL_REVIEW_CODEX_EFFORT:-$default_effort}
# The Claude reviewer runs at max regardless of tier. It is only reached when
# the code was written by the Codex family - employee work - which is where
# review depth matters most, and Sonnet at max costs less than Opus did at
# the tiered level it replaces. The tiering still governs the Codex reviewer.
claude_effort=${CROSS_MODEL_REVIEW_CLAUDE_EFFORT:-max}
case "$codex_effort:$claude_effort" in
  high:high|high:xhigh|high:max|xhigh:high|xhigh:xhigh|xhigh:max|max:high|max:xhigh|max:max) ;;
  *)
    printf '%s\n' "Invalid review effort: codex=$codex_effort claude=$claude_effort (expected high, xhigh, or max)" >&2
    exit 2
    ;;
esac

if [ ! -d "$workdir" ]; then
  printf '%s\n' "Not a directory: $workdir" >&2
  exit 2
fi
workdir=$(cd "$workdir" && pwd -P)

# ---------------------------------------------------------------- routing ---

# Deployments that cannot write to a system bin directory keep their CLIs in an
# instance-local tools directory instead. This container is one: /usr/local and
# the home directory are both read-only, so codex lives under $JINN_HOME/tools/bin
# and would otherwise be invisible to the `command -v` probe below — the reviewer
# would look missing while sitting on disk, and the run would stop for the wrong
# reason. Appending rather than prepending keeps a system install winning.
for _extra_bin in "${JINN_HOME:-$HOME/.jinn}/tools/bin"; do
  if [ -d "$_extra_bin" ]; then
    case ":$PATH:" in
      *":$_extra_bin:"*) ;;
      *) PATH="$PATH:$_extra_bin"; export PATH ;;
    esac
  fi
done
unset _extra_bin

if [ -n "$host_override" ]; then
  host=$host_override
else
  host=$("$detector" 2>/dev/null || printf 'other\n')
fi

case "$host" in
  claude-code|codex|other) ;;
  *)
    printf '%s\n' "Invalid host: $host (expected claude-code, codex, or other)" >&2
    exit 2
    ;;
esac

# An explicit route remains an override, but it still gets the safe fallback
# chain for the opposite family. Same-family requests are refused: a review by
# the family that wrote the code shares its blind spots. A separate explicit
# operator decision would be required to change that policy; this skill does
# not provide a same-family fallback.
# A reviewer override cannot rescue an undetected host: with no author family
# known there is nothing to check the override against.
if [ "$host" = other ] && [ -n "$reviewer_override" ]; then
  printf '%s\n' \
    "Refusing --reviewer on an undetected host." \
    "Pass --host claude-code or --host codex so the reviewer can be checked against the author family." >&2
  exit 2
fi

  if [ -n "$reviewer_override" ]; then
  case "$reviewer_override" in
    codex|claude-vps|claude) ;;
    *)
      printf '%s\n' "Invalid reviewer: $reviewer_override (expected codex, claude-vps, or claude)" >&2
      exit 2
      ;;
  esac
  case "$host:$reviewer_override" in
    codex:codex|claude-code:claude-vps|claude-code:claude)
    printf '%s\n' \
      "Refusing a same-family review: host $host with reviewer $reviewer_override." \
      "A review by the family that wrote the code shares its blind spots and is not a cross-model review." >&2
    exit 2
    ;;
  esac
fi

candidate_routes=()
add_candidate() {
  candidate_routes[${#candidate_routes[@]}]=$1
}

if [ -n "$reviewer_override" ]; then
  case "$reviewer_override" in
    claude-vps)
      add_candidate claude-vps 0
      [ "$host" = claude-code ] || add_candidate claude 0
      ;;
    claude)
      add_candidate claude 0
      ;;
    codex)
      add_candidate codex 0
      ;;
  esac
else
  case "$host" in
    claude-code)
      add_candidate codex 0
      ;;
    codex)
      add_candidate claude-vps 0
      add_candidate claude 0
      ;;
    other)
      # Fail closed. An undetected host is most often a Claude one whose markers
      # went missing, so guessing the Claude cascade here is exactly the
      # same-family review this script exists to prevent. Pass --host to say
      # which family wrote the code.
      ;;
  esac
fi

capacity_pattern='rate[[:space:]_-]*limit|weekly[[:space:]_-]*(limit|quota)|overload|overloaded|too[[:space:]]+many[[:space:]]+requests|quota|capacity|resource[[:space:]]+exhausted|usage[[:space:]]+limit|limit[[:space:]]+reached|(^|[^0-9])529([^0-9]|$)'
contains_capacity_signal() {
  grep -Eiq "$capacity_pattern" "$@" 2>/dev/null
}

fallback_reasons=""
remember_fallback() {
  if [ -n "$fallback_reasons" ]; then
    fallback_reasons="$fallback_reasons; $1"
  else
    fallback_reasons=$1
  fi
}

candidate_reason=""
candidate_available() {
  local candidate=$1
  local candidate_output candidate_status timeout_probe
  candidate_reason=""

  case "$candidate" in
    codex)
      if command -v codex >/dev/null 2>&1; then
        return 0
      fi
      candidate_reason="codex not installed"
      return 1
      ;;
    claude-vps|claude)
      if ! command -v "$candidate" >/dev/null 2>&1; then
        candidate_reason="$candidate not installed"
        return 1
      fi
      candidate_output=$(mktemp -t cross-model-review-probe.XXXXXX)
      candidate_status=0
      if command -v timeout >/dev/null 2>&1; then
        timeout_probe=timeout
      elif command -v gtimeout >/dev/null 2>&1; then
        timeout_probe=gtimeout
      else
        timeout_probe=""
      fi
      if [ -n "$timeout_probe" ]; then
        "$timeout_probe" 10 "$candidate" --version >"$candidate_output" 2>&1 || candidate_status=$?
      else
        "$candidate" --version >"$candidate_output" 2>&1 || candidate_status=$?
      fi
      if [ "$candidate_status" -eq 0 ]; then
        rm -f "$candidate_output"
        return 0
      fi
      if contains_capacity_signal "$candidate_output"; then
        candidate_reason="$candidate capacity unavailable"
      elif [ "$candidate" = claude-vps ]; then
        candidate_reason="claude-vps proxy unavailable"
      else
        candidate_reason="plain claude unavailable"
      fi
      rm -f "$candidate_output"
      return 1
      ;;
    *)
      candidate_reason="unsupported route $candidate"
      return 1
      ;;
  esac
}

selected_index=-1
route=""
route_reason=""
selection_context=""
if [ -n "$reviewer_override" ]; then
  selection_context="CLI override --reviewer $reviewer_override"
elif [ "$host" = claude-code ]; then
  selection_context="host claude-code requires the Codex family"
elif [ "$host" = codex ]; then
  selection_context="host codex requires the Claude family"
else
  selection_context="host undetected - pass --host claude-code or --host codex to name the author family"
fi

select_candidate() {
  local start=$1 i candidate
  for ((i = start; i < ${#candidate_routes[@]}; i += 1)); do
    candidate=${candidate_routes[$i]}
    if candidate_available "$candidate"; then
      selected_index=$i
      reviewer=$candidate
      route=$candidate
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
          ;;
        claude)
          reviewer_bin=claude
          reviewer_model=$claude_model
          reviewer_effort=$claude_effort
          ;;
      esac
      if [ -n "$fallback_reasons" ]; then
        route_reason="$fallback_reasons; selected $route"
      else
        route_reason="$selection_context"
      fi
      return 0
    fi
    remember_fallback "$candidate_reason"
  done
  selected_index=-1
  reviewer=""
  route=SKIPPED
  route_reason="$fallback_reasons"
  # With no candidate ever tried there is nothing to report but the reason the
  # list was empty, and "no reviewer candidates" would send the reader off to
  # install a CLI that is already there.
  [ -n "$route_reason" ] || route_reason="$selection_context"
  [ -n "$route_reason" ] || route_reason="no reviewer candidates"
  return 1
}

emit_route() {
  printf 'ROUTE: %s\n' "$route" >&2
  printf 'FALLBACK_REASON: %s\n' "$route_reason" >&2
}

select_candidate 0 || true

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

# Mandatory local secret scan and redaction before any diff reaches an external
# reviewer. There is no repository allowlist: new secrets are protected by
# default too.
secret_scan_redact() {
  perl -0pe '
    s/(-----BEGIN (?:RSA|OPENSSH|EC|DSA) PRIVATE KEY-----).*?(-----END (?:RSA|OPENSSH|EC|DSA) PRIVATE KEY-----)/$1\n[REDACTED PRIVATE KEY]\n$2/sg;
    s/\b(?:AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9_-]{20,})\b/[REDACTED TOKEN]/g;
    s/((?i:(?:api[_-]?key|access[_-]?token|auth(?:orization)?|client[_-]?secret|password|passwd|secret|token))\s*[:=]\s*["'"'"']?)[^\s,"'"'"']{8,}/$1[REDACTED]/g;
  '
}

if [ -n "$diff_text" ]; then
  redacted_diff=$(printf '%s' "$diff_text" | secret_scan_redact)
  if [ "$redacted_diff" != "$diff_text" ]; then
    printf '%s\n' 'cross-model-review: local secret scan redacted credential-like values from the diff' >&2
    diff_text=$redacted_diff
  fi
fi

if [ -n "$out_file" ]; then
  rm -f "${out_file}.router-status"
fi

if [ "$route" = SKIPPED ]; then
  emit_route
  if [ "$print_command" -eq 1 ]; then
    printf '%s\n' "host:     $host"
    printf '%s\n' "route:    SKIPPED"
    printf '%s\n' "fallback: $route_reason"
    printf '%s\n' "scope:    $scope — $scope_label"
    printf '%s\n' "command:  no reviewer available; review skipped"
    exit 0
  fi
  [ -n "$out_file" ] || out_file=$(mktemp -t cross-model-review-out.XXXXXX)
  printf '%s\n' SKIPPED > "${out_file}.router-status"
  {
    printf 'VERDICT: SKIPPED\n'
    printf 'ROUTE: SKIPPED\n'
    printf 'FALLBACK_REASON: %s\n' "$route_reason"
    printf '%s\n' 'The review was deliberately skipped because no reviewer was available.'
  } > "$out_file"
  cat "$out_file"
  exit 0
fi

# --------------------------------------------------------------- prompt ---

# GNU mktemp requires the template to end in at least three X's; BSD mktemp -t
# accepts a bare prefix and appends its own suffix. Writing the X's explicitly
# satisfies both, so the script no longer dies on Linux before it reviews
# anything ("mktemp: too few X's in template").
prompt_file=$(mktemp -t cross-model-review-prompt.XXXXXX)
[ -n "$out_file" ] || out_file=$(mktemp -t cross-model-review-out.XXXXXX)
cleanup() { rm -f "$prompt_file"; }
trap cleanup EXIT

review_independence_note='The code you are about to review was written or approved by a *different* model family than you. Your entire value here is catching what that agent could not see in its own work — its blind spots, its convenient assumptions, the edge case it decided was fine.'

{
  cat <<EOF
You are an independent code reviewer. $review_independence_note

Working directory: $workdir
Review scope: $scope_label
Command that produced this scope: $scope_command
Declared criticality: $criticality
Selected reviewer: $reviewer_model ($reviewer_effort)

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

Then, most severe first, one block per finding. Use BLOCKER for a defect that
makes merge or release unsafe (for example secret exposure, auth bypass,
irreversible data loss, or a broken rollback path). Use CRITICAL for a
material correctness, security, or availability defect that must be fixed
before the review can be considered clean. Use MAJOR and MINOR for lower
severity findings.

### BLOCKER - short title
### CRITICAL - short title
### MAJOR - short title
### MINOR - short title
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

build_command() {
  local output_file=$1
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
      -o "$output_file"
      -)
  else
    cmd+=("$reviewer_bin" -p
      --model "$reviewer_model"
      --effort "$reviewer_effort"
      --allowedTools "Read Grep Glob Bash WebFetch"
      --disallowedTools "Edit Write NotebookEdit"
      --permission-mode plan)
  fi
}

build_command "$out_file"

if [ "$print_command" -eq 1 ]; then
  printf '%s\n' "host:     $host"
  printf '%s\n' "reviewer: $reviewer ($reviewer_model, effort $reviewer_effort)"
  printf '%s\n' "route:    $route"
  printf '%s\n' "fallback: $route_reason"
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
printf '%s\n' "cross-model-review: criticality=$criticality" >&2
printf '%s\n' "cross-model-review: reviewing $scope_label" >&2

contains_capacity_signal_files() {
  grep -Eiq "$capacity_pattern" "$@" 2>/dev/null
}

attempt_out=""
attempt_log=""
attempt_status=0
run_attempt() {
  attempt_out=$(mktemp -t cross-model-review-attempt.XXXXXX)
  attempt_log=$(mktemp -t cross-model-review-attempt-log.XXXXXX)
  attempt_status=0
  build_command "$attempt_out"
  if [ "$reviewer" = codex ]; then
    "${cmd[@]}" < "$prompt_file" > "$attempt_log" 2>&1 || attempt_status=$?
  else
    ( cd "$workdir" && "${cmd[@]}" < "$prompt_file" > "$attempt_out" 2> "$attempt_log" ) || attempt_status=$?
  fi
}

attempt_can_fallback() {
  case "$reviewer" in
    claude-vps)
      if [ "$attempt_status" -ne 0 ]; then
        attempt_reason="claude-vps route failed (status $attempt_status)"
        return 0
      fi
      if [ "$attempt_status" -ne 0 ] && contains_capacity_signal_files "$attempt_out" "$attempt_log"; then
        attempt_reason="claude-vps rate-limit/weekly-limit/overload"
        return 0
      fi
      ;;
    claude)
      if [ "$attempt_status" -ne 0 ]; then
        if contains_capacity_signal_files "$attempt_out" "$attempt_log"; then
          attempt_reason="plain claude rate-limit/weekly-limit/overload"
        else
          attempt_reason="plain claude route failed (status $attempt_status)"
        fi
        return 0
      fi
      ;;
    codex)
      if [ "$attempt_status" -ne 0 ] && contains_capacity_signal_files "$attempt_out" "$attempt_log"; then
        attempt_reason="codex rate-limit/weekly-limit/overload"
        return 0
      fi
      ;;
  esac
  return 1
}

write_skipped_output() {
  emit_route
  [ -n "$out_file" ] || out_file=$(mktemp -t cross-model-review-out.XXXXXX)
  printf '%s\n' SKIPPED > "${out_file}.router-status"
  {
    printf 'VERDICT: SKIPPED\n'
    printf 'ROUTE: SKIPPED\n'
    printf 'FALLBACK_REASON: %s\n' "$route_reason"
    printf '%s\n' 'The review was deliberately skipped because no reviewer was available.'
  } > "$out_file"
  cat "$out_file"
}

while :; do
  emit_route
  run_attempt
  if attempt_can_fallback; then
    remember_fallback "$attempt_reason"
    rm -f "$attempt_out" "$attempt_log"
    if select_candidate "$((selected_index + 1))"; then
      printf '%s\n' "cross-model-review: $attempt_reason; trying fallback route $route" >&2
      continue
    fi
    printf '%s\n' "cross-model-review: $attempt_reason; no reviewer remains, review skipped" >&2
    write_skipped_output
    exit 0
  fi
  break
done

if [ "$attempt_status" -ne 0 ]; then
  if [ "$attempt_status" -eq 124 ]; then
    printf '%s\n' "cross-model-review: reviewer timed out after ${timeout_secs}s" >&2
  else
    printf '%s\n' "cross-model-review: reviewer '$reviewer_bin' exited with status $attempt_status" >&2
  fi
  if [ -s "$attempt_out" ]; then
    cp "$attempt_out" "$out_file"
    printf '%s\n' "cross-model-review: partial output kept at $out_file" >&2
  fi
  rm -f "$attempt_out" "$attempt_log"
  exit 4
fi

if [ ! -s "$attempt_out" ]; then
  rm -f "$attempt_out" "$attempt_log"
  printf '%s\n' "cross-model-review: reviewer produced no output" >&2
  exit 5
fi

cp "$attempt_out" "$out_file"
rm -f "$attempt_out" "$attempt_log"

{
  printf '\nROUTE: %s\n' "$route"
  printf 'FALLBACK_REASON: %s\n' "$route_reason"
} >> "$out_file"

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
