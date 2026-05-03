import Foundation

/// Loader for the per-(year, month) total + adjusted asset counts the
/// timeline sidebar's `YearRow` and `MonthRow` need to compute their progress
/// badges.
///
/// Issue #20: previously these dicts were populated lazily — total counts
/// only when a year was expanded (`computeMonthsWithAssets(for:)`), adjusted
/// counts only when each `MonthRow` rendered (`.task(id:)` on the row). For
/// collapsed years, both dicts were empty for that year's months, so
/// `YearRow`'s progress badge could not compute and rendered nothing.
/// Subsequent updates during a long export went unnoticed unless the user
/// expanded the year.
///
/// This loader fixes that by fanning out async fetches for **every** known
/// year × month at startup, using the existing cached count APIs
/// (`PhotoLibraryService.cachedCountAssets(in:)` and
/// `cachedCountAdjustedAssets(in:)`). The `CollectionCountCache` actor
/// dedups overlapping calls, so calling `loadCounts(forYears:)` multiple
/// times is cheap. As each (year, month) pair lands, the `@Published` dicts
/// update and dependent `YearRow` / `MonthRow` views re-render
/// progressively.
///
/// Cost (see `AGENTS.md` perf notes): a typical 10-year library is ~120
/// fetches, completing sub-second; a 30-year archive is ~360 fetches, a few
/// seconds of background work. None of it blocks the main actor — each
/// call to `cachedCountAssets` dispatches into `Task.detached` inside
/// `PhotoLibraryManager`, and the wrapper `await` here simply yields the
/// runloop while the detached fetch runs.
@MainActor
final class TimelineSidebarCounts: ObservableObject {
  @Published private(set) var assetCountsByYearMonth: [String: Int] = [:]
  @Published private(set) var adjustedCountsByYearMonth: [String: Int] = [:]
  /// Last error encountered while fetching counts. Surfaces once so a future
  /// view-side banner can mention "couldn't load progress" without us having
  /// to thread Result types throughout the loader.
  @Published private(set) var lastError: Error?

  private let service: any PhotoLibraryService

  init(service: any PhotoLibraryService) {
    self.service = service
  }

  /// Fetches per-month total + adjusted counts for every (year ∈ years) × (month ∈ 1...12).
  /// `preferredYear` is loaded first so its badge data lands quickly even on
  /// large libraries (typically the user's currently-selected year, surfaced
  /// by `TimelineSidebarView`).
  func loadCounts(forYears years: [Int], preferredYear: Int? = nil) async {
    let ordered = orderYears(years, preferredYear: preferredYear)
    for year in ordered {
      await loadYear(year)
    }
  }

  // MARK: - Read helpers

  /// Months 1...12 of `year` whose total count is non-zero. Replaces the old
  /// `computeMonthsWithAssets(for:)` view-method; the loader's dict is the
  /// new source of truth.
  func monthsWithAssets(for year: Int) -> [Int] {
    var months: [Int] = []
    for month in 1...12 where (assetCountsByYearMonth["\(year)-\(month)"] ?? 0) > 0 {
      months.append(month)
    }
    return months
  }

  // MARK: - Internals

  /// Loads one year's twelve months. Each month's total + adjusted are
  /// fetched concurrently via `async let`; months are processed sequentially
  /// so dict updates land in a predictable order on the main actor (cheaper
  /// for SwiftUI diffing than 12 simultaneous mutations).
  private func loadYear(_ year: Int) async {
    for month in 1...12 {
      async let totalTask = service.cachedCountAssets(
        in: .timeline(year: year, month: month))
      async let adjustedTask = service.cachedCountAdjustedAssets(
        in: .timeline(year: year, month: month))

      let key = "\(year)-\(month)"
      do {
        let total = try await totalTask
        assetCountsByYearMonth[key] = total
      } catch {
        lastError = error
      }
      do {
        let adjusted = try await adjustedTask
        adjustedCountsByYearMonth[key] = adjusted
      } catch {
        lastError = error
      }
    }
  }

  private func orderYears(_ years: [Int], preferredYear: Int?) -> [Int] {
    guard let preferredYear, years.contains(preferredYear) else { return years }
    var ordered = [preferredYear]
    ordered.append(contentsOf: years.filter { $0 != preferredYear })
    return ordered
  }
}
