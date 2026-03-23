import Foundation
import Testing

@testable import photo_export

@MainActor
struct ExportDestinationValidationTests {
  // MARK: - urlForMonth input validation
  // These test the validation guards in urlForMonth without needing a real folder selected.

  @Test func testUrlForMonthThrowsWhenNoSelection() {
    let mgr = ExportDestinationManager()
    // No folder selected → should throw noSelection
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try mgr.urlForMonth(year: 2025, month: 6)
    }
  }

  @Test func testUrlForMonthInvalidYear() {
    let mgr = ExportDestinationManager()
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try mgr.urlForMonth(year: 0, month: 6)
    }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try mgr.urlForMonth(year: -1, month: 6)
    }
  }

  @Test func testUrlForMonthInvalidMonth() {
    let mgr = ExportDestinationManager()
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try mgr.urlForMonth(year: 2025, month: 0)
    }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try mgr.urlForMonth(year: 2025, month: 13)
    }
    #expect(throws: ExportDestinationManager.ExportDestinationError.self) {
      try mgr.urlForMonth(year: 2025, month: -1)
    }
  }
}
