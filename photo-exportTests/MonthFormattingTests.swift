import Foundation
import Testing

@testable import photo_export

struct MonthFormattingTests {
  @Test func testAllValidMonthsReturnNames() {
    let expected = [
      1: "January", 2: "February", 3: "March", 4: "April",
      5: "May", 6: "June", 7: "July", 8: "August",
      9: "September", 10: "October", 11: "November", 12: "December",
    ]
    for (month, name) in expected {
      #expect(MonthFormatting.name(for: month) == name, "Month \(month) should be \(name)")
    }
  }

  @Test func testInvalidMonthReturnsFallback() {
    // Out-of-range months fall back to the raw number string
    #expect(MonthFormatting.name(for: 0) == "0")
    #expect(MonthFormatting.name(for: 13) == "13")
    #expect(MonthFormatting.name(for: -1) == "-1")
  }
}
