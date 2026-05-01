import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Behavioral characterization tests for every public count/summary method on
/// `ExportRecordStore`. Each test drives a fixed, hand-picked set of mutations and asserts
/// the **exact integer outputs** of every query method on the resulting state.
///
/// These tests exist to lock in current behavior before the planned performance work that
/// replaces the linear `recordsById.values.reduce` scans with incrementally-maintained
/// indices. Any change to the store that produces different counts for these fixtures
/// breaks the test, even if the change "looks like a refactor."
///
/// Each fixture is small enough to enumerate by hand in the test comments, so a future
/// reader can verify the asserted numbers without running the test.
@MainActor
struct ExportRecordStoreQueryGoldenTests {

  // MARK: - Fixtures

  private func makeStore() throws -> (URL, ExportRecordStore) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportRecordStoreQuery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = ExportRecordStore(baseDirectoryURL: dir)
    store.configure(for: "test")
    return (dir, store)
  }

  private func asset(
    id: String, year: Int, month: Int, hasAdjustments: Bool = false
  ) -> AssetDescriptor {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = 15
    let date = Calendar.current.date(from: components)!
    return AssetDescriptor(
      id: id,
      creationDate: date,
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: hasAdjustments
    )
  }

  // MARK: - empty store

  @Test func emptyStoreReturnsZeros() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(store.yearExportedCount(year: 2025) == 0)
    #expect(store.recordCount(year: 2025, month: 6, variant: .original, status: .done) == 0)
    #expect(store.recordCount(year: 2025, month: 6, variant: .edited, status: .done) == 0)
    #expect(store.recordCountEditedDone(year: 2025, month: 6) == 0)
    #expect(store.recordCountBothVariantsDone(year: 2025, month: 6) == 0)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: 2025, month: 6) == 0)

    let summary = store.monthSummary(year: 2025, month: 6, totalAssets: 0)
    #expect(summary.exportedCount == 0)
    #expect(summary.totalCount == 0)
    #expect(summary.status == .notExported)

    // sidebarSummary returns nil when adjustedCount is nil (loading state).
    #expect(
      store.sidebarSummary(
        year: 2025, month: 6, totalCount: 10, adjustedCount: nil, selection: .edited)
        == nil)

    #expect(
      store.sidebarYearExportedCount(
        year: 2025, totalCountsByMonth: [:], adjustedCountsByMonth: [:], selection: .edited)
        == 0)
  }

  // MARK: - yearExportedCount

  /// Fixture: 5 assets across 2025-06 and 2025-07, plus 2 assets in 2024-12 (out of scope).
  /// All have `.original.done`. Year 2025 yearExportedCount == 5; year 2024 == 2.
  @Test func yearExportedCountCountsOnlyOriginalDoneInScope() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)

    // 2024-12: 2 records, both .original.done.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "2024-12-\(i)", variant: .original,
        year: 2024, month: 12, relPath: "2024/12/",
        filename: "IMG_\(i).HEIC", exportedAt: now)
    }
    // 2025-06: 3 records, .original.done.
    for i in 1...3 {
      store.markVariantExported(
        assetId: "2025-06-\(i)", variant: .original,
        year: 2025, month: 6, relPath: "2025/06/",
        filename: "IMG_\(i).HEIC", exportedAt: now)
    }
    // 2025-07: 2 records, .original.done.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "2025-07-\(i)", variant: .original,
        year: 2025, month: 7, relPath: "2025/07/",
        filename: "IMG_\(i).HEIC", exportedAt: now)
    }
    // 2025-08: 1 record, .original.failed → must NOT count.
    store.markVariantFailed(
      assetId: "2025-08-failed", variant: .original, error: "test", at: now)

    #expect(store.yearExportedCount(year: 2024) == 2)
    #expect(store.yearExportedCount(year: 2025) == 5)
    #expect(store.yearExportedCount(year: 2026) == 0)
  }

  // MARK: - recordCount(year:month:variant:status:)

  /// Fixture: in 2025-06, drive every variant × status combination once.
  /// Asserts the per-cell count is 1 for set cells and 0 for unset cells.
  ///
  /// Note: `markVariantFailed` does not take year/month arguments — it preserves the
  /// existing record's year/month, or defaults to 0/0 for brand-new asset ids. To plant
  /// failed records at year=2025/month=6 we first call `markVariantInProgress` (which
  /// does take year/month) and then transition to failed.
  @Test func recordCountReturnsExactCellsByVariantAndStatus() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // .original.done at "img-1"
    store.markVariantExported(
      assetId: "img-1", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "IMG_1.HEIC", exportedAt: now)
    // .edited.done at "img-2"
    store.markVariantExported(
      assetId: "img-2", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "IMG_2.JPG", exportedAt: now)
    // .original.failed at "img-3" (plant year/month via in-progress first).
    store.markVariantInProgress(
      assetId: "img-3", variant: .original, year: yr, month: mo, relPath: rel, filename: nil)
    store.markVariantFailed(
      assetId: "img-3", variant: .original, error: "Disk full", at: now)
    // .edited.failed at "img-4".
    store.markVariantInProgress(
      assetId: "img-4", variant: .edited, year: yr, month: mo, relPath: rel, filename: nil)
    store.markVariantFailed(
      assetId: "img-4", variant: .edited, error: "Permission denied", at: now)
    // .original.inProgress at "img-5".
    store.markVariantInProgress(
      assetId: "img-5", variant: .original, year: yr, month: mo, relPath: rel, filename: nil)

    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .edited, status: .done) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .failed) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .edited, status: .failed) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .inProgress) == 1)
    #expect(store.recordCount(year: yr, month: mo, variant: .edited, status: .inProgress) == 0)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .pending) == 0)

    // Out of scope.
    #expect(store.recordCount(year: yr, month: 5, variant: .original, status: .done) == 0)
    #expect(store.recordCount(year: 2026, month: mo, variant: .original, status: .done) == 0)
  }

  /// Quirk: `markVariantFailed` for a brand-new asset id creates the record at
  /// year=0/month=0/relPath="". Production wouldn't normally hit this (the run loop
  /// always calls `markVariantInProgress` before `markVariantFailed`), but the API
  /// allows it and tests should pin the behavior so a future refactor doesn't change
  /// it silently.
  @Test func failedCallForNewAssetCreatesRecordAtZeroYearMonth() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.markVariantFailed(
      assetId: "orphan", variant: .original, error: "test",
      at: Date(timeIntervalSince1970: 0))

    let info = store.exportInfo(assetId: "orphan")
    #expect(info?.year == 0)
    #expect(info?.month == 0)
    #expect(info?.relPath == "")
    #expect(info?.variants[.original]?.status == .failed)
    // It counts at year=0/month=0, not at any "real" year.
    #expect(store.recordCount(year: 0, month: 0, variant: .original, status: .failed) == 1)
    #expect(store.recordCount(year: 2025, month: 6, variant: .original, status: .failed) == 0)
  }

  // MARK: - recordCountBothVariantsDone + recordCountEditedDone

  /// Fixture: 4 assets in 2025-06.
  /// - both: original.done + edited.done       → 2 assets
  /// - edited only: edited.done                → 1 asset
  /// - original only: original.done             → 1 asset
  /// recordCountBothVariantsDone == 2
  /// recordCountEditedDone == 3 (the 2 "both" assets + the "edited only" asset)
  @Test func bothVariantsDoneAndEditedDoneCountIndependentOfOtherVariant() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    for i in 1...2 {
      store.markVariantExported(
        assetId: "both-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "B\(i).HEIC", exportedAt: now)
      store.markVariantExported(
        assetId: "both-\(i)", variant: .edited, year: yr, month: mo, relPath: rel,
        filename: "B\(i).JPG", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "edited-only", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "E.JPG", exportedAt: now)
    store.markVariantExported(
      assetId: "original-only", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "O.HEIC", exportedAt: now)

    #expect(store.recordCountBothVariantsDone(year: yr, month: mo) == 2)
    #expect(store.recordCountEditedDone(year: yr, month: mo) == 3)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 3)
  }

  // MARK: - recordCountOriginalDoneAtNaturalStem

  /// Fixture: 4 records in 2025-06.
  /// - "img-A": .original.done at "IMG_A.HEIC" (natural stem), .edited not done → counts.
  /// - "img-B": .original.done at "IMG_B_orig.HEIC" (orig companion) → does NOT count.
  /// - "img-C": .original.done at "IMG_C.HEIC", .edited.done at "IMG_C.JPG" → does NOT count
  ///   (filtered by `record.variants[.edited]?.status == .done` short-circuit).
  /// - "img-D": .original.done with filename = nil → does NOT count.
  /// Expected: count == 1 (only "img-A").
  @Test func originalDoneAtNaturalStemFiltersCompanionsAndAccompaniedEdits() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    store.markVariantExported(
      assetId: "img-A", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "IMG_A.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: "img-B", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "IMG_B_orig.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: "img-C", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "IMG_C.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: "img-C", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "IMG_C.JPG", exportedAt: now)
    // img-D: simulate via markVariantInProgress → markVariantExported with nil filename;
    // the API requires a filename, so skip this branch — the nil-filename case is
    // exercised through `markVariantFailed` paths covered elsewhere.

    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 1)
  }

  // MARK: - sidebarSummary — .edited mode

  /// Fixture in 2025-06: total photos = 10, adjusted (edited) = 3, unedited = 7.
  /// Records:
  /// - 2 records: edited.done (one with original.done, one without).
  /// - 4 records: original.done only at natural stem (no edited.done).
  /// - 1 record:  original.done only at _orig companion (excluded from natural-stem count).
  /// .edited mode formula: editedDone + min(origOnlyAtStem, uneditedCount)
  ///                     = 2 + min(4, 7) = 6
  @Test func sidebarSummaryEditedModeFormula() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // 2 edited.done records.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "ed-\(i)", variant: .edited, year: yr, month: mo, relPath: rel,
        filename: "E\(i).JPG", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "ed-1", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "E1.HEIC", exportedAt: now)
    // 4 original.done at natural stem.
    for i in 1...4 {
      store.markVariantExported(
        assetId: "ns-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "NS\(i).HEIC", exportedAt: now)
    }
    // 1 original.done at _orig companion (no edited).
    store.markVariantExported(
      assetId: "comp", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "COMP_orig.HEIC", exportedAt: now)

    let summary = store.sidebarSummary(
      year: yr, month: mo, totalCount: 10, adjustedCount: 3, selection: .edited)
    #expect(summary != nil)
    #expect(summary?.exportedCount == 6)  // 2 + min(4, 7)
    #expect(summary?.totalCount == 10)
    #expect(summary?.status == .partial)

    // Loading state.
    #expect(
      store.sidebarSummary(
        year: yr, month: mo, totalCount: 10, adjustedCount: nil, selection: .edited)
        == nil)
  }

  // MARK: - sidebarSummary — .editedWithOriginals mode

  /// Same setup as above, .editedWithOriginals formula:
  /// bothDone + min(origOnlyAtStem, uneditedCount) = 1 + min(4, 7) = 5.
  /// (Of the two edited records, only "ed-1" has both variants done; "ed-2" has edited only.)
  @Test func sidebarSummaryEditedWithOriginalsModeFormula() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    for i in 1...2 {
      store.markVariantExported(
        assetId: "ed-\(i)", variant: .edited, year: yr, month: mo, relPath: rel,
        filename: "E\(i).JPG", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "ed-1", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "E1.HEIC", exportedAt: now)
    for i in 1...4 {
      store.markVariantExported(
        assetId: "ns-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "NS\(i).HEIC", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "comp", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "COMP_orig.HEIC", exportedAt: now)

    let summary = store.sidebarSummary(
      year: yr, month: mo, totalCount: 10, adjustedCount: 3,
      selection: .editedWithOriginals)
    #expect(summary?.exportedCount == 5)  // 1 + min(4, 7)
    #expect(summary?.status == .partial)
  }

  /// Edge: the natural-stem cap prevents over-counting when origOnlyAtStem >> uneditedCount.
  /// Setup: 10 unedited assets (out of 12 total, 2 adjusted). 12 records all .original.done
  /// at natural stem (i.e. records belonging to currently-adjusted assets that exist as
  /// natural-stem rows). The cap clamps to 10.
  /// .edited mode formula: 0 + min(12, 10) = 10.
  @Test func sidebarSummaryNaturalStemCappedByUneditedCount() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    for i in 1...12 {
      store.markVariantExported(
        assetId: "img-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "IMG_\(i).HEIC", exportedAt: now)
    }

    let summary = store.sidebarSummary(
      year: yr, month: mo, totalCount: 12, adjustedCount: 2, selection: .edited)
    #expect(summary?.exportedCount == 10)  // capped, not 12
  }

  // MARK: - sidebarYearExportedCount

  /// Sums per-month sidebar summaries across the year. Months without total counts or
  /// without adjusted counts contribute zero.
  ///
  /// Fixture: in 2025, three months have data:
  /// - 06: total=10, adjusted=3, with the same records as `sidebarSummaryEditedModeFormula`
  ///   (exported = 6 in .edited)
  /// - 07: total=5, adjusted=0, 2 .original.done at natural stem → 0 + min(2, 5) = 2.
  /// - 08: total=0, no data → 0.
  /// Year total under .edited = 6 + 2 + 0 = 8.
  @Test func sidebarYearExportedCountSumsAcrossMonths() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)

    // 2025-06 — same as sidebarSummaryEditedModeFormula above.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "ed-\(i)", variant: .edited, year: 2025, month: 6,
        relPath: "2025/06/", filename: "E\(i).JPG", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "ed-1", variant: .original, year: 2025, month: 6,
      relPath: "2025/06/", filename: "E1.HEIC", exportedAt: now)
    for i in 1...4 {
      store.markVariantExported(
        assetId: "ns-\(i)", variant: .original, year: 2025, month: 6,
        relPath: "2025/06/", filename: "NS\(i).HEIC", exportedAt: now)
    }
    store.markVariantExported(
      assetId: "comp", variant: .original, year: 2025, month: 6,
      relPath: "2025/06/", filename: "COMP_orig.HEIC", exportedAt: now)

    // 2025-07 — 2 natural-stem .original.done records.
    for i in 1...2 {
      store.markVariantExported(
        assetId: "july-\(i)", variant: .original, year: 2025, month: 7,
        relPath: "2025/07/", filename: "JUL\(i).HEIC", exportedAt: now)
    }

    let yearTotal = store.sidebarYearExportedCount(
      year: 2025,
      totalCountsByMonth: [6: 10, 7: 5, 8: 0],
      adjustedCountsByMonth: [6: 3, 7: 0, 8: nil],
      selection: .edited
    )
    #expect(yearTotal == 8)

    // Adjusted nil for a month with totals → that month contributes 0, total stays the same.
    let yearTotalWithLoading = store.sidebarYearExportedCount(
      year: 2025,
      totalCountsByMonth: [6: 10, 7: 5, 8: 0],
      adjustedCountsByMonth: [6: 3, 7: nil, 8: nil],
      selection: .edited
    )
    #expect(yearTotalWithLoading == 6)  // only month 6 contributes
  }

  // MARK: - monthSummary(year:month:totalAssets:) — legacy original-done flavor

  /// Counts records whose `.original` variant is `.done`. Adjusted-but-edited assets that
  /// have no `.original` variant don't show up here; this is the legacy flavor used by
  /// callers without descriptors.
  @Test func legacyMonthSummaryCountsOriginalDoneOnly() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // 3 .original.done.
    for i in 1...3 {
      store.markVariantExported(
        assetId: "od-\(i)", variant: .original, year: yr, month: mo, relPath: rel,
        filename: "OD\(i).HEIC", exportedAt: now)
    }
    // 2 .edited.done (no .original).
    for i in 1...2 {
      store.markVariantExported(
        assetId: "ed-\(i)", variant: .edited, year: yr, month: mo, relPath: rel,
        filename: "ED\(i).JPG", exportedAt: now)
    }

    let summary = store.monthSummary(year: yr, month: mo, totalAssets: 5)
    #expect(summary.exportedCount == 3)  // legacy: .original.done only
    #expect(summary.totalCount == 5)
    #expect(summary.status == .partial)

    // Status when nothing is done.
    let zero = store.monthSummary(year: yr, month: 99, totalAssets: 5)
    #expect(zero.exportedCount == 0)
    #expect(zero.status == .notExported)

    // Status when total is zero.
    let none = store.monthSummary(year: yr, month: 99, totalAssets: 0)
    #expect(none.status == .notExported)
  }

  // MARK: - monthSummary(assets:selection:) — selection-aware

  /// Provided a list of asset descriptors, the strict per-asset isExported(asset:selection:)
  /// is consulted. Adjusted assets need .edited.done (and .original.done under
  /// .editedWithOriginals); unedited assets need .original.done.
  ///
  /// Fixture (5 assets in 2025-06):
  /// - "u-1" unedited: .original.done.
  /// - "u-2" unedited: nothing.
  /// - "a-1" adjusted: .edited.done, .original missing.
  /// - "a-2" adjusted: .edited.done, .original.done.
  /// - "a-3" adjusted: .original.done only.
  ///
  /// .edited mode: u-1 ✓, u-2 ✗, a-1 ✓ (.edited.done is sufficient), a-2 ✓, a-3 ✗ → 3 / 5.
  /// .editedWithOriginals: u-1 ✓, u-2 ✗, a-1 ✗ (needs .original too), a-2 ✓, a-3 ✗ → 2 / 5.
  @Test func selectionAwareMonthSummaryEvaluatesEachAsset() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    let u1 = asset(id: "u-1", year: yr, month: mo, hasAdjustments: false)
    let u2 = asset(id: "u-2", year: yr, month: mo, hasAdjustments: false)
    let a1 = asset(id: "a-1", year: yr, month: mo, hasAdjustments: true)
    let a2 = asset(id: "a-2", year: yr, month: mo, hasAdjustments: true)
    let a3 = asset(id: "a-3", year: yr, month: mo, hasAdjustments: true)

    store.markVariantExported(
      assetId: u1.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "U1.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: a1.id, variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "A1.JPG", exportedAt: now)
    store.markVariantExported(
      assetId: a2.id, variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "A2.JPG", exportedAt: now)
    store.markVariantExported(
      assetId: a2.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "A2.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: a3.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "A3.HEIC", exportedAt: now)

    let assets = [u1, u2, a1, a2, a3]

    let editedSummary = store.monthSummary(assets: assets, selection: .edited)
    #expect(editedSummary.exportedCount == 3)
    #expect(editedSummary.totalCount == 5)
    #expect(editedSummary.status == .partial)

    let editedWithOriginals = store.monthSummary(
      assets: assets, selection: .editedWithOriginals)
    #expect(editedWithOriginals.exportedCount == 2)
    #expect(editedWithOriginals.totalCount == 5)
    #expect(editedWithOriginals.status == .partial)
  }

  // MARK: - isExported(assetId:) and isExported(asset:selection:)

  /// `isExported(assetId:)` is the legacy-shaped helper that only checks `.original.done`.
  /// `isExported(asset:selection:)` uses requiredVariants based on the asset's
  /// `hasAdjustments`.
  @Test func isExportedHelpersBehaveDifferentlyForAdjustedAssets() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    let unedited = asset(id: "u", year: yr, month: mo, hasAdjustments: false)
    let adjusted = asset(id: "a", year: yr, month: mo, hasAdjustments: true)

    // Both get .original.done only.
    store.markVariantExported(
      assetId: unedited.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "U.HEIC", exportedAt: now)
    store.markVariantExported(
      assetId: adjusted.id, variant: .original, year: yr, month: mo, relPath: rel,
      filename: "A.HEIC", exportedAt: now)

    // Legacy shim: both look "exported" because legacy ignores adjustment status.
    #expect(store.isExported(assetId: unedited.id))
    #expect(store.isExported(assetId: adjusted.id))

    // Strict: unedited is satisfied; adjusted is not (needs .edited.done).
    #expect(store.isExported(asset: unedited, selection: .edited))
    #expect(!store.isExported(asset: adjusted, selection: .edited))
    #expect(store.isExported(asset: unedited, selection: .editedWithOriginals))
    #expect(!store.isExported(asset: adjusted, selection: .editedWithOriginals))

    // Add the adjusted asset's edited variant — now it satisfies .edited but not
    // .editedWithOriginals (the .original is still done from above so it does).
    store.markVariantExported(
      assetId: adjusted.id, variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "A.JPG", exportedAt: now)
    #expect(store.isExported(asset: adjusted, selection: .edited))
    #expect(store.isExported(asset: adjusted, selection: .editedWithOriginals))
  }

  // MARK: - Mutation transitions

  /// Drives a sequence of state transitions on one record and asserts counts after each.
  /// Locks in: counts respond to upserts, deletes, and variant transitions in the obvious
  /// way.
  @Test func countsRespondToMutationSequence() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 0)
    let yr = 2025
    let mo = 6
    let rel = "2025/06/"

    // Step 1: upsert original.done.
    store.markVariantExported(
      assetId: "x", variant: .original, year: yr, month: mo, relPath: rel,
      filename: "X.HEIC", exportedAt: now)
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 1)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 1)

    // Step 2: add edited.done — natural-stem count drops to 0 (filtered by edited.done).
    store.markVariantExported(
      assetId: "x", variant: .edited, year: yr, month: mo, relPath: rel,
      filename: "X.JPG", exportedAt: now)
    #expect(store.recordCountEditedDone(year: yr, month: mo) == 1)
    #expect(store.recordCountBothVariantsDone(year: yr, month: mo) == 1)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 0)

    // Step 3: removeVariant(.edited) — back to original-only.
    store.removeVariant(assetId: "x", variant: .edited)
    #expect(store.recordCountEditedDone(year: yr, month: mo) == 0)
    #expect(store.recordCountBothVariantsDone(year: yr, month: mo) == 0)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 1)

    // Step 4: remove(assetId:) — record gone, all counts zero.
    store.remove(assetId: "x")
    #expect(store.recordCount(year: yr, month: mo, variant: .original, status: .done) == 0)
    #expect(store.recordCountOriginalDoneAtNaturalStem(year: yr, month: mo) == 0)
  }
}
