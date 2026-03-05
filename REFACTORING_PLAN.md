# Photo Export — Refactoring Plan (v7)

## Context

Code review identified critical bugs, dead code, missing test coverage, and architectural gaps. This plan sequences fixes so each step is independently verifiable and never breaks the build.

**Guiding principle**: Fix bugs first, delete dead code (reduces surface area), then extract protocols + add tests.

**Decisions made**:
- `TestPhotoAccessView` is a dev-only debug view → **delete it** with dead code.
- Protocols will use **domain wrapper types** (not raw PHAsset) for true unit test isolation.
- `PhotoLibraryProviding` is **non-`@MainActor`** — only UI state updates are actor-isolated, not the protocol contract. To satisfy Swift 6 conformance rules, the `@MainActor` UI manager and the nonisolated protocol are implemented by **separate types** (split architecture).
- `ExportDestinationProviding` is **`@MainActor`** and conformed to by `@MainActor ExportDestinationManager` to avoid Swift 6 conformance-isolation errors.
- File **timestamps must be preserved** after protocol migration — `creationDate` is carried on `ExportJob`, populated from `ExportableAsset` during enqueue.
- `ExportManager` authorization has a **single source of truth**: injected `@MainActor isAuthorized` closure. No secondary manager coupling.
- `fetchResources(for:)` is **async** in `PhotoLibraryProviding` so export pipeline does not force synchronous resource lookups on MainActor.
- Destination tests use **dependency injection** (injected `UserDefaults` suite + init flags to skip bookmark restore and volume observers), not preprocessor guards.
- Domain wrapper enums use **explicit `init(from:)` mappers** with `switch` statements, not raw `Int` values, to prevent silent mis-mapping from Photos framework enums.
- `PhotoLibraryService` methods that return Photos reference types (`[PHAsset]`) use a dedicated background `DispatchQueue` + continuation, not `Task.detached`, to avoid Swift 6 `Sendable` violations.
- `ExportableResource.resourceToken` has a strict invariant: **unique within an asset and reversible** by `PhotoLibraryService.writeResource` (no best-effort matching).
- Async year/month loading in `ContentView` uses **cancellation + stale-result guards** to prevent out-of-order task completions from overwriting newer state.
- Export auth revocation has explicit policy: if authorization is lost while queue is active, **cancel queue immediately**, mark in-progress job as failed (`"Authorization revoked"`), and drop pending jobs.
- `ExportManager` event stream has explicit per-run lifecycle: start of each export run creates a fresh stream; drain/cancel finishes that run’s stream.
- `PhotoLibraryService` uses separate queues for long fetches vs quick stats queries to avoid starvation.

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
**Resolution**: Delete TestPhotoAccessView first, then do a single clean migration to `@EnvironmentObject`.
**Reordered steps**:
1. Delete `TestPhotoAccessView.swift` — it's dead code with no dependents in the main app.
2. Change `AssetDetailView` line 8 to `@EnvironmentObject private var exportRecordStore: ExportRecordStore`.
3. Remove the `ExportRecordStoreKey` + extension from `ContentView.swift:13-22`.

---

## Phase 2: Dead Code Removal

Each deletion is verified unreferenced before removing. Build after each.

### 2.1 — Delete `fetchAssetsByYearAndMonth()`
**File**: `photo-export/Managers/PhotoLibraryManager.swift:57-104`
**Why**: After 1.4 deleted TestPhotoAccessView, this method has zero callers.

### 2.2 — Delete `MainView` struct
**File**: `photo-export/ContentView.swift:419-484`
**Why**: Body says "Deprecated MainView". Never instantiated. Also delete the trailing comment on line 484.

### 2.3 — Delete `InfoPlist.swift`
**File**: `photo-export/InfoPlist.swift`
**Why**: `register()` is a no-op (loop body commented out). Never imported or called.

### 2.4 — Delete `AssetMetadata` model and `extractAssetMetadata()`
**Files**: `photo-export/Models/AssetMetadata.swift` (entire file), `photo-export/Managers/PhotoLibraryManager.swift:252-262`
**Why**: Never used. All code reads `PHAsset` properties directly.

