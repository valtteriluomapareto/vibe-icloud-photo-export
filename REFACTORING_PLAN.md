# Photo Export — Refactoring Plan (v5)

## Context

Code review identified critical bugs, dead code, missing test coverage, and architectural gaps. This plan sequences fixes so each step is independently verifiable and never breaks the build.

**Guiding principle**: Fix bugs first, delete dead code (reduces surface area), then extract protocols + add tests.

**Decisions made**:
- `TestPhotoAccessView` is a dev-only debug view → **delete it** with dead code.
- Protocols will use **domain wrapper types** (not raw PHAsset) for true unit test isolation.
- `PhotoLibraryProviding` is **non-`@MainActor`** — only UI state updates are actor-isolated, not the protocol contract. Expensive fetch/write operations must not be forced onto MainActor by the protocol.
- File **timestamps must be preserved** after protocol migration — `creationDate` is carried on `ExportJob`, populated from `ExportableAsset` during enqueue.
- Destination tests use **dependency injection via `convenience init`** on the production type (accessible via `@testable import`), not preprocessor-guarded mutators or separate test doubles for the manager itself.

---

## Phase 1: Critical Bug Fixes

Each fix is small and isolated. Build + run `ExportRecordStoreTests` after each. These are the only existing tests — the plan does not claim broader test coverage until Phase 4.

### 1.1 — `requestFullImage` double-resume crash guard
**File**: `photo-export/Managers/PhotoLibraryManager.swift:326-363`
**Problem**: Unlike `loadThumbnail` (line 303-313 has `hasResumed`), the `requestFullImage` callback has no guard. The Photos framework can invoke the handler multiple times (e.g. degraded then full quality). A second `continuation.resume()` crashes.
**Fix**: Add `var hasResumed = false` + `guard !hasResumed else { return }` before both the error and success resume paths, identical to the `loadThumbnail` pattern.

### 1.2 — Temp file cleanup on export failure
**File**: `photo-export/Managers/ExportManager.swift:173-281`
**Problem**: The catch block (line 273) never removes the `.tmp` file. The comment says "Attempt cleanup" but no code follows.
**Complication**: The `defer` at line 222 ends security-scoped access before the catch block executes. Temp file deletion without scoped access can silently fail on sandboxed external drives.
**Fix**:
1. Hoist `var tempURL: URL? = nil` before the `do {` block so it's visible in `catch`.
2. Move the temp cleanup **inside the do-block** as a second `defer` (after the scoped-access defer), so it runs while scoped access is still active:
```swift
defer {
  if let tempURL, FileManager.default.fileExists(atPath: tempURL.path) {
    try? FileManager.default.removeItem(at: tempURL)
  }
}
```
This runs after `writeResource` but before `endScopedAccess`, and covers all failure paths (write failure, move failure, timestamp failure).

### 1.3 — Crash-safe snapshot compaction
**File**: `photo-export/Managers/ExportRecordStore.swift:326-337` (free function `writeSnapshotAndTruncate`)
**Problem**: `removeItem` then `moveItem` — crash between them loses the snapshot.
**Complication**: `FileManager.replaceItemAt(_:withItemAt:)` requires the target to exist. On first compaction, no snapshot file exists yet.
**Fix**: Branch on existence:
```swift
if fileManager.fileExists(atPath: snapshotFileURL.path) {
  _ = try fileManager.replaceItemAt(snapshotFileURL, withItemAt: tmpURL)
} else {
  try fileManager.moveItem(at: tmpURL, to: snapshotFileURL)
}
```
The first-ever compaction uses `moveItem` (safe — no prior snapshot to lose). Subsequent compactions use atomic `replaceItemAt`.

