import Foundation
import Photos
import os

/// Production implementation of AssetResourceWriter that wraps PHAssetResourceManager.
struct ProductionAssetResourceWriter: AssetResourceWriter {
  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ResourceWriter")

  func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
    async throws
  {
    // Resolve the real PHAssetResource from the asset
    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
    guard let asset = fetchResult.firstObject else {
      throw NSError(
        domain: "Export", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Asset not found for resource write"])
    }

    let phResources = PHAssetResource.assetResources(for: asset)
    guard
      let phResource = phResources.first(where: {
        $0.type == resource.type && $0.originalFilename == resource.originalFilename
      })
    else {
      throw NSError(
        domain: "Export", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Matching PHAssetResource not found"])
    }

    let start = Date()
    Self.logger.debug(
      "writeResource begin type: \(phResource.type.rawValue) filename: \(phResource.originalFilename, privacy: .public) -> \(url.lastPathComponent, privacy: .public)"
    )
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = true
      PHAssetResourceManager.default().writeData(for: phResource, toFile: url, options: options) {
        error in
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        if let error {
          Self.logger.error(
            "writeResource failed after \(elapsedMs)ms: \(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: error)
        } else {
          Self.logger.debug(
            "writeResource success after \(elapsedMs)ms -> \(url.lastPathComponent, privacy: .public)"
          )
          continuation.resume(returning: ())
        }
      }
    }
  }
}
