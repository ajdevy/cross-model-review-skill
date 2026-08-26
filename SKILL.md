---
name: cross-model-review
description: 'Get code reviewed by a model from a different family than the current agent, so the reviewer does not share the author''s blind spots. Routes automatically: Claude Code hosts call Codex (gpt-5.6-terra, reasoning max), Codex/ChatGPT hosts call claude-vps (claude-opus-5, effort max), anything else calls claude-vps. Triggers on: "cross model review", "second opinion", "review with another model", "ревью другой моделью", "проверь другой моделью".'
---

# Cross-Model Review

**Goal:** Have the current change reviewed by a model that did not write it and does not share the author's assumptions.

**Your role:** Determine the scope, run the reviewer CLI through the bundled script, then triage what comes back. You own the final judgement — the other model is a second opinion, not an authority.

## Routing

The script detects the host agent and picks the opposite family. Never invoke the same family that produced the code.

| Host agent | Reviewer CLI | Model | Thinking |
| --- | --- | --- | --- |
| Claude Code | `codex exec` | `gpt-5.6-terra` | `model_reasoning_effort=max` |
| Codex / ChatGPT | `claude-vps -p` | `claude-opus-5` | `--effort max` |
| Anything else | `claude-vps -p` | `claude-opus-5` | `--effort max` |

Detection order: `CROSS_MODEL_REVIEW_HOST` override → process ancestry (`codex`, `ChatGPT`, `claude`) → `CODEX_*` / `CLAUDECODE` / `AI_AGENT` env markers → `other`.

## Usage

Everything runs through one script. Bare paths resolve from the skill root.

```bash
./scripts/cross-model-review.sh [options] [-- extra review instructions]
```

Scope selection (`--scope`, default `auto`):

| Scope | Reviews |
| --- | --- |
| `auto` | uncommitted changes if the worktree is dirty, otherwise the branch vs its base |
| `uncommitted` | staged + unstaged + untracked |
| `staged` | `git diff --cached` |
| `branch` | `git diff <merge-base>...HEAD`, base auto-detected or `--base <branch>` |
| `commit` | one commit, `--commit <sha>` |
| `paths` | whole files/directories, `--path <p>` (repeatable) |
| `all` | the whole project |

Other options: `--cwd <dir>`, `--out <file>`, `--timeout <seconds>` (default 2400), `--host` / `--reviewer` to override routing, `--print-command` to show the command without running it, `--dry-run` to also print the prompt.

Exit codes: `0` ok, `2` usage/empty scope, `3` reviewer CLI missing, `4` reviewer failed or timed out, `5` reviewer returned nothing, `6` reviewer replied without a `VERDICT:` line.

Exit `6` almost always means the reviewer asked a clarifying question instead of reviewing — its own global instructions pulled it toward gathering requirements first. The prompt already tells it the run is non-interactive; if it happens anyway, re-run once with the missing context supplied after `--`. Do not present a question as if it were a review.

## Workflow

### 1. Fix the scope before spending a review

Confirm the working directory and what is actually under review. `--scope auto` is right most of the time; be explicit when the user named a branch, commit, or set of files. If the diff is empty the script exits `2` — do not re-run it with a wider scope to manufacture something to review; tell the user there is nothing there.

Preview the routing first when the environment is unfamiliar:

```bash
./scripts/cross-model-review.sh --print-command
```

### 2. Run the review

```bash
./scripts/cross-model-review.sh --out /tmp/cross-model-review.md -- "Focus on the retry path; this replaces a hand-rolled backoff."
```

Pass anything the reviewer cannot infer from the diff after `--`: the intent of the change, known constraints, what the user is worried about. A max-reasoning review takes minutes — run it in the background and keep working if there is independent work left, and never poll it in a tight loop.

The review lands on stdout and in `--out`. Routing metadata goes to stderr.

### 3. Triage the findings — do not just forward them

The reviewer has not seen your conversation and may be wrong. For each finding, decide one of:

- **Confirmed** — you traced it to the code and the failure scenario holds. Fix it or list it as required work.
- **Rejected** — you checked and it is wrong, already handled elsewhere, or out of scope. Say why in one line.
- **Unresolved** — you cannot settle it without information you do not have. Name what would settle it.

Verify before accepting. A finding that names a file and line you can open is checkable in seconds; a finding that does not is usually a hallucination. Never apply a suggested fix you have not confirmed against the real code.

### 4. Report

Give the user, in this order:

1. Which model reviewed, at which effort, over which scope.
2. The reviewer's verdict line.
3. Confirmed findings, most severe first, each with your own one-line assessment.
4. Rejected findings, compressed to one line each with the reason.
5. What you changed, if anything.

Report the reviewer's verdict as its opinion, not as fact. If you disagree with a BLOCKER, say so and explain — the user needs your read, not a relay.

## Hard rules

- The reviewer is read-only. The Codex route runs `--sandbox read-only`; the Claude route runs `--permission-mode plan` with `Edit`/`Write`/`NotebookEdit` disallowed. Do not weaken either to let the reviewer "just fix it."
- Never route a review to the same model family that wrote the code. That defeats the whole skill. If the opposite CLI is unavailable, say so and stop rather than falling back to a same-family review.
- Do not apply fixes during the review run. Review first, triage, then change code as a separate step the user can see.
- Do not paste the raw reviewer output as your answer. Triage is the deliverable.
- Secrets stay out of the prompt. The script sends a diff — if the diff contains credentials, that is a finding to raise, not something to ship to another provider silently.

## See also

For review → fix → re-review until the verdict is clean, pair this with a **`cross-model-review-loop`** skill that drives this one across rounds and tracks convergence (not included in this repository).

## Requirements

- Codex route: `codex` on PATH, logged in.
- Claude route: `claude-vps` on PATH with its proxy tunnel up. If `claude-vps` is absent the script falls back to `claude` and says so on stderr; if the tunnel is down it fails loudly instead of bypassing the proxy.
- Model and effort defaults are overridable: `CROSS_MODEL_REVIEW_CODEX_MODEL`, `CROSS_MODEL_REVIEW_CODEX_EFFORT`, `CROSS_MODEL_REVIEW_CLAUDE_MODEL`, `CROSS_MODEL_REVIEW_CLAUDE_EFFORT`, `CROSS_MODEL_REVIEW_DIFF_LIMIT`, `CROSS_MODEL_REVIEW_TIMEOUT`.