### 1.4 — Fix AssetDetailView export status (always nil)
**File**: `photo-export/Views/AssetDetailView.swift:8`
**Problem**: Uses `@Environment(\.exportRecordStore)` but the custom key is never injected via `.environment(...)`.
**Resolution**: Delete TestPhotoAccessView first (reorder: do 2.1 before 1.4), then do a single clean migration to `@EnvironmentObject`. This avoids the two-step churn of temporarily adding `.environment(\.exportRecordStore, ...)` then removing it.
**Reordered steps**:
1. Delete `TestPhotoAccessView.swift` (moved from 2.1 to here — it's dead code with no dependents in the main app).
2. Change `AssetDetailView` line 8 to `@EnvironmentObject private var exportRecordStore: ExportRecordStore`.
3. Remove the `ExportRecordStoreKey` + extension from `ContentView.swift:13-22`.

---

## Phase 2: Dead Code Removal

Each deletion is verified unreferenced before removing. Build after each.

### 2.1 — Delete `fetchAssetsByYearAndMonth()`
**File**: `photo-export/Managers/PhotoLibraryManager.swift:57-104`
**Why**: After 1.4 deleted TestPhotoAccessView, this method has zero callers. It loaded the entire library into memory — the app uses per-month `fetchAssets(year:month:)` instead.

### 2.2 — Delete `MainView` struct
**File**: `photo-export/ContentView.swift:419-484`
**Why**: Body says "Deprecated MainView". Never instantiated. Also delete the trailing comment on line 484.

### 2.3 — Delete `InfoPlist.swift`
**File**: `photo-export/InfoPlist.swift`
**Why**: `register()` is a no-op (loop body commented out). Never imported or called. `NSPhotoLibraryUsageDescription` is in Xcode target build settings.

### 2.4 — Delete `AssetMetadata` model and `extractAssetMetadata()`
**Files**: `photo-export/Models/AssetMetadata.swift` (entire file), `photo-export/Managers/PhotoLibraryManager.swift:252-262`
**Why**: Never used. All code reads `PHAsset` properties directly.

### 2.5 — Remove unused `isShowingAuthorizationView` state
**File**: `photo-export/ContentView.swift:27`
**Why**: Set on line 134, never read. Auth gate uses `photoLibraryManager.isAuthorized` directly.

**Verify entire phase**: Build succeeds, all tests pass.

---

## Phase 3: Code Quality Fixes

### 3.1 — Extract shared `monthName` helper
**Problem**: Duplicated in ContentView, MonthRow, MonthContentView (3 remaining after TestPhotoAccessView deletion).
**Fix**: New file `photo-export/Helpers/MonthFormatting.swift`:
```swift
import Foundation

func monthName(for month: Int) -> String {
  let formatter = DateFormatter()
  formatter.dateFormat = "MMMM"
  guard let date = Calendar.current.date(from: DateComponents(year: 2023, month: month)) else {
    return "\(month)"
  }
  return formatter.string(from: date)
}
```
Uses guard-let (not force unwrap) matching the safer pattern from `ContentView.swift:272-276`. Replace all 3 call sites.

### 3.2 — Concurrency cleanup for `PhotoLibraryManager`
**File**: `photo-export/Managers/PhotoLibraryManager.swift:7`
**Problem**: Has `@Published` properties read by SwiftUI but no class-level actor isolation. Individual methods annotated inconsistently.

**Why NOT class-wide `@MainActor`**: The manager contains heavy fetch loops (`fetchAssets` at line 106-175, `countAssets` at 177-223, `availableYears` at 225-249) that do real work. Making the entire class `@MainActor` pins these to the main thread, risking UI hitches on large libraries.

**Why NOT per-property `@MainActor`**: Fetch methods synchronously read `isAuthorized` in guard statements (lines 110, 179, 203, 227). If `isAuthorized` is `@MainActor`-isolated but the method is not, the compiler rejects the synchronous read. Splitting isolation at the property level creates a cascade of compile errors.

**Fix** (class-wide `@MainActor` + explicit background dispatch for heavy work):
1. Add `@MainActor` to the class declaration. This is the only approach that keeps guard reads of `isAuthorized` valid while satisfying the compiler.
2. For heavy fetch methods (`fetchAssets`, `countAssets`, `availableYears`): wrap the actual Photos framework query + loop in an explicit background dispatch to avoid main thread hitching:
```swift
@MainActor
func fetchAssets(year: Int, month: Int? = nil, ...) async throws -> [PHAsset] {
  guard isAuthorized else { throw ... }  // MainActor read — valid
  // Heavy work on background
  return try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
      // ... batch loop ...
      continuation.resume(returning: assets)
    }
  }
}
```
This keeps the guard on MainActor (valid) while moving the expensive Photos query off-main.
3. Remove redundant per-method `@MainActor` from `loadThumbnail` and `requestFullImage`.
4. In `requestAuthorization()`, replace `await MainActor.run { ... }` with direct property assignment (already on MainActor).

### 3.3 — Break up `export(job:)` method and prepare helper visibility for Phase 4
**File**: `photo-export/Managers/ExportManager.swift:173-281`
**Fix**: Extract private helpers. Keep `export(job:)` as orchestrator:
- `resolveAsset(id:) -> PHAsset?` — wraps `PHAsset.fetchAssets(withLocalIdentifiers:)`. Stays private for now (will become a protocol call in Phase 4.5).
- `selectPrimaryResource(from:) -> PHAssetResource?` — already exists at line 284, change from `private` to `internal`. **Note**: In Phase 4.5, the signature will change to accept `[ExportableResource]` and return `ExportableResource?`. This is an explicit migration step in 4.5, not a conflict.
- `uniqueFileURL(in:baseName:ext:) -> URL` — already non-private, already testable.

---

## Phase 4: Protocol Extraction + Testability

**Risk**: High. Touches ExportManager init, all injection sites, introduces new types. Commit protocol + conformance separately from tests.

### 4.1 — Define domain wrapper types
**New file**: `photo-export/Models/ExportableAsset.swift`
```swift
import Foundation

/// Lightweight value type decoupled from PHAsset for testability
struct ExportableAsset: Identifiable, Equatable {
  let id: String            // PHAsset.localIdentifier
  let creationDate: Date?
  let mediaType: MediaKind
  let pixelWidth: Int
  let pixelHeight: Int

  enum MediaKind: Int, Codable {
    case image, video, audio, unknown
  }
}

/// Represents an exportable resource (decoupled from PHAssetResource)
struct ExportableResource: Equatable {
  let type: ResourceKind
  let originalFilename: String
  /// Opaque token that the PhotoLibraryProviding implementation uses to
  /// resolve the exact PHAssetResource. Treated as an opaque blob by
  /// ExportManager — never parsed, only passed back to writeResource().
  /// The provider creates it; ExportManager stores and returns it.
  /// Tests can use any arbitrary string (e.g. "mock-token-1").
  let resourceToken: String

  enum ResourceKind: Int {
    case photo, video, alternatePhoto, fullSizePhoto, other
  }
}
```
**Token design**: `resourceToken` is an **opaque passthrough** — ExportManager never inspects or parses it. Only the `PhotoLibraryProviding` implementation creates and consumes it. The real implementation can use any encoding it wants (index, UUID, serialized struct) without collision or parsing concerns. ExportManager just stores the token and passes it back to `writeResource`.

### 4.2 — Extract `PhotoLibraryProviding` protocol
**New file**: `photo-export/Protocols/PhotoLibraryProviding.swift`
```swift
protocol PhotoLibraryProviding: AnyObject {
  var isAuthorized: Bool { get }
  func fetchExportableAssets(year: Int, month: Int?) async throws -> [ExportableAsset]
  func fetchResources(for assetId: String) -> [ExportableResource]
  func writeResource(_ resource: ExportableResource, to url: URL) async throws
}
```
**Not `@MainActor`**: The protocol is non-isolated. Fetch and write operations are potentially expensive and should not be forced onto MainActor by the protocol contract. The concrete `PhotoLibraryManager` implementation is `@MainActor` (from Phase 3.2) but its heavy work dispatches to background. Callers from ExportManager (itself `@MainActor`) will `await` these calls, which is correct.

### 4.3 — Extract `ExportDestinationProviding` protocol
**New file**: `photo-export/Protocols/ExportDestinationProviding.swift`
```swift
protocol ExportDestinationProviding: AnyObject {
  var canExportNow: Bool { get }
  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL
  func beginScopedAccess() -> Bool
  func endScopedAccess()
}
```
Also non-isolated. ExportManager calls these from `@MainActor` context anyway.

### 4.4 — Make existing managers conform
- `PhotoLibraryManager`: Add `PhotoLibraryProviding` conformance. Implement:
  - `fetchExportableAssets`: wraps existing `fetchAssets` + maps `PHAsset` → `ExportableAsset`
  - `fetchResources`: wraps `PHAssetResource.assetResources(for:)`, maps to `ExportableResource`. Token creation is internal to this method — ExportManager never sees the encoding.
  - `writeResource`: uses `resourceToken` (opaque to caller) to look up the `PHAssetResource`, then calls `PHAssetResourceManager.writeData`
- `ExportDestinationManager`: Add `ExportDestinationProviding` conformance (existing methods already match the protocol).

### 4.5 — Update `ExportManager` to depend on protocols + migrate helpers
Replace concrete types with protocol types in stored properties and init:
```swift
private let photoLibraryManager: any PhotoLibraryProviding
private let exportDestinationManager: any ExportDestinationProviding
```
Specific migrations in this step:
1. Remove `resolveAsset(id:)` — replaced by `photoLibraryManager.fetchResources(for:)` and `photoLibraryManager.writeResource(_:to:)`
2. Migrate `selectPrimaryResource(from: [PHAssetResource])` → `selectPrimaryResource(from: [ExportableResource]) -> ExportableResource?` using `ExportableResource.ResourceKind`
3. Remove direct calls to `PHAsset.fetchAssets(withLocalIdentifiers:)` and `PHAssetResource.assetResources(for:)` — all Photos interaction goes through protocol
4. **Timestamp preservation**: `ExportJob` already has `year` and `month`, but the current code uses `asset.creationDate` for file timestamps (ExportManager.swift:256). After migration, `PHAsset` is no longer available at export time. Fix: add `creationDate: Date?` to `ExportJob`. Populate it from `ExportableAsset.creationDate` during `enqueueMonth`/`enqueueYear`. The `export(job:)` method uses `job.creationDate` instead of `asset.creationDate` for `FileIOService.applyTimestamps`.

### 4.6 — Add test infrastructure to `ExportManager`
**Problem**: Queue processing is fire-and-forget `Task`-based (lines 41-53, 160-165). Tests cannot deterministically wait for the queue to drain without sleeping/polling, making assertions flaky.
**Fix**: Add an internal `AsyncStream`-based notification:
```swift
// Internal: fires each time a job completes (success or failure)
private var jobCompletionContinuation: AsyncStream<Void>.Continuation?
private(set) var jobCompletionStream: AsyncStream<Void>?

/// Call once before starting exports in tests.
func enableJobCompletionStream() {
  let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
  jobCompletionStream = stream
  jobCompletionContinuation = continuation
}
```
In `processNext()`, after each job completes: `jobCompletionContinuation?.yield(())`. When queue drains: `jobCompletionContinuation?.finish()`.

Tests consume the stream to wait for exactly N completions, with a timeout:
```swift
func awaitJobCompletions(_ count: Int, timeout: Duration = .seconds(5)) async throws {
  guard let stream = exportManager.jobCompletionStream else { return }
  var remaining = count
  for await _ in stream {
    remaining -= 1
    if remaining <= 0 { break }
  }
}
```
This handles the paused state correctly: no job completes → stream doesn't yield → test can assert queue state without hanging.

### 4.7 — Add `ExportManager` unit tests
**New file**: `photo-exportTests/ExportManagerTests.swift`
Create `MockPhotoLibrary: PhotoLibraryProviding` and `MockExportDestination: ExportDestinationProviding`. Tests:
- Queue management: `startExportMonth` enqueues only unexported assets, `pause()` stops processing, `resume()` continues, `cancelAndClear()` resets all state. Use `jobCompletionStream` for deterministic assertions.
- `uniqueFileURL()`: collision avoidance (create files in temp dir, verify suffixes)
- `selectPrimaryResource()`: priority ordering with `[ExportableResource]` arrays (now `internal` with `ExportableResource` signature from 4.5)
- Export flow: mock library returns assets, mock destination returns temp dir, verify `ExportRecordStore` gets `markExported` calls
- Timestamp: verify `job.creationDate` is passed through to `FileIOService.applyTimestamps`

### 4.8 — Add `ExportDestinationManager` tests
**New file**: `photo-exportTests/ExportDestinationManagerTests.swift`
**Test seam**: Extract the validation and directory-creation logic that `urlForMonth` depends on into a testable path. The real class has these properties (from `ExportDestinationManager.swift`):
- `selectedFolderURL: URL?` (private(set), line 10)
- `isAvailable: Bool` (private(set), line 11)
- `isWritable: Bool` (private(set), line 12)
- `destinationId: String?` (private(set), line 14)
- `bookmarkDefaultsKey: String` (private let, line 17)

**Approach**: Add an `internal` convenience initializer for tests that bypasses NSOpenPanel/bookmark restoration:
```swift
/// Test-only initializer; bypasses bookmark restoration and volume observation.
internal convenience init(testFolderURL: URL) {
  self.init()
  // Override state set by init()'s restoreBookmarkIfAvailable()
  self.selectedFolderURL = testFolderURL
  self.isAvailable = true
  self.isWritable = true
  self.destinationId = "test-destination"
  self.statusMessage = nil
}
```
This works because the default `init()` already exists and sets up the properties. The convenience init calls it, then overrides the relevant state. `bookmarkDefaultsKey` stays as-is (unused in tests since we don't save/restore). `volumeObservers` are set by `init()` but harmless in tests.

Tests: `urlForMonth` validation (invalid year → error, month 0 → error, month 13 → error, path too long → error), `ensureDirectoryExists` creates directories in temp folder, `clearSelection` resets all state to nil.

---

## Phase 5: Edge Case Hardening

### 5.1 — Handle `.limited` photo authorization
**File**: `photo-export/Managers/PhotoLibraryManager.swift`
**Fix**:
1. Line 30: Change `isAuthorized = authorizationStatus == .authorized` to `isAuthorized = [.authorized, .limited].contains(authorizationStatus)`
2. Add `@Published var isLimited: Bool = false` — set alongside `isAuthorized`.
3. In `requestAuthorization()` (line 53): Update return value to `status == .authorized || status == .limited` to match the `isAuthorized` property contract. This prevents state/return divergence.
**File**: `photo-export/ContentView.swift` — Add a subtle info banner below the navigation title when `photoLibraryManager.isLimited`, explaining only selected photos are available.

---

## Execution Order & Safety

| Step | Risk | Actual test coverage | Rollback |
|------|------|---------------------|----------|
| Phase 1 (bug fixes) | Low | ExportRecordStoreTests for 1.3; others verified by build only | `git revert` per commit |
| Phase 2 (dead code) | Very low | Build verification (deleting unreferenced code) | `git revert` |
| Phase 3 (quality) | Low-Medium | Build + ExportRecordStoreTests. 3.2 changes async dispatch patterns — verify no UI regressions manually | `git revert` |
| Phase 4 (protocols) | **High** — actor boundaries, type migration, constructor changes, new test infra | New tests validate protocol seams + ExportManager logic | Commit 4.1-4.5 (conformance) separate from 4.6-4.8 (tests) |
| Phase 5 (edge cases) | Low | Build verification; manual test with limited auth | `git revert` |

**After each phase**: `xcodebuild clean build` + `xcodebuild test` + manual smoke test (browse library, view detail pane export status, export a month).

---

## Files Modified (summary)

| File | Phases |
|------|--------|
| `Managers/PhotoLibraryManager.swift` | 1.1, 2.1, 2.4, 3.2, 4.4, 5.1 |
| `Managers/ExportManager.swift` | 1.2, 3.3, 4.5, 4.6 |
| `Managers/ExportRecordStore.swift` | 1.3 |
| `Managers/ExportDestinationManager.swift` | 4.4, 4.8 |
| `Views/AssetDetailView.swift` | 1.4 |
| `ContentView.swift` | 1.4, 2.2, 2.5, 3.1, 5.1 |
| `Views/MonthContentView.swift` | 3.1 |
| `Views/TestPhotoAccessView.swift` | 1.4 (delete — moved early to unblock AssetDetailView fix) |
| `InfoPlist.swift` | 2.3 (delete) |
| `Models/AssetMetadata.swift` | 2.4 (delete) |
| **New**: `Models/ExportableAsset.swift` | 4.1 |
| **New**: `Protocols/PhotoLibraryProviding.swift` | 4.2 |
| **New**: `Protocols/ExportDestinationProviding.swift` | 4.3 |
| **New**: `Helpers/MonthFormatting.swift` | 3.1 |
| **New**: `photo-exportTests/ExportManagerTests.swift` | 4.7 |
| **New**: `photo-exportTests/ExportDestinationManagerTests.swift` | 4.8 |

## Verification

After all phases:
1. `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' clean build`
2. `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' test`
3. Manual: launch app → browse years/months → view detail (verify export status shows) → select destination → export a month → pause/resume/cancel → check `.limited` auth banner if applicable
