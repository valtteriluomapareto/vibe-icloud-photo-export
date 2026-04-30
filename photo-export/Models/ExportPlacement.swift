import Foundation

/// A single export "slot" — a `(kind, id, relativePath)` triple that records, queue jobs, and
/// destination directories all key by.
///
/// Three kinds:
/// - `.timeline`: per-month folders like `2025/02/`. Synthesized at the boundary from
///   `(year, month)`; never persisted as a placement metadata entry on disk (the timeline store
///   keeps its existing asset-keyed shape).
/// - `.favorites`: a single fixed folder `Collections/Favorites/`.
/// - `.album`: per-album folders under `Collections/Albums/...` with sibling-collision
///   disambiguation (`_2`, `_3` suffixes) and rename-detection via `displayPathHash8`.
///
/// Identity is `id` only. Manual `Hashable`/`Equatable` over `id` (not synthesized over all
/// fields) so two `ExportPlacement` values with the same `id` but different `createdAt`
/// timestamps compare equal — `createdAt` is diagnostic, not part of identity. Without manual
/// conformance a freshly-constructed lookup placement (with `createdAt = Date()`) would fail
/// to match the persisted version (with the original timestamp).
struct ExportPlacement: Codable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case timeline
    case favorites
    case album
  }

  let kind: Kind
  /// Stable string id; used as the placement-section key on disk for the collection store and
  /// as the queue-counts dict key in `ExportManager`.
  let id: String
  /// Human-readable label shown in diagnostic logs (and any future rename dialog).
  /// `relativePath` is sanitized and `id` is opaque, so neither is suitable.
  let displayName: String
  /// `PHAssetCollection.localIdentifier` for `.album` placements. `nil` for `.timeline` (no
  /// PhotoKit collection) and `.favorites` (synthetic; backed by a `favorite == YES`
  /// predicate, not a real `PHAssetCollection`).
  let collectionLocalIdentifier: String?
  /// Frozen at placement creation. Never recomputed. Used to construct destination URLs and
  /// to read the on-disk record subdirectory for each placement.
  let relativePath: String
  /// Diagnostic; set when the placement is first persisted. Not part of identity.
  let createdAt: Date
}

extension ExportPlacement: Hashable {
  static func == (lhs: ExportPlacement, rhs: ExportPlacement) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

extension ExportPlacement {
  /// Synthetic timeline placement for `(year, month)`. Constructed at the queue/store
  /// boundary; never persisted in the timeline store's records (which stay asset-keyed).
  ///
  /// Format: `id = "timeline:<YYYY>-<MM>"`, `relativePath = "<YYYY>/<MM>/"`.
  static func timeline(year: Int, month: Int, createdAt: Date = Date()) -> ExportPlacement {
    let monthString = String(format: "%02d", month)
    let yearString = String(format: "%04d", year)
    return ExportPlacement(
      kind: .timeline,
      id: "timeline:\(year)-\(monthString)",
      displayName: "\(year)/\(monthString)",
      collectionLocalIdentifier: nil,
      relativePath: "\(yearString)/\(monthString)/",
      createdAt: createdAt
    )
  }

  /// Synthetic favorites placement. There is exactly one of these per destination; the
  /// collection store keys it under `id == "collections:favorites"`.
  static func favorites(createdAt: Date = Date()) -> ExportPlacement {
    ExportPlacement(
      kind: .favorites,
      id: "collections:favorites",
      displayName: "Favorites",
      collectionLocalIdentifier: nil,
      relativePath: "Collections/Favorites/",
      createdAt: createdAt
    )
  }
}

/// In-memory ergonomic key for record lookups: `(placementId, assetId)`. Not persisted —
/// records on disk are nested by placement id (outer dict) and asset id (inner dict).
struct ExportRecordKey: Hashable, Sendable {
  let placementId: String
  let assetId: String
}

/// Scope for `CollectionExportRecordStore.recordCount(in:)`. Mirrors the kinds the collection
/// store accepts (`.favorites`, `.album`); excludes `.timeline` because the collection store
/// rejects timeline placements at the API boundary.
enum CollectionPlacementScope: Hashable, Sendable {
  case favorites
  case album(collectionLocalId: String)
  case any  // favorites + albums
}
