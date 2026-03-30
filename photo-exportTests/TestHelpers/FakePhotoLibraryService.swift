import AppKit
import Foundation
import Photos

@testable import Photo_Export

@MainActor
final class FakePhotoLibraryService: PhotoLibraryService {
  var isAuthorized: Bool = true
  var authorizationStatus: PHAuthorizationStatus = .authorized

  // Canned data
  var assetsByYearMonth: [String: [AssetDescriptor]] = [:]
  var resourcesByAssetId: [String: [ResourceDescriptor]] = [:]
  var detailsByAssetId: [String: AssetDetails] = [:]
  var thumbnailsByAssetId: [String: NSImage] = [:]
  var hqThumbnailsByAssetId: [String: NSImage] = [:]
  var fullImagesByAssetId: [String: NSImage] = [:]
  var yearCounts: [(year: Int, count: Int)] = []

  // Call tracking
  var fetchAssetsCalls: [(year: Int, month: Int?, mediaType: PHAssetMediaType?)] = []
  var writeResourceCalls: [(ResourceDescriptor, String, URL)] = []
  var startCachingCalls: [[AssetDescriptor]] = []
  var stopCachingCalls: [[AssetDescriptor]] = []

  // Error injection
  var fetchAssetsError: Error?
  var requestFullImageError: Error?

  func requestAuthorization() async -> Bool { isAuthorized }

  func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  {
    fetchAssetsCalls.append((year, month, mediaType))
    if let error = fetchAssetsError { throw error }

    if let month {
      let key = "\(year)-\(month)"
      let assets = assetsByYearMonth[key] ?? []
      if let mediaType {
        return assets.filter { $0.mediaType == mediaType }
      }
      return assets
    } else {
      // Fetch all months for the year
      var allAssets: [AssetDescriptor] = []
      for m in 1...12 {
        let key = "\(year)-\(m)"
        allAssets.append(contentsOf: assetsByYearMonth[key] ?? [])
      }
      if let mediaType {
        return allAssets.filter { $0.mediaType == mediaType }
      }
      return allAssets
    }
  }

  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
    for assets in assetsByYearMonth.values {
      if let found = assets.first(where: { $0.id == assetId }) { return found }
    }
    return nil
  }

  func countAssets(year: Int, month: Int) throws -> Int {
    let key = "\(year)-\(month)"
    return assetsByYearMonth[key]?.count ?? 0
  }

  func countAssets(year: Int) throws -> Int {
    var total = 0
    for m in 1...12 {
      total += (assetsByYearMonth["\(year)-\(m)"]?.count ?? 0)
    }
    return total
  }

  func availableYears() throws -> [Int] {
    yearCounts.map(\.year)
  }

  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    yearCounts
  }

  func startCachingThumbnails(for assets: [AssetDescriptor]) {
    startCachingCalls.append(assets)
  }

  func stopCachingThumbnails(for assets: [AssetDescriptor]) {
    stopCachingCalls.append(assets)
  }

  func loadThumbnail(for assetId: String, allowNetwork: Bool) async -> NSImage? {
    thumbnailsByAssetId[assetId]
  }

  func loadThumbnailHighQuality(for assetId: String, allowNetwork: Bool) async -> NSImage? {
    hqThumbnailsByAssetId[assetId]
  }

  func requestFullImage(for assetId: String) async throws -> NSImage {
    if let error = requestFullImageError { throw error }
    guard let image = fullImagesByAssetId[assetId] else {
      throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No image"])
    }
    return image
  }

  func resources(for assetId: String) -> [ResourceDescriptor] {
    resourcesByAssetId[assetId] ?? []
  }

  func assetDetails(for assetId: String) -> AssetDetails? {
    detailsByAssetId[assetId]
  }
}
