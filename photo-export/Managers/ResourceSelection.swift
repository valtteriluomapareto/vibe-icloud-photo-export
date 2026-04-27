import Foundation
import Photos

/// Variant-aware resource selection used by both the export pipeline and the
/// backup scanner so both sides agree on what constitutes an original-side
/// resource vs an edited-side resource.
enum ResourceSelection {
  /// True when `type` identifies original (pre-edit) bytes for this media kind.
  /// Kept intentionally narrow: only the canonical original cases count.
  static func isOriginalResource(type: PHAssetResourceType, mediaType: PHAssetMediaType) -> Bool {
    switch mediaType {
    case .image:
      return type == .photo || type == .alternatePhoto
    case .video:
      return type == .video
    default:
      return type == .photo || type == .video
    }
  }

  /// True when `type` identifies the current edited/rendered bytes for this
  /// media kind.
  static func isEditedResource(type: PHAssetResourceType, mediaType: PHAssetMediaType) -> Bool {
    switch mediaType {
    case .image:
      return type == .fullSizePhoto
    case .video:
      return type == .fullSizeVideo
    default:
      return type == .fullSizePhoto || type == .fullSizeVideo
    }
  }

  /// Selects the resource to write for an original export.
  ///
  /// Preserves the pipeline's existing preference order: canonical original
  /// first, fall back to `alternatePhoto`, then last-resort any resource so a
  /// broken asset still gets a chance to export. Edited-side resource types
  /// are never returned by this function.
  static func selectOriginalResource(
    from resources: [ResourceDescriptor],
    mediaType: PHAssetMediaType
  ) -> ResourceDescriptor? {
    switch mediaType {
    case .image:
      if let photo = resources.first(where: { $0.type == .photo }) { return photo }
      if let alt = resources.first(where: { $0.type == .alternatePhoto }) { return alt }
    case .video:
      if let video = resources.first(where: { $0.type == .video }) { return video }
    default:
      if let photo = resources.first(where: { $0.type == .photo }) { return photo }
      if let video = resources.first(where: { $0.type == .video }) { return video }
      if let alt = resources.first(where: { $0.type == .alternatePhoto }) { return alt }
    }
    // Last-resort: some assets only expose edited-side resources. Matches
    // prior "primary resource" fallback so this does not regress.
    return resources.first
  }

  /// Selects the resource to write for an edited export. Returns nil when the
  /// asset does not expose a current edited resource of the expected kind —
  /// callers must treat this as a failed edited variant rather than falling
  /// back to original bytes.
  static func selectEditedResource(
    from resources: [ResourceDescriptor],
    mediaType: PHAssetMediaType
  ) -> ResourceDescriptor? {
    switch mediaType {
    case .image:
      return resources.first(where: { $0.type == .fullSizePhoto })
    case .video:
      return resources.first(where: { $0.type == .fullSizeVideo })
    default:
      return resources.first(where: {
        $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
      })
    }
  }
}
