import Foundation
import Testing

@testable import Photo_Export

struct MonthFormattingTests {
  @Test func allValidMonthsReturnNonEmptyStrings() {
    for month in 1...12 {
      let name = MonthFormatting.name(for: month)
      #expect(!name.isEmpty, "Month \(month) should return a non-empty name")
      // Ensure we get a word, not a numeric fallback
      #expect(name != "\(month)", "Month \(month) should not fall back to a numeric string")
    }
  }

  @Test func outOfRangeMonthsWrapViaCalendar() {
    // Calendar wraps: 0 → month 12, 13 → month 1, -1 → month 11
    let wrap0 = MonthFormatting.name(for: 0)
    let wrap13 = MonthFormatting.name(for: 13)
    let wrapNeg = MonthFormatting.name(for: -1)

    #expect(!wrap0.isEmpty)
    #expect(!wrap13.isEmpty)
    #expect(!wrapNeg.isEmpty)

    // Verify wrapping gives same result as the canonical month
    #expect(wrap0 == MonthFormatting.name(for: 12))
    #expect(wrap13 == MonthFormatting.name(for: 1))
    #expect(wrapNeg == MonthFormatting.name(for: 11))
  }
}
