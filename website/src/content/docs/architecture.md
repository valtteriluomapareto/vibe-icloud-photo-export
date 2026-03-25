---
title: Architecture
description: How Photo Export is built — SwiftUI + Managers pattern.
---

Photo Export follows a **SwiftUI + Managers** pattern. Views are thin; logic lives in Managers and ViewModels. The app uses system frameworks only — no external dependencies.

## App entry point

`photo_exportApp.swift` creates four `@StateObject` dependencies and injects them as `@EnvironmentObject` into the view hierarchy.

## Managers

All managers are `@MainActor`.

### PhotoLibraryManager

Handles Photos framework authorization and asset fetching (thumbnails, full-size images). Uses `PHCachingImageManager` for efficient thumbnail loading.

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
- Sequential export pipeline (bounded concurrency planned)
- Atomic writes: temp file → move to final location
- Updates export records after each successful export

## Views

| View | Purpose |
|------|---------|
| `ContentView` | `NavigationSplitView` with year/month sidebar |
| `MonthContentView` | Thumbnail grid for a selected month |
| `AssetDetailView` | Full-size image/video preview |
| `ExportToolbarView` | Export controls and progress |
| `OnboardingView` | First-run authorization and folder selection |

## ViewModels

- **MonthViewModel** — Manages async asset loading for a selected month. Uses `.task(id:)` for cancellation-aware loading.

## Key conventions

- **Logging:** `os.Logger` with subsystem `com.valtteriluoma.photo-export`. No `print` in production code.
- **Concurrency:** All managers are `@MainActor`. Export is currently serial.
- **Asset identity:** Track by `PHAsset.localIdentifier`. Never overwrite existing files.
- **Async views:** Use `.task(id:)` for cancellation-aware async loading.
- **Linting:** SwiftLint with `--strict`, 140-char line length.
- **Formatting:** swift-format with 4-space indentation, 120-char line length.
