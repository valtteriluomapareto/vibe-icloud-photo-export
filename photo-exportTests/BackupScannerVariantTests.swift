import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Scanner tests for variant-aware classification under the redesigned `_orig`-companion
/// naming convention.
@MainActor
struct BackupScannerVariantTests {
  private func makeScannedFile(
    _ filename: String, year: Int = 2025, month: Int = 6, modDate: Date? = nil
  ) throws -> (BackupScanner.ScannedFile, URL) {
    let rootDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BSV-\(UUID().uuidString)", isDirectory: true)
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

  // MARK: - Cross-extension default-mode classifier

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
    let (file, root) = try makeScannedFile("IMG_0001.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .edited)
    #expect(result.matched.first?.asset.id == "heic-asset")
  }

  // MARK: - Same-extension default-mode classifies as `.original`

  @Test func classifiesSameExtensionEditAsOriginalWhenStemAndExtMatchOriginalResource()
    async throws
  {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "jpg-asset", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "jpg-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    // Default mode wrote `IMG_0001.JPG` (the edit, but at natural stem). Scanner can't
    // distinguish this from the original by filename alone — documented limitation.
    let (file, root) = try makeScannedFile("IMG_0001.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
  }

  // MARK: - `_orig` companion classifies as `.original`

  @Test func origCompanionClassifiesAsOriginal() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "pair-asset", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "pair-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001_orig.HEIC", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
    #expect(result.matched.first?.asset.id == "pair-asset")
  }

  // MARK: - User filename `vacation_orig.JPG` falls through to step 2

  @Test func userOrigFilenameWithoutAdjustedSiblingClassifiesAsOriginal() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // Asset is unedited; its actual original filename is `vacation_orig.JPG`. No asset with
    // stem `vacation` and adjustments exists, so step 1 fails to match and the file falls
    // through to step 2 (exact original).
    let asset = TestAssetFactory.makeAsset(
      id: "user-named", creationDate: modDate, hasAdjustments: false)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "user-named": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "vacation_orig.JPG")
        ]
      ]
    )
    let (file, root) = try makeScannedFile("vacation_orig.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
  }

  // MARK: - Native ` (N)` filename + `_orig` companion → edit + original pair

  @Test func nativeCollisionSuffixedAssetWithOrigCompanionPairsAsEditAndOriginal() async throws {
    // Asset's actual original filename is `IMG_0001 (1).JPG` (native ` (N)` in the user's
    // filename, not app-added). Destination has the include-originals output:
    // `IMG_0001 (1).JPG` (the edit, at the asset's native stem) and
    // `IMG_0001 (1)_orig.JPG` (the original companion). The natural-stem file pairs with
    // the `_orig` sibling, so it must classify as `.edited`, not `.original`.
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "native-suffix", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "native-suffix": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001 (1).JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (editedFile, root1) = try makeScannedFile(
      "IMG_0001 (1).JPG", modDate: modDate)
    let (origFile, root2) = try makeScannedFile(
      "IMG_0001 (1)_orig.JPG", year: 2025, month: 6, modDate: modDate)
    defer {
      try? FileManager.default.removeItem(at: root1)
      try? FileManager.default.removeItem(at: root2)
    }

    let result = try await BackupScanner.matchFiles(
      [editedFile, origFile], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 2)
    let byFilename = Dictionary(
      uniqueKeysWithValues: result.matched.map { ($0.file.filename, $0.variant) })
    #expect(byFilename["IMG_0001 (1).JPG"] == .edited)
    #expect(byFilename["IMG_0001 (1)_orig.JPG"] == .original)
  }

  // MARK: - Same-extension include-originals pair classifies losslessly

  @Test func sameExtensionIncludeOriginalsPairClassifiesEditAndOriginal() async throws {
    // Asset is JPEG → JPEG-edited, exported with include-originals: destination contains
    // `IMG_0001.JPG` (edit) + `IMG_0001_orig.JPG` (original). The pair-aware classifier
    // uses the `_orig` sibling signal to label the natural-stem file as `.edited`.
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "jpg-pair", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "jpg-pair": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (editFile, root1) = try makeScannedFile("IMG_0001.JPG", modDate: modDate)
    let (origFile, root2) = try makeScannedFile(
      "IMG_0001_orig.JPG", year: 2025, month: 6, modDate: modDate)
    defer {
      try? FileManager.default.removeItem(at: root1)
      try? FileManager.default.removeItem(at: root2)
    }

    let result = try await BackupScanner.matchFiles(
      [editFile, origFile], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 2)
    let byFilename = Dictionary(
      uniqueKeysWithValues: result.matched.map { ($0.file.filename, $0.variant) })
    #expect(byFilename["IMG_0001.JPG"] == .edited)
    #expect(byFilename["IMG_0001_orig.JPG"] == .original)
  }

  // MARK: - Two adjusted assets share a stem; date narrows to one

  @Test func origCompanionDisambiguatesByDateWhenMultipleCandidates() async throws {
    let modDateA = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let modDateB = Date(timeIntervalSinceReferenceDate: 900_000_000)
    let assetA = TestAssetFactory.makeAsset(
      id: "asset-a", creationDate: modDateA, hasAdjustments: true)
    let assetB = TestAssetFactory.makeAsset(
      id: "asset-b", creationDate: modDateB, hasAdjustments: true)
    let svc = service(
      ["2025-6": [assetA, assetB]],
      resources: [
        "asset-a": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_TEST.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullA.JPG"),
        ],
        "asset-b": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_TEST.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullB.JPG"),
        ],
      ]
    )
    // The companion's mod date matches Asset B.
    let (file, root) = try makeScannedFile("IMG_TEST_orig.JPG", modDate: modDateB)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.asset.id == "asset-b")
    #expect(result.matched.first?.variant == .original)
  }

  // MARK: - `_orig` matching with multiple candidates and identical dates → ambiguous

  @Test func origCompanionWithIdenticalDatesIsAmbiguous() async throws {
    // Two adjusted assets share both an original Photos filename and a creation date.
    // Step 1 collects both; `narrow` cannot pick one by date (identical), so the file
    // is ambiguous rather than a coin-flip classification.
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // Distinct dimensions so dimension-based discriminator can't accidentally match either.
    let assetA = TestAssetFactory.makeAsset(
      id: "asset-a", creationDate: modDate, pixelWidth: 100, pixelHeight: 100,
      hasAdjustments: true)
    let assetB = TestAssetFactory.makeAsset(
      id: "asset-b", creationDate: modDate, pixelWidth: 200, pixelHeight: 200,
      hasAdjustments: true)
    let svc = service(
      ["2025-6": [assetA, assetB]],
      resources: [
        "asset-a": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_TEST.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullA.JPG"),
        ],
        "asset-b": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_TEST.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullB.JPG"),
        ],
      ]
    )
    let (file, root) = try makeScannedFile("IMG_TEST_orig.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.count == 1)
  }

  // MARK: - Import merges original and edited into separate variants

  @Test func importMergesOriginalAndEditedForSameAsset() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BSV-merge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "merge-test")

    let now = Date()
    store.bulkImportRecords([
      ExportRecord(
        id: "pair", year: 2025, month: 3, relPath: "2025/03/",
        variants: [
          .original: ExportVariantRecord(
            filename: "IMG_0001_orig.HEIC", status: .done, exportDate: now, lastError: nil)
        ])
    ])
    store.bulkImportRecords([
      ExportRecord(
        id: "pair", year: 2025, month: 3, relPath: "2025/03/",
        variants: [
          .edited: ExportVariantRecord(
            filename: "IMG_0001.JPG", status: .done, exportDate: now, lastError: nil)
        ])
    ])
    store.flushForTesting()

    let record = store.exportInfo(assetId: "pair")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001_orig.HEIC")
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG")
  }
}
