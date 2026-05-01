import Foundation

/// Build-time feature flags. Kept deliberately small — these are *not* user preferences
/// and are not surfaced anywhere in UI.
enum AppFlags {
  /// Gates the user-visible Collections surface (the `Timeline` / `Collections` segmented
  /// control, the `Collections` sidebar, and the new export actions). The persistence layer
  /// (the new `CollectionExportRecordStore`) loads regardless; only the UI is gated.
  ///
  /// Phase 4 of `docs/project/plans/collections-export-plan.md` flips this to `true`. Under
  /// the release strategy, no App Store build ships with the flag on until phases 1–4 are
  /// all ready. Removed in a follow-up cleanup once the feature stabilizes.
  static let enableCollections: Bool = true
}
