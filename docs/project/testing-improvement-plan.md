# Testing Improvement Plan

Current state: **54 tests in 8 suites, 17.65% code coverage.** Pure logic and persistence are well covered; the real app behavior — export pipeline, import matching, UI — is not.

---

## Current Coverage Summary

| Component | Coverage | Tests | Verdict |
|-----------|----------|-------|---------|
| ExportRecordStore | High | 14 | Solid — persistence, replay, corruption, isolation, coalescing |
| BackupScanner (parsing) | Good | 17 | Scanning and parsing covered; matching algorithm not |
| ExportManager helpers | Partial (7.5%) | 10 | Only `splitFilename`, `uniqueFileURL`, queue counters |
| ContinuationResume pattern | Complete | 4 | Concurrent lock safety verified |
| Authorization mapping | Complete | 5 | All `PHAuthorizationStatus` values |
| MonthFormatting | Complete | 2 | Edge cases included |
| Temp file cleanup | Complete | 2 | Defer pattern verified |
| ExportManager core | 0% | 0 | Entire export pipeline untested |
| FileIOService | 0% | 0 | Atomic move, timestamps untested |
| PhotoLibraryManager | 3.8% | 0 | Only auth mapping, no asset logic |
| ExportDestinationManager | Low | 5 | Only input validation guards |
| MonthViewModel | 0% | 0 | All async loading untested |
| All Views | 0% | 0 | UI tests are template stubs |

---

## Step 1: Fix Low-Signal Existing Tests

Before adding new tests, fix the ones that give false confidence.

### 1a. ExportDestinationValidationTests

`ExportDestinationValidationTests.swift` claims to test `.invalidYear` / `.invalidMonth`, but all cases fail earlier on the "no folder selected" guard. Split into two groups:
- Tests with no folder selected (test that specific error)
- Tests with a folder set but invalid year/month values (test the actual validation)

### 1b. TempFileCleanupTests

`TempFileCleanupTests.swift` reimplements a local defer pattern instead of exercising the production cleanup in `ExportManager.export()`. Either:
- Rewrite to call the real production code path, or
- Delete and replace with an integration test that covers the export cleanup (Step 3)

### 1c. MonthFormattingTests

`MonthFormattingTests.swift` hard-codes English month names against locale-sensitive `Calendar` code. Fix by either:
- Pinning the locale in the test (`Locale(identifier: "en_US")`)
- Asserting non-empty strings rather than exact English values

---

## Step 2: App-Owned Abstractions and Protocol Seams

The highest-risk code is the hardest to test because managers use Photos framework types (`PHAsset`, `PHAssetResource`, `PHAssetResourceManager`) directly. Wrapping these behind thin protocols is not enough — `PHAsset` leaks into `MonthViewModel.assets`, views (`ThumbnailView`, `AssetDetailView`), and the export path. The fix is to introduce **app-owned value types** that replace `PHAsset`/`PHAssetResource` at the boundary, plus injectable protocols for I/O.

### 2a. App-owned asset/resource types

Create lightweight value types that replace `PHAsset` and `PHAssetResource` in all non-framework code:

```swift
/// Replaces PHAsset across the app boundary
struct AssetDescriptor: Identifiable, Sendable {
  let id: String                    // localIdentifier
  let creationDate: Date?
  let mediaType: PHAssetMediaType   // keep the enum, it's just an int
  let pixelWidth: Int
  let pixelHeight: Int
  let duration: TimeInterval        // needed by current detail UI for videos
}

/// Replaces PHAssetResource in the export path
struct ResourceDescriptor: Sendable {
  let type: PHAssetResourceType     // keep the enum
  let originalFilename: String
}
```

`PhotoLibraryManager` produces these from real `PHAsset`/`PHAssetResource` objects. All downstream consumers — `MonthViewModel`, views, `ExportManager` — work with the descriptors instead. This removes the direct Photos dependency from the test boundary entirely.

**Migration scope:** `MonthViewModel.assets: [PHAsset]` → `[AssetDescriptor]`, thumbnail keying stays on `id` (already `String`), views swap `PHAsset` params for `AssetDescriptor`, `ExportManager.export()` receives descriptors instead of fetching `PHAsset` inline.

If a screen still needs richer metadata than `AssetDescriptor` should carry — for example filename or file size in the detail panel — add a separate app-owned detail type such as `AssetDetails` and load it through `PhotoLibraryService`. Do not pass raw `PHAssetResource` back into views.

### 2b. PhotoLibraryService protocol

Now that the return types are app-owned, the protocol is straightforward:

```swift
protocol PhotoLibraryService {
  func fetchAssets(year: Int, month: Int, mediaTypes: [PHAssetMediaType]) -> [AssetDescriptor]
  func countAssets(year: Int, month: Int) -> Int
  func availableYears() -> [Int]
  func loadThumbnail(for assetId: String, size: CGSize) async -> NSImage?
  func requestFullImage(for assetId: String) async throws -> NSImage
  func resources(for assetId: String) -> [ResourceDescriptor]
}
```

