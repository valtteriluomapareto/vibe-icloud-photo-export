import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Scanner tests for variant-aware classification.
@MainActor
struct EditedVariantScannerTests {
  private func makeScannedFile(
    _ filename: String, year: Int = 2025, month: Int = 6, modDate: Date? = nil
  ) throws -> (BackupScanner.ScannedFile, URL) {
    let rootDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EVS-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    let monthStr = String(format: "%02d", month)
    let dir = rootDir.appendingPathComponent("\(year)", isDirectory: true)
      .appendingPathComponent(monthStr, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(filename)
    FileManager.default.createFile(atPath: url.path, contents: Data("test".utf8))
    let ext = url.pathExtension
    let stem = (filename as NSString).deletingPathExtension
    let (baseStem, hadSuffix) = BackupScanner.stripCollisionSuffix(from: stem)
    let baseFilename = ext.isEmpty ? baseStem : baseStem + "." + ext
    let sf = BackupScanner.ScannedFile(
      url: url,
      year: year,
      month: month,
      filename: filename,
      baseFilename: baseFilename,
      hasCollisionSuffix: hadSuffix,
      fileExtension: ext.lowercased(),
      modificationDate: modDate,
      fileSize: 4
    )
    return (sf, rootDir)
  }

  private func service(
    _ assetsByYearMonth: [String: [AssetDescriptor]],
    resources: [String: [ResourceDescriptor]]
  ) -> FakePhotoLibraryService {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth = assetsByYearMonth
    svc.resourcesByAssetId = resources
    return svc
  }

  // MARK: - Exact original match

  @Test func classifiesOriginalFileAsOriginalVariant() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "orig-asset", creationDate: modDate, hasAdjustments: false)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "orig-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
    #expect(result.matched.first?.asset.id == "orig-asset")
  }

  // MARK: - Edited file with cross-extension

  @Test func classifiesEditedJpegAgainstHeicOriginal() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "heic-asset", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "heic-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001_edited.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .edited)
    #expect(result.matched.first?.asset.id == "heic-asset")
  }

  // MARK: - Original filename naturally containing "_edited"

  @Test func originalFilenameContainingEditedIsNotMisclassified() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // A user-supplied original filename that happens to end with "_edited".
    let asset = TestAssetFactory.makeAsset(
      id: "user-named", creationDate: modDate, hasAdjustments: false)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "user-named": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "vacation_edited.JPG")
        ]
      ]
    )
    let (file, root) = try makeScannedFile("vacation_edited.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
  }

  // MARK: - Collision-suffix edited companion

  @Test func collisionSuffixedEditedCompanionIsMatched() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "pair-asset", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "pair-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001 (1)_edited.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .edited)
    if case let .edited(parsed) = result.matched.first?.classification {
      #expect(parsed.groupStem == "IMG_0001 (1)")
      #expect(parsed.canonicalOriginalStem == "IMG_0001")
    } else {
      Issue.record("Expected edited classification")
    }
  }

  // MARK: - Final file-collision suffix form

  @Test func finalCollisionSuffixOnEditedFilenameClassifiesAsEdited() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "edited-collision", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "edited-collision": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001_edited (1).JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .edited)
    if case let .edited(parsed) = result.matched.first?.classification {
      #expect(parsed.fileCollisionSuffix == 1)
    } else {
      Issue.record("Expected edited classification")
    }
  }

  // MARK: - Import merges original and edited into separate variants

  @Test func importMergesOriginalAndEditedForSameAsset() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EVS-merge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "merge-test")

    let now = Date()
    store.bulkImportRecords([
      ExportRecord(
        id: "pair", year: 2025, month: 3, relPath: "2025/03/",
        variants: [
          .original: ExportVariantRecord(
            filename: "IMG_0001.JPG", status: .done, exportDate: now, lastError: nil)
        ])
    ])
    store.bulkImportRecords([
      ExportRecord(
        id: "pair", year: 2025, month: 3, relPath: "2025/03/",
        variants: [
          .edited: ExportVariantRecord(
            filename: "IMG_0001_edited.JPG", status: .done, exportDate: now, lastError: nil)
        ])
    ])
    store.flushForTesting()

    let record = store.exportInfo(assetId: "pair")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(record?.variants[.edited]?.filename == "IMG_0001_edited.JPG")
  }
}
