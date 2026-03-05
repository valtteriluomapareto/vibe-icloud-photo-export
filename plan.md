# UI Overhaul Implementation Plan

## Status: All steps implemented on `claude/ui-overhaul-yXZoJ` — NOT YET MERGED TO MAIN

The feature branch has been rebased/merged with main to resolve conflicts, but a PR still needs to be created and merged.

---

## Step 1: Add `ExportAllManager` capability to `ExportManager` — DONE

**File:** `photo-export/Managers/ExportManager.swift`

- Added `startExportAll()` method that iterates all available years and calls `enqueueYear` for each, with generation-based cancellation support.
- Added published properties for progress tracking:
  - `@Published private(set) var totalJobsEnqueued: Int = 0`
  - `@Published private(set) var totalJobsCompleted: Int = 0`
  - `@Published private(set) var currentAssetFilename: String?`
- Updated `processNext()` to increment `totalJobsCompleted` and set `currentAssetFilename`.
- Updated `cancelAndClear()` to reset counters and clean up in-flight records.
- Added `queuedCount(year:month:)` for per-month queue status queries.

---

## Step 2: Create `ExportToolbarView` — DONE

**New file:** `photo-export/Views/ExportToolbarView.swift`

Contains:
1. **Destination indicator**: drive icon + folder name + status color + "Change..." button
2. **Primary actions**: "Export All" button, Pause/Resume/Cancel controls
3. **Progress bar**: linear progress with completed/total count and current filename

---

## Step 3: Refactor `ContentView` sidebar — DONE

**File:** `photo-export/ContentView.swift`

- Removed `exportDestinationSection` (moved to toolbar)
- Removed `exportProcessSection` (moved to toolbar)
- Removed per-year "Export Year" buttons and per-month "Export" buttons
- Added `.toolbar { ExportToolbarView() }` to NavigationSplitView
- Deleted dead `MainView` struct and unused `EnvironmentKey`
- Simplified `MonthRow`: shows month name, status icon, inline progress during export
- Adopted `MonthFormatting.name(for:)` from main branch

---

## Step 4: Add per-month "Export Month" button to `MonthContentView` — DONE

**File:** `photo-export/Views/MonthContentView.swift`

- Added "Export Month" button in the header area next to export summary
- Disabled when `!exportDestinationManager.canExportNow`

---

## Step 5: Create `OnboardingView` — DONE

**New file:** `photo-export/Views/OnboardingView.swift`

- Welcome header with app icon
- Step 1: folder selection with "Choose Folder..." button
- Step 2: export scope picker (Everything / Let me pick months)
- "Start Export" and "Skip" buttons
- Gated by `@AppStorage("hasCompletedOnboarding")` in ContentView

---

## Step 6: Improve `ThumbnailView` with failure state — DONE

**File:** `photo-export/Views/ThumbnailView.swift`

- Changed from `thumbnail: NSImage?` to `state: ThumbnailState` enum (`.loading`, `.loaded(NSImage)`, `.failed`)
- Failed state shows gray rectangle with warning icon and "Failed" text
- `MonthViewModel` tracks `failedThumbnailIds: Set<String>` and exposes `thumbnailState(for:)`

---

## Step 7: Enrich `AssetDetailView` metadata — DONE

**File:** `photo-export/Views/AssetDetailView.swift`

- Added original filename display from `PHAssetResource`
- Added file size display using `ByteCountFormatter`
- Fixed pre-existing bug: switched from broken `@Environment(\.exportRecordStore)` to `@EnvironmentObject`

---

## Step 8: Add sidebar progress indicators during export — DONE

**File:** `photo-export/ContentView.swift` (in `MonthRow`)

- `ExportManager.queuedCount(year:month:)` returns pending job count per month
- `MonthRow` shows spinner + "N left" text when jobs are queued, otherwise shows static status

---

## Conflict resolution with main

Resolved conflicts with main branch changes:
- Integrated generation-based cancellation into `startExportAll()` and `processNext()`
- Adapted to refactored `beginScopedAccess() -> URL?` and `endScopedAccess(for:)` signatures
- Adopted `MonthFormatting.name(for:)` helper, removed duplicate `monthName()` functions

---

## Remaining work

- [ ] Create PR from `claude/ui-overhaul-yXZoJ` to main
- [ ] Code review
- [ ] Merge to main

## File Change Summary

| File | Action | Status |
|---|---|---|
| `Managers/ExportManager.swift` | Add `startExportAll()`, progress properties, per-month queue count | Done |
| `Views/ExportToolbarView.swift` | **New** — toolbar with destination, actions, progress | Done |
| `Views/OnboardingView.swift` | **New** — first-launch guided setup | Done |
| `Views/ThumbnailView.swift` | Add failure state rendering | Done |
| `Views/MonthContentView.swift` | Add "Export Month" button | Done |
| `Views/AssetDetailView.swift` | Add filename, file size; fix @EnvironmentObject bug | Done |
| `ContentView.swift` | Remove destination/process sections, remove dead `MainView`, add toolbar, add onboarding gate, simplify `MonthRow` | Done |
| `ViewModels/MonthViewModel.swift` | Track thumbnail failure state | Done |
