---
name: cross-model-review
description: 'Get code reviewed by a model from the opposite family, with explicit routing, criticality-to-effort mapping, and no same-family fallback. Triggers on: "cross model review", "second opinion", "review with another model", "ревью другой моделью", "проверь другой моделью".'
---

# Cross-Model Review

**Goal:** Have the current change reviewed by a model that did not write it and does not share the author's assumptions.

**Your role:** Determine the scope, run the reviewer CLI through the bundled script, then triage what comes back. The other model is a second opinion; the host agent owns the final judgement.

## Routing

The script detects the author family and selects only the opposite family:

| Host family | Route order | Model | Effort |
| --- | --- | --- | --- |
| Claude Code | `codex exec` | `gpt-5.6-luna` | criticality mapping below |
| Codex / ChatGPT | `claude-vps -p`, then plain `claude -p` | `sonnet` | criticality mapping below |
| Unknown | `SKIPPED` until `--host` is supplied | none | none |

`claude-vps` may fall back to plain `claude` when the tunnel, proxy, quota, or capacity is unavailable. A Codex host never falls back to Codex, and a Claude Code host never falls back to Claude. Same-family fallback is forbidden unless the operator makes a separate explicit decision; this skill has no implicit same-family fallback.

Detection order is `CROSS_MODEL_REVIEW_HOST` override, process ancestry (`codex`, `ChatGPT`, `claude`), then `CODEX_*` / `CLAUDECODE` / `AI_AGENT` markers. An unresolved host fails closed. `--reviewer` is accepted only when it names a route from the opposite family.

## Criticality and effort

The default is `normal`. Select `--criticality infrastructure` for infrastructure changes and `--criticality security` for security-sensitive work. Use `--criticality critical` only when the operator has classified the PR as critical.

| Criticality | Codex `model_reasoning_effort` | Claude `--effort` | Intended use |
| --- | --- | --- | --- |
| `normal` | `high` | `high` | ordinary review |
| `infrastructure` | `xhigh` | `xhigh` | deployment, host, proxy, CI, backup, or infrastructure behavior |
| `security` | `xhigh` | `xhigh` | secrets, auth, isolation, public exposure, or security controls |
| `critical` | `max` | `max` | operator-declared critical PR only |

`CROSS_MODEL_REVIEW_CODEX_EFFORT` and `CROSS_MODEL_REVIEW_CLAUDE_EFFORT` may override the mapped value for an explicit operational reason. The selected model and effort are printed in routing metadata. The default timeout is 2400 seconds.

## Secret boundary

Before any diff is placed in an external reviewer prompt, the script runs a
local credential scan and redacts detected private keys, provider tokens, and
credential-like assignment values. This applies to every repository without an
allowlist; raw credential-like values must not cross the local process boundary.

## Usage

Everything runs through one script. Bare paths resolve from the skill root.

```bash
./scripts/cross-model-review.sh [options] [-- extra review instructions]
```

Scope selection (`--scope`, default `auto`):

| Scope | Reviews |
| --- | --- |
| `auto` | uncommitted changes if dirty, otherwise the branch against its base |
| `uncommitted` | staged, unstaged, and untracked changes |
| `staged` | `git diff --cached` |
| `branch` | `git diff <merge-base>...HEAD` |
| `commit` | one commit, selected by `--commit <sha>` |
| `paths` | whole files or directories selected by repeated `--path` |
| `all` | the whole project |

Important options: `--cwd`, `--host`, `--reviewer`, `--criticality`, `--out`, `--timeout`, `--print-command`, and `--dry-run`.

Exit codes: `0` completed or deliberately skipped, `2` usage/empty scope, `3` no opposite-family route, `4` reviewer failure or timeout, `5` empty output, `6` missing `VERDICT:` line. A skipped run writes `VERDICT: SKIPPED` and must not be presented as a review.

## Reviewer contract

The reviewer is read-only. The Codex route uses `--sandbox read-only`; the Claude route uses `--permission-mode plan` and disallows edit tools. Do not weaken this boundary and do not ask the reviewer to fix the change.

The prompt requires this format:

```text
VERDICT: BLOCKER | CONCERNS | LGTM

### BLOCKER | CRITICAL | MAJOR | MINOR - short title
- Where: path:line
- Defect: one sentence
- Failure: concrete state and result
- Fix: specific change

### Blind-spot check
...

### Checked
...
```

Use `BLOCKER` when merge or release is unsafe, such as secret exposure, auth bypass, irreversible data loss, or a broken rollback path. Use `CRITICAL` for a material correctness, security, or availability defect that must be fixed before the review is clean. `MAJOR` and `MINOR` are lower-severity findings.

## Workflow and triage

1. Confirm the working directory and exact scope before spending a review.
2. Preview routing with `--print-command` when the environment is unfamiliar.
3. Run the reviewer and read the complete report.
4. Classify every finding as confirmed, rejected, or unresolved. Verify a finding against the real files before changing anything.
5. Fix confirmed findings separately, run project checks, then use `cross-model-review-loop` for re-review.

Never paste raw reviewer output as the final report. Report route, model, effort, scope, verdict, and your triage. Keep secrets out of the prompt; a credential in the diff is a security finding, not input to ship to another provider.

## Requirements

- Codex route: `codex` on PATH and authenticated.
- Claude route: `claude-vps` is probed first; plain `claude` is the opposite-family fallback when available.
- No same-family fallback. If the opposite family is unavailable, skip and report it.
- Model defaults are `gpt-5.6-luna` and `sonnet`; model names and effort values are overridable through the documented environment variables.
