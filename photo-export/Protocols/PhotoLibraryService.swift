import AppKit
import Photos

/// Abstracts access to the Photos library for testability.
/// PhotoLibraryManager conforms in production; tests inject a fake.
@MainActor
protocol PhotoLibraryService: AnyObject {
  var isAuthorized: Bool { get }
  var authorizationStatus: PHAuthorizationStatus { get }

  func requestAuthorization() async -> Bool
  func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws
    -> [AssetDescriptor]
  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor?
  func countAssets(year: Int, month: Int) throws -> Int
  func countAssets(year: Int) throws -> Int
  func availableYears() throws -> [Int]
  func availableYearsWithCounts() throws -> [(year: Int, count: Int)]

  func startCachingThumbnails(for assets: [AssetDescriptor])
  func stopCachingThumbnails(for assets: [AssetDescriptor])
  func loadThumbnail(for assetId: String, allowNetwork: Bool) async -> NSImage?
  func loadThumbnailHighQuality(for assetId: String, allowNetwork: Bool) async -> NSImage?
  func requestFullImage(for assetId: String) async throws -> NSImage

  func resources(for assetId: String) -> [ResourceDescriptor]
  func assetDetails(for assetId: String) -> AssetDetails?
}

extension PhotoLibraryService {
  func fetchAssets(year: Int, month: Int?) async throws -> [AssetDescriptor] {
    try await fetchAssets(year: year, month: month, mediaType: nil)
  }
}
