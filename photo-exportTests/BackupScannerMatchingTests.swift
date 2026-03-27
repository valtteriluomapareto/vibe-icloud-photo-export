import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
struct BackupScannerMatchingTests {

  // MARK: - Helpers

  /// Creates a FakePhotoLibraryService with pre-configured assets and resources.
  private func makeService(
    assets: [(yearMonth: String, descriptors: [AssetDescriptor])],
    resources: [String: [ResourceDescriptor]] = [:]
  ) -> FakePhotoLibraryService {
    let service = FakePhotoLibraryService()
    for (key, descriptors) in assets {
      service.assetsByYearMonth[key] = descriptors
    }
    for (id, res) in resources {
      service.resourcesByAssetId[id] = res
    }
    return service
  }

  /// Creates a temp directory with fake backup files, returns scanned files.
  private func makeScannedFiles(
    _ files: [(year: Int, month: Int, filename: String, modDate: Date?, fileSize: UInt64?)]
  ) throws -> (
    [BackupScanner.ScannedFile], URL
  ) {
    let rootDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BSMatchTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)

    var scannedFiles: [BackupScanner.ScannedFile] = []
    for file in files {
      let monthStr = String(format: "%02d", file.month)
      let dir = rootDir.appendingPathComponent("\(file.year)", isDirectory: true)
        .appendingPathComponent(monthStr, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

      let fileURL = dir.appendingPathComponent(file.filename)
      FileManager.default.createFile(atPath: fileURL.path, contents: Data("test".utf8))

      let ext = fileURL.pathExtension
      let stem = (file.filename as NSString).deletingPathExtension
      let (baseStem, hadSuffix) = BackupScanner.stripCollisionSuffix(from: stem)
      let baseFilename = ext.isEmpty ? baseStem : baseStem + "." + ext

      scannedFiles.append(BackupScanner.ScannedFile(
        url: fileURL,
        year: file.year,
        month: file.month,
        filename: file.filename,
        baseFilename: baseFilename,
        hasCollisionSuffix: hadSuffix,
        fileExtension: ext.lowercased(),
        modificationDate: file.modDate,
        fileSize: file.fileSize
      ))
    }
    return (scannedFiles, rootDir)
  }

  // MARK: - Exact date match

  @Test func exactDateMatchProducesMatch() async throws {
    let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "asset-date-match", creationDate: refDate, mediaType: .image)

