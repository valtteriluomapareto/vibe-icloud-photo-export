import Foundation

@testable import Photo_Export

final class FakeAssetResourceWriter: AssetResourceWriter, @unchecked Sendable {
  // Call tracking
  struct WriteCall: Equatable {
    let resource: ResourceDescriptor
    let assetId: String
    let url: URL
  }

  private let lock = NSLock()
  private var _writeCalls: [WriteCall] = []

  var writeCalls: [WriteCall] {
    lock.lock()
    defer { lock.unlock() }
    return _writeCalls
  }

  // Error injection
  var writeError: Error?

  // Behavior: if true, creates a small file at the destination (simulating a real write)
  var shouldCreateFile: Bool = true

  /// Delay every `writeResource` call by this many seconds via `Task.sleep`. Used by
  /// cancellation tests to keep the writer hung long enough for `cancelAndClear` to
  /// race against the in-flight write deterministically. The sleep is cancellable, so
  /// the writer cooperates with `Task.isCancelled` checks higher in the stack.
  var writeDelaySeconds: TimeInterval = 0

  func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
    async throws
  {
    lock.lock()
    _writeCalls.append(WriteCall(resource: resource, assetId: assetId, url: url))
    lock.unlock()

    if writeDelaySeconds > 0 {
      try await Task.sleep(nanoseconds: UInt64(writeDelaySeconds * 1_000_000_000))
    }
    if let error = writeError { throw error }
    if shouldCreateFile {
      FileManager.default.createFile(atPath: url.path, contents: Data("fake-content".utf8))
    }
  }
}
