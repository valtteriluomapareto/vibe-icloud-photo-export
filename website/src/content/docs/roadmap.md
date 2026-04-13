---
title: Ideas
description: Ideas for future features and improvements.
---

Photo Export is intentionally focused. Below are ideas we're considering that would improve reliability, usability, and media support without turning the app into something larger than it needs to be. None of these are committed to a timeline.

## Usability

- **Retry failed exports** — re-attempt individual failures without restarting the entire batch
- **Media filtering** — filter the library view by photos, videos, or both
- **Manual refresh and change observation** — keep the library view current when new photos arrive
- **Search and filter** — find assets by name or date within the browser
- **Accessibility and polish** — improve VoiceOver support and refine the onboarding flow

## Reliability and performance

- **Concurrent export queue** — export multiple assets in parallel for faster throughput
- **Preflight destination checks** — verify permissions, mount status, and available space before starting
- **Stronger crash-resume** — more resilient recovery for long-running export sessions
- **Persistent month-level caching** — speed up sidebar loading for larger libraries

## Media support

- **Live Photos** — export paired image and video components together
- **iCloud originals** — detect remote-only assets and let users choose to download or skip
- **Metadata sidecars** — optionally export metadata alongside media files

## Bigger ideas

- **Flexible naming schemes** — configurable folder structures beyond year/month
- **SQLite-backed records** — replace JSONL storage if it becomes a bottleneck at scale
- **Multiple destinations** — export to more than one location with independent tracking
- **Localization** — support languages beyond English

Have an idea? [Open an issue on GitHub.](https://github.com/valtteriluomapareto/photo-export/issues)