### 2.5 — Remove unused `isShowingAuthorizationView` state
**File**: `photo-export/ContentView.swift:27`
**Why**: Set on line 134, never read.

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

### 3.2 — Concurrency cleanup + split `PhotoLibraryManager`
**File**: `photo-export/Managers/PhotoLibraryManager.swift`

**Problem**: Has `@Published` properties read by SwiftUI but no class-level actor isolation. Individual methods annotated inconsistently. A class-wide `@MainActor` + nonisolated protocol conformance is a Swift 6 error.

**Fix** (split into two types):

1. **`PhotoLibraryManager`** stays `@MainActor`, owns UI state only:
```swift
@MainActor
final class PhotoLibraryManager: ObservableObject {
  @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
  @Published var isAuthorized: Bool = false
  @Published var isLimited: Bool = false  // added in Phase 5

  let service: PhotoLibraryService  // nonisolated fetch/write operations

  init() {
    self.service = PhotoLibraryService()
    verifyPhotoLibraryPermissions()
    authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    isAuthorized = authorizationStatus == .authorized
  }

  func requestAuthorization() async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    authorizationStatus = status
    isAuthorized = status == .authorized
    return status == .authorized
  }

  // Thumbnail/image loading stays here (UI-facing, uses PHCachingImageManager)
  func loadThumbnail(for asset: PHAsset, ...) async -> NSImage? { ... }
  func requestFullImage(for asset: PHAsset) async throws -> NSImage { ... }

  // Delegation for data queries — these check isAuthorized then delegate
  func fetchAssets(year: Int, month: Int?, ...) async throws -> [PHAsset] {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    return try await service.fetchAssets(year: year, month: month)
  }
  func countAssets(year: Int, month: Int) async throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    return try await service.countAssets(year: year, month: month)
  }
  func availableYears() async throws -> [Int] {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    return try await service.availableYears()
  }
}
```

2. **New file `photo-export/Managers/PhotoLibraryService.swift`** — nonisolated, does heavy Photos framework work off MainActor:
```swift
final class PhotoLibraryService {
  private let fetchQueue = DispatchQueue(
    label: "com.valtteriluoma.photo-export.photos.fetch",
    qos: .userInitiated
  )
  private let statsQueue = DispatchQueue(
    label: "com.valtteriluoma.photo-export.photos.stats",
    qos: .utility
  )

  func fetchAssets(year: Int, month: Int?, ...) async throws -> [PHAsset] {
    try await withCheckedThrowingContinuation { continuation in
      fetchQueue.async {
        do {
          // PHFetchOptions setup, PHAsset.fetchAssets, batch loop
          // ... existing logic from PhotoLibraryManager.fetchAssets ...
          continuation.resume(returning: assets)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func countAssets(year: Int, month: Int) async throws -> Int {
    try await withCheckedThrowingContinuation { continuation in
      statsQueue.async {
        do {
          // ... existing logic ...
          continuation.resume(returning: count)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func availableYears() async throws -> [Int] {
    try await withCheckedThrowingContinuation { continuation in
      statsQueue.async {
        do {
          // ... existing logic ...
          continuation.resume(returning: years)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
```
Why queue + continuation: `Task.detached` requires `Sendable` values and fails for `[PHAsset]` under Swift 6 strict checking. This approach keeps heavy work off-main without introducing `Sendable` violations.
Why separate queues: long-running month fetches must not starve lightweight stats calls (`countAssets`, `availableYears`) used by sidebar rendering.

3. **Migrate `countAssets` and `availableYears` from sync to async**. Current callers:
   - `ContentView.swift:136` — `years = (try? photoLibraryManager.availableYears()) ?? []`
   - `ContentView.swift:146` — same
   - `ContentView.swift:281` — `(try? photoLibraryManager.countAssets(year:month:)) ?? 0`

   These are called in `.onAppear` and `.onChange` closures. Migrate to async with cancellation + stale guards:
