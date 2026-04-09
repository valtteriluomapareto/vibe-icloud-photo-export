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

**CRITICAL — `[PROMPT]` cannot be combined with `--uncommitted` or `--commit`.** Despite `codex review --help` showing `[OPTIONS] [PROMPT]`, passing a prompt together with `--uncommitted` or `--commit` causes an error. Use these patterns:

| Target | Command |
|--------|---------|
| empty or `uncommitted` | `codex review --uncommitted` (no custom prompt possible) |
| looks like a commit SHA (hex, 7-40 chars) | `codex review --commit <sha>` (no custom prompt possible) |
| starts with `--base` | `codex review --base <branch>` (no custom prompt possible) |
| custom prompt only (no flags) | `codex review "<prompt>"` |

For multiple commit SHAs, run `codex review --commit <sha>` once per SHA.

Run the command from the project root.

If `codex` is not found, tell the user to install it (`npm install -g @openai/codex`).

## Waiting for codex to finish

Codex review is a long-running command. It reads many files, may run builds/tests, and often takes 2-5 minutes.

**How to run and wait:**

1. Run `codex review ...` via Bash. It will automatically run in background and return a task output file path.
2. **Wait with a generous initial sleep** before checking the output. Use `sleep 120` (2 minutes) as the minimum first wait, then read the output file to check if it's done.
3. To check if codex is done, look for the review summary at the end of the output file (lines starting with `Review comment:` or a summary paragraph). If the output is still growing or ends mid-file-content, codex is still working.
4. If not done after the first check, wait again with `sleep 60` increments and re-check, using a **timeout of at least 3-4 minutes** on each wait command.
5. You can also check if the codex process is still running: `ps aux | grep 'codex review' | grep -v grep`.
6. **Do NOT** try to read the full output file if it exceeds the token limit. Instead, read only the last 100-150 lines to find the review conclusion, then read earlier sections selectively if needed.

**Example wait pattern:**
```bash
# First wait — give codex time to read files and run builds
sleep 120 && tail -100 <output-file>
# If still running, wait more
sleep 90 && tail -100 <output-file>
```
