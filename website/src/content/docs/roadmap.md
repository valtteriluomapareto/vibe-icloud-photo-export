---
title: Roadmap
description: Planned improvements and future features for Photo Export.
---

Photo Export is intentionally narrow today. The roadmap focuses on changes that improve reliability, scalability, and day-to-day usability without turning the app into a much larger product.

## Near-term priorities

- **Retry failed exports** so users do not need to restart larger export runs for a handful of bad files
- **Media filtering in the UI** for photos, videos, or both
- **Manual refresh and change observation** so the library view stays current
- **Accessibility and polish** across the onboarding flow, sidebar, and export controls

## Reliability and performance

- **Bounded concurrent export queue** to increase throughput without overwhelming disk or memory
- **Preflight destination checks** for permissions, mount status, and available space
- **Stronger crash-resume semantics** for long-running export sessions
- **Persistent month-level caching** for larger libraries

## Photos and media support

- **Live Photos support** with coherent image and video pairing
- **iCloud originals handling** with clear download-or-skip behavior
- **Improved metadata export options** including sidecars and privacy controls

## Longer-term exploration

- **Flexible naming schemes** beyond the current year/month structure
- **SQLite-backed export records** if JSONL storage becomes a bottleneck
- **Multiple destinations** with per-destination state
- **Localization** beyond the current English-first experience
