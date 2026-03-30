---
name: codex-review
description: Use Codex CLI to review code changes — uncommitted work, a specific commit, or a range against a base branch. Optionally accepts a focus area for targeted review.
user-invocable: true
disable-model-invocation: false
argument-hint: "[uncommitted | <commit-sha> | --base <branch>] [--focus <area>]"
---

Run `codex review` to get an AI code review of the requested changes.

## Determine what to review

- **No arguments** (`/review`): review uncommitted changes (staged + unstaged + untracked).
- **A commit SHA** (`/review abc1234`): review that specific commit.
- **Multiple commit SHAs** (`/review abc1234 def5678`): review each commit separately.
- **`--base <branch>`** (`/review --base main`): review all changes against the given base branch.
- **`uncommitted`** (`/review uncommitted`): explicitly review uncommitted changes.
- **`--focus <area>`** (`/review --focus "error handling"`): adds a focus area the reviewer should pay special attention to. Can be combined with any of the above.

Raw arguments: $ARGUMENTS

## Parsing arguments

1. Extract the optional `--focus` value: everything after `--focus` up to the next `--` flag or end of string. Remove it from the remaining arguments.
2. The remaining arguments determine the review target (empty, SHA, `--base`, or `uncommitted`) as described above.

## Review instructions

Build a custom prompt string with the following content:

```
In addition to correctness and security, always evaluate:
- **Maintainability & readability**: Is the code easy to understand and modify? Are names clear? Is complexity justified?
- **Documentation & website consistency**: Check if the changes affect user-visible behavior, CLI flags, architecture, or features. If so, flag whether docs (README.md, CLAUDE.md, website/src/content/docs/) need updating to stay in sync.
```

If a `--focus` area was provided, also append:

```
Pay special attention to: <focus area>
```

## Execution

Build and run the appropriate `codex review` command.

**Important:** `codex review` does NOT have an `--instructions` flag. Custom review instructions must be passed as the `[PROMPT]` positional argument. However, `[PROMPT]` cannot be combined with `--commit`. Use these patterns:

| Target | Command |
|--------|---------|
| empty or `uncommitted` | `codex review --uncommitted "<prompt>"` |
| looks like a commit SHA (hex, 7-40 chars) | `codex review --commit <sha>` (no custom prompt — codex uses its default review prompt) |
| starts with `--base` | `codex review --base <branch> "<prompt>"` |

For `--commit` reviews where you want custom instructions, there is no way to pass them. Just run `codex review --commit <sha>` and rely on the default review behavior.

For multiple commit SHAs, run `codex review --commit <sha>` once per SHA.

Run the command from the project root. Stream the output directly to the user — do not summarise or filter it.

If `codex` is not found, tell the user to install it (`npm install -g @openai/codex`).
