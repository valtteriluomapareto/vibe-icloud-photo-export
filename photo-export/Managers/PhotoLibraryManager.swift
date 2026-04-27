import AppKit
import Photos
import SwiftUI
import os

/// Manages access to the Photos library, including authorization and asset fetching
@MainActor
final class PhotoLibraryManager: NSObject, ObservableObject, PhotoLibraryService {
  /// Published properties to track authorization status
  @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
  @Published var isAuthorized: Bool = false

  private let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Photos")

  /// Errors that can occur in the Photo Library Manager
  enum PhotoLibraryError: Error {
    case authorizationDenied
    case fetchFailed
    case assetUnavailable
  }

  /// Shared caching image manager for thumbnails
  private static let cachingImageManager = PHCachingImageManager()

  /// Bounded cache of recently-fetched PHAsset objects keyed by localIdentifier.
  /// Populated by fetchAssets so thumbnail and resource lookups avoid re-fetching.
  /// Replaced wholesale on each fetch rather than doing per-entry eviction.
  private var phAssetCache: [String: PHAsset] = [:]

  /// Cache of adjusted-asset counts keyed by `"YYYY-M"`. Populated lazily by
  /// `countAdjustedAssets` and cleared when the Photos library changes or the user re-authorises.
  private var adjustedCountByYearMonth: [String: Int] = [:]

  nonisolated static func isAuthorizationSufficient(_ status: PHAuthorizationStatus) -> Bool {
    status == .authorized || status == .limited
  }

  override init() {
    super.init()
    // Check if Info.plist contains photos usage description
    verifyPhotoLibraryPermissions()
    // Observe library changes to invalidate cache
    PHPhotoLibrary.shared().register(self)

    // Initialize with current authorization status
    authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    isAuthorized = Self.isAuthorizationSufficient(authorizationStatus)
  }

  /// Verify that Photos usage description is properly set in Info.plist
  private func verifyPhotoLibraryPermissions() {
    let bundleDict = Bundle.main.infoDictionary
    if bundleDict?["NSPhotoLibraryUsageDescription"] == nil {
      logger.warning("NSPhotoLibraryUsageDescription not found in Info.plist")
      logger.warning(
        "Available keys: \(bundleDict?.keys.joined(separator: ", ") ?? "none", privacy: .public)")
    } else {
      logger.debug("Found NSPhotoLibraryUsageDescription in Info.plist")
    }
  }

