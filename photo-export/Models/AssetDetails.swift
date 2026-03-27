import Foundation
import Photos

/// Extended asset metadata for the detail panel. Loaded on demand via PhotoLibraryService.
struct AssetDetails: Sendable {
  let originalFilename: String?
  let fileSize: Int64?
  let resources: [ResourceDescriptor]
}