```swift
@State private var yearsTask: Task<Void, Never>?
@State private var yearsLoadToken: Int = 0
@State private var monthTasksByYear: [Int: Task<Void, Never>] = [:]
@State private var monthLoadTokenByYear: [Int: Int] = [:]

func reloadYears() {
  yearsTask?.cancel()
  yearsLoadToken += 1
  let token = yearsLoadToken
  yearsTask = Task {
    let fetched = (try? await photoLibraryManager.availableYears()) ?? []
    guard !Task.isCancelled else { return }
    guard yearsLoadToken == token else { return }  // stale completion guard
    years = fetched
  }
}

func computeMonthsWithAssets(for year: Int) async -> [Int] {
  var months: [Int] = []
  for month in 1...12 {
    let count = (try? await photoLibraryManager.countAssets(year: year, month: month)) ?? 0
    assetCountsByYearMonth["\(year)-\(month)"] = count
    if count > 0 { months.append(month) }
  }
  return months
}

func loadMonths(for year: Int) {
  monthTasksByYear[year]?.cancel()
  let nextToken = (monthLoadTokenByYear[year] ?? 0) + 1
  monthLoadTokenByYear[year] = nextToken

  monthTasksByYear[year] = Task {
    let months = await computeMonthsWithAssets(for: year)
    guard !Task.isCancelled else { return }
    guard monthLoadTokenByYear[year] == nextToken else { return }  // stale guard
    monthsWithAssetsByYear[year] = months
  }
}

// onDisappear cleanup
.onDisappear {
  yearsTask?.cancel()
  monthTasksByYear.values.forEach { $0.cancel() }
}
```
   Call sites in `.onAppear` / `.onChange` should call `reloadYears()` and `loadMonths(for:)`, not ad-hoc `Task {}` blocks.

### 3.3 — Break up `export(job:)` method and prepare helper visibility for Phase 4
**File**: `photo-export/Managers/ExportManager.swift:173-281`
**Fix**: Extract private helpers. Keep `export(job:)` as orchestrator:
- `resolveAsset(id:) -> PHAsset?` — wraps `PHAsset.fetchAssets(withLocalIdentifiers:)`. Stays private (becomes protocol call in 4.5).
- `selectPrimaryResource(from:) -> PHAssetResource?` — change from `private` to `internal`. In Phase 4.5, signature migrates to `[ExportableResource] -> ExportableResource?` as an explicit step.
- `uniqueFileURL(in:baseName:ext:) -> URL` — already non-private, already testable.

---

## Phase 4: Protocol Extraction + Testability

**Risk**: High. Touches ExportManager init, all injection sites, introduces new types. Commit protocol + conformance separately from tests.

### 4.1 — Define domain wrapper types
**New file**: `photo-export/Models/ExportableAsset.swift`
```swift
import Foundation
import Photos

/// Lightweight value type decoupled from PHAsset for testability
struct ExportableAsset: Identifiable, Equatable {
  let id: String            // PHAsset.localIdentifier
  let creationDate: Date?
  let mediaType: MediaKind
  let pixelWidth: Int
  let pixelHeight: Int

  /// Explicit mapping from Photos framework type — no raw-value coupling
  enum MediaKind: Codable, Equatable {
    case image, video, audio, unknown

    init(from type: PHAssetMediaType) {
      switch type {
      case .image: self = .image
      case .video: self = .video
      case .audio: self = .audio
      default:     self = .unknown
      }
    }
  }
}

/// Represents an exportable resource (decoupled from PHAssetResource)
struct ExportableResource: Equatable {
  let type: ResourceKind
  let originalFilename: String
  /// Opaque token that the PhotoLibraryProviding implementation uses to
  /// resolve the exact PHAssetResource. Treated as an opaque blob by
  /// ExportManager — never parsed, only passed back to writeResource().
  /// Tests can use any arbitrary string (e.g. "mock-token-1").
  let resourceToken: String

  /// Explicit mapping from Photos framework type — no raw-value coupling
  enum ResourceKind: Equatable {
    case photo, video, alternatePhoto, fullSizePhoto, other

    init(from type: PHAssetResourceType) {
      switch type {
      case .photo:          self = .photo
      case .video:          self = .video
      case .alternatePhoto: self = .alternatePhoto
      case .fullSizePhoto:  self = .fullSizePhoto
      default:              self = .other
      }
    }
  }
}
```
**Token design**: `resourceToken` is an **opaque passthrough** — ExportManager never inspects or parses it. Only the `PhotoLibraryProviding` implementation creates and consumes it.
Token invariant must be explicit and testable:
- unique within an asset resource list
- reversible without fuzzy matching
- stable for the lifetime of the export run

