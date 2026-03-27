import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct ExportDestinationValidationTests {

  // MARK: - No folder selected

  @Test func urlForMonthThrowsNoSelectionWhenNoFolderSelected() {
    let mgr = ExportDestinationManager()
    #expect(throws: ExportDestinationManager.ExportDestinationError.noSelection) {
      try mgr.urlForMonth(year: 2025, month: 6)
    }
  }

  // MARK: - Invalid year/month (folder selected, available, writable)

  /// Helper that creates a manager pointing at a real temp directory so the
  /// noSelection / notAvailable / notWritable guards pass and we actually hit
  /// the year/month validation.
  private func managerWithFolder() throws -> (ExportDestinationManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportDestValidation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mgr = ExportDestinationManager()
    mgr.setSelectedFolderForTesting(dir)
    return (mgr, dir)
  }

  @Test func urlForMonthThrowsInvalidYearForZero() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidYear) {
      try mgr.urlForMonth(year: 0, month: 6)
    }
  }

  @Test func urlForMonthThrowsInvalidYearForNegative() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidYear) {
      try mgr.urlForMonth(year: -1, month: 6)
    }
  }

  @Test func urlForMonthThrowsInvalidMonthForZero() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidMonth) {
      try mgr.urlForMonth(year: 2025, month: 0)
    }
  }

  @Test func urlForMonthThrowsInvalidMonthForThirteen() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidMonth) {
      try mgr.urlForMonth(year: 2025, month: 13)
    }
  }

  @Test func urlForMonthThrowsInvalidMonthForNegative() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ExportDestinationManager.ExportDestinationError.invalidMonth) {
      try mgr.urlForMonth(year: 2025, month: -1)
    }
  }

  // MARK: - Happy path (valid year/month creates directory)

  @Test func urlForMonthCreatesYearMonthDirectory() throws {
    let (mgr, dir) = try managerWithFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let result = try mgr.urlForMonth(year: 2025, month: 6)
    #expect(result.lastPathComponent == "06")
    #expect(result.deletingLastPathComponent().lastPathComponent == "2025")
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: result.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
  }
}
