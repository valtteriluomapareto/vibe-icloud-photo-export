---
title: Architecture
description: How Photo Export is built — SwiftUI + Managers pattern.
---

Photo Export follows a small **SwiftUI + Managers** architecture. Views stay relatively thin, stateful workflows live in managers or view models, and the project relies on Apple system frameworks only.

## App entry point

[`photo_exportApp.swift`](https://github.com/valtteriluomapareto/vibe-icloud-photo-export/blob/main/photo-export/photo_exportApp.swift) creates the shared app state and injects it into the view tree with `@EnvironmentObject`.

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
- JSONL-based persistence with compaction
- Reconfigures automatically when the destination changes
- Provides month-level aggregation for sidebar badges

### ExportManager

Orchestrates the export queue. Depends on the other three managers.

- Enqueue/pause/cancel/resume operations
- Sequential export pipeline
- Atomic writes: temp file → move to final location
- Updates export records after each successful export
- Runs the "Import Existing Backup…" flow

## Supporting Services

- `BackupScanner` scans an existing backup folder and matches files back to Photos assets.
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

The export record store keeps per-destination state under Application Support. A detailed format description lives in [`persistence-store.md`](https://github.com/valtteriluomapareto/vibe-icloud-photo-export/blob/main/docs/reference/persistence-store.md).

## Project Conventions

- **Logging:** `os.Logger` with subsystem `com.valtteriluoma.photo-export`. No `print` in production code.
- **Concurrency:** UI-facing managers are `@MainActor`. Export is currently serial.
- **Asset identity:** Track by `PHAsset.localIdentifier`. Never overwrite existing files.
- **Async views:** Use `.task(id:)` for cancellation-aware async loading.
- **Linting:** SwiftLint with `--strict`, 140-char line length.
- **Formatting:** swift-format with 4-space indentation, 120-char line length.