Concrete implementation rule:
```swift
// fetchResources(for:)
let resources = PHAssetResource.assetResources(for: asset)
return resources.enumerated().map { index, r in
  ExportableResource(
    type: .init(from: r.type),
    originalFilename: r.originalFilename,
    resourceToken: "\(asset.localIdentifier)#\(index)"
  )
}

// writeResource(_:to:)
let parts = resource.resourceToken.split(separator: "#", maxSplits: 1)
guard parts.count == 2, let index = Int(parts[1]) else { throw TokenError.invalid }
let assetId = String(parts[0])
let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
guard let asset = fetch.firstObject else { throw TokenError.assetNotFound }
let resources = PHAssetResource.assetResources(for: asset)
guard resources.indices.contains(index) else { throw TokenError.resourceNotFound }
let resolved = resources[index]
```
`writeResource` must fail hard on invalid token / missing resource (no fallback by filename/type).
**Enum design**: No `Int` raw values. Explicit `init(from:)` with exhaustive `switch` prevents silent mis-mapping from Photos enums.

### 4.2 — Extract `PhotoLibraryProviding` protocol
**New file**: `photo-export/Protocols/PhotoLibraryProviding.swift`
```swift
protocol PhotoLibraryProviding: AnyObject {
  func fetchExportableAssets(year: Int, month: Int?) async throws -> [ExportableAsset]
  func fetchResources(for assetId: String) async throws -> [ExportableResource]
  func writeResource(_ resource: ExportableResource, to url: URL) async throws
}
```
**Design**:
- **Non-`@MainActor`**: Protocol is nonisolated. This is critical for Swift 6 compatibility — the concrete `PhotoLibraryService` is also nonisolated, so conformance has no actor-isolation conflict.
- **Async `fetchResources`**: Resource lookup can perform Photos work and must not force synchronous execution on MainActor paths.
- **No `isAuthorized`**: Auth state lives on `@MainActor PhotoLibraryManager`, not on the protocol. ExportManager receives an injected auth closure (single source of truth), keeping protocol responsibilities focused on data operations only.

### 4.3 — Extract `ExportDestinationProviding` protocol
**New file**: `photo-export/Protocols/ExportDestinationProviding.swift`
```swift
@MainActor
protocol ExportDestinationProviding: AnyObject {
  var canExportNow: Bool { get }
  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL
  func beginScopedAccess() -> Bool
  func endScopedAccess()
}
```
`@MainActor` alignment with `ExportDestinationManager` avoids Swift 6 conformance-isolation errors for this UI-bound dependency.

### 4.4 — Make service/managers conform
- `PhotoLibraryService`: Add `PhotoLibraryProviding` conformance. Implement:
  - `fetchExportableAssets`: wraps existing `fetchAssets` + maps `PHAsset` → `ExportableAsset` using `MediaKind(from:)`
  - `fetchResources`: async wrapper around `PHAssetResource.assetResources(for:)`, mapped to `ExportableResource` using `ResourceKind(from:)`. Token creation is internal to this method.
  - `writeResource`: uses `resourceToken` to look up the `PHAssetResource`, then calls `PHAssetResourceManager.writeData`
- `ExportDestinationManager`: Add `ExportDestinationProviding` conformance (existing methods already match).

