# UI Overhaul Implementation Plan

## Overview
Restructure the UI to move settings/controls out of the sidebar into a toolbar, add prominent export progress, improve the first-launch experience, and polish thumbnail/detail views.

---

## Step 1: Add `ExportAllManager` capability to `ExportManager`

**File:** `photo-export/Managers/ExportManager.swift`

- Add a new `startExportAll()` method that iterates all available years (via `PhotoLibraryManager.availableYears()`) and calls `enqueueYear` for each.
- Add published properties for overall progress tracking:
  - `@Published private(set) var totalJobsEnqueued: Int = 0` — total jobs added in current batch
  - `@Published private(set) var totalJobsCompleted: Int = 0` — completed so far
  - `@Published private(set) var currentAssetFilename: String?` — name of file currently being exported
- Update `processNext()` to increment `totalJobsCompleted` and set `currentAssetFilename` when starting a job.
- Update `cancelAndClear()` to reset these counters.
- These published properties power the toolbar progress bar.

---

## Step 2: Create `ExportToolbarView` (new file)

**New file:** `photo-export/Views/ExportToolbarView.swift`

A SwiftUI view used as `.toolbar { }` content in ContentView. Contains:

1. **Destination indicator** (left): folder icon + truncated path + green/yellow status icon + "Change…" button. If no folder selected, show "Select Folder…" button.
2. **Primary actions** (center): "Export All" button (`.borderedProminent`), Pause/Resume toggle button.
3. **Progress bar** (right): `ProgressView(value:total:)` with `totalJobsCompleted / totalJobsEnqueued`, percentage text, and `currentAssetFilename` below in caption. Only visible when `exportManager.isRunning || exportManager.totalJobsEnqueued > 0`.

This view reads from `ExportManager` and `ExportDestinationManager` via `@EnvironmentObject`.

---

## Step 3: Refactor `ContentView` sidebar

**File:** `photo-export/ContentView.swift`

- **Remove** `exportDestinationSection` (moved to toolbar).
- **Remove** `exportProcessSection` (moved to toolbar).
- **Remove** per-year "Export Year" buttons from the sidebar year rows (moved to toolbar / content area).
- **Remove** per-month "Export" buttons from `MonthRow` (move to content area).
- **Add** a search/filter `TextField` at the top of the sidebar list for filtering months by name.
- **Add** `.toolbar { ExportToolbarView() }` to the `NavigationSplitView`.
- **Delete** the dead `MainView` struct (lines 419–478) and the trailing comment on line 484.
- Simplify `MonthRow` to show: month name, export count badge, and status icon only (no buttons).
- Add inline progress indicator to `MonthRow` during active export: if the export manager's queue contains jobs for that year/month, show a mini progress indicator or percentage instead of the static count.

---

## Step 4: Add per-month "Export Month" button to `MonthContentView`

**File:** `photo-export/Views/MonthContentView.swift`

- Add an "Export Month" button in the header area (next to the month title or in `exportSummaryView`).
- Disable when `!exportDestinationManager.canExportNow`.
- This replaces the per-month export buttons that were removed from the sidebar.

---

## Step 5: Create `OnboardingView` (new file)

**New file:** `photo-export/Views/OnboardingView.swift`

Shown when `exportDestinationManager.selectedFolderURL == nil` (first launch or after clearing). Contains:

1. App icon / welcome header: "Welcome to Photo Export"
2. Subtitle: "Back up your Photos library to any drive."
3. Step 1: "Select an export destination" with a "Choose Folder…" button that calls `exportDestinationManager.selectFolder()`.
4. Step 2: "Choose what to export" with two radio options: "Everything (recommended)" / "Let me pick months".
5. A "Start Export" button that either calls `exportManager.startExportAll()` or dismisses to the main view.
6. A "Skip" link/button to go straight to the main view without exporting.

**Integration in `ContentView`:** After the authorization check, add a second check: if authorized but no destination selected, show `OnboardingView` instead of the `NavigationSplitView`. Add a `@State private var hasCompletedOnboarding: Bool` (persisted via `@AppStorage`) so onboarding only shows once; after that, missing destination just shows the toolbar prompt.

---

## Step 6: Improve `ThumbnailView` with failure state

**File:** `photo-export/Views/ThumbnailView.swift`

- Change the `thumbnail: NSImage?` parameter to accept a loading state enum:
  ```swift
  enum ThumbnailState {
    case loading
    case loaded(NSImage)
    case failed
  }
  ```
- Update `MonthViewModel` to track failed thumbnails (e.g., `failedThumbnailIds: Set<String>`).
- In `ThumbnailView`, when state is `.failed`, show a gray rectangle with a warning icon and "Could not load" caption text, instead of an infinite spinner.
- Update `MonthContentView` to pass the correct state.

---

## Step 7: Enrich `AssetDetailView` metadata

**File:** `photo-export/Views/AssetDetailView.swift`

- Add **filename**: use `PHAssetResource.assetResources(for: asset)` to get the original filename and display it.
- Add **file size**: use `PHAssetResource` `value(forKey: "fileSize")` to get and format the byte size (e.g., "4.2 MB").
- These are cheap synchronous calls on `PHAssetResource` so they can be computed inline.

---

## Step 8: Add sidebar progress indicators during export

**File:** `photo-export/ContentView.swift` (in `MonthRow`)

- Expose per-month queue status from `ExportManager`. Add a method or published dictionary:
  `func queuedCount(year: Int, month: Int) -> Int` — returns number of pending/in-progress jobs for that month.
- In `MonthRow`, when jobs are queued for that month, show a small `ProgressView` or a "⟳" indicator alongside the count, instead of the static export status.

---

## File Change Summary

| File | Action |
|---|---|
| `Managers/ExportManager.swift` | Add `startExportAll()`, progress properties, per-month queue count |
| `Views/ExportToolbarView.swift` | **New** — toolbar with destination, actions, progress |
| `Views/OnboardingView.swift` | **New** — first-launch guided setup |
| `Views/ThumbnailView.swift` | Add failure state rendering |
| `Views/MonthContentView.swift` | Add "Export Month" button |
| `Views/AssetDetailView.swift` | Add filename and file size metadata |
| `ContentView.swift` | Remove destination/process sections, remove dead `MainView`, add toolbar, add search filter, add onboarding gate, simplify `MonthRow` |
| `ViewModels/MonthViewModel.swift` | Track thumbnail failure state |

## Implementation Order

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8

Steps 1-3 are the core restructuring (toolbar + sidebar cleanup). Steps 4-5 add new views. Steps 6-8 are polish improvements. Each step produces a compilable state.
