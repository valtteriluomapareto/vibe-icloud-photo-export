import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import os

/// Scans a backup folder in YYYY/MM/ layout and matches files to Photos library assets.
///
/// Used by the "Import Existing Backup…" feature to rebuild local export state
/// from an existing backup folder on a fresh install.
struct BackupScanner {

  // MARK: - Types

  /// A file discovered in the backup folder's YYYY/MM/ hierarchy.
  struct ScannedFile: Equatable {
    let url: URL
    let year: Int
    let month: Int
    let filename: String
    /// Filename with collision suffix ` (N)` stripped, e.g. "IMG_0001.jpg" from "IMG_0001 (2).jpg"
    let baseFilename: String
    let hasCollisionSuffix: Bool
    let fileExtension: String
    let modificationDate: Date?
    let fileSize: UInt64?
  }

  /// The outcome of matching scanned backup files against the Photos library.
  struct MatchResult {
    /// Files that matched exactly one Photos asset with strong confirmation.
    var matched: [(file: ScannedFile, asset: PHAsset)] = []
    /// Files where multiple Photos assets fit equally well.
    var ambiguous: [ScannedFile] = []
    /// Files with no matching Photos asset found.
    var unmatched: [ScannedFile] = []
  }

  /// Progress updates emitted during scan/match.
  enum ImportStage: Equatable {
    case scanningBackupFolder
    case readingPhotosLibrary
    case matchingAssets(matched: Int, total: Int)
    case rebuildingLocalState
    case done
  }

  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "BackupScanner")

  // MARK: - Collision suffix pattern

  /// Matches the app's collision suffix pattern: ` (N)` before the extension.
  /// e.g., "IMG_0001 (2).jpg" → base "IMG_0001", suffix " (2)"
  private static let collisionSuffixPattern = try! NSRegularExpression(
    pattern: #" \(\d+\)$"#)

  /// Strips the collision suffix from a filename stem (no extension).
  /// Returns the stripped stem and whether a suffix was found.
  static func stripCollisionSuffix(from stem: String) -> (stripped: String, hadSuffix: Bool) {
    let range = NSRange(stem.startIndex..., in: stem)
    if let match = collisionSuffixPattern.firstMatch(in: stem, range: range) {
      let matchRange = Range(match.range, in: stem)!
      let stripped = String(stem[stem.startIndex..<matchRange.lowerBound])
      return (stripped, true)
    }
    return (stem, false)
  }

  // MARK: - Backup folder scanning

  /// Enumerates files in YYYY/MM/ directories under the backup root.
  /// Only considers directories where YYYY is a 4-digit year and MM is 01–12.
  static func scanBackupFolder(at rootURL: URL) -> [ScannedFile] {
    let fm = FileManager.default
    var results: [ScannedFile] = []

    // List year directories
    guard let yearEntries = try? fm.contentsOfDirectory(
      at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else {
      logger.warning("Could not enumerate backup root: \(rootURL.path, privacy: .public)")
      return []
    }

    for yearDir in yearEntries {
      guard isDirectory(yearDir),
        let year = parseYear(yearDir.lastPathComponent)
      else { continue }

      guard let monthEntries = try? fm.contentsOfDirectory(
        at: yearDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      else { continue }

      for monthDir in monthEntries {
        guard isDirectory(monthDir),
          let month = parseMonth(monthDir.lastPathComponent)
        else { continue }

        guard let files = try? fm.contentsOfDirectory(
          at: monthDir,
          includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
          options: [.skipsHiddenFiles])
        else { continue }

        for fileURL in files {
          guard isRegularFile(fileURL) else { continue }

          let filename = fileURL.lastPathComponent
          let ext = fileURL.pathExtension
          let stem = (filename as NSString).deletingPathExtension
          let (baseStem, hadSuffix) = stripCollisionSuffix(from: stem)
          let baseFilename =
            ext.isEmpty ? baseStem : baseStem + "." + ext

          let resourceValues = try? fileURL.resourceValues(forKeys: [
            .contentModificationDateKey, .fileSizeKey
          ])

          results.append(
            ScannedFile(
              url: fileURL,
              year: year,
              month: month,
              filename: filename,
              baseFilename: baseFilename,
              hasCollisionSuffix: hadSuffix,
              fileExtension: ext.lowercased(),
              modificationDate: resourceValues?.contentModificationDate,
              fileSize: resourceValues?.fileSize.map(UInt64.init)
            ))
        }
      }
    }

    logger.info("Scanned \(results.count) files in backup folder")
    return results
  }

  // MARK: - Asset fingerprint (cheap, built once per asset)

  /// Value-type snapshot of a PHAsset's metadata, built once per asset batch.
  /// Avoids repeated PHAssetResource lookups during matching.
  struct AssetFingerprint {
    let localIdentifier: String
    let mediaType: PHAssetMediaType
    let creationDate: Date?
    /// Seconds since reference date, truncated — used as hash key for fast lookup
    let creationSecond: Int?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    /// Original filenames from PHAssetResource (cached once)
    let originalFilenames: [String]
  }

  /// Builds fingerprints for a batch of PHAssets. Calls PHAssetResource once per asset.
  static func buildFingerprints(for assets: [PHAsset]) -> [AssetFingerprint] {
    assets.map { asset in
      let resources = PHAssetResource.assetResources(for: asset)
      let filenames = resources.map { $0.originalFilename }
      let creationSecond: Int? =
        asset.creationDate.map { Int($0.timeIntervalSinceReferenceDate) }
      return AssetFingerprint(
        localIdentifier: asset.localIdentifier,
        mediaType: asset.mediaType,
        creationDate: asset.creationDate,
        creationSecond: creationSecond,
        pixelWidth: asset.pixelWidth,
        pixelHeight: asset.pixelHeight,
        duration: asset.duration,
        originalFilenames: filenames
      )
    }
  }

  // MARK: - Matching

  /// Matches scanned backup files against Photos library assets.
  ///
  /// Hybrid matching strategy:
  /// 1. Build AssetFingerprint snapshots once per asset (O(assets) PHAssetResource calls)
  /// 2. Index fingerprints by (mediaType, creation-second) for fast lookup
  /// 3. For each file, use modification date as primary lookup key
  /// 4. If not unique, intersect with filename matches from cached fingerprints
  /// 5. Only if still ambiguous, lazily read file dimensions/duration (cached per file)
  ///
  /// Adjacent months are included to handle time-zone boundary drift.
  static func matchFiles(
    _ scannedFiles: [ScannedFile],
    photoLibraryManager: PhotoLibraryManager,
    progress: @MainActor (ImportStage) -> Void
  ) async throws -> MatchResult {
    var result = MatchResult()

    // Group scanned files by year-month for batch fetching
    var filesByYearMonth: [String: [ScannedFile]] = [:]
    for file in scannedFiles {
      let key = "\(file.year)-\(file.month)"
      filesByYearMonth[key, default: []].append(file)
    }

    // Caches: assets and fingerprints per year-month
    var assetsByYearMonth: [String: [PHAsset]] = [:]
    var fingerprintsByYearMonth: [String: [AssetFingerprint]] = [:]

    let totalFiles = scannedFiles.count
    var matchedCount = 0

    for (_, files) in filesByYearMonth {
      let year = files[0].year
      let month = files[0].month

      // Pre-fetch primary month and adjacent months (for time-zone boundary drift)
      let monthsToFetch = adjacentYearMonths(year: year, month: month)
      for (y, m) in monthsToFetch {
        let k = "\(y)-\(m)"
        if assetsByYearMonth[k] == nil {
          try Task.checkCancellation()
          await progress(.readingPhotosLibrary)
          let assets = (try? await photoLibraryManager.fetchAssets(year: y, month: m)) ?? []
          assetsByYearMonth[k] = assets
          // Build fingerprints once — this is the only PHAssetResource call site
          fingerprintsByYearMonth[k] = buildFingerprints(for: assets)
        }
      }

      // Combine fingerprints from primary and adjacent months
      var combinedFingerprints: [AssetFingerprint] = []
      for (y, m) in monthsToFetch {
        combinedFingerprints.append(contentsOf: fingerprintsByYearMonth["\(y)-\(m)"] ?? [])
      }

      // Build index: (mediaType, creationSecond) → [fingerprint indices]
      var dateIndex: [DateIndexKey: [Int]] = [:]
      for (i, fp) in combinedFingerprints.enumerated() {
        if let sec = fp.creationSecond {
          let key = DateIndexKey(mediaType: fp.mediaType, creationSecond: sec)
          dateIndex[key, default: []].append(i)
        }
      }

      // Combine assets for result references (matched result needs PHAsset)
      var combinedAssets: [PHAsset] = []
      for (y, m) in monthsToFetch {
        combinedAssets.append(contentsOf: assetsByYearMonth["\(y)-\(m)"] ?? [])
      }
      // Build localIdentifier → PHAsset lookup
      var assetById: [String: PHAsset] = [:]
      for asset in combinedAssets {
        assetById[asset.localIdentifier] = asset
      }

      for file in files {
        try Task.checkCancellation()
        matchedCount += 1
        if matchedCount % 50 == 0 {
          await progress(.matchingAssets(matched: result.matched.count, total: totalFiles))
          await Task.yield()
        }

        if combinedFingerprints.isEmpty {
          result.unmatched.append(file)
          continue
        }

        let matchOutcome = matchSingleFile(
          file,
          fingerprints: combinedFingerprints,
          dateIndex: dateIndex
        )
        switch matchOutcome {
        case .matched(let fp):
          if let asset = assetById[fp.localIdentifier] {
            result.matched.append((file: file, asset: asset))
          } else {
            result.unmatched.append(file)
          }
        case .ambiguous:
          result.ambiguous.append(file)
        case .unmatched:
          result.unmatched.append(file)
        }
      }
    }

    logger.info(
      "Match complete: \(result.matched.count) matched, \(result.ambiguous.count) ambiguous, \(result.unmatched.count) unmatched"
    )
    return result
  }

  /// Hash key for the (mediaType, creationSecond) index.
  private struct DateIndexKey: Hashable {
    let mediaType: PHAssetMediaType
    let creationSecond: Int
  }

  /// Returns (year, month) tuples for a month and its two neighbors.
  /// Handles year boundaries (e.g., Jan → prev Dec, Dec → next Jan).
  private static func adjacentYearMonths(year: Int, month: Int) -> [(Int, Int)] {
    var results = [(year, month)]
    if month == 1 {
      results.append((year - 1, 12))
    } else {
      results.append((year, month - 1))
    }
    if month == 12 {
      results.append((year + 1, 1))
    } else {
      results.append((year, month + 1))
    }
    return results
  }

  // MARK: - Hybrid single-file matching

  private enum SingleMatchOutcome {
    case matched(AssetFingerprint)
    case ambiguous
    case unmatched
  }

  /// Hybrid matching for a single backup file against pre-built fingerprints.
  ///
  /// 1. Primary: find candidates by mod-date → creation-second match (fast hash lookup)
  /// 2. If not unique, narrow by filename from cached fingerprints
  /// 3. Only if still ambiguous, lazily read file dimensions/duration (once per file)
  private static func matchSingleFile(
    _ file: ScannedFile,
    fingerprints: [AssetFingerprint],
    dateIndex: [DateIndexKey: [Int]]
  ) -> SingleMatchOutcome {
    let expectedMediaType = mediaType(for: file.fileExtension)

    // Step 1: Fast date-based lookup
    var candidates: [AssetFingerprint] = []
    if let modDate = file.modificationDate {
      let modSecond = Int(modDate.timeIntervalSinceReferenceDate)
      // Check the exact second and ±1 second to handle rounding
      for offset in -1...1 {
        let key = DateIndexKey(mediaType: expectedMediaType, creationSecond: modSecond + offset)
        if let indices = dateIndex[key] {
          for i in indices {
            let fp = fingerprints[i]
            // Verify within 1.0 second (the hash is truncated, so refine here)
            if let cd = fp.creationDate {
              if abs(modDate.timeIntervalSince(cd)) <= 1.0 {
                candidates.append(fp)
              }
            }
          }
        }
      }
    }

    if candidates.count == 1 {
      return .matched(candidates[0])
    }

    // Step 2: Narrow by filename (using cached fingerprint filenames, no Photos calls)
    if candidates.count > 1 {
      let byFilename = candidates.filter { fp in
        filenameMatches(file: file, fingerprint: fp)
      }
      if byFilename.count == 1 { return .matched(byFilename[0]) }
      if byFilename.count > 1 { return .ambiguous }
      // filename didn't help — still ambiguous from date alone
      return .ambiguous
    }

    // Step 3: No date match — fall back to filename-only search across all fingerprints
    let nameMatched = fingerprints.filter { fp in
      fp.mediaType == expectedMediaType
        && fp.creationDate != nil
        && self.filenameMatches(file: file, fingerprint: fp)
    }

    if nameMatched.isEmpty {
      return .unmatched
    }

    // Step 4: Disambiguate filename matches with lazy file metadata (read once per file)
    let withDiscriminator = discriminateByFileMetadata(
      file: file, candidates: nameMatched)

    if withDiscriminator.count == 1 {
      return .matched(withDiscriminator[0])
    } else if withDiscriminator.count > 1 {
      return .ambiguous
    }

    // Had filename matches but no strong discriminator confirmed any
    return .ambiguous
  }

  /// Checks if a file's name matches an asset fingerprint's original filenames.
  private static func filenameMatches(
    file: ScannedFile, fingerprint: AssetFingerprint
  ) -> Bool {
    // Exact filename match
    if fingerprint.originalFilenames.contains(file.filename) {
      return true
    }
    // Base filename match (collision suffix stripped)
    if fingerprint.originalFilenames.contains(file.baseFilename) {
      return true
    }
    return false
  }

  /// Lazy discriminator: reads file dimensions/duration ONCE and checks all candidates.
  private static func discriminateByFileMetadata(
    file: ScannedFile, candidates: [AssetFingerprint]
  ) -> [AssetFingerprint] {
    // Read file metadata once
    var fileDimensions: (width: Int, height: Int)?
    var fileDuration: TimeInterval?

    let mediaType = mediaType(for: file.fileExtension)
    if mediaType == .image {
      fileDimensions = imagePixelDimensions(at: file.url)
    } else if mediaType == .video {
      fileDuration = videoDuration(at: file.url)
    }

    return candidates.filter { fp in
      // Mod date match
      if let modDate = file.modificationDate, let cd = fp.creationDate {
        if abs(modDate.timeIntervalSince(cd)) <= 1.0 {
          return true
        }
      }

      // Image dimensions match
      if let dims = fileDimensions {
        let widthMatch = dims.width == fp.pixelWidth && dims.height == fp.pixelHeight
        let rotatedMatch = dims.width == fp.pixelHeight && dims.height == fp.pixelWidth
        if widthMatch || rotatedMatch {
          return true
        }
      }

      // Video duration match
      if let dur = fileDuration, dur > 0, abs(dur - fp.duration) <= 1.0 {
        return true
      }

      return false
    }
  }

  // MARK: - Media type inference

  private static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "heic", "heif", "png", "tiff", "tif", "gif", "bmp", "webp", "dng", "raw",
    "cr2", "cr3", "nef", "arw", "orf", "rw2"
  ]

  private static let videoExtensions: Set<String> = [
    "mov", "mp4", "m4v", "avi", "mkv", "3gp", "mts"
  ]

  static func mediaType(for fileExtension: String) -> PHAssetMediaType {
    let ext = fileExtension.lowercased()
    if imageExtensions.contains(ext) { return .image }
    if videoExtensions.contains(ext) { return .video }
    return .unknown
  }

  // MARK: - File metadata helpers

  /// Reads pixel dimensions from an image file without loading the full image.
  private static func imagePixelDimensions(at url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return nil }
    guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
  }

  /// Reads the duration of a video file.
  /// Uses the legacy synchronous `duration` property since this is only called
  /// for the rare ambiguous-file fallback path, not the hot loop.
  @available(macOS, deprecated: 13.0, message: "Acceptable: only used in rare fallback path")
  private static func videoDuration(at url: URL) -> TimeInterval {
    let avAsset = AVURLAsset(
      url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let duration = avAsset.duration
    guard duration.timescale > 0 else { return 0 }
    return CMTimeGetSeconds(duration)
  }

  // MARK: - Filesystem helpers

  private static func isDirectory(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
    return values?.isDirectory == true
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
    return values?.isRegularFile == true
  }

  private static func parseYear(_ component: String) -> Int? {
    guard component.count == 4, let year = Int(component), year >= 1900, year <= 2100 else {
      return nil
    }
    return year
  }

  private static func parseMonth(_ component: String) -> Int? {
    guard component.count == 2, let month = Int(component), (1...12).contains(month) else {
      return nil
    }
    return month
  }
}
