import Foundation

/// App-owned descriptor for a Photos collection (Favorites, an album, or a folder).
/// Replaces `PHAssetCollection` / `PHCollectionList` at all non-framework boundaries —
/// `PhotoLibraryManager` is the only place those PhotoKit types appear in production.
///
/// Three kinds:
/// - `.favorites`: synthetic. There is no underlying `PHAssetCollection`; the contents are
///   resolved via a `favorite == YES` predicate. `localIdentifier` is `nil`.
/// - `.album`: a user-created album. `localIdentifier` is the underlying
///   `PHAssetCollection.localIdentifier`.
/// - `.folder`: a user-created folder (a `PHCollectionList`). Folders are not directly
///   exportable; they only exist to group children. `localIdentifier` is the underlying
///   `PHCollectionList.localIdentifier` and is used solely for tree identity.
struct PhotoCollectionDescriptor: Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case favorites
    case album
    case folder
  }

  /// Stable identifier used as the SwiftUI `Identifiable` key. For `.album` and `.folder`
  /// kinds this is the `localIdentifier` (with a kind prefix to disambiguate the synthetic
  /// favorites root); for `.favorites` it is the constant `"favorites"` token.
  let id: String

  /// `PHAssetCollection.localIdentifier` for `.album`, `PHCollectionList.localIdentifier`
  /// for `.folder`. `nil` for `.favorites` (synthetic).
  let localIdentifier: String?

  /// Display title as shown in Photos. Unsanitized — `ExportPathPolicy` sanitizes it
  /// when constructing on-disk paths.
  let title: String

  let kind: Kind

  /// Display hierarchy from the root down to (but not including) this collection's title.
  /// Empty for top-level collections. Unsanitized — sanitization happens in
  /// `ExportPathPolicy`. Used by the placement-id format's `displayPathHash8` segment so a
  /// rename of an album within its folder produces a fresh placement id.
  let pathComponents: [String]

  /// Best-effort asset count. **Always `nil`** in production today: the sidebar
  /// populates per-row counts asynchronously via `PhotoLibraryService.cachedCountAssets(in:)`,
  /// which is the only consumer that reads counts at all. Eagerly populating this field
  /// at tree-build time used to add 1–3 seconds of main-actor block per fetch on
  /// libraries with 500+ albums (a `PHAsset.fetchAssets(in:).count` per album, all on
  /// main); now we leave it nil. The field is preserved as part of the descriptor's
  /// shape in case a future PhotoKit version exposes a free count API; no production
  /// code currently reads it.
  let estimatedAssetCount: Int?

  /// Children of a `.folder`. Empty for `.album` and `.favorites`.
  let children: [PhotoCollectionDescriptor]
}
