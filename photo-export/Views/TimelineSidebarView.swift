import SwiftUI

/// Sidebar for the Timeline section: years → months tree. Extracted from `ContentView`
/// during the Phase 4 refactor so the same content area can host either a Timeline
/// sidebar or a Collections sidebar without duplicating the surrounding split view.
///
/// Selection is bridged out through `selection: Binding<LibrarySelection?>` so the
/// content view receives a unified selection regardless of which section is active.
struct TimelineSidebarView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager

  @Binding var selection: LibrarySelection?

  @State private var years: [Int] = []
  @State private var expandedYears: Set<Int> = []
  @State private var monthsWithAssetsByYear: [Int: [Int]] = [:]
  @State private var assetCountsByYearMonth: [String: Int] = [:]
  @State private var assetCountsByYear: [Int: Int] = [:]
  @State private var adjustedCountsByYearMonth: [String: Int] = [:]

  var body: some View {
    List(selection: yearMonthSelection) {
      Section("Photos by Year") {
        ForEach(years, id: \.self) { year in
          DisclosureGroup(
            isExpanded: Binding(
              get: { expandedYears.contains(year) },
              set: { newValue in
                if newValue {
                  expandedYears.insert(year)
                } else {
                  expandedYears.remove(year)
                }
              }
            )
          ) {
            ForEach(monthsWithAssetsByYear[year] ?? [], id: \.self) { month in
              MonthRow(
                year: year,
                month: month,
                total: assetCountsByYearMonth["\(year)-\(month)"] ?? 0,
                adjusted: adjustedCountsByYearMonth["\(year)-\(month)"]
              )
              .tag(LibrarySelection.timelineMonth(year: year, month: month))
              .task(id: "\(year)-\(month)-adjusted") {
                await loadAdjustedCount(year: year, month: month)
              }
            }
          } label: {
            YearRow(
              year: year,
              totalAssets: assetCountsByYear[year] ?? 0,
              totalCountsByMonth: monthTotals(for: year),
              adjustedCountsByMonth: adjustedMonths(for: year)
            )
          }
        }
      }
    }
    .navigationTitle("Photo Export")
    .onAppear { handleAppear() }
    .onChange(of: photoLibraryManager.isAuthorized) { _, new in
      if new {
        loadYears()
        if case .timelineMonth(let year, _) = selection {
          expandedYears.insert(year)
          monthsWithAssetsByYear[year] = computeMonthsWithAssets(for: year)
        }
      } else {
        years = []
        expandedYears.removeAll()
        monthsWithAssetsByYear.removeAll()
        assetCountsByYear.removeAll()
      }
    }
    .onChange(of: expandedYears) { _, _ in
      for year in expandedYears where monthsWithAssetsByYear[year] == nil {
        monthsWithAssetsByYear[year] = computeMonthsWithAssets(for: year)
      }
    }
  }

  // MARK: - Selection bridging

  /// `List(selection:)` always wants the same value type as its tags. We bridge
  /// `Binding<LibrarySelection?>` so that timeline-tagged rows can drive the unified
  /// selection state without losing the section's last-selected month when the user
  /// flips the segmented control to Collections and back.
  private var yearMonthSelection: Binding<LibrarySelection?> {
    Binding(
      get: { selection },
      set: { newValue in
        if let newValue, case .timelineMonth = newValue {
          selection = newValue
        }
      }
    )
  }

  // MARK: - Helpers

  private func handleAppear() {
    if photoLibraryManager.isAuthorized {
      loadYears()
      if case .timelineMonth(let year, _) = selection {
        expandedYears.insert(year)
        monthsWithAssetsByYear[year] = computeMonthsWithAssets(for: year)
      }
    }
  }

  private func loadYears() {
    let yearCounts = (try? photoLibraryManager.availableYearsWithCounts()) ?? []
    years = yearCounts.map(\.year)
    for (year, count) in yearCounts {
      assetCountsByYear[year] = count
    }
  }

  private func computeMonthsWithAssets(for year: Int) -> [Int] {
    var months: [Int] = []
    for month in 1...12 {
      let count = (try? photoLibraryManager.countAssets(year: year, month: month)) ?? 0
      assetCountsByYearMonth["\(year)-\(month)"] = count
      if count > 0 {
        months.append(month)
      }
    }
    return months
  }

  private func loadAdjustedCount(year: Int, month: Int) async {
    let key = "\(year)-\(month)"
    guard adjustedCountsByYearMonth[key] == nil else { return }
    if let count = try? await photoLibraryManager.countAdjustedAssets(year: year, month: month) {
      adjustedCountsByYearMonth[key] = count
    }
  }

  private func monthTotals(for year: Int) -> [Int: Int] {
    var map: [Int: Int] = [:]
    for month in 1...12 {
      map[month] = assetCountsByYearMonth["\(year)-\(month)"] ?? 0
    }
    return map
  }

  private func adjustedMonths(for year: Int) -> [Int: Int?] {
    var map: [Int: Int?] = [:]
    for month in 1...12 {
      map[month] = adjustedCountsByYearMonth["\(year)-\(month)"]
    }
    return map
  }
}
