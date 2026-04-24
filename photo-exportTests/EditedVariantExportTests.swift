import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Covers the edited-variant export pipeline: filename contract, collision pairing, failure
/// propagation, and selection-aware enqueue/skip behaviour.
@MainActor
struct EditedVariantExportTests {
  // MARK: - Test harness

  private func makeTestHarness() -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeFileSystem, ExportRecordStore
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EditedVariantTest-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "test")

    // Reset the persisted selection so each test starts from a known state.
    UserDefaults.standard.removeObject(forKey: ExportManager.versionSelectionDefaultsKey)

    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      assetResourceWriter: writer,
      fileSystem: fileSystem
    )
    return (manager, photoLib, dest, writer, fileSystem, store)
  }

  private func waitForQueueDrained(_ manager: ExportManager, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    while (manager.isRunning || manager.queueCount > 0 || manager.hasActiveExportWork)
      && Date() < deadline
    {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - Edited-only with unedited assets

  @Test func editedOnlySkipsUneditedAssets() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedOnly

    let unedited = TestAssetFactory.makeAsset(id: "plain-asset", hasAdjustments: false)
    photoLib.assetsByYearMonth["2025-3"] = [unedited]
    photoLib.resourcesByAssetId["plain-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 3)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.isEmpty)
    #expect(store.exportInfo(assetId: "plain-asset") == nil)
    #expect(manager.totalJobsEnqueued == 0)
  }

  // MARK: - Edited-only writes _edited filename

  @Test func editedOnlyWritesEditedFilename() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedOnly

    let asset = TestAssetFactory.makeAsset(id: "edited-asset", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-4"] = [asset]
    photoLib.resourcesByAssetId["edited-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 4)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 1)
    #expect(writer.writeCalls.first?.resource.type == .fullSizePhoto)
    let record = store.exportInfo(assetId: "edited-asset")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_0001_edited.JPG")
    #expect(record?.variants[.original] == nil)
  }

  // MARK: - HEIC original + JPEG edit → _edited.JPG

  @Test func heicOriginalPlusJpegEditProducesEditedJpeg() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedOnly

    let asset = TestAssetFactory.makeAsset(id: "heic-asset", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-5"] = [asset]
    photoLib.resourcesByAssetId["heic-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 5)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 1)
    let record = store.exportInfo(assetId: "heic-asset")
    #expect(record?.variants[.edited]?.filename == "IMG_0001_edited.JPG")
  }

  // MARK: - Original + edited writes both

  @Test func originalAndEditedWritesBothVariants() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .originalAndEdited

    let asset = TestAssetFactory.makeAsset(id: "dual-asset", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-6"] = [asset]
    photoLib.resourcesByAssetId["dual-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 6)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 2)
    let record = store.exportInfo(assetId: "dual-asset")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.edited]?.filename == "IMG_0001_edited.JPG")
  }

  @Test func originalAndEditedUneditedAssetWritesOriginalOnly() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .originalAndEdited

    let unedited = TestAssetFactory.makeAsset(id: "plain", hasAdjustments: false)
    photoLib.assetsByYearMonth["2025-7"] = [unedited]
    photoLib.resourcesByAssetId["plain"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    ]

    manager.startExportMonth(year: 2025, month: 7)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 1)
    let record = store.exportInfo(assetId: "plain")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited] == nil)
  }

  // MARK: - Missing edited resource fails the edited variant (not "skipped")

  @Test func editedOnlyFailsWhenEditedResourceUnavailable() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .editedOnly

    let asset = TestAssetFactory.makeAsset(id: "broken-edit", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-8"] = [asset]
    photoLib.resourcesByAssetId["broken-edit"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
      // No .fullSizePhoto resource despite hasAdjustments.
    ]

    manager.startExportMonth(year: 2025, month: 8)
    await waitForQueueDrained(manager)

    let record = store.exportInfo(assetId: "broken-edit")
    #expect(record?.variants[.edited]?.status == .failed)
    #expect(record?.variants[.edited]?.lastError == "Edited resource unavailable")
  }

  // MARK: - Pair-preserving re-export after collision

  @Test func pairedCompanionFollowsOriginalCollisionSuffix() async throws {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    manager.versionSelection = .originalOnly
    let aOriginal = TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    let bOriginal = TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    let bEdited = TestAssetFactory.makeResource(
      type: .fullSizePhoto, originalFilename: "FullRender.JPG")

    let assetA = TestAssetFactory.makeAsset(id: "asset-a", hasAdjustments: false)
    let assetB = TestAssetFactory.makeAsset(id: "asset-b", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-9"] = [assetA, assetB]
    photoLib.resourcesByAssetId["asset-a"] = [aOriginal]
    photoLib.resourcesByAssetId["asset-b"] = [bOriginal, bEdited]

    manager.startExportMonth(year: 2025, month: 9)
    await waitForQueueDrained(manager)

    #expect(store.exportInfo(assetId: "asset-a")?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(
      store.exportInfo(assetId: "asset-b")?.variants[.original]?.filename == "IMG_0001 (1).JPG")

    // Flip selection to include edited, re-run the month. Asset B's edited companion must pair
    // against its recorded original group stem.
    manager.versionSelection = .originalAndEdited
    manager.startExportMonth(year: 2025, month: 9)
    await waitForQueueDrained(manager)

    let bRecord = store.exportInfo(assetId: "asset-b")
    #expect(bRecord?.variants[.edited]?.status == .done)
    #expect(bRecord?.variants[.edited]?.filename == "IMG_0001 (1)_edited.JPG")
  }

  // MARK: - Symmetric pair preservation (edited first, then original)

  @Test func symmetricPairingWhenEditedExportedFirst() async throws {
    let (manager, photoLib, dest, _, fileSystem, store) = makeTestHarness()
    defer { dest.cleanup() }

    // Pre-seed Asset A's original on disk so Asset B's edited-only export collides.
    let monthDir = try dest.urlForMonth(year: 2025, month: 10, createIfNeeded: true)
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("IMG_0001.JPG").path,
      contents: Data("dummy".utf8))

    manager.versionSelection = .editedOnly
    let assetB = TestAssetFactory.makeAsset(id: "b-only", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-10"] = [assetB]
    photoLib.resourcesByAssetId["b-only"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 10)
    await waitForQueueDrained(manager)

    let editedRecord = store.exportInfo(assetId: "b-only")
    #expect(editedRecord?.variants[.edited]?.filename == "IMG_0001 (1)_edited.JPG")

    // Now switch to originalAndEdited; the original variant must pair against the recorded group
    // stem "IMG_0001 (1)".
    manager.versionSelection = .originalAndEdited
    manager.startExportMonth(year: 2025, month: 10)
    await waitForQueueDrained(manager)

    let fullRecord = store.exportInfo(assetId: "b-only")
    #expect(fullRecord?.variants[.original]?.status == .done)
    #expect(fullRecord?.variants[.original]?.filename == "IMG_0001 (1).JPG")
    _ = fileSystem  // silence unused warning
  }

  // MARK: - Step-1 fail-path guard

  @Test func pairedOriginalFailsInsteadOfOverwritingAnotherAssetsFile() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    manager.versionSelection = .editedOnly
    // Asset B exports edited-only first.
    let assetB = TestAssetFactory.makeAsset(id: "b", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-11"] = [assetB]
    photoLib.resourcesByAssetId["b"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]
    // Pre-seed IMG_0001.JPG on disk so Asset B's stem resolves to "IMG_0001 (1)".
    let monthDir = try dest.urlForMonth(year: 2025, month: 11, createIfNeeded: true)
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("IMG_0001.JPG").path,
      contents: Data("dummy".utf8))

    manager.startExportMonth(year: 2025, month: 11)
    await waitForQueueDrained(manager)
    #expect(store.exportInfo(assetId: "b")?.variants[.edited]?.filename == "IMG_0001 (1)_edited.JPG")

    // Asset C separately takes the "IMG_0001 (1).JPG" stem on disk (simulating another
    // asset exporting in between).
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("IMG_0001 (1).JPG").path,
      contents: Data("other-asset".utf8))

    // Switching Asset B to originalAndEdited should fail its original variant rather than
    // overwriting Asset C's file or re-allocating a different stem that splits the pair.
    manager.versionSelection = .originalAndEdited
    manager.startExportMonth(year: 2025, month: 11)
    await waitForQueueDrained(manager)

    let bRecord = store.exportInfo(assetId: "b")
    #expect(bRecord?.variants[.original]?.status == .failed)
    #expect(bRecord?.variants[.original]?.lastError?.contains("already exists") == true)
    // Asset C's bytes on disk must be untouched.
    let cData = try Data(
      contentsOf: monthDir.appendingPathComponent("IMG_0001 (1).JPG"))
    #expect(String(data: cData, encoding: .utf8) == "other-asset")
  }

  // MARK: - Stale .tmp cleanup at export start

  @Test func staleTempFileIsRemovedBeforeWrite() async throws {
    let (manager, photoLib, dest, _, _, _) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .originalOnly

    let asset = TestAssetFactory.makeAsset(id: "stale-tmp", hasAdjustments: false)
    photoLib.assetsByYearMonth["2025-12"] = [asset]
    photoLib.resourcesByAssetId["stale-tmp"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
    ]

    // Seed a stale sibling .tmp at the target.
    let monthDir = try dest.urlForMonth(year: 2025, month: 12, createIfNeeded: true)
    let staleTmp = monthDir.appendingPathComponent("IMG_0001.JPG.tmp")
    FileManager.default.createFile(atPath: staleTmp.path, contents: Data("leftover".utf8))
    #expect(FileManager.default.fileExists(atPath: staleTmp.path))

    manager.startExportMonth(year: 2025, month: 12)
    await waitForQueueDrained(manager)

    // After export finishes, the sibling .tmp should be gone.
    #expect(!FileManager.default.fileExists(atPath: staleTmp.path))
  }

  // MARK: - Switching selection enqueues only missing variants

  @Test func originalAndEditedEnqueuesOnlyMissingEditedForAlreadyExportedOriginals() async throws
  {
    let (manager, photoLib, dest, writer, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    manager.versionSelection = .originalOnly
    let asset = TestAssetFactory.makeAsset(id: "switch-asset", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-1"] = [asset]
    photoLib.resourcesByAssetId["switch-asset"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
      TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
    ]

    manager.startExportMonth(year: 2025, month: 1)
    await waitForQueueDrained(manager)
    #expect(writer.writeCalls.count == 1)
    #expect(store.exportInfo(assetId: "switch-asset")?.variants[.original]?.status == .done)

    // Flip selection; only the edited variant is new work.
    manager.versionSelection = .originalAndEdited
    manager.startExportMonth(year: 2025, month: 1)
    await waitForQueueDrained(manager)

    #expect(writer.writeCalls.count == 2)
    #expect(writer.writeCalls.last?.resource.type == .fullSizePhoto)
    #expect(store.exportInfo(assetId: "switch-asset")?.variants[.edited]?.status == .done)
  }

  // MARK: - Original succeeds and edited fails independently

  // MARK: - Sidebar summary accuracy for originalAndEdited

  @Test func sidebarSummaryDoesNotOvercountWhenOnlyEditedIsDone() async throws {
    let (_, _, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    // One adjusted asset exported edited-only; the original variant is NOT done.
    store.markVariantExported(
      assetId: "edited-only-asset", variant: .edited, year: 2025, month: 6,
      relPath: "2025/06/", filename: "IMG_0001_edited.JPG", exportedAt: Date())
    store.flushForTesting()

    // The sidebar under originalAndEdited would previously have counted this as complete,
    // because `editedDone` was added directly. The fixed formula counts only records where
    // both variants are done (zero here) and caps original-only completions at the unedited
    // asset count (also zero here).
    let summary = store.sidebarSummary(
      year: 2025, month: 6, totalCount: 1, adjustedCount: 1,
      selection: .originalAndEdited)
    #expect(summary?.exportedCount == 0)
    #expect(summary?.status == .notExported)
  }

  @Test func sidebarSummaryCountsBothVariantsDone() async throws {
    let (_, _, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }

    let now = Date()
    store.markVariantExported(
      assetId: "adj-asset", variant: .original, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_0001.JPG", exportedAt: now)
    store.markVariantExported(
      assetId: "adj-asset", variant: .edited, year: 2025, month: 7,
      relPath: "2025/07/", filename: "IMG_0001_edited.JPG", exportedAt: now)
    // An unedited asset with original done only.
    store.markExported(
      assetId: "plain-asset", year: 2025, month: 7, relPath: "2025/07/",
      filename: "IMG_0002.JPG", exportedAt: now)
    store.flushForTesting()

    let summary = store.sidebarSummary(
      year: 2025, month: 7, totalCount: 2, adjustedCount: 1,
      selection: .originalAndEdited)
    #expect(summary?.exportedCount == 2)
    #expect(summary?.status == .complete)
  }

  // MARK: - Original succeeds and edited fails independently

  @Test func originalSucceedsEvenIfEditedFails() async throws {
    let (manager, photoLib, dest, _, _, store) = makeTestHarness()
    defer { dest.cleanup() }
    manager.versionSelection = .originalAndEdited

    let asset = TestAssetFactory.makeAsset(id: "mixed", hasAdjustments: true)
    photoLib.assetsByYearMonth["2025-2"] = [asset]
    photoLib.resourcesByAssetId["mixed"] = [
      TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
      // No .fullSizePhoto — edited variant will fail.
    ]

    manager.startExportMonth(year: 2025, month: 2)
    await waitForQueueDrained(manager)

    let record = store.exportInfo(assetId: "mixed")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited]?.status == .failed)
  }
}