  /// Request authorization to access the Photos library
  func requestAuthorization() async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)

    await MainActor.run {
      self.authorizationStatus = status
      self.isAuthorized = Self.isAuthorizationSufficient(status)
      // Authorisation changes may change which assets are visible; drop the adjusted-count
      // cache so the next query reflects the new scope.
      self.adjustedCountByYearMonth.removeAll()
    }

    return Self.isAuthorizationSufficient(status)
  }

  /// Returns the number of assets in the given year/month whose `hasAdjustments` is true.
  ///
  /// `PHAsset.hasAdjustments` cannot be expressed as a Photos fetch predicate, so this falls
  /// back to iterating the month's assets. Results are cached until the next library change
  /// or authorisation change.
  func countAdjustedAssets(year: Int, month: Int) async throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    let key = "\(year)-\(month)"
    if let cached = adjustedCountByYearMonth[key] { return cached }
    let assets = try await fetchPHAssets(year: year, month: month, mediaType: nil)
    var count = 0
    for asset in assets where asset.hasAdjustments { count += 1 }
    adjustedCountByYearMonth[key] = count
    return count
  }

  /// Returns the number of assets in the given year whose `hasAdjustments` is true. Sums the
  /// per-month cache, populating each month on demand.
  func countAdjustedAssets(year: Int) async throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    var total = 0
    for month in 1...12 {
      total += try await countAdjustedAssets(year: year, month: month)
    }
    return total
  }

  // MARK: - Asset Fetching (PhotoLibraryService)

  func fetchAssets(year: Int, month: Int? = nil, mediaType: PHAssetMediaType? = nil) async throws
    -> [AssetDescriptor]
  {
    let phAssets = try await fetchPHAssets(year: year, month: month, mediaType: mediaType)
    cacheAssets(phAssets)
    return phAssets.map { Self.descriptor(from: $0) }
  }

  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
    // Always re-fetch from Photos to ensure the asset still exists
    // (it may have been deleted since it was enqueued for export)
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
    guard let asset = result.firstObject else {
      phAssetCache.removeValue(forKey: assetId)
      return nil
    }
    cacheAssets([asset])
    return Self.descriptor(from: asset)
  }

  /// Fast count of assets in a given year/month without loading them into memory
  func countAssets(year: Int, month: Int) throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    let calendar = Calendar.current
    var start = DateComponents()
    start.year = year
    start.month = month
    start.day = 1
    var end = DateComponents()
    end.year = year
    end.month = month + 1
    end.day = 1
    guard let startDate = calendar.date(from: start), let endDate = calendar.date(from: end)
    else {
      throw PhotoLibraryError.fetchFailed
    }
    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(
      format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
      endDate as NSDate)
    let result = PHAsset.fetchAssets(with: opts)
    return result.count
  }

  /// Fast count of assets in a given year
  func countAssets(year: Int) throws -> Int {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
    let calendar = Calendar.current
    var start = DateComponents()
    start.year = year
    start.month = 1
    start.day = 1
    var end = DateComponents()
    end.year = year + 1
    end.month = 1
    end.day = 1
    guard let startDate = calendar.date(from: start), let endDate = calendar.date(from: end)
    else {
      throw PhotoLibraryError.fetchFailed
    }
    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(
      format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
      endDate as NSDate)
    let result = PHAsset.fetchAssets(with: opts)
    return result.count
  }

  /// Returns descending list of years that have at least one asset
  func availableYears() throws -> [Int] {
    try availableYearsWithCounts().map(\.year)
  }

  /// Returns descending list of years with at least one asset, together with per-year asset counts.
  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }

    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    let result = PHAsset.fetchAssets(with: opts)
    let count = result.count
    guard count > 0 else { return [] }

    guard let firstDate = result.object(at: 0).creationDate,
      let lastDate = result.object(at: count - 1).creationDate
    else {
      return []
    }

    let calendar = Calendar.current
    let startYear = calendar.component(.year, from: firstDate)
    let endYear = calendar.component(.year, from: lastDate)
    guard startYear <= endYear else { return [] }

    var yearCounts: [(year: Int, count: Int)] = []
    for year in stride(from: endYear, through: startYear, by: -1) {
      let c = (try? self.countAssets(year: year)) ?? 0
      if c > 0 {
        yearCounts.append((year, c))
      }
    }
    return yearCounts
  }

  // MARK: - Thumbnail Management (PhotoLibraryService)

  func startCachingThumbnails(for assets: [AssetDescriptor]) {
    // Use cached PHAssets (populated by the preceding fetchAssets call)
    let phAssets = assets.compactMap { phAssetCache[$0.id] }
    guard !phAssets.isEmpty else { return }
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.isNetworkAccessAllowed = true
    options.resizeMode = .fast
    Self.cachingImageManager.startCachingImages(
      for: phAssets, targetSize: CGSize(width: 200, height: 200),
      contentMode: .aspectFill, options: options)
  }

  func stopCachingThumbnails(for assets: [AssetDescriptor]) {
    let phAssets = assets.compactMap { phAssetCache[$0.id] }
    guard !phAssets.isEmpty else { return }
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.isNetworkAccessAllowed = true
    options.resizeMode = .fast
    Self.cachingImageManager.stopCachingImages(
      for: phAssets, targetSize: CGSize(width: 200, height: 200),
      contentMode: .aspectFill, options: options)
  }

  /// Load thumbnail for an asset (fast/degraded version only, for initial grid population)
  func loadThumbnail(for assetId: String, allowNetwork: Bool = true) async -> NSImage? {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return nil }
    return await withCheckedContinuation { continuation in
      let options = PHImageRequestOptions()
      options.deliveryMode = .fastFormat
      options.isNetworkAccessAllowed = false
      options.resizeMode = .fast

      let resumed = OSAllocatedUnfairLock(initialState: false)

      Self.cachingImageManager.requestImage(
        for: asset,
        targetSize: CGSize(width: 200, height: 200),
        contentMode: .aspectFill,
        options: options
      ) { image, _ in
        guard
          resumed.withLock({
            let was = $0
            $0 = true
            return !was
          })
        else { return }
        self.logger.debug(
          "thumbnail fast id: \(assetId, privacy: .public) imageNil: \((image == nil))"
        )
        continuation.resume(returning: image)
      }
    }
  }

  /// Load a high-quality thumbnail for an asset
  func loadThumbnailHighQuality(for assetId: String, allowNetwork: Bool = true) async -> NSImage? {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return nil }
    return await withCheckedContinuation { continuation in
      let options = PHImageRequestOptions()
      options.deliveryMode = .highQualityFormat
      options.isNetworkAccessAllowed = allowNetwork
      options.resizeMode = .exact

      let resumed = OSAllocatedUnfairLock(initialState: false)

      Self.cachingImageManager.requestImage(
        for: asset,
        targetSize: CGSize(width: 200, height: 200),
        contentMode: .aspectFill,
        options: options
      ) { image, _ in
        guard
          resumed.withLock({
            let was = $0
            $0 = true
            return !was
          })
        else { return }
        self.logger.debug(
          "thumbnail HQ id: \(assetId, privacy: .public) imageNil: \((image == nil))"
        )
        continuation.resume(returning: image)
      }
    }
  }

  /// Request a full-size image for an asset
  func requestFullImage(for assetId: String) async throws -> NSImage {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else {
      throw PhotoLibraryError.assetUnavailable
    }
    return try await withCheckedThrowingContinuation { continuation in
      let options = PHImageRequestOptions()
      options.deliveryMode = .highQualityFormat
      options.isNetworkAccessAllowed = true
      options.isSynchronous = false

      self.logger.debug(
        "requestFullImage start id: \(assetId, privacy: .public) size: \(asset.pixelWidth)x\(asset.pixelHeight)"
      )

      let resumed = OSAllocatedUnfairLock(initialState: false)

      PHImageManager.default().requestImage(
        for: asset,
        targetSize: PHImageManagerMaximumSize,
        contentMode: .aspectFit,
        options: options
      ) { image, info in
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
        let isInCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
        let isCancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
        let requestID = (info?[PHImageResultRequestIDKey] as? NSNumber)?.intValue ?? 0
        let error = info?[PHImageErrorKey] as? NSError
        self.logger.debug(
          "requestFullImage callback id: \(assetId, privacy: .public) requestID: \(requestID) degraded: \(isDegraded) inCloud: \(isInCloud) cancelled: \(isCancelled) imageNil: \((image == nil)) error: \(String(describing: error?.localizedDescription), privacy: .public)"
        )

        if isCancelled || error != nil {
          guard
            resumed.withLock({
              let was = $0
              $0 = true
              return !was
            })
          else { return }
          if let error = error as? Error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(throwing: PhotoLibraryError.assetUnavailable)
          }
          return
        }

        if isDegraded { return }

        guard
          resumed.withLock({
            let was = $0
            $0 = true
            return !was
          })
        else { return }

        guard let image = image else {
          continuation.resume(throwing: PhotoLibraryError.assetUnavailable)
          return
        }

        continuation.resume(returning: image)
      }
    }
  }

  // MARK: - Resource Access (PhotoLibraryService)

  func resources(for assetId: String) -> [ResourceDescriptor] {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return [] }
    return PHAssetResource.assetResources(for: asset).map {
      ResourceDescriptor(type: $0.type, originalFilename: $0.originalFilename)
    }
  }

  func assetDetails(for assetId: String) -> AssetDetails? {
    guard let asset = cachedOrFetchPHAsset(id: assetId) else { return nil }
    let phResources = PHAssetResource.assetResources(for: asset)
    let primaryResource =
      phResources.first(where: { $0.type == .photo })
      ?? phResources.first(where: { $0.type == .video })
      ?? phResources.first
    let originalFilename = primaryResource?.originalFilename
    // "fileSize" is an undocumented KVC property on PHAssetResource
    let fileSize: Int64? = {
      guard let r = primaryResource,
        let size = r.value(forKey: "fileSize") as? Int64, size > 0
      else { return nil }
      return size
    }()
    let descriptors = phResources.map {
      ResourceDescriptor(type: $0.type, originalFilename: $0.originalFilename)
    }
    return AssetDetails(
      originalFilename: originalFilename, fileSize: fileSize, resources: descriptors)
  }

  // MARK: - Internal PHAsset Helpers

  /// Inserts assets into the cache.
  private func cacheAssets(_ assets: [PHAsset]) {
    for asset in assets {
      phAssetCache[asset.localIdentifier] = asset
    }
  }

  /// Resolves a single PHAsset by id, preferring the in-memory cache.
  private func cachedOrFetchPHAsset(id: String) -> PHAsset? {
    if let cached = phAssetCache[id] { return cached }
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    guard let asset = result.firstObject else { return nil }
    cacheAssets([asset])
    return asset
  }

  /// Clears the entire PHAsset cache (called on library changes).
  private func invalidateCache() {
    phAssetCache.removeAll()
    adjustedCountByYearMonth.removeAll()
  }

  private func fetchPHAssets(identifiers: [String]) -> [PHAsset] {
    let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
    var assets: [PHAsset] = []
    result.enumerateObjects { asset, _, _ in
      assets.append(asset)
    }
    return assets
  }

  /// Fetch raw PHAssets for a specific year and month
  private func fetchPHAssets(year: Int, month: Int? = nil, mediaType: PHAssetMediaType? = nil)
    async throws -> [PHAsset]
  {
    guard isAuthorized else {
      throw PhotoLibraryError.authorizationDenied
    }

    // Create date predicates for filtering
    let calendar = Calendar.current
    var startDateComponents = DateComponents()
    startDateComponents.year = year
    startDateComponents.month = month ?? 1
    startDateComponents.day = 1

    var endDateComponents = DateComponents()
    endDateComponents.year = month == nil ? year + 1 : year
    endDateComponents.month = month == nil ? 1 : (month! + 1)
    endDateComponents.day = 1

    guard let startDate = calendar.date(from: startDateComponents),
      let endDate = calendar.date(from: endDateComponents)
    else {
      throw PhotoLibraryError.fetchFailed
    }

    // Create fetch options
    let fetchOptions = PHFetchOptions()

    // Create date predicate
    fetchOptions.predicate = NSPredicate(
      format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
      endDate as NSDate)

    // Add media type filter if specified
    if let mediaType = mediaType {
      let mediaTypePredicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)

      if let existingPredicate = fetchOptions.predicate {
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
          existingPredicate, mediaTypePredicate,
        ])
      } else {
        fetchOptions.predicate = mediaTypePredicate
      }
    }

    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

    // Fetch assets
    let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
    var assets: [PHAsset] = []

    // Process in batches to avoid loading everything into memory at once
    let totalAssets = fetchResult.count
    let batchSize = 500

    for index in 0..<totalAssets {
      autoreleasepool {
        assets.append(fetchResult.object(at: index))
      }

      // Yield to main thread periodically
      if index % batchSize == 0 && index > 0 {
        try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
      }
    }

    return assets
  }

  static func descriptor(from asset: PHAsset) -> AssetDescriptor {
    AssetDescriptor(
      id: asset.localIdentifier,
      creationDate: asset.creationDate,
      mediaType: asset.mediaType,
      pixelWidth: asset.pixelWidth,
      pixelHeight: asset.pixelHeight,
      duration: asset.duration,
      hasAdjustments: asset.hasAdjustments
    )
  }
}

// MARK: - PHPhotoLibraryChangeObserver

extension PhotoLibraryManager: @preconcurrency PHPhotoLibraryChangeObserver {
  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor in
      self.invalidateCache()
    }
  }
}