`PhotoLibraryManager` conforms. Tests inject a `FakePhotoLibraryService` returning canned descriptors and images — no `PHAsset` instances needed anywhere in the test target.

### 2c. AssetResourceWriter protocol

The export path calls `PHAssetResource.assetResources(for:)` and `PHAssetResourceManager.default().writeData(...)` directly (ExportManager lines 316, 441–465). These need their own seam:

```swift
protocol AssetResourceWriter {
  func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL) async throws
}
```

Production implementation wraps `PHAssetResourceManager`. The fake records calls and can inject write failures.

### 2d. FileSystemService protocol

Extract from `FileIOService` and direct `FileManager` usage in `ExportManager`:

```swift
protocol FileSystemService {
  func moveItemAtomically(from src: URL, to dst: URL) throws
  func applyTimestamps(to url: URL, creationDate: Date?, modificationDate: Date?) throws
  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
  func fileExists(atPath: String) -> Bool
  func removeItem(at url: URL) throws
}
```

`FileIOService` conforms. Tests inject a `FakeFileSystem` that records calls and can simulate failures.

### 2e. ExportDestination protocol

Extract from `ExportDestinationManager`:

```swift
protocol ExportDestination {
  var selectedFolderURL: URL? { get }
  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL
  func beginScopedAccess() -> URL?
  func endScopedAccess(for url: URL)
}
```

---

## Step 3: Test the Export Pipeline (High Priority)

**Target:** `ExportManager.swift` — currently 7.54% coverage.

With protocol seams from Step 2, write manager-level integration tests using temp directories and fakes.

### Test cases needed:

| Scenario | What it validates |
|----------|-------------------|
| **Export happy path** | Asset descriptor resolved → resource selected → file written → timestamps applied → record marked done |
| **Missing asset descriptor** | `PhotoLibraryService` cannot resolve queued asset ID → error recorded, queue continues |
| **No exportable resource** | Asset descriptor exists but `resources(for:)` returns no eligible resource → marked failed with reason |
| **Write failure** | `writeResource` throws → temp file cleaned up, record marked failed |
| **Atomic move failure** | `moveItemAtomically` throws → record marked failed, no partial file left |
| **Timestamp application failure** | Move succeeds but timestamp fails → record still marked done (logged warning) |
| **Cancellation after markInProgress** | Cancel mid-export → generation check triggers early exit, pending items cleared |
| **Pause/resume cycle** | Pause stops `processNext`, resume restarts it |
| **Queue draining** | Multiple months enqueued → all processed in order → `isExporting` becomes false |
| **Duplicate skipping** | Already-exported asset not re-enqueued |
| **Generation counter** | Old generation tasks exit cleanly when a new export starts |

### Test cases for import rebuild:

| Scenario | What it validates |
|----------|-------------------|
| **Import happy path** | Scan → match → records created with correct metadata |
| **Import cancellation** | Cancel during scan → partial results discarded |
| **Import with no matches** | All files unmatched → zero records created, stats reported |

---

## Step 4: Test BackupScanner Matching (High Priority)

**Target:** `BackupScanner.matchFiles()` (line 190+), `matchSingleFile()` (line 330+), `discriminateByFileMetadata()` (line 414+).

Current tests cover parsing but stop before the matching algorithm.

### Test cases needed:

| Scenario | What it validates |
|----------|-------------------|
| **Exact date match** | File creation date within ±1s of asset → matched |
| **Ambiguous date match** | Multiple assets share the same second → falls through to filename refinement |
| **Filename refinement** | Original filename in asset resources matches file on disk → disambiguated |
| **Filename-only fallback** | No date match but filename matches exactly one asset → matched |
| **Unmatched file** | No date or filename match → reported as unmatched |
| **Adjacent-month rollover** | Photo taken Dec 31 23:59 stored in Jan folder → adjacent month fetch finds it |
| **Rotated image dimensions** | Width/height swapped due to EXIF rotation → discriminator handles both orientations |
| **Video duration tolerance** | Duration matches within acceptable tolerance → matched |
| **Multiple candidates** | Several assets match date → lazy discriminator called to narrow down |

These tests need real (tiny) image/video fixture files for metadata reading, or a protocol seam around `imagePixelDimensions()` / `videoDuration()`.

---

## Step 5: Test ExportRecordStore Recovery Paths (Medium Priority)

**Target:** Snapshot compaction (line 263+) and snapshot+log overlay (line 91+, line 350+).

Current tests cover normal operations but skip recovery edge cases.

### Test cases needed:

