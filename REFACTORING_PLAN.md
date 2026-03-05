# Photo Export — Refactoring Plan (v11)

## Context

This is a ~2,750-line solo macOS app with 15 Swift source files. The plan is sized accordingly: fix real bugs, clean up dead code, and make targeted improvements. No architecture astronautics.

The project uses **Swift Testing** (not XCTest) and **Swift 5**. There is currently no `.xctestplan` file — the scheme uses the `<Testables>` model directly.

## Confirmed Bugs (from code review)

1. **`requestFullImage` can double-resume its continuation** — no resume guard at all. Crash risk.
2. **`loadThumbnail` resume guard is not thread-safe** — `var hasResumed` is a plain Bool accessed from concurrent PHImageManager callbacks.
3. **Temp file leak on export failure** — `ExportManager.export(job:)` catch block never deletes `tempURL`.
4. **`.limited` auth status treated as unauthorized** — `isAuthorized = status == .authorized` ignores `.limited`.
5. **Double security-scope start** — `urlForMonth()` calls `beginScopedAccess()`/`endScopedAccess()` internally, AND `export(job:)` calls them again separately.
6. **`MonthContentView` creates a throwaway `PhotoLibraryManager()`** — fallback default parameter constructs an unauthorized instance.
7. **Stale task can call `processNext()` after `cancelAndClear()`** — no generation guard on the processing chain.

## Non-Bugs Removed from Scope

These were in the previous plan but are not real problems in this codebase:

- **State machine for ExportManager** — the sequential queue is 340 lines and works. The specific bugs above are fixed directly.
- **Domain wrappers (`ExportableAsset`, `resourceToken`)** — the code already passes `localIdentifier` strings across boundaries via `ExportJob`.
- **`PhotoLibraryService` as a separate type** — one consumer, no polymorphism benefit.
- **Destination type split** — `ExportDestinationManager` is 293 lines and does its job. Fix the double-scope bug directly.
- **`SidebarViewModel` extraction** — ContentView is the sidebar. Moving code between files doesn't reduce complexity.
- **CI concurrency baseline enforcement** — solo project, no CI. When Swift 6 arrives, the compiler will tell you what to fix.
- **Characterization tests before rewrite** — there is no rewrite. Bugs are fixed in place.

---

## Phase 1: Fix Real Bugs

All bug fixes in this phase are independent and can be done in any order. Each is a single commit.

### 1.1 — Fix `requestFullImage` double-resume crash (HIGHEST PRIORITY)

**File**: `photo-export/Managers/PhotoLibraryManager.swift` (lines 326-362)

**Problem**: `requestFullImage` uses `withCheckedThrowingContinuation` but has NO resume guard. Despite requesting `.highQualityFormat`, the Photos framework can still invoke the handler multiple times (e.g., error then callback, or on cancellation). A double resume crashes the app.

**Fix**:
```swift
import os  // for OSAllocatedUnfairLock

// Inside requestFullImage:
let resumed = OSAllocatedUnfairLock(initialState: false)
PHImageManager.default().requestImage(...) { image, info in
    guard resumed.withLock({
        let was = $0; $0 = true; return !was
    }) else { return }
    // ... existing resume logic
}
```

**Test**: `photo-exportTests/ContinuationResumeTests.swift`
- Verify that wrapping a multi-callback scenario in the lock pattern produces exactly one resume.
- This is a unit test of the lock pattern itself (the PHImageManager callback is not injectable without disproportionate seam work).

### 1.2 — Fix `loadThumbnail` thread-unsafe resume guard

**File**: `photo-export/Managers/PhotoLibraryManager.swift` (lines 297-320)

**Problem**: `var hasResumed = false` is a plain local Bool. PHImageManager delivers `.opportunistic` callbacks on arbitrary threads. Two callbacks on different threads can both read `false` before either writes `true`.

**Fix**: Same `OSAllocatedUnfairLock<Bool>` pattern as 1.1.

**Test**: Covered by the same `ContinuationResumeTests.swift`.

### 1.3 — Fix temp file leak on export failure

**File**: `photo-export/Managers/ExportManager.swift` (lines 173-280)

**Problem**: When `writeResource` or the atomic move throws, the catch block (line 273) logs and marks failed but never cleans up `tempURL`. Temp files accumulate in the export directory.

**Fix**: Add cleanup `defer` after `tempURL` is defined (line 213):
```swift
let tempURL = finalURL.appendingPathExtension("tmp")
defer {
    if FileManager.default.fileExists(atPath: tempURL.path) {
        try? FileManager.default.removeItem(at: tempURL)
    }
}
```

Place this inside the `do` block, after `tempURL` is computed but before the write begins.

**Test**: `photo-exportTests/TempFileCleanupTests.swift`
- Create a temp file at a known path, simulate the cleanup logic, assert the file is gone.

### 1.4 — Fix `.limited` authorization mapping

**File**: `photo-export/Managers/PhotoLibraryManager.swift` (lines 29-30, 48-51)

**Problem**: `isAuthorized = authorizationStatus == .authorized` means users who grant "Limited" access are treated as unauthorized and cannot use the app.

