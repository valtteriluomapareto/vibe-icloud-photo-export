# Photo Export — Refactoring Plan (v8)

## Context

Code review found correctness bugs, dead code, weak verification gates, and concurrency design gaps. This v8 plan addresses those issues with a stricter execution model:

1. Pre-adapt for Swift 6 strict concurrency now (without waiting for full toolchain migration).
2. Make risky changes testable before doing the migration.
3. Keep each step independently verifiable with explicit exit criteria.

## Locked Decisions

- Swift 6 pre-adaptation is in scope now.
- Authorization revocation policy is **pause + require re-authorization to resume** (not cancel/drop all pending jobs).
- Non-`@MainActor` protocols must use Sendable/domain wrappers only (no `PHAsset` or other Photos reference types crossing nonisolated async boundaries).
- `PhotoLibraryManager` remains `@MainActor` and owns UI/auth state.
- Security-scoped access will use a single scoped operation API (`withScopedAccess`) instead of split `begin/end` calls.
- Export queue processing uses run-generation guards to prevent stale tasks from mutating state after pause/cancel/revoke.
- Queue test signaling uses a per-run event stream with strict completion semantics.
- File timestamp and file move side effects are validated via dependency injection (`FileIOProviding`), not inferred from filesystem side effects.
- `resourceToken` is structured/versioned and validated for round-trip correctness.

---

## Phase 0: Swift 6 Concurrency Baseline (New)

### 0.1 — Enable strict concurrency diagnostics
**Files**: `photo-export.xcodeproj/project.pbxproj`

**Changes**:
1. Keep `SWIFT_VERSION = 5.0` for now.
2. Add strict concurrency diagnostics for Debug/Test configurations (for example, `SWIFT_STRICT_CONCURRENCY = complete` and warning flags as supported by current Xcode).
3. Document active compiler diagnostics in this repo (`CONCURRENCY_BASELINE.md`) with: warning, file, and planned fix phase.

**Exit criteria**:
- Project builds.
- Strict-concurrency warnings are triaged and mapped to plan steps.

### 0.2 — Add deterministic test seams before risky migrations
**Files**:
- `photo-export/Managers/ExportManager.swift`
- `photo-export/Managers/ExportRecordStore.swift`
- `photo-exportTests/ExportRecordStoreTests.swift`

**Changes**:
1. Add `FileIOProviding` abstraction and inject into `ExportManager`.
2. Add deterministic hooks for tests (for timeout, queue lifecycle, and controllable in-flight export behavior).
3. Remove sleep-based assertion from `ExportRecordStoreTests` by making notification debounce configurable/injectable for tests.

**Exit criteria**:
- Existing tests pass without `Task.sleep`-timing assumptions.
- No new behavior change in production codepaths.

---

## Phase 1: Critical Correctness Fixes

### 1.1 — `requestFullImage` double-resume crash guard
**File**: `photo-export/Managers/PhotoLibraryManager.swift`

**Problem**: `requestFullImage` continuation can be resumed multiple times.

**Fix**:
- Mirror `loadThumbnail` pattern with `hasResumed` guard on all resume paths.

**Verification**:
- Unit test with callback invoked multiple times (degraded/full/error order variants) verifies single terminal resume.

### 1.2 — Temp file cleanup on export failure with scoped access intact
**File**: `photo-export/Managers/ExportManager.swift`

**Problem**: temp `.tmp` files can leak on failure; cleanup timing currently conflicts with scoped-access lifecycle.

**Fix**:
1. Explicit cleanup ownership: cleanup is performed by `do`-scope `defer` while access scope is active.
2. Ensure all failure paths (write/move/timestamp/cancel) remove temp file best-effort.

**Verification**:
- Table-driven tests: write failure, move failure, timestamp failure, cancellation while writing.
- Assert temp-file cleanup attempts happen for each path.

### 1.3 — Crash-safe snapshot compaction
**File**: `photo-export/Managers/ExportRecordStore.swift`

**Problem**: remove-then-move can lose snapshot on crash.

**Fix**:
- If snapshot exists: `replaceItemAt`.
- Else: `moveItem` first snapshot.