| Scenario | What it validates |
|----------|-------------------|
| **Compaction trigger** | After 1000 mutations → snapshot written, log truncated |
| **Compaction crash recovery** | Snapshot write interrupted → next load falls back to log replay |
| **Snapshot + log overlay** | Snapshot has 50 records, log has 10 mutations → final state correct |
| **Corrupted snapshot** | JSON parse fails → falls back to empty state + log replay |
| **Empty snapshot + populated log** | First compaction not yet triggered → all state from log |
| **Permission error on write** | Disk permissions prevent snapshot write → graceful degradation |

---

## Step 6: Test MonthViewModel (Medium Priority)

**Target:** `MonthViewModel.swift` — 0% coverage, complex async state.

Requires `PhotoLibraryService` fake from Step 2.

### Test cases needed:

| Scenario | What it validates |
|----------|-------------------|
| **loadAssets happy path** | Assets fetched → thumbnails loaded → first asset selected |
| **Thumbnail failure** | Load fails → asset added to `failedThumbnailIds` → retry works |
| **HQ upgrade** | Background task upgrades thumbnails after initial load |
| **HQ skipped during export** | Network access blocked while `isExporting` is true |
| **Month change cancellation** | Changing month cancels previous load task |
| **Empty month** | No assets → empty state, no errors |

---

## Step 7: Test ExportDestinationManager (Medium Priority)

### Test cases needed:

| Scenario | What it validates |
|----------|-------------------|
| **Bookmark round-trip** | Save bookmark → restore → URL matches |
| **Stale bookmark** | Bookmark data resolves with `isStale` flag → re-saved |
| **validate() cascade** | URL unreachable → not directory → not writable → correct error at each stage |
| **Volume unmount** | Destination volume ejected → validation updates, error message shown |
| **Path length limit** | Path exceeding 1000 UTF-8 bytes → rejected |
| **Security-scoped access pairing** | begin/end always paired, even on error |

---

## Step 8: Add UI Tests and Run in CI (Lower Priority)

Current UI test target has only template stubs. The shared scheme and CI pipeline skip the UI bundle entirely.

### 8a. Add deterministic UI test mode

Before adding CI XCUI coverage, make the app launch into a predictable fake-data mode.

Add a small composition root for UI tests:
- Launch argument or environment variable (for example `UI_TEST_MODE=1`)
- `photo_exportApp` checks for that flag at startup
- App injects fake `PhotoLibraryService`, fake `ExportDestination`, fake `ExportRecordStore` seed data, and a no-op folder picker/resource writer
- UI tests never depend on the real Photos library, `NSOpenPanel`, or local machine state

Without this harness, the flows below will be brittle and unsuitable for CI.

### 8b. Implement real XCUI test flows:

| Flow | Key assertions |
|------|----------------|
| **First launch / onboarding** | Onboarding view appears, folder picker works, export-all toggle |
| **Browse library** | Sidebar shows years/months, selecting month loads thumbnails |
| **Select asset** | Clicking thumbnail shows detail view with metadata |
| **Export month** | Start export → progress shown → completion state |
| **Pause / resume / cancel** | Toolbar buttons toggle state correctly |
| **Import existing backup** | Import sheet opens, stages progress, results shown |

### 8c. Enable in CI:

- Add UI test bundle to the shared scheme's test action
- Add a separate CI job (or step) that runs UI tests — they're slower and may need a different `destination`
- Consider running UI tests only on PR merges (not every push) to keep CI fast

---

## Step 9: Add Test Infrastructure (Supporting)

### 9a. Test fixtures directory

Create `photo-exportTests/Fixtures/` for small test assets:
- Tiny JPEG (1x1) for image metadata tests
- Tiny MP4 for video duration tests
- Sample export-records snapshot JSON for recovery tests

### 9b. Shared test helpers

Extract common patterns into `photo-exportTests/TestHelpers/`:
- `makeTempDir()` / `cleanup()` (currently duplicated across test files)
- `FakePhotoLibraryService`, `FakeFileSystem`, `FakeExportDestination`, `FakeAssetResourceWriter` (from Step 2)
- Builder helpers for creating `ExportRecord` instances

### 9c. Test plan (optional)

Consider adding an `.xctestplan` file if tests grow complex enough to need selective runs or environment variable configuration.

---

## Suggested Execution Order

```
Step 1  Fix low-signal tests           (quick wins, improves trust in suite)
Step 2  Protocol seams                  (prerequisite for Steps 3, 4, 6)
Step 3  Export pipeline tests           (highest risk, highest value)
Step 4  BackupScanner matching tests    (second highest risk)
Step 5  ExportRecordStore recovery      (medium risk, moderate effort)
Step 6  MonthViewModel tests            (medium risk, needs Step 2)
Step 7  ExportDestinationManager tests  (medium risk, partially needs Step 2)
Step 8  UI tests + CI integration       (valuable but highest effort)
Step 9  Test infrastructure             (do incrementally alongside Steps 2-8)
```

Steps 1 and 2 can be done in parallel. Steps 3-7 can be tackled in any order once Step 2 is complete.
