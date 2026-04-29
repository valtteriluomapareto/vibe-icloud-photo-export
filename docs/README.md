# Documentation Guide

This repository keeps public-facing docs and maintainer-facing notes in separate places so the root stays easy to scan.

## Public Documentation

- [`README.md`](../README.md): project overview, build, test, and top-level usage
- [`website/src/content/docs/`](../website/src/content/docs/): user-facing documentation published to the project website
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contributor workflow and expectations

## Maintainer Notes

Active notes (current process and open work):

- [`docs/project/implementation-tasks.md`](project/implementation-tasks.md): open work items
- [`docs/project/release-process.md`](project/release-process.md): how to cut a release (version bump, tag, publish)
- [`docs/project/import-existing-backup-plan.md`](project/import-existing-backup-plan.md): backup import design notes (Phase 1 implemented)
- [`docs/project/testing-improvement-plan.md`](project/testing-improvement-plan.md): test coverage gaps and improvement plan
- [`docs/project/plans/auto-sync-background-sync-plan.md`](project/plans/auto-sync-background-sync-plan.md): proposed auto-sync and background-sync implementation plan

Archived planning material (completed or superseded — kept as decision records):

- [`docs/project/archive/app-store-plan.md`](project/archive/app-store-plan.md): pre-launch Mac App Store plan (launched April 2026)
- [`docs/project/archive/app-store-ci-plan.md`](project/archive/app-store-ci-plan.md): App Store CI workflow plan
- [`docs/project/archive/github-actions-publishing-plan.md`](project/archive/github-actions-publishing-plan.md): direct-distribution release workflow plan
- [`docs/project/archive/refactoring-plan.md`](project/archive/refactoring-plan.md): refactoring decisions (Phases 1–4 complete)

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