**Verification**:
- Tests cover both branches: first compaction (no snapshot), subsequent compaction (existing snapshot).
- Assert snapshot survives and log truncates correctly.

### 1.4 — Fix `AssetDetailView` export status wiring
**Files**:
- `photo-export/Views/TestPhotoAccessView.swift` (delete)
- `photo-export/Views/AssetDetailView.swift`
- `photo-export/ContentView.swift`

**Problem**: custom environment key for export store is never injected.

**Fix**:
1. Delete `TestPhotoAccessView`.
2. Migrate `AssetDetailView` to `@EnvironmentObject ExportRecordStore`.
3. Remove unused custom `EnvironmentKey` from `ContentView`.

**Verification**:
- Build passes.
- UI smoke: selecting asset displays export status in detail pane.

---

## Phase 2: Dead Code + Hidden Coupling Removal

### 2.1 — Delete `fetchAssetsByYearAndMonth()`
**File**: `photo-export/Managers/PhotoLibraryManager.swift`

### 2.2 — Delete deprecated `MainView`
**File**: `photo-export/ContentView.swift`

### 2.3 — Delete `InfoPlist.swift`
**File**: `photo-export/InfoPlist.swift`

### 2.4 — Delete unused `AssetMetadata` + `extractAssetMetadata()`
**Files**:
- `photo-export/Models/AssetMetadata.swift`
- `photo-export/Managers/PhotoLibraryManager.swift`

### 2.5 — Remove unused `isShowingAuthorizationView`
**File**: `photo-export/ContentView.swift`

### 2.6 — Remove accidental second `PhotoLibraryManager` construction path
**File**: `photo-export/Views/MonthContentView.swift`

**Problem**: view can instantiate a fallback manager, creating duplicate state sources.

**Fix**:
- Require environment/injected manager only; remove `PhotoLibraryManager()` fallback path.

**Verification for entire phase**:
- Build succeeds.
- No references to removed symbols.

---

## Phase 3: UI Concurrency Hardening (Deterministic)

### 3.1 — Shared month formatting helper with static formatter
**New file**: `photo-export/Helpers/MonthFormatting.swift`

**Fix**:
- Create shared `monthName(for:)` using cached static `DateFormatter`.
- Replace duplicate helpers across `ContentView`, `MonthRow`, and `MonthContentView`.

### 3.2 — Move sidebar loading orchestration to testable view model
**New file**: `photo-export/ViewModels/SidebarViewModel.swift`

**Fix**:
- Extract year/month loading and stale-result/cancellation logic out of `ContentView`.
- Keep computation pure: collect counts in local variables first; apply state only once after token/cancel checks.

### 3.3 — Async migration of year/month counting with cancellation safety
**Files**:
- `photo-export/ContentView.swift`
- `photo-export/Managers/PhotoLibraryManager.swift`
- `photo-export/Managers/PhotoLibraryService.swift` (new)

**Fix**:
- Migrate `availableYears` and month-count querying to async.
- Add explicit cancellation checks inside month loops.
- Ensure stale tasks cannot mutate published state.

### 3.4 — Tests for out-of-order completion and cancellation
**New file**: `photo-exportTests/SidebarViewModelTests.swift`

**Tests**:
- Slow-old / fast-new completion ordering.
- Task cancellation before completion.
- Partial month computations do not leak stale counts.

---

## Phase 4: Swift 6-Oriented Architecture Split + Protocol Extraction

This phase is high risk and is split into small commits. No substep proceeds without passing listed tests.

### 4.1 — Domain wrappers and Sendable boundaries
**New file**: `photo-export/Models/ExportableAsset.swift`

**Rules**:
- All nonisolated protocol APIs use Sendable wrapper/domain types.
- Explicit enum mappers (`init(from:)` switch), no raw-value coupling.

### 4.2 — Structured `resourceToken` contract
**Files**:
- `photo-export/Models/ExportableAsset.swift`
- `photo-export/Managers/PhotoLibraryService.swift`

