# Refactoring Plan

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

## Phase 1: Fix Real Bugs ✅ DONE

All bug fixes in this phase are independent and can be done in any order. Each is a single commit.

### 1.1 — Fix `requestFullImage` double-resume crash (HIGHEST PRIORITY) ✅ DONE

**File**: `photo-export/Managers/PhotoLibraryManager.swift`

**Problem**: `requestFullImage` uses `withCheckedThrowingContinuation` but has NO resume guard. Despite requesting `.highQualityFormat`, the Photos framework can still invoke the handler multiple times (e.g., error then callback, or on cancellation). A double resume crashes the app.

**Fix applied**: Added `OSAllocatedUnfairLock<Bool>` guard. Error/cancel is checked before the degraded early-return. Degraded non-error callbacks are skipped. The lock prevents double-resume regardless of which terminal path fires first.

**Test**: `photo-exportTests/ContinuationResumeTests.swift` — 4 tests covering concurrent resumes, degraded-then-final, error-before-final scenarios. All passing.

### 1.2 — Fix `loadThumbnail` thread-unsafe resume guard ✅ DONE

**File**: `photo-export/Managers/PhotoLibraryManager.swift`

**Problem**: `var hasResumed = false` is a plain local Bool. PHImageManager delivers `.opportunistic` callbacks on arbitrary threads. Two callbacks on different threads can both read `false` before either writes `true`.

**Fix applied**: Replaced plain `var hasResumed` with `OSAllocatedUnfairLock<Bool>`. First callback wins (opportunistic delivery).

**Test**: Covered by `ContinuationResumeTests.swift`.

### 1.3 — Fix temp file leak on export failure ✅ DONE

**File**: `photo-export/Managers/ExportManager.swift`

**Problem**: When `writeResource` or the atomic move throws, the catch block logs and marks failed but never cleans up `tempURL`. Temp files accumulate in the export directory.

**Fix applied**: Added `defer` cleanup block immediately after `tempURL` is defined. Removes the temp file if it exists when the scope exits (success or failure).

**Test**: `photo-exportTests/TempFileCleanupTests.swift` — 2 tests validating cleanup on failure and no-op when file doesn't exist. All passing.

### 1.4 — Fix `.limited` authorization mapping ✅ DONE

**File**: `photo-export/Managers/PhotoLibraryManager.swift`

**Problem**: `isAuthorized = authorizationStatus == .authorized` means users who grant "Limited" access are treated as unauthorized and cannot use the app.

**Fix applied**: Both `init()` and `requestAuthorization()` now check `status == .authorized || status == .limited`. Return value of `requestAuthorization()` also updated.

**Test**: `photo-exportTests/AuthorizationMappingTests.swift` — 5 tests covering all `PHAuthorizationStatus` values. All passing.

### 1.5 — Fix double security-scope in `urlForMonth` ✅ DONE

**Files**: `photo-export/Managers/ExportDestinationManager.swift`, `photo-export/Managers/ExportManager.swift`

**Problem**: `urlForMonth()` internally calls `beginScopedAccess()`/`endScopedAccess()` for directory creation. But its only caller (`ExportManager.export`) also calls `beginScopedAccess()` separately. Security scope is started twice and stopped in overlapping defers.

**Fix applied**: Removed internal scope management from `urlForMonth()`. In `ExportManager.export(job:)`, moved scope acquisition to *before* the `urlForMonth()` call so directory creation runs under active scope. Single scope/defer pair now covers the entire export operation.

### 1.6 — Remove fallback `PhotoLibraryManager()` in MonthContentView ✅ DONE

**File**: `photo-export/Views/MonthContentView.swift`

**Problem**: The init has `photoLibraryManager: PhotoLibraryManager? = nil` with a fallback `?? PhotoLibraryManager()`. This creates a disconnected, unauthorized instance.

**Fix applied**: Changed parameter to non-optional `PhotoLibraryManager`. Removed the dead `onAppear` block that attempted to detect the placeholder.

### 1.7 — Add run-generation guard to ExportManager ✅ DONE

**File**: `photo-export/Managers/ExportManager.swift`

**Problem**: When `cancelAndClear()` is called, the in-flight `export(job:)` may be mid-continuation. When it eventually resumes, `processNext()` is called from the stale task's completion, potentially restarting the queue.

