import Foundation

@testable import Photo_Export

@MainActor
final class FakeExportDestination: ExportDestination {
  var selectedFolderURL: URL?
  var canExportNow: Bool = true
  var canImportNow: Bool = true

  // The root temp directory for test exports
  let rootURL: URL

  // Call tracking
  var beginScopedAccessCount = 0
  var endScopedAccessCount = 0

  // Error injection
  var urlForMonthError: Error?

  init() {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("FakeExportDest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    selectedFolderURL = rootURL
  }

  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL {
    if let error = urlForMonthError { throw error }
    let monthStr = String(format: "%02d", month)
    let dir = rootURL.appendingPathComponent("\(year)", isDirectory: true)
      .appendingPathComponent(monthStr, isDirectory: true)
    if createIfNeeded {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  func beginScopedAccess() -> URL? {
    beginScopedAccessCount += 1
    return selectedFolderURL
  }

  func endScopedAccess(for url: URL) {
    endScopedAccessCount += 1
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