**Fix**:
```swift
// In init():
isAuthorized = authorizationStatus == .authorized || authorizationStatus == .limited

// In requestAuthorization():
self.isAuthorized = status == .authorized || status == .limited
```

**Test**: `photo-exportTests/AuthorizationMappingTests.swift`
- Test the mapping logic directly: given each `PHAuthorizationStatus` value, assert the expected `isAuthorized` result.
- Note: This requires extracting the mapping to a pure function since `PHPhotoLibrary.authorizationStatus` is not injectable. The test validates the mapping logic, not the Photos framework call.

### 1.5 — Fix double security-scope in `urlForMonth`

**File**: `photo-export/Managers/ExportDestinationManager.swift` (lines 132-134)

**Problem**: `urlForMonth()` internally calls `beginScopedAccess()`/`endScopedAccess()` for directory creation. But its only caller (`ExportManager.export`, line 220) also calls `beginScopedAccess()` separately. Security scope is started twice and stopped in overlapping defers.

**Fix**: Remove the scope management from inside `urlForMonth()`. The caller already owns the scope:
```swift
// Remove these lines from urlForMonth():
// let didStart = beginScopedAccess()
// defer { if didStart { endScopedAccess() } }
// guard didStart else { throw ExportDestinationError.scopeAccessDenied }
```

The caller (`ExportManager.export`) already starts scope at line 220 and ends it via defer at line 222. After this change, `urlForMonth` is a pure path-construction + directory-creation method that assumes the caller has already acquired scope access.

**Exit criteria**: Build passes. Export still writes to the correct directory.

### 1.6 — Remove fallback `PhotoLibraryManager()` in MonthContentView

**File**: `photo-export/Views/MonthContentView.swift` (line 18-27)

**Problem**: The init has `photoLibraryManager: PhotoLibraryManager? = nil` with a fallback `?? PhotoLibraryManager()`. This creates a disconnected, unauthorized instance. The parameter is always passed from ContentView (line 110), so the fallback is dead code that will cause a compile break when `@MainActor` is added to PhotoLibraryManager.

**Fix**: Remove the optional and default:
```swift
init(year: Int, month: Int, selectedAsset: Binding<PHAsset?>,
     photoLibraryManager: PhotoLibraryManager) {
    // ...
    _viewModel = StateObject(
        wrappedValue: MonthViewModel(photoLibraryManager: photoLibraryManager))
}
```

**Exit criteria**: Build passes.

### 1.7 — Add run-generation guard to ExportManager

**File**: `photo-export/Managers/ExportManager.swift`

**Problem**: When `cancelAndClear()` is called, `currentTask` is cancelled, but the in-flight `export(job:)` may be mid-continuation. When it eventually resumes, `processNext()` is called from the stale task's completion (line 162-164), potentially restarting the queue.

**Fix**: Add a generation counter:
```swift
private var generation: Int = 0

func cancelAndClear() {
    generation += 1  // Invalidate any in-flight work
    // ... existing cleanup
}

private func processNext() {
    let currentGen = generation
    // ... existing guard checks ...
    currentTask = Task { [weak self] in
        await self?.export(job: job)
        await MainActor.run { [weak self] in
            guard let self, self.generation == currentGen else { return }
            self.processNext()
        }
    }
}
```

**Exit criteria**: Build passes. After `cancelAndClear()`, no stale task can call `processNext()`.

---

## Phase 2: Dead Code and Cleanup

One commit. Low risk, high hygiene value.

### 2.1 — Remove dead code

**Remove**:
- `photo-export/Views/TestPhotoAccessView.swift` (entire file, if it exists)
- `photo-export/InfoPlist.swift` (entire file)
- `photo-export/Models/AssetMetadata.swift` (entire file)
- `PhotoLibraryManager.extractAssetMetadata()` (line 252-262) — only consumer was AssetMetadata
- `PhotoLibraryManager.fetchAssetsByYearAndMonth()` (lines 57-104) — no callers after TestPhotoAccessView removal
- `ContentView.MainView` struct (lines 419-478) — deprecated, zero references
- `ContentView.isShowingAuthorizationView` (line 27) — written but never read
- `photo-exportTests/photo_exportTests.swift` — empty test stub
- `ContentView` custom `ExportRecordStoreKey` and `EnvironmentValues` extension (lines 13-22) — replaced in 2.2

### 2.2 — Fix AssetDetailView environment access

**File**: `photo-export/Views/AssetDetailView.swift` (line 8)

**Change**: Replace `@Environment(\.exportRecordStore) private var exportRecordStore` with `@EnvironmentObject private var exportRecordStore: ExportRecordStore`.

**Also**: Remove the `exportRecordStore?.` optional chaining on line 103 — it becomes a non-optional `exportRecordStore.` call.

**Also**: Remove the `ExportRecordStoreKey` and `EnvironmentValues` extension from ContentView.swift (listed in 2.1).

**Exit criteria**: Build passes. Asset detail view shows export status via `@EnvironmentObject`.

---