### 4.5 — Update `ExportManager` to depend on protocols + migrate helpers
Replace concrete types with protocol types in stored properties and init:
```swift
private let photoLibraryService: any PhotoLibraryProviding
private let exportDestinationManager: any ExportDestinationProviding
private let exportRecordStore: ExportRecordStore
private let isAuthorized: @MainActor () -> Bool
```
`ExportManager` does **not** keep a second manager reference. Auth checks use only the injected closure:
```swift
init(
  photoLibraryService: any PhotoLibraryProviding,
  exportDestinationManager: any ExportDestinationProviding,
  exportRecordStore: ExportRecordStore,
  isAuthorized: @escaping @MainActor () -> Bool
) {
  self.photoLibraryService = photoLibraryService
  self.exportDestinationManager = exportDestinationManager
  self.exportRecordStore = exportRecordStore
  self.isAuthorized = isAuthorized
}
```
In `enqueueMonth`/`enqueueYear`: `guard isAuthorized() else { return }`.
Composition root (`photo_exportApp.swift`) passes a single source of truth closure, e.g. `isAuthorized: { plm.isAuthorized }`.

Specific migrations:
1. Remove `resolveAsset(id:)` — replaced by `await photoLibraryService.fetchResources(for:)` and `photoLibraryService.writeResource(_:to:)`
2. Migrate `selectPrimaryResource(from: [PHAssetResource])` → `selectPrimaryResource(from: [ExportableResource]) -> ExportableResource?` using `ExportableResource.ResourceKind`
3. Remove direct calls to `PHAsset.fetchAssets(withLocalIdentifiers:)` and `PHAssetResource.assetResources(for:)` — all Photos interaction goes through `PhotoLibraryProviding`
4. **Timestamp preservation**: Add `creationDate: Date?` to `ExportJob`. Populate from `ExportableAsset.creationDate` during `enqueueMonth`/`enqueueYear`. `export(job:)` uses `job.creationDate` for `FileIOService.applyTimestamps`.
5. **Auth revocation policy (explicit)**:
   - Add `currentJob: ExportJob?` in `ExportManager` (set in `processNext`, clear after completion).
   - Add method `handleAuthorizationRevoked()`:
```swift
@MainActor
func handleAuthorizationRevoked() {
  currentTask?.cancel()
  currentTask = nil

  if let currentJob {
    exportRecordStore.markFailed(
      assetId: currentJob.assetLocalIdentifier,
      error: "Authorization revoked",
      at: Date()
    )
  }

  pendingJobs.removeAll()
  currentJob = nil
  isProcessing = false
  isRunning = false
  isPaused = false
  updateQueueCount()
  eventContinuation?.yield(.cancelled)
  eventContinuation?.finish()
}
```
   - Composition root (`photo_exportApp.swift`) hooks revocation:
```swift
.onChange(of: photoLibraryManager.isAuthorized) { _, newValue in
  if !newValue { exportManager.handleAuthorizationRevoked() }
}
```

### 4.6 — Add test infrastructure to `ExportManager`
**Problem**: Queue processing is fire-and-forget `Task`-based (lines 41-53, 160-165). Tests cannot deterministically wait for queue events without sleeping.
**Fix**: Add a typed `AsyncStream`-based event system with **per-run lifecycle**:
```swift
enum ExportQueueEvent: Equatable {
  case jobFinished(String)  // asset ID
  case paused
  case cancelled
  case drained
}

// Internal: fires for each queue lifecycle event
private var eventContinuation: AsyncStream<ExportQueueEvent>.Continuation?
private(set) var eventStream: AsyncStream<ExportQueueEvent>?

/// Call before each test run. Closes previous stream (if any) and opens a fresh one.
@discardableResult
func prepareEventStreamForNextRun() -> AsyncStream<ExportQueueEvent> {
  eventContinuation?.finish()
  let (stream, continuation) = AsyncStream.makeStream(of: ExportQueueEvent.self)
  eventStream = stream
  eventContinuation = continuation
  return stream
}
```
Emit points in existing code:
- `processNext()` after job completes: `eventContinuation?.yield(.jobFinished(job.assetLocalIdentifier))`
- `processNext()` when queue empty: `eventContinuation?.yield(.drained)` then `eventContinuation?.finish()`
- `pause()`: `eventContinuation?.yield(.paused)` (do NOT finish — stream stays open for resume)
- `cancelAndClear()`: `eventContinuation?.yield(.cancelled)` then `eventContinuation?.finish()`
- `resume()`: no event needed — next `jobFinished` confirms resumption
- At start of each new export run in tests, call `prepareEventStreamForNextRun()` to avoid reusing a finished stream from prior runs.

