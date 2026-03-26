# Documentation Guide

This repository keeps public-facing docs and maintainer-facing notes in separate places so the root stays easy to scan.

## Public Documentation

- [`README.md`](../README.md): project overview, build, test, and top-level usage
- [`website/src/content/docs/`](../website/src/content/docs/): user-facing documentation published to the project website
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contributor workflow and expectations

## Maintainer Notes

- [`docs/project/implementation-tasks.md`](project/implementation-tasks.md): current open work
- [`docs/project/implemented-features.md`](project/implemented-features.md): shipped capabilities snapshot
- [`docs/project/future-enhancements.md`](project/future-enhancements.md): longer-term ideas
- [`docs/project/public-deployment-plan.md`](project/public-deployment-plan.md): distribution and notarization planning
- [`docs/project/github-actions-publishing-plan.md`](project/github-actions-publishing-plan.md): CI/release workflow planning
- [`docs/project/import-existing-backup-plan.md`](project/import-existing-backup-plan.md): backup import design notes
- [`docs/project/refactoring-plan.md`](project/refactoring-plan.md): targeted cleanup history and rationale
- [`docs/project/ui-overhaul-plan.md`](project/ui-overhaul-plan.md): UI overhaul implementation notes

## Reference Material

- [`docs/reference/swift-swiftui-best-practices.md`](reference/swift-swiftui-best-practices.md): architecture and implementation guidance
- [`photo-export/Resources/PERSISTENCE_STORE.md`](../photo-export/Resources/PERSISTENCE_STORE.md): export record persistence format and behavior
- [`CLAUDE.md`](../CLAUDE.md): repository guidance for Claude Code

## Maintenance Rules

- Prefer descriptive file names over generic names like `plan.md`.
- Keep user-facing instructions in one of the public documentation locations above.
- Move obsolete planning material into `docs/project/` instead of leaving it in the repo root.
- Update docs in the same change that alters behavior, setup, or contributor workflow.
