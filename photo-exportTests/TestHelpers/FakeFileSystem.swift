import Foundation

@testable import Photo_Export

/// A FileSystemService that delegates to the real filesystem but records calls and can inject errors.
final class FakeFileSystem: FileSystemService, @unchecked Sendable {
  private let lock = NSLock()

  // Call tracking
  private var _moveCalls: [(from: URL, to: URL)] = []
  private var _timestampCalls: [(date: Date, url: URL)] = []

  var moveCalls: [(from: URL, to: URL)] {
    lock.lock()
    defer { lock.unlock() }
    return _moveCalls
  }

  var timestampCalls: [(date: Date, url: URL)] {
    lock.lock()
    defer { lock.unlock() }
    return _timestampCalls
  }

  // Error injection
  var moveError: Error?
  var shouldApplyTimestamps = true

  // Delegate to real filesystem by default
  private let real = FileIOService()

  func moveItemAtomically(from src: URL, to dst: URL) throws {
    lock.lock()
    _moveCalls.append((from: src, to: dst))
    lock.unlock()

    if let error = moveError { throw error }
    try real.moveItemAtomically(from: src, to: dst)
  }

  func applyTimestamps(creationDate: Date, to url: URL) {
    lock.lock()
    _timestampCalls.append((date: creationDate, url: url))
    lock.unlock()

    if shouldApplyTimestamps {
      real.applyTimestamps(creationDate: creationDate, to: url)
    }
  }

  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
    try real.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
  }

  func fileExists(atPath path: String) -> Bool {
    real.fileExists(atPath: path)
  }

  func removeItem(at url: URL) throws {
    try real.removeItem(at: url)
  }
}
