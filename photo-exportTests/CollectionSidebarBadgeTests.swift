import Foundation
import Testing

@testable import Photo_Export

/// Pure-function tests for the sidebar's progress badge. The bug these
/// guard against (issue surfaced live in the field): a 941-asset album
/// with only 19 stored records was rendering a green check, because
/// `summary.status == .complete` reports "all stored records are done"
/// regardless of how many assets the album currently has. The badge
/// helper compares against the live count instead.
struct CollectionSidebarBadgeTests {
  @Test func recordsBelowLiveCountIsPartial() {
    // The reported bug: only 19 records exist for an album that
    // currently has 941 assets. The sidebar must show partial, not
    // complete.
    #expect(
      CollectionSidebarBadge.state(liveCount: 941, exportedRecords: 19)
        == .partial(exported: 19, total: 941))
  }

  @Test func exportedMeetsLiveCountIsComplete() {
    #expect(
      CollectionSidebarBadge.state(liveCount: 19, exportedRecords: 19) == .complete)
  }

  @Test func recordsAboveLiveCountClampsToComplete() {
    // Album shrank after a past export — the records list overcounts.
    // Treat as complete; nothing in the current album is missing.
    #expect(
      CollectionSidebarBadge.state(liveCount: 50, exportedRecords: 100) == .complete)
  }

  @Test func zeroRecordsIsNotStarted() {
    #expect(
      CollectionSidebarBadge.state(liveCount: 100, exportedRecords: 0)
        == .notStarted(total: 100))
  }

  @Test func singleAssetSingleRecordIsComplete() {
    #expect(
      CollectionSidebarBadge.state(liveCount: 1, exportedRecords: 1) == .complete)
  }

  @Test func singleAssetZeroRecordsIsNotStarted() {
    #expect(
      CollectionSidebarBadge.state(liveCount: 1, exportedRecords: 0)
        == .notStarted(total: 1))
  }
}
