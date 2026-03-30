import Foundation

/// Abstracts the export destination folder management for testability.
/// ExportDestinationManager conforms in production; tests inject a fake.
@MainActor
protocol ExportDestination: AnyObject {
  var selectedFolderURL: URL? { get }
  var canExportNow: Bool { get }
  var canImportNow: Bool { get }
  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool) throws -> URL
  func beginScopedAccess() -> URL?
  func endScopedAccess(for url: URL)
}
