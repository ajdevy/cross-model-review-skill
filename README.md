# cross-model-review

A [Claude Code](https://claude.com/claude-code) / [Codex](https://openai.com/codex/) skill that gets your code reviewed by a model from a *different* family than the one that wrote it, so the reviewer doesn't share the author's blind spots.

Routing is automatic: a Claude Code host calls Codex (`gpt-5.6-luna`, reasoning `max`), a Codex/ChatGPT host calls `claude-vps` (`sonnet`, effort `max`). The full behavior, options, and workflow are documented in [`SKILL.md`](./SKILL.md) — that file is the skill definition itself, written to be read by an agent.

## Install

Skills are picked up from a directory your agent scans. Clone this repo where that agent expects skills, or symlink it in:

```bash
git clone https://github.com/ajdevy/cross-model-review-skill.git
ln -s "$PWD/cross-model-review-skill" ~/.claude/skills/cross-model-review
```

Adjust the symlink target for your agent (Codex, OpenCode, Cursor, etc. each have their own skills directory). The directory name at the symlink destination — `cross-model-review` — is what agents match against the skill's trigger phrases, so keep it as `cross-model-review` regardless of what this repo/clone is named.

## Requirements

- [`codex`](https://github.com/openai/codex) CLI on `PATH`, logged in — used when the host agent is Claude Code.
- A Claude CLI on `PATH` (`claude-vps` or `claude`) — used when the host agent is Codex/ChatGPT or anything else.

See [`SKILL.md`](./SKILL.md) for scope options, exit codes, and environment overrides.

## License

MIT — see [LICENSE](./LICENSE).
