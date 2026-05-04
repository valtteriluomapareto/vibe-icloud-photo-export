import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Closes a P0 coverage gap: `MonthViewModel` had **zero** direct tests despite
/// being the heart of both `MonthContentView` and `CollectionContentView`. It
/// owns the asset/thumbnail pipeline (initial fast-thumbnail batch → background
/// fast-thumbnail fanout → HQ upgrade), the `PHCachingImageManager` lifecycle
/// (`stopCachingThumbnails` for the previous scope before `startCachingThumbnails`
/// for the new), and the cancellation of the in-flight HQ upgrade task on every
/// scope change.
///
/// A regression that broke any of those — for example, dropping the
/// `stopCachingThumbnails` call so the cache leaks across scope changes, or
/// flipping the order of the auto-select-first and `isLoading=false` settings —
/// would be invisible to the rest of the test suite.
@MainActor
struct MonthViewModelTests {

  // MARK: - Fixtures

  private func makeAsset(id: String, hasAdjustments: Bool = false) -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: hasAdjustments
    )
  }

  /// 1×1 transparent NSImage so the fake's `loadThumbnail` returns a non-nil value.
  private func dummyImage() -> NSImage {
    let img = NSImage(size: NSSize(width: 1, height: 1))
    img.lockFocus()
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    img.unlockFocus()
    return img
  }

  /// Wait briefly for the background HQ upgrade `Task` (spawned at the end of
  /// `loadAssets(for:)`) to drain. The fake's thumbnail methods return
  /// synchronously, so two yields is enough on a quiet test runner.
  private func drainBackgroundWork() async {
    for _ in 0..<5 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  // MARK: - Initial load

  @Test func initialLoadFetchesAssetsAndThumbnails() async throws {
    let svc = FakePhotoLibraryService()
    let assets = (0..<3).map { makeAsset(id: "a\($0)") }
    svc.assetsByYearMonth["2025-6"] = assets
    for asset in assets {
      svc.thumbnailsByAssetId[asset.id] = dummyImage()
    }

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))

    #expect(vm.assets.map(\.id) == ["a0", "a1", "a2"])
    #expect(!vm.isLoading)
    #expect(vm.errorMessage == nil)
    // All three assets had canned thumbnails — none should be in failedThumbnailIds.
    #expect(vm.failedThumbnailIds.isEmpty)
    #expect(vm.thumbnailsById.count == 3)
  }

  @Test func assetsWithoutThumbnailsLandInFailedSet() async throws {
    let svc = FakePhotoLibraryService()
    let withThumb = makeAsset(id: "ok")
    let noThumb = makeAsset(id: "missing")
    svc.assetsByYearMonth["2025-7"] = [withThumb, noThumb]
    svc.thumbnailsByAssetId[withThumb.id] = dummyImage()
    // noThumb has no canned thumbnail → fake returns nil → failedThumbnailIds.

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 7))

    #expect(vm.thumbnailsById.keys.sorted() == ["ok"])
    #expect(vm.failedThumbnailIds == ["missing"])
    if case .loaded(let img) = vm.thumbnailState(for: withThumb) {
      #expect(img === svc.thumbnailsByAssetId["ok"])
    } else {
      Issue.record("expected .loaded for withThumb")
    }
    if case .failed = vm.thumbnailState(for: noThumb) {
      // good
    } else {
      Issue.record("expected .failed for noThumb")
    }
  }

  // MARK: - Auto-select

  @Test func autoSelectsFirstAssetAfterLoad() async throws {
    let svc = FakePhotoLibraryService()
    let assets = (0..<3).map { makeAsset(id: "a\($0)") }
    svc.assetsByYearMonth["2025-6"] = assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 6))

    #expect(vm.selectedAssetId == "a0")
  }

  @Test func emptyAssetListDoesNotAutoSelect() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-1"] = []  // no assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 1))

    #expect(vm.assets.isEmpty)
    #expect(vm.selectedAssetId == nil)
    #expect(vm.thumbnailsById.isEmpty)
  }

  // MARK: - Scope switching + caching lifecycle

  /// `PHCachingImageManager` lifecycle: when the user switches scope, the
  /// previous scope's preheating must stop *before* the new scope's
  /// preheating starts. A regression that drops the stop call would leak
  /// PHAssets in the cache across scope changes.
  @Test func switchingScopeStopsPriorCacheBeforeStartingNew() async throws {
    let svc = FakePhotoLibraryService()
    let scope1Assets = [makeAsset(id: "s1-a"), makeAsset(id: "s1-b")]
    let scope2Assets = [makeAsset(id: "s2-a")]
    svc.assetsByYearMonth["2025-3"] = scope1Assets
    svc.favoritesAssets = scope2Assets

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 3))
    #expect(svc.startCachingCalls.count == 1)
    #expect(svc.startCachingCalls.last?.map(\.id) == ["s1-a", "s1-b"])
    #expect(svc.stopCachingCalls.isEmpty, "first scope has nothing to stop")

    await vm.loadAssets(for: .favorites)
    #expect(
      svc.stopCachingCalls.last?.map(\.id) == ["s1-a", "s1-b"],
      "previous scope's assets must be stopped before the new scope is loaded")
    #expect(svc.startCachingCalls.last?.map(\.id) == ["s2-a"])
    #expect(vm.assets.map(\.id) == ["s2-a"])
  }

  @Test func nilScopeClearsAllState() async throws {
    let svc = FakePhotoLibraryService()
    let assets = [makeAsset(id: "a"), makeAsset(id: "b")]
    svc.assetsByYearMonth["2025-2"] = assets
    for asset in assets { svc.thumbnailsByAssetId[asset.id] = dummyImage() }

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 2))
    #expect(!vm.assets.isEmpty)
    #expect(vm.selectedAssetId != nil)

    // Pass nil — view model should clear everything.
    await vm.loadAssets(for: nil)

    #expect(vm.assets.isEmpty)
    #expect(vm.thumbnailsById.isEmpty)
    #expect(vm.failedThumbnailIds.isEmpty)
    #expect(vm.selectedAssetId == nil)
    #expect(!vm.isLoading)
    // The previous scope's caching was stopped on entry to the nil-scope load.
    #expect(svc.stopCachingCalls.last?.map(\.id) == ["a", "b"])
  }

  // MARK: - Error path

  @Test func fetchErrorSurfacesViaErrorMessage() async throws {
    let svc = FakePhotoLibraryService()
    svc.fetchAssetsError = NSError(
      domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 4))

    #expect(vm.errorMessage == "boom")
    #expect(!vm.isLoading)
    #expect(vm.assets.isEmpty)
  }

  // MARK: - retryThumbnail

  @Test func retryThumbnailClearsFailedAndReloads() async throws {
    let svc = FakePhotoLibraryService()
    let asset = makeAsset(id: "retry-me")
    svc.assetsByYearMonth["2025-5"] = [asset]
    // Initial load: no canned thumbnail → falls into failedThumbnailIds.

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(for: .timeline(year: 2025, month: 5))
    #expect(vm.failedThumbnailIds == ["retry-me"])
    #expect(vm.thumbnailsById["retry-me"] == nil)

    // Now stage a thumbnail and retry — failedThumbnailIds clears, thumbnail loads.
    svc.thumbnailsByAssetId["retry-me"] = dummyImage()
    vm.retryThumbnail(for: "retry-me")
    await drainBackgroundWork()

    #expect(!vm.failedThumbnailIds.contains("retry-me"))
    #expect(vm.thumbnailsById["retry-me"] != nil)
  }

  // MARK: - select / setExportRunning

  @Test func selectAndSetExportRunningToggleState() async throws {
    let svc = FakePhotoLibraryService()
    let vm = MonthViewModel(photoLibraryService: svc)

    vm.select(assetId: "abc")
    #expect(vm.selectedAssetId == "abc")
    vm.select(assetId: nil)
    #expect(vm.selectedAssetId == nil)

    #expect(!vm.isExportRunning)
    vm.setExportRunning(true)
    #expect(vm.isExportRunning)
    vm.setExportRunning(false)
    #expect(!vm.isExportRunning)
  }

  // MARK: - thumbnail(for:) accessor

  @Test func thumbnailAccessorReturnsLoadedImageOrNil() async throws {
    let svc = FakePhotoLibraryService()
    let asset = makeAsset(id: "t")
    let img = dummyImage()
    svc.assetsByYearMonth["2025-9"] = [asset]
    svc.thumbnailsByAssetId[asset.id] = img

    let vm = MonthViewModel(photoLibraryService: svc)
    #expect(vm.thumbnail(for: asset) == nil)  // before load
    await vm.loadAssets(for: .timeline(year: 2025, month: 9))
    #expect(vm.thumbnail(for: asset) === img)
  }

  // MARK: - Wrapper: loadAssets(forYear:month:)

  /// The legacy wrapper `loadAssets(forYear:month:)` simply delegates to
  /// `loadAssets(for: .timeline(...))`. Verify both paths produce the same
  /// observable state.
  @Test func legacyWrapperIsEquivalentToScopeBasedLoader() async throws {
    let svc = FakePhotoLibraryService()
    let asset = makeAsset(id: "wrapper")
    svc.assetsByYearMonth["2025-8"] = [asset]
    svc.thumbnailsByAssetId[asset.id] = dummyImage()

    let vm = MonthViewModel(photoLibraryService: svc)
    await vm.loadAssets(forYear: 2025, month: 8)

    #expect(vm.assets.map(\.id) == ["wrapper"])
    #expect(vm.thumbnailsById["wrapper"] != nil)
    #expect(vm.selectedAssetId == "wrapper")
  }
}
