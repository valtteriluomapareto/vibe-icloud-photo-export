import Foundation
import Testing

@testable import Photo_Export

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

  @Test func testOutOfRangeMonthsWrapViaCalenar() {
    // Calendar wraps out-of-range months (0 → December, 13 → January)
    #expect(MonthFormatting.name(for: 0) == "December")
    #expect(MonthFormatting.name(for: 13) == "January")
    #expect(MonthFormatting.name(for: -1) == "November")
  }
}
