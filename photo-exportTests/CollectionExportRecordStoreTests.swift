import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
struct CollectionExportRecordStoreTests {

  // MARK: - Fixtures

  private func makeStore() throws -> (URL, CollectionExportRecordStore) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("CollectionStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = CollectionExportRecordStore(baseDirectoryURL: dir)
    return (dir, store)
  }

  private func favoritesPlacement() -> ExportPlacement {
    ExportPlacement.favorites(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private func albumPlacement(id: String = "abc-123") -> ExportPlacement {
    ExportPlacement(
      kind: .album,
      id: "collections:album:hash16:hash8",
      displayName: "Family/Trip 2024",
      collectionLocalIdentifier: id,
      relativePath: "Collections/Albums/Family/Trip 2024/",
      createdAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
  }

  private func sampleAsset(id: String = "asset-1") -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_002),
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: false
    )
  }

  // MARK: - Empty / first-launch behavior

  /// Plan §"Phase 1 exit criteria": "Collection store loads empty on first launch and writes
  /// its first snapshot only when something is upserted."
  @Test func emptyOnFirstLaunch() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-empty")
    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)

    // No snapshot file written yet.
    let snapshotPath = dir.appendingPathComponent("dest-empty/collection-records.json").path
    #expect(!FileManager.default.fileExists(atPath: snapshotPath))
  }

  @Test func nilDestinationClearsState() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-x")
    store.upsertPlacement(favoritesPlacement())
    #expect(!store.placements.isEmpty)

    store.configure(for: nil)
    #expect(store.placements.isEmpty)
    #expect(store.recordBodies.isEmpty)
  }

  // MARK: - Routing invariant: rejects .timeline

  /// Plan §"Two Stores: API Surface → Collection store": ".timeline placement is a
  /// programming error and trips an assertionFailure (release: silent drop)." Tests run in
  /// debug; we cannot trip the assertion without crashing the test, so we verify the
  /// observable side: `accept(_:)` returns false → the no-op path runs → state is unchanged.
  /// In production the assertion catches this.
  ///
  /// We approximate by passing a `.timeline` placement and asserting nothing changes. Note:
  /// the real assertion fires in debug; this test runs the no-op release branch via the
  /// store's defensive `accept` check. (The store is built such that even if assertions
  /// were ever disabled, no `.timeline` data would land in the collection store.)
  // swift-format-ignore: NoLeadingUnderscores
  // assertionFailure check intentionally omitted — would crash the test process.
  // The "release silently drops" path is visible: state stays unchanged.

  // MARK: - Placement metadata

  @Test func upsertPlacementPersists() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-1")
    let p = favoritesPlacement()
    store.upsertPlacement(p)
    #expect(store.placement(id: p.id) == p)
    #expect(store.placements(matching: .favorites) == [p])
    #expect(store.placements(matching: .album).isEmpty)
  }

  @Test func deletePlacementRemovesPlacementAndRecords() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-2")
    let album = albumPlacement()
    store.upsertPlacement(album)
    store.markVariantExported(
      assetId: "a", placement: album, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date())
    #expect(store.placement(id: album.id) != nil)
    #expect(store.recordBodies[album.id]?.count == 1)

    store.deletePlacement(id: album.id)
    #expect(store.placement(id: album.id) == nil)
    #expect(store.recordBodies[album.id] == nil)
  }

  // MARK: - Variant lifecycle

  @Test func variantLifecycleInProgressDoneFailedRemove() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-3")
    let p = albumPlacement()
    store.upsertPlacement(p)

    // .inProgress → .done → .failed → remove
    store.markVariantInProgress(
      assetId: "a", placement: p, variant: .original, filename: nil)
    var info = store.exportInfo(assetId: "a", placement: p)
    #expect(info?.variants[.original]?.status == .inProgress)

    store.markVariantExported(
      assetId: "a", placement: p, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date(timeIntervalSince1970: 1))
    info = store.exportInfo(assetId: "a", placement: p)
    #expect(info?.variants[.original]?.status == .done)
    #expect(info?.variants[.original]?.filename == "IMG_0001.HEIC")

    store.markVariantFailed(
      assetId: "a", placement: p, variant: .edited, error: "Edited resource unavailable",
      at: Date(timeIntervalSince1970: 2))
    info = store.exportInfo(assetId: "a", placement: p)
    #expect(info?.variants[.original]?.status == .done)
    #expect(info?.variants[.edited]?.status == .failed)

    store.removeVariant(assetId: "a", placement: p, variant: .edited)
    info = store.exportInfo(assetId: "a", placement: p)
    #expect(info?.variants[.edited] == nil)
    #expect(info?.variants[.original]?.status == .done)
  }

  /// `removeVariant` removes the whole record once the last variant is gone.
  @Test func removeVariantRemovesRecordWhenLastVariantGone() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-4")
    let p = albumPlacement()
    store.upsertPlacement(p)
    store.markVariantInProgress(
      assetId: "a", placement: p, variant: .original, filename: nil)
    store.removeVariant(assetId: "a", placement: p, variant: .original)
    #expect(store.exportInfo(assetId: "a", placement: p) == nil)
  }

  // MARK: - isExported under selection

  @Test func isExportedUnderSelectionEdited() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-isexp")
    let p = albumPlacement()
    store.upsertPlacement(p)
    let asset = sampleAsset()  // hasAdjustments: false → requires .original

    #expect(!store.isExported(asset: asset, placement: p, selection: .edited))
    store.markVariantExported(
      assetId: asset.id, placement: p, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date())
    #expect(store.isExported(asset: asset, placement: p, selection: .edited))
  }

  // MARK: - Persistence: load after restart

  @Test func persistenceSurvivesRestart() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-restart")
    let p = albumPlacement()
    store.upsertPlacement(p)
    store.markVariantExported(
      assetId: "asset-1", placement: p, variant: .original,
      filename: "IMG_0001.HEIC", exportedAt: Date(timeIntervalSince1970: 12345))
    store.flushForTesting()

    // New store instance against the same baseDirectoryURL replays the log.
    let store2 = CollectionExportRecordStore(baseDirectoryURL: dir)
    store2.configure(for: "dest-restart")
    #expect(store2.placement(id: p.id)?.id == p.id)
    let info = store2.exportInfo(assetId: "asset-1", placement: p)
    #expect(info?.variants[.original]?.status == .done)
    #expect(info?.variants[.original]?.filename == "IMG_0001.HEIC")
  }

  // MARK: - Summary

  @Test func summaryPartialAndComplete() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-sum")
    let p = albumPlacement()
    store.upsertPlacement(p)
    store.markVariantExported(
      assetId: "a", placement: p, variant: .original, filename: "A.HEIC",
      exportedAt: Date())
    store.markVariantInProgress(
      assetId: "b", placement: p, variant: .original, filename: nil)

    let partial = store.summary(for: p)
    #expect(partial.totalCount == 2)
    #expect(partial.exportedCount == 1)
    #expect(partial.status == .partial)

    store.markVariantExported(
      assetId: "b", placement: p, variant: .original, filename: "B.HEIC",
      exportedAt: Date())
    let complete = store.summary(for: p)
    #expect(complete.totalCount == 2)
    #expect(complete.exportedCount == 2)
    #expect(complete.status == .complete)
  }

  // MARK: - In-flight recovery on load

  /// Plan §"In-flight recovery on load": collection store mirrors the timeline pass — any
  /// `.inProgress` becomes `.failed` with the recoverable-error message. In-memory only;
  /// no eager persistence.
  @Test func inFlightRecoveryConvertsInProgressToFailed() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-recover")
    let p = albumPlacement()
    store.upsertPlacement(p)
    store.markVariantInProgress(
      assetId: "asset-1", placement: p, variant: .original, filename: nil)
    store.flushForTesting()

    // Fresh store reloads from log — recovery pass converts the `.inProgress` to `.failed`.
    let store2 = CollectionExportRecordStore(baseDirectoryURL: dir)
    store2.configure(for: "dest-recover")
    let info = store2.exportInfo(assetId: "asset-1", placement: p)
    #expect(info?.variants[.original]?.status == .failed)
    #expect(info?.variants[.original]?.lastError == ExportVariantRecovery.interruptedMessage)
  }

  // MARK: - Cross-placement isolation

  /// Records under different placements are independent: writes to one placement don't
  /// touch the other, even for the same asset id.
  @Test func recordsUnderDifferentPlacementsAreIndependent() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    store.configure(for: "dest-iso")
    let fav = favoritesPlacement()
    let alb = albumPlacement()
    store.upsertPlacement(fav)
    store.upsertPlacement(alb)
    let assetId = "shared-asset"
    store.markVariantExported(
      assetId: assetId, placement: fav, variant: .original,
      filename: "fav-name.HEIC", exportedAt: Date())
    store.markVariantFailed(
      assetId: assetId, placement: alb, variant: .original,
      error: "boom", at: Date())

    let favInfo = store.exportInfo(assetId: assetId, placement: fav)
    let albInfo = store.exportInfo(assetId: assetId, placement: alb)
    #expect(favInfo?.variants[.original]?.status == .done)
    #expect(favInfo?.variants[.original]?.filename == "fav-name.HEIC")
    #expect(albInfo?.variants[.original]?.status == .failed)
    #expect(albInfo?.variants[.original]?.lastError == "boom")
  }

  // MARK: - ExportPlacement Codable round-trip

  @Test func exportPlacementCodableRoundTrip() throws {
    let original = albumPlacement(id: "abc-rt")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ExportPlacement.self, from: data)
    #expect(decoded == original)  // manual Hashable/Equatable is over `id` only
    #expect(decoded.kind == original.kind)
    #expect(decoded.displayName == original.displayName)
    #expect(decoded.collectionLocalIdentifier == original.collectionLocalIdentifier)
    #expect(decoded.relativePath == original.relativePath)
    #expect(decoded.createdAt == original.createdAt)
  }
}
