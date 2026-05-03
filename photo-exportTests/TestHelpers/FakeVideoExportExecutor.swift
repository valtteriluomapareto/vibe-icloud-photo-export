import AVFoundation
import Foundation

@testable import Photo_Export

/// Test double for `VideoExportExecutor`. Lets unit tests drive the
/// `requestSession` / `runExport` / `cancel` seam without constructing a
/// real `AVAssetExportSession` or talking to PhotoKit.
final class FakeVideoExportExecutor: VideoExportExecutor, @unchecked Sendable {
  // Recorded calls
  private let lock = NSLock()
  private(set) var requestCalls: [MediaRenderRequest] = []
  private(set) var runCalls: [(URL, AVFileType)] = []
  private(set) var cancelCount: Int = 0

  // Behavior knobs
  var requestSessionResult: Result<ExportSessionHandle, Error> = .success(
    ExportSessionHandle(NSObject()))
  /// Closure invoked when `runExport` is called. Default: returns success.
  /// Use this to drive each `AVAssetExportSession.Status` mapping branch.
  var runExportBehavior: @Sendable (ExportSessionHandle, URL, AVFileType) async throws -> Void = {
    _, url, _ in
    FileManager.default.createFile(atPath: url.path, contents: Data("fake".utf8))
  }
  /// Optional latch the runExport call awaits before doing anything. Used
  /// by cancel-during-render tests.
  var runExportLatch: AsyncSemaphore?

  func requestSession(for request: MediaRenderRequest) async throws -> ExportSessionHandle {
    lock.lock()
    requestCalls.append(request)
    lock.unlock()
    return try requestSessionResult.get()
  }

  func runExport(session: ExportSessionHandle, to url: URL, fileType: AVFileType) async throws {
    if let latch = runExportLatch { await latch.wait() }
    lock.lock()
    runCalls.append((url, fileType))
    lock.unlock()
    try await runExportBehavior(session, url, fileType)
  }

  func cancel(session: ExportSessionHandle) {
    lock.lock()
    cancelCount += 1
    lock.unlock()
  }
}
