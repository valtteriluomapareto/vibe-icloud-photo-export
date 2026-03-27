# Documentation Guide

This repository keeps public-facing docs and maintainer-facing notes in separate places so the root stays easy to scan.

## Public Documentation

- [`README.md`](../README.md): project overview, build, test, and top-level usage
- [`website/src/content/docs/`](../website/src/content/docs/): user-facing documentation published to the project website
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contributor workflow and expectations

## Maintainer Notes

- [`docs/project/implementation-tasks.md`](project/implementation-tasks.md): open work items
- [`docs/project/release-process.md`](project/release-process.md): how to cut a release (version bump, tag, publish)
- [`docs/project/github-actions-publishing-plan.md`](project/github-actions-publishing-plan.md): CI/release workflow planning
- [`docs/project/import-existing-backup-plan.md`](project/import-existing-backup-plan.md): backup import design notes
- [`docs/project/refactoring-plan.md`](project/refactoring-plan.md): refactoring decisions and remaining test infrastructure work
- [`docs/project/testing-improvement-plan.md`](project/testing-improvement-plan.md): test coverage gaps and step-by-step improvement plan

## Reference Material

- [`docs/reference/swift-swiftui-best-practices.md`](reference/swift-swiftui-best-practices.md): architecture and implementation guidance
- [`docs/reference/persistence-store.md`](reference/persistence-store.md): export record persistence format and behavior
- [`docs/reference/competitors.md`](reference/competitors.md): competitor app research for comparison page
- [`CLAUDE.md`](../CLAUDE.md): repository guidance for Claude Code

## Maintenance Rules

- Prefer descriptive file names over generic names like `plan.md`.
- Keep user-facing instructions in one of the public documentation locations above.
- Move obsolete planning material into `docs/project/` instead of leaving it in the repo root.
- Update docs in the same change that alters behavior, setup, or contributor workflow.
- Future enhancements and roadmap live on the [project website](../website/src/content/docs/roadmap.md) — do not duplicate here.
