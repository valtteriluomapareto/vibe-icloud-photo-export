import Foundation

enum MonthFormatting {
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM"
    return f
  }()

  static func name(for month: Int) -> String {
    let date = Calendar.current.date(from: DateComponents(year: 2023, month: month))!
    return formatter.string(from: date)
  }
}