**Fix**:
- Replace delimiter token (`"assetId#index"`) with versioned structured token (encoded payload containing asset ID + resource identity fields).
- Enforce parse + validation + round-trip tests.
- Invalid token is hard failure (no fuzzy fallback).

### 4.3 — `PhotoLibraryExportProviding` protocol (nonisolated)
**New file**: `photo-export/Protocols/PhotoLibraryExportProviding.swift`

**Contract**:
- Export pipeline only.
- No UI auth state.
- No Photos reference types in protocol signatures.

### 4.4 — `ExportDestinationProviding` protocol with scoped operation API
**New file**: `photo-export/Protocols/ExportDestinationProviding.swift`

**Contract**:
- `@MainActor` protocol.
- Keep `urlForMonth(...)`.
- Replace split `beginScopedAccess/endScopedAccess` with one balanced API:

```swift
@MainActor
protocol ExportDestinationProviding: AnyObject {
  var canExportNow: Bool { get }
  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL
  func withScopedAccess<T>(_ operation: () async throws -> T) async throws -> T
}
```

### 4.5 — `PhotoLibraryService` conformance and queue separation
**File**: `photo-export/Managers/PhotoLibraryService.swift` (new)

**Fix**:
- Implement protocol with separate queues for heavy fetches vs light stats.
- Keep non-Sendable Photos references internal to service implementation.
- Expose only wrapper types across async boundary.

### 4.6 — `ExportManager` protocol migration + run-generation state machine
**File**: `photo-export/Managers/ExportManager.swift`

**Fix**:
1. Replace concrete deps with protocols:
   - `photoLibraryService: any PhotoLibraryExportProviding`
   - `exportDestinationManager: any ExportDestinationProviding`
   - `fileIO: any FileIOProviding`
   - injected `isAuthorized: @MainActor () -> Bool`
2. Add `runID` generation token and attach it to processing tasks.
3. All terminal record writes pass through one idempotent finalize path guarded by current `runID`.
4. Late completions from stale tasks are ignored.
5. Keep `creationDate` on `ExportJob` and pass it via injected file IO.

### 4.7 — Authorization revocation policy: pause + require re-auth
**Files**:
- `photo-export/Managers/ExportManager.swift`
- `photo-export/photo_exportApp.swift`
- `photo-export/Managers/PhotoLibraryManager.swift`

**Policy**:
- On authorization loss while queue is active:
  1. Cancel current export task.
  2. Requeue interrupted job at front (if still needed).
  3. Keep remaining pending jobs.
  4. Set `isPaused = true`, `requiresReauthorization = true`, `isRunning = false`, `isProcessing = false`.
  5. Emit `.blockedByAuthorization` event (non-terminal for queue data).
- Resume requires explicit user action + positive auth check.
- No automatic resume on authorization regain.

**Additional lifecycle fix**:
- Add `refreshAuthorizationStatus()` to `PhotoLibraryManager`.
- Call on app activation/scene active and before queue processing entry points.

### 4.8 — Event stream test infrastructure (strict semantics)
**File**: `photo-export/Managers/ExportManager.swift`

**Fix**:
- Per-run stream creation.
- Stream close is explicit and single-owner.
- `awaitEvents` must throw if stream ends before expected event count unless partial explicitly requested.
- Add event for authorization blocking.

### 4.9 — Composition root update
**File**: `photo-export/photo_exportApp.swift`

**Fix**:
- Wire new protocol dependencies.
- Inject single-source auth closure.
- Connect auth status changes to revocation handler.

---

## Phase 5: Test Expansion for Real Verification

### 5.1 — `ExportManager` deterministic tests
**New file**: `photo-exportTests/ExportManagerTests.swift`

**Coverage**:
- Queue lifecycle: paused, resumed, drained, cancelled, blocked-by-auth.
- Revocation while in-flight with blocking mock writer.
- Stale run completion ignored.
- Negative paths: asset missing, no resource, scope denied, write fail, move fail, timestamp fail.
- Temp file cleanup assertions.
- Timestamp pass-through via `FileIOProviding` spy.

