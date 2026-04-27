import Foundation
import Photos

/// App-owned value type that replaces PHAsset at all non-framework boundaries.
/// Produced by PhotoLibraryManager, consumed by views, view models, and the export pipeline.
struct AssetDescriptor: Identifiable, Sendable, Equatable {
  let id: String
  let creationDate: Date?
  let mediaType: PHAssetMediaType
  let pixelWidth: Int
  let pixelHeight: Int
  let duration: TimeInterval
  /// Whether Photos has edits on this asset. Used to decide whether an edited
  /// export is even applicable for the asset.
  let hasAdjustments: Bool
}

/// App-owned value type that replaces PHAssetResource in the export path.
struct ResourceDescriptor: Sendable, Equatable {
  let type: PHAssetResourceType
  let originalFilename: String
}
