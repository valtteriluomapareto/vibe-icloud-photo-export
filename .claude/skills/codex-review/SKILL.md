---
name: codex-review
description: Ask OpenAI Codex CLI to review uncommitted changes
disable-model-invocation: true
argument-hint: [optional focus area]
allowed-tools: Bash, Read
---

Run OpenAI Codex CLI as a reviewing agent on the current uncommitted changes.

## Steps

1. First check there are uncommitted changes:
   ```
   git diff --stat HEAD
   git status -u
   ```
   If there are no changes, tell the user and stop.

2. Run the Codex review:
   ```
   codex review --uncommitted
   ```
   Wait for it to complete (this may take a few minutes). Use a timeout of 300000ms.

3. Read the full review output carefully.

4. Present the findings to the user organized by severity (P0/P1/P2/P3).

5. If the user provided a focus area via `$ARGUMENTS`, highlight findings related to that area first.

6. After presenting findings, ask the user if they want you to fix any of the issues found.