Test helper with **real timeout**:
```swift
enum ExportTestError: Error { case timedOut }

func awaitEvents(
  _ count: Int,
  from stream: AsyncStream<ExportQueueEvent>,
  timeout: UInt64 = 5_000_000_000
) async throws -> [ExportQueueEvent] {
  try await withThrowingTaskGroup(of: [ExportQueueEvent].self) { group in
    group.addTask {
      var collected: [ExportQueueEvent] = []
      for await event in stream {
        collected.append(event)
        if collected.count >= count { break }
      }
      return collected
    }
    group.addTask {
      try await Task.sleep(nanoseconds: timeout)
      throw ExportTestError.timedOut
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}
```
This handles all states: paused (yields `.paused` event), cancelled (yields `.cancelled` + finishes), drained (yields `.drained` + finishes). Stream lifecycle is deterministic per run. Tests never hang because the timeout task races the stream consumer.

### 4.7 — Add `ExportManager` unit tests
**New file**: `photo-exportTests/ExportManagerTests.swift`
Create mocks with explicit actor annotations:
```swift
final class MockPhotoLibrary: PhotoLibraryProviding { ... }   // nonisolated
@MainActor
final class MockExportDestination: ExportDestinationProviding { ... }
```
Mark test methods or the whole test type `@MainActor` when touching `ExportManager`/destination mocks.

Tests:
- Queue management: call `prepareEventStreamForNextRun()` per run; assert `pause()` → `.paused`, `resume()` → subsequent `.jobFinished`, `cancelAndClear()` → `.cancelled`
- `uniqueFileURL()`: collision avoidance (create files in temp dir, verify suffixes)
- `selectPrimaryResource()`: priority ordering with `[ExportableResource]` arrays (now `internal` with `ExportableResource` signature from 4.5)
- Export flow: mock library returns assets, mock destination returns temp dir, verify `ExportRecordStore` gets `markExported` calls
- Timestamp: verify `job.creationDate` is passed through to `FileIOService.applyTimestamps`
- Auth revocation: simulate `handleAuthorizationRevoked()` while queue active; assert in-progress asset marked failed with `"Authorization revoked"`, pending jobs cleared, `.cancelled` event emitted

### 4.8 — Add `ExportDestinationManager` tests
**New file**: `photo-exportTests/ExportDestinationManagerTests.swift`
**Test seam**: Inject dependencies to bypass production side effects. Modify `ExportDestinationManager` to accept injected `UserDefaults` and init flags:
```swift
@MainActor
final class ExportDestinationManager: ObservableObject {
  private let defaults: UserDefaults
  private let bookmarkDefaultsKey = "ExportDestinationBookmark"
  // ... existing @Published properties ...

  init(
    defaults: UserDefaults = .standard,
    restoreBookmark: Bool = true,
    observeVolumes: Bool = true
  ) {
    self.defaults = defaults
    if restoreBookmark { restoreBookmarkIfAvailable() }
    if observeVolumes { observeVolumeChanges() }
  }

  func clearSelection() {
    selectedFolderURL = nil
    isAvailable = false
    isWritable = false
    statusMessage = "No export folder selected"
    destinationId = nil
    defaults.removeObject(forKey: bookmarkDefaultsKey)  // uses injected defaults
  }

  // Test convenience init — no bookmark restore, no volume observers, isolated UserDefaults
  internal convenience init(testFolderURL: URL, defaultsSuiteName: String = "test.\(UUID())") {
    self.init(
      defaults: UserDefaults(suiteName: defaultsSuiteName)!,
      restoreBookmark: false,
      observeVolumes: false
    )
    selectedFolderURL = testFolderURL
    isAvailable = true
    isWritable = true
    destinationId = "test-destination"
    statusMessage = nil
  }
}
```
**Key changes from v5**:
- `defaults` is injected, not hardcoded `UserDefaults.standard` — `clearSelection` writes to the injected suite, never touching production state.
- `restoreBookmark: false` skips `restoreBookmarkIfAvailable()` — no production bookmark read.
- `observeVolumes: false` skips `observeVolumeChanges()` — no NSWorkspace notification observers.
- Default `init()` call site in `photo_exportApp.swift` passes no arguments, getting `.standard`/`true`/`true` defaults — zero change to production behavior.

