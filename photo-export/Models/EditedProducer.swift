import AVFoundation
import Foundation

/// Names the byte source for an edited variant. Returned by
/// `ResourceSelection.selectEditedProducer` so `ExportManager` can switch on a
/// single value rather than carrying media-kind-specific booleans inline.
enum EditedProducer: Sendable, Equatable {
  case resource(ResourceDescriptor)
  case render(MediaRenderRequest)
  case none

  /// Filename whose extension drives the edited-variant on-disk filename.
  /// Same role for both byte sources, so call sites that only need the
  /// extension (e.g. paired-stem allocation, destination resolution) can
  /// read it without unwrapping the case.
  var originalFilename: String? {
    switch self {
    case .resource(let resource): return resource.originalFilename
    case .render(let request): return request.originalFilename
    case .none: return nil
    }
  }
}

/// Everything a `MediaRenderer` needs to render an edited asset and resolve
/// the destination filename for it.
struct MediaRenderRequest: Sendable, Equatable {
  let assetId: String
  let originalFilename: String
  let fileType: AVFileType
  let kind: Kind

  enum Kind: Sendable { case video }
}