### 5.2 — `ExportDestinationManager` tests with isolated storage
**New file**: `photo-exportTests/ExportDestinationManagerTests.swift`

**Coverage**:
- Validation errors for year/month/path.
- Directory creation behavior.
- Scoped-access API guarantees balancing.
- `clearSelection` affects only injected test storage.

### 5.3 — `PhotoLibraryManager` auth mapping tests
**New file**: `photo-exportTests/PhotoLibraryManagerAuthorizationTests.swift`

**Coverage**:
- `.authorized` and `.limited` map to `isAuthorized == true`.
- denied/restricted map false.
- refresh path updates state correctly.

### 5.4 — `ExportRecordStore` compaction and notification determinism
**File**: `photo-exportTests/ExportRecordStoreTests.swift`

**Coverage**:
- First and subsequent compaction branches.
- Notification coalescing without fixed sleeps.

---

## Phase 6: Limited Authorization UX + Final Hardening

### 6.1 — `.limited` UX banner and behavior
**Files**:
- `photo-export/Managers/PhotoLibraryManager.swift`
- `photo-export/ContentView.swift`

**Fix**:
- Track `isLimited`.
- Show subtle banner explaining subset visibility.
- Keep export controls consistent with authorized/limited state.

### 6.2 — Final manual smoke tests
1. Launch app, browse years/months.
2. View detail pane export status.
3. Start month export, pause/resume.
4. Revoke authorization mid-export, verify queue goes blocked/paused.
5. Re-authorize, explicitly resume, verify queue continues.
6. Validate limited-access banner behavior.

---

## Execution Model (Replaces prior verification section)

Each step must meet these gates before moving forward:
1. Build gate: `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' build`
2. Targeted test gate: run only tests for touched area.
3. Phase gate: full test run at end of each phase.
4. Manual gate: only for behavior/UI changes.

### Commit strategy

- One commit per numbered step.
- High-risk steps (`3.2`, `3.3`, `4.x`, `5.1`) must not mix production migration and new test framework work in the same commit unless the test seam is required by that exact change.
- Rollback remains `git revert` per step.

### Recommended test commands

1. Targeted: `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -only-testing:photo-exportTests/<SuiteName> test`
2. Full phase gate: `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' test`

---

## File Impact Summary (v8)

| File | Planned phases |
|------|----------------|
| `Managers/PhotoLibraryManager.swift` | 1.1, 2.1, 2.4, 3.3, 4.7, 6.1 |
| `Managers/PhotoLibraryService.swift` (new) | 3.3, 4.2, 4.5 |
| `Managers/ExportManager.swift` | 1.2, 4.6, 4.7, 4.8 |
| `Managers/ExportRecordStore.swift` | 1.3, 0.2 |
| `Managers/ExportDestinationManager.swift` | 4.4, 5.2 |
| `Managers/FileIOService.swift` + new protocol | 0.2, 4.6 |
| `Protocols/PhotoLibraryExportProviding.swift` (new) | 4.3 |
| `Protocols/ExportDestinationProviding.swift` (new) | 4.4 |
| `Models/ExportableAsset.swift` (new) | 4.1, 4.2 |
| `Views/AssetDetailView.swift` | 1.4 |
| `Views/MonthContentView.swift` | 2.6, 3.1 |
| `Views/TestPhotoAccessView.swift` | 1.4 (delete) |
| `ContentView.swift` | 1.4, 2.2, 2.5, 3.1, 3.2, 6.1 |
| `InfoPlist.swift` | 2.3 (delete) |
| `Models/AssetMetadata.swift` | 2.4 (delete) |
| `photo_exportApp.swift` | 4.7, 4.9 |
| `ViewModels/SidebarViewModel.swift` (new) | 3.2, 3.4 |
| `photo-exportTests/ExportManagerTests.swift` (new) | 5.1 |
| `photo-exportTests/ExportDestinationManagerTests.swift` (new) | 5.2 |
| `photo-exportTests/PhotoLibraryManagerAuthorizationTests.swift` (new) | 5.3 |
| `photo-exportTests/SidebarViewModelTests.swift` (new) | 3.4 |