Tests: `urlForMonth` validation (invalid year → error, month 0 → error, month 13 → error, path too long → error), `ensureDirectoryExists` creates directories in temp folder, `clearSelection` resets all state (writes only to test-suite `UserDefaults`).

---

## Phase 5: Edge Case Hardening

### 5.1 — Handle `.limited` photo authorization
**File**: `photo-export/Managers/PhotoLibraryManager.swift`
**Fix**:
1. Change `isAuthorized = authorizationStatus == .authorized` to `isAuthorized = [.authorized, .limited].contains(authorizationStatus)`
2. Add `@Published var isLimited: Bool = false` — set alongside `isAuthorized`.
3. In `requestAuthorization()`: Update return value to `status == .authorized || status == .limited` to match the `isAuthorized` property contract.
**File**: `photo-export/ContentView.swift` — Add a subtle info banner when `photoLibraryManager.isLimited`, explaining only selected photos are available.

---

## Execution Order & Safety

| Step | Risk | Actual test coverage | Rollback |
|------|------|---------------------|----------|
| Phase 1 (bug fixes) | Low | ExportRecordStoreTests for 1.3; others verified by build only | `git revert` per commit |
| Phase 2 (dead code) | Very low | Build verification (deleting unreferenced code) | `git revert` |
| Phase 3 (quality) | **Medium** — split architecture + sync→async migration touches many call sites | Build + ExportRecordStoreTests + manual smoke test for UI responsiveness | `git revert` |
| Phase 4 (protocols) | **High** — type migration, constructor changes, new test infra | New tests validate protocol seams + ExportManager logic | Commit 4.1-4.5 (conformance) separate from 4.6-4.8 (tests) |
| Phase 5 (edge cases) | Low | Build verification; manual test with limited auth | `git revert` |

**After each phase**: `xcodebuild clean build` + `xcodebuild test` + manual smoke test (browse library, view detail pane export status, export a month).

---

## Files Modified (summary)

| File | Phases |
|------|--------|
| `Managers/PhotoLibraryManager.swift` | 1.1, 2.1, 2.4, 3.2 (split), 5.1 |
| `Managers/ExportManager.swift` | 1.2, 3.3, 4.5, 4.6 |
| `Managers/ExportRecordStore.swift` | 1.3 |
| `Managers/ExportDestinationManager.swift` | 4.4, 4.8 (inject defaults + init flags) |
| `photo_exportApp.swift` | 4.5 (ExportManager init/wiring + `isAuthorized` closure injection) |
| `Views/AssetDetailView.swift` | 1.4 |
| `ContentView.swift` | 1.4, 2.2, 2.5, 3.1, 3.2 (async migration), 5.1 |
| `Views/MonthContentView.swift` | 3.1 |
| `Views/TestPhotoAccessView.swift` | 1.4 (delete) |
| `InfoPlist.swift` | 2.3 (delete) |
| `Models/AssetMetadata.swift` | 2.4 (delete) |
| **New**: `Managers/PhotoLibraryService.swift` | 3.2 |
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