**Fix applied**: Added `private var generation: Int = 0`. `cancelAndClear()` increments generation. `processNext()` captures `currentGen` and the task completion checks `self.generation == currentGen` before calling `processNext()`.

---

## Phase 2: Dead Code and Cleanup ✅ DONE

### 2.1 — Remove dead code ✅ DONE

**Removed**:
- `photo-export/Views/TestPhotoAccessView.swift` (entire file)
- `photo-export/InfoPlist.swift` (entire file)
- `photo-export/Models/AssetMetadata.swift` (entire file)
- `PhotoLibraryManager.extractAssetMetadata()` — only consumer was AssetMetadata
- `PhotoLibraryManager.fetchAssetsByYearAndMonth()` — no callers after TestPhotoAccessView removal
- `ContentView.MainView` struct — deprecated, zero references
- `ContentView.isShowingAuthorizationView` — written but never read
- `photo-exportTests/photo_exportTests.swift` — empty test stub
- `ContentView` custom `ExportRecordStoreKey` and `EnvironmentValues` extension — replaced in 2.2

### 2.2 — Fix AssetDetailView environment access ✅ DONE

**File**: `photo-export/Views/AssetDetailView.swift`

**Fix applied**: Replaced `@Environment(\.exportRecordStore)` with `@EnvironmentObject`. Removed optional chaining on `exportRecordStore`. Removed the now-unused `ExportRecordStoreKey` and `EnvironmentValues` extension from ContentView.swift.

---

## Phase 3: Concurrency Prep ✅ DONE

### 3.1 — Add `@MainActor` to PhotoLibraryManager ✅ DONE

**File**: `photo-export/Managers/PhotoLibraryManager.swift`

**Fix applied**: Added `@MainActor` annotation to class declaration. All call sites were already on `@MainActor`. Build passes.

### 3.2 — Shared month formatting helper ✅ DONE

**Fix applied**: Created `photo-export/Helpers/MonthFormatting.swift` with a static `DateFormatter`. Replaced all three duplicate `monthName()` implementations in `ContentView`/`MonthRow` and `MonthContentView` with `MonthFormatting.name(for:)`.

---

## Phase 4: Test Infrastructure (Optional) — NOT STARTED

These steps add test seams for the export path. Phase 1 tests are pattern-level (they validate the fix logic in isolation). Phase 4 provides end-to-end coverage through the actual ExportManager code paths by making dependencies injectable.

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

**Run all tests:**
```bash
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" \
  -destination 'platform=macOS' test
```

**Last run**: 22 tests in 4 suites — all passing.

---

## File Impact Summary

| File | Steps | Status |
|---|---|---|
| `photo-export/Managers/PhotoLibraryManager.swift` | 1.1, 1.2, 1.4, 2.1, 3.1 | ✅ Done |
| `photo-export/Managers/ExportManager.swift` | 1.3, 1.5, 1.7 | ✅ Done |
| `photo-export/Managers/ExportDestinationManager.swift` | 1.5 | ✅ Done |
| `photo-export/Views/MonthContentView.swift` | 1.6, 3.2 | ✅ Done |
| `photo-export/Views/AssetDetailView.swift` | 2.2 | ✅ Done |
| `photo-export/ContentView.swift` | 2.1, 2.2, 3.2 | ✅ Done |
| `photo-export/InfoPlist.swift` | 2.1 (delete) | ✅ Deleted |
| `photo-export/Models/AssetMetadata.swift` | 2.1 (delete) | ✅ Deleted |
| `photo-export/Views/TestPhotoAccessView.swift` | 2.1 (delete) | ✅ Deleted |
| `photo-exportTests/photo_exportTests.swift` | 2.1 (delete) | ✅ Deleted |
| `photo-export/Helpers/MonthFormatting.swift` | 3.2 (new) | ✅ Created |
| `photo-export/Protocols/FileIOProviding.swift` | 4.1 (new) | Not started |
| `photo-export/Protocols/ResourceWriting.swift` | 4.2 (new) | Not started |
| `photo-exportTests/ContinuationResumeTests.swift` | 1.1, 1.2 (new) | ✅ Created |
| `photo-exportTests/TempFileCleanupTests.swift` | 1.3 (new) | ✅ Created |
| `photo-exportTests/AuthorizationMappingTests.swift` | 1.4 (new) | ✅ Created |
| `photo-exportTests/ExportManagerFailurePathTests.swift` | 4.3 (new) | Not started |