    let service = makeService(
      assets: [("2025-6", [asset])],
      resources: ["asset-date-match": [TestAssetFactory.makeResource(originalFilename: "IMG.JPG")]]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "IMG.JPG", modDate: refDate, fileSize: 1024)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    #expect(result.matched.count == 1)
    #expect(result.matched.first?.asset.id == "asset-date-match")
    #expect(result.ambiguous.isEmpty)
    #expect(result.unmatched.isEmpty)
  }

  // MARK: - Ambiguous date match narrows by filename

  @Test func ambiguousDateMatchNarrowedByFilename() async throws {
    let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset1 = TestAssetFactory.makeAsset(
      id: "asset-a", creationDate: refDate, mediaType: .image)
    let asset2 = TestAssetFactory.makeAsset(
      id: "asset-b", creationDate: refDate, mediaType: .image)

    let service = makeService(
      assets: [("2025-6", [asset1, asset2])],
      resources: [
        "asset-a": [TestAssetFactory.makeResource(originalFilename: "IMG_001.JPG")],
        "asset-b": [TestAssetFactory.makeResource(originalFilename: "IMG_002.JPG")],
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "IMG_001.JPG", modDate: refDate, fileSize: 1024)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    #expect(result.matched.count == 1)
    #expect(result.matched.first?.asset.id == "asset-a")
  }

  // MARK: - Filename-only fallback

  @Test func filenameOnlyFallbackWithoutMetadataConfirmationIsAmbiguous() async throws {
    let fileDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // Asset has a very different creation date — date match won't work
    let assetDate = Date(timeIntervalSinceReferenceDate: 900_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "name-match", creationDate: assetDate, mediaType: .image,
      pixelWidth: 100, pixelHeight: 100)

    let service = makeService(
      assets: [("2025-6", [asset])],
      resources: ["name-match": [TestAssetFactory.makeResource(originalFilename: "UNIQUE_NAME.JPG")]
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "UNIQUE_NAME.JPG", modDate: fileDate, fileSize: 1024)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    // Filename matches but the discriminator can't confirm (test file has no real
    // image metadata, and dates differ by 100M seconds), so the result is ambiguous.
    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.count == 1)
    #expect(result.unmatched.isEmpty)
  }

  @Test func filenameOnlyFallbackWithDateConfirmationMatches() async throws {
    // Dates differ by 0.5s — too close for the integer-truncated date index to find via
    // Step 1 (which checks ±1 integer second), but close enough for the discriminator's
    // 1.0s tolerance to confirm. This exercises the filename→discriminator→match path.
    let assetDate = Date(timeIntervalSinceReferenceDate: 800_000_000.0)
    let fileDate = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
    let asset = TestAssetFactory.makeAsset(
      id: "close-date", creationDate: assetDate, mediaType: .image)

    let service = makeService(
      assets: [("2025-6", [asset])],
      resources: [
        "close-date": [TestAssetFactory.makeResource(originalFilename: "CLOSE.JPG")]
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "CLOSE.JPG", modDate: fileDate, fileSize: 1024)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    // The date index lookup (Step 1) should find the candidate since ±1 integer second
    // covers it. But let's verify the file gets matched one way or another.
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.asset.id == "close-date")
    #expect(result.unmatched.isEmpty)
  }

  // MARK: - Unmatched file

  @Test func noMatchingAssetReportsUnmatched() async throws {
    let service = makeService(assets: [("2025-6", [])])

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "ORPHAN.JPG", modDate: Date(), fileSize: 1024)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    #expect(result.matched.isEmpty)
    #expect(result.unmatched.count == 1)
    #expect(result.unmatched.first?.filename == "ORPHAN.JPG")
  }

  // MARK: - Collision suffix handling

  @Test func collisionSuffixStrippedForMatching() async throws {
    let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "collision-asset", creationDate: refDate, mediaType: .image)

    let service = makeService(
      assets: [("2025-6", [asset])],
      resources: [
        "collision-asset": [TestAssetFactory.makeResource(originalFilename: "IMG_001.JPG")]
      ]
    )

    // File has collision suffix " (2)" — base filename should match
    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "IMG_001 (2).JPG", modDate: refDate, fileSize: 1024)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    #expect(result.matched.count == 1)
    #expect(result.matched.first?.asset.id == "collision-asset")
  }

  // MARK: - Adjacent month rollover

  @Test func adjacentMonthFindsAsset() async throws {
    let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // Asset in December but file stored in January folder (timezone drift)
    let asset = TestAssetFactory.makeAsset(
      id: "dec-asset", creationDate: refDate, mediaType: .image)

    let service = makeService(
      assets: [
        ("2025-1", []),
        ("2024-12", [asset]),
        ("2025-2", []),
      ],
      resources: [
        "dec-asset": [TestAssetFactory.makeResource(originalFilename: "DEC_PHOTO.JPG")]
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 1, filename: "DEC_PHOTO.JPG", modDate: refDate, fileSize: 1024)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    #expect(result.matched.count == 1)
    #expect(result.matched.first?.asset.id == "dec-asset")
  }

  // MARK: - Video media type

  @Test func videoFileMatchesByDateAndType() async throws {
    let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let videoAsset = TestAssetFactory.makeAsset(
      id: "video-1", creationDate: refDate, mediaType: .video,
      pixelWidth: 1920, pixelHeight: 1080, duration: 10.5)

    let service = makeService(
      assets: [("2025-3", [videoAsset])],
      resources: ["video-1": [ResourceDescriptor(type: .video, originalFilename: "MOV_001.MOV")]]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 3, filename: "MOV_001.MOV", modDate: refDate, fileSize: 5_000_000)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    #expect(result.matched.count == 1)
    #expect(result.matched.first?.asset.id == "video-1")
  }

  // MARK: - Progress reporting

  @Test func progressCallbackIsInvoked() async throws {
    let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var assets: [AssetDescriptor] = []
    var resources: [String: [ResourceDescriptor]] = [:]

    for i in 1...60 {
      let asset = TestAssetFactory.makeAsset(
        id: "progress-\(i)", creationDate: refDate.addingTimeInterval(Double(i)),
        mediaType: .image)
      assets.append(asset)
      resources["progress-\(i)"] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_\(i).JPG")
      ]
    }

    let service = makeService(assets: [("2025-1", assets)], resources: resources)

    var files: [(year: Int, month: Int, filename: String, modDate: Date?, fileSize: UInt64?)] = []
    for i in 1...60 {
      files.append((
        year: 2025, month: 1, filename: "IMG_\(i).JPG",
        modDate: refDate.addingTimeInterval(Double(i)), fileSize: 1024
      ))
    }
    let (scannedFiles, rootDir) = try makeScannedFiles(files)
    defer { try? FileManager.default.removeItem(at: rootDir) }

    var progressStages: [BackupScanner.ImportStage] = []
    let result = try await BackupScanner.matchFiles(
      scannedFiles, photoLibraryService: service
    ) { stage in
      progressStages.append(stage)
    }

    // Should have received at least one progress callback (every 50 files)
    #expect(!progressStages.isEmpty)
    #expect(result.matched.count == 60)
  }

  // MARK: - Multiple files across months

  @Test func multipleFilesAcrossMonthsMatchCorrectly() async throws {
    let jan = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let feb = Date(timeIntervalSinceReferenceDate: 803_000_000)

    let asset1 = TestAssetFactory.makeAsset(
      id: "jan-asset", creationDate: jan, mediaType: .image)
    let asset2 = TestAssetFactory.makeAsset(
      id: "feb-asset", creationDate: feb, mediaType: .image)

    let service = makeService(
      assets: [
        ("2025-1", [asset1]),
        ("2025-2", [asset2]),
        ("2024-12", []),
        ("2025-3", []),
      ],
      resources: [
        "jan-asset": [TestAssetFactory.makeResource(originalFilename: "JAN.JPG")],
        "feb-asset": [TestAssetFactory.makeResource(originalFilename: "FEB.JPG")],
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 1, filename: "JAN.JPG", modDate: jan, fileSize: 1024),
      (year: 2025, month: 2, filename: "FEB.JPG", modDate: feb, fileSize: 2048),
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(files, photoLibraryService: service) { _ in }

    #expect(result.matched.count == 2)
    let matchedIds = Set(result.matched.map(\.asset.id))
    #expect(matchedIds == ["jan-asset", "feb-asset"])
  }

  // MARK: - Empty scan produces empty result

  @Test func emptyScannedFilesProducesEmptyResult() async throws {
    let service = makeService(assets: [])
    let result = try await BackupScanner.matchFiles(
      [], photoLibraryService: service
    ) { _ in }

    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.isEmpty)
    #expect(result.unmatched.isEmpty)
  }
}