## Phase 3: Concurrency Prep (Optional, Swift 6 Readiness)

This phase prepares for strict concurrency but does not require Swift 6. Each step is independent.

### 3.1 — Add `@MainActor` to PhotoLibraryManager

**File**: `photo-export/Managers/PhotoLibraryManager.swift`

**Prerequisite**: Step 1.6 (remove fallback construction) must be done first, or this will cause a compile break in MonthContentView's `StateObject` initializer.

**Change**: Add `@MainActor` to the class declaration:
```swift
@MainActor
final class PhotoLibraryManager: ObservableObject {
```

**Call-site fixes needed**: Most callers are already on `@MainActor` (views, `ExportManager`). Audit each call site:
- `ContentView.onAppear` / `.onChange` call `availableYears()` and `computeMonthsWithAssets()` synchronously — these are already on main.
- `MonthViewModel.loadAssets()` calls `fetchAssets()` — already `@MainActor`.
- `ExportManager.enqueueMonth/Year()` calls `fetchAssets()` — already `@MainActor`.

**Performance note**: `countAssets()` is called synchronously 12 times per expanded year from `computeMonthsWithAssets()`. This blocks the main thread. Consider wrapping in `Task {}` as a follow-up, but it's an existing problem, not introduced by this change.

**Exit criteria**: Build passes with `@MainActor` annotation.

### 3.2 — Shared month formatting helper

**Problem**: `monthName(_:)` is duplicated in `ContentView`, `MonthRow`, and `MonthContentView`, each creating a new `DateFormatter` per call.

**Fix**: Create `photo-export/Helpers/MonthFormatting.swift`:
```swift
import Foundation

enum MonthFormatting {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f
    }()

    static func name(for month: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(year: 2023, month: month))!
        return formatter.string(from: date)
    }
}
```

Replace all three `monthName()` implementations with `MonthFormatting.name(for:)`.

**Exit criteria**: Build passes. No duplicate `monthName` functions remain.

---

## Phase 4: Test Infrastructure (Optional)

These steps add test seams for the export path. Only pursue if you want meaningful unit test coverage of ExportManager.

### 4.1 — Add `FileIOProviding` protocol

**New file**: `photo-export/Protocols/FileIOProviding.swift`

```swift
protocol FileIOProviding {
    func moveItemAtomically(from src: URL, to dst: URL) throws
    func applyTimestamps(creationDate: Date, to url: URL)
}
```

Make `FileIOService` conform. Change `ExportManager` to accept `FileIOProviding` (defaulting to `FileIOService` in production).

### 4.2 — Add `ResourceWriting` protocol

**New file**: `photo-export/Protocols/ResourceWriting.swift`

Wraps `PHAssetResourceManager.writeData(for:toFile:options:)`. Allows injecting a mock that writes known bytes to a temp file.

### 4.3 — ExportManager failure path tests

**New file**: `photo-exportTests/ExportManagerFailurePathTests.swift`

With the seams from 4.1 and 4.2, test:
- Temp file is cleaned up after write failure
- Temp file is cleaned up after move failure
- Failed export is recorded in the store
- Generation guard prevents stale `processNext()` calls

---

## Verification

All steps use the standard test invocation:
```bash
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" \
  -destination 'platform=macOS' test
```

For running specific test files:
```bash
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" \
  -destination 'platform=macOS' \
  -only-testing photo-exportTests/ContinuationResumeTests test
```

Note: The project uses Swift Testing (`@Test`), not XCTest. Test filtering with `-only-testing` uses the target/suite format.

---

## File Impact Summary

| File | Steps |
|---|---|
| `photo-export/Managers/PhotoLibraryManager.swift` | 1.1, 1.2, 1.4, 2.1, 3.1 |
| `photo-export/Managers/ExportManager.swift` | 1.3, 1.7, 4.1, 4.2 |
| `photo-export/Managers/ExportDestinationManager.swift` | 1.5 |
| `photo-export/Views/MonthContentView.swift` | 1.6, 3.2 |
| `photo-export/Views/AssetDetailView.swift` | 2.2 |
| `photo-export/ContentView.swift` | 2.1, 2.2, 3.2 |
| `photo-export/InfoPlist.swift` | 2.1 (delete) |
| `photo-export/Models/AssetMetadata.swift` | 2.1 (delete) |
| `photo-export/Views/TestPhotoAccessView.swift` | 2.1 (delete) |
| `photo-exportTests/photo_exportTests.swift` | 2.1 (delete) |
| `photo-export/Helpers/MonthFormatting.swift` | 3.2 (new) |
| `photo-export/Protocols/FileIOProviding.swift` | 4.1 (new) |
| `photo-export/Protocols/ResourceWriting.swift` | 4.2 (new) |
| `photo-exportTests/ContinuationResumeTests.swift` | 1.1, 1.2 (new) |
| `photo-exportTests/TempFileCleanupTests.swift` | 1.3 (new) |
| `photo-exportTests/AuthorizationMappingTests.swift` | 1.4 (new) |
| `photo-exportTests/ExportManagerFailurePathTests.swift` | 4.3 (new) |
