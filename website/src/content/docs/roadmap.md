---
title: Roadmap
description: Planned improvements and future features for Photo Export.
---

Photo Export is a functional MVP. Here are the planned improvements, roughly grouped by area.

## Export pipeline & performance

- **Bounded concurrent export queue** — Async semaphore-backed task queue to export multiple assets in parallel with a configurable limit
- **Atomic write verification** — Verify file size/date after atomic move to catch partial or corrupt files
- **Crash-resume semantics** — Granular in-progress states ("copying", "verifying", "done") for precise resume after crashes
- **Preflight destination checks** — Verify available space, permissions, and mount status before starting

## Data & persistence

- **SQLite migration** — Switch ExportRecordStore from JSONL to SQLite for large libraries (10k–100k+ assets)
- **Background compaction** — Scheduled compaction and store integrity verification
- **Persistent month cache** — Cache per-month asset totals across sessions for faster sidebar loading

## Photos integration & media

- **Live Photos** — Export image+video pairs together coherently
- **iCloud originals** — Download originals with progress or skip remote-only assets when offline
- **Library change observation** — Live-update month lists when the Photos library changes during app use

## File system & naming

- **Flexible naming scheme** — User-configurable naming (e.g., `YYYYMMDD_HHMMSS_originalName.ext`) with collision-safe suffixing
- **Folder manifests** — Optional JSON/CSV manifest per month folder for auditing
- **Path validation** — Hardened handling of long or invalid file names

## Metadata & privacy

- **Metadata sidecars** — Optional per-asset JSON or XMP sidecar with EXIF/IPTC/location data
- **Location privacy controls** — Option to strip or retain GPS data in exported images

## UI/UX

- **Filter and search** — Filter by photos/videos/favorites/edited, search by date range or filename
- **Preferences window** — Centralized settings for destination, parallelism, naming, metadata, and privacy
- **Accessibility** — Improved VoiceOver labels, focus order, and dynamic type support

## Quality & testing

- **Integration tests** — Full export simulations with temporary directories, including edge cases
- **Performance tests** — Time and memory benchmarks for month loads and bulk exports
- **Property-based tests** — Fuzz ExportRecordStore mutation sequences for compaction correctness

## Future considerations

- **Multiple destinations** — Support more than one export root with per-destination status
- **Background agent** — Optional background process to continue exports when the UI is closed
- **Localization** — English and Finnish to start
