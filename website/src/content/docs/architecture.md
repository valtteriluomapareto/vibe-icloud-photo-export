---
title: Architecture
description: How Photo Export is built — SwiftUI + Managers pattern.
---

Photo Export follows a small **SwiftUI + Managers** architecture. Views stay relatively thin, stateful workflows live in managers or view models, and the project relies on Apple system frameworks only.

## App entry point

[`photo_exportApp.swift`](https://github.com/valtteriluomapareto/photo-export/blob/main/photo-export/photo_exportApp.swift) creates the shared app state and injects it into the view tree with `@EnvironmentObject`.

## Managers

Most long-lived state lives in manager types under `photo-export/Managers/`.

### PhotoLibraryManager

Handles Photos authorization and asset fetching. Uses `PHCachingImageManager` for thumbnail work.

- Queries assets grouped by year and month
- Provides both thumbnail and full-size image loading
- Manages Photos library authorization flow

### ExportDestinationManager

Manages the chosen export destination folder using security-scoped bookmarks.

- Presents the macOS folder picker
- Persists the selection via security-scoped bookmarks
- Validates folder accessibility on launch

### ExportRecordStore

Tracks which assets have been exported per-destination to avoid duplicates and support resume.

- Stores records by `PHAsset.localIdentifier`
- Per-variant state: each record carries a `variants` dictionary keyed by `original` /
  `edited`, so the same asset can track an original export and an edited export
  independently
- Legacy flat records (single `filename` + `status`) decode into a synthesized `.original`
  variant so existing users keep their progress after upgrade
- JSONL-based persistence with compaction
- Reconfigures automatically when the destination changes
- Provides selection-aware month summaries for the thumbnail grid and approximate counts
  for sidebar badges

### ExportManager

Orchestrates the export queue. Depends on the other three managers.

- Enqueue/pause/cancel/resume operations
- Persists the user's version selection (`edited` / `editedWithOriginals`) in
  `UserDefaults` and snapshots it onto each enqueued job
- Sequential export pipeline; each job writes every variant required for the asset under
  the active selection
- `ExportFilenamePolicy` decides the `_orig` companion filename shape; `ResourceSelection`
  picks between original-side and edited-side `PHAssetResource`s
- Atomic writes: per-variant temp file → move to final location, with stale `.tmp`
  cleanup at export start
- Updates per-variant export records after each successful write; a failed edited variant
  does not roll back a completed original variant
- Runs the "Import Existing Backup…" flow

## Supporting Services

- `BackupScanner` scans an existing backup folder and matches files back to Photos assets.
  Its fingerprints split original-side and edited-side resource filenames so each scanned
  file is classified per variant before being merged into the record store.
- `ExportFilenamePolicy` is the shared source of truth for `_orig` companion filename
  rules and used by both the export pipeline and the backup scanner.
- `ResourceSelection` picks the right `PHAssetResource` for a variant and is the shared
  classifier for "original-side" vs "edited-side" resources.
- `FileIOService` centralizes atomic file moves and timestamp handling.

## Views and View Models

The main UI lives under `photo-export/Views/` and `photo-export/ViewModels/`.

| Type                | Responsibility                                            |
| ------------------- | --------------------------------------------------------- |
| `ContentView`       | Main `NavigationSplitView` shell and year/month selection |
| `MonthContentView`  | Thumbnail grid for the selected month                     |
| `AssetDetailView`   | Full-size image or video preview                          |
| `ExportToolbarView` | Export destination and queue controls                     |
| `OnboardingView`    | First-run flow for permissions and destination setup      |
| `ImportView`        | Progress and results for importing an existing backup     |
| `MonthViewModel`    | Cancellation-aware loading for month content              |

## Persistence

The export record store keeps per-destination state under Application Support. A detailed format description lives in [`persistence-store.md`](https://github.com/valtteriluomapareto/photo-export/blob/main/docs/reference/persistence-store.md).

## Design choices worth knowing

- **Logging:** `os.Logger` with subsystem `com.valtteriluoma.photo-export` — visible in Console.app for diagnostics.
- **Concurrency:** UI-facing managers run on the main actor. Export is sequential rather than parallel, by design.
- **Asset identity:** Tracked by `PHAsset.localIdentifier`. Existing files in the destination are never overwritten — re-running an export resumes where it left off.

Contributor-facing conventions (linting rules, formatting, the SwiftUI + Managers code style) live in the [contributor guide](https://github.com/valtteriluomapareto/photo-export/blob/main/CONTRIBUTING.md) and [`AGENTS.md`](https://github.com/valtteriluomapareto/photo-export/blob/main/AGENTS.md).
