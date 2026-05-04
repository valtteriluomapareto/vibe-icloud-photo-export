import Foundation

/// Renders managed media (currently edited videos) to a destination URL.
/// Production wraps `PHImageManager.requestExportSession` + `AVAssetExportSession`.
/// Tests inject a fake. Forward-compatible with future render kinds via
/// `MediaRenderRequest.Kind`.
protocol MediaRenderer: Sendable {
  func render(request: MediaRenderRequest, to url: URL) async throws
}
