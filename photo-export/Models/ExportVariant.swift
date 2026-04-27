import Foundation

/// Which concrete file is being written or recorded for a given Photos asset.
enum ExportVariant: String, Codable, CaseIterable, Hashable, Sendable {
  case original
  case edited
}

/// User-facing selection that drives which variants are required per asset.
enum ExportVersionSelection: String, Codable, CaseIterable, Sendable {
  /// One file per asset: edited bytes if Photos has an edit, original bytes otherwise.
  /// The user sees what they see in Photos.app.
  case edited
  /// `edited` plus a `_orig` companion for any asset that has Photos edits. Lets the user
  /// keep RAW or pre-edit backups alongside the user-visible rendering.
  case editedWithOriginals
}

/// Required variants for an asset under the active selection.
///
/// Every asset is applicable in every mode: an unedited asset is exported as `.original`,
/// an adjusted asset as `.edited` (with an additional `.original` companion under
/// `editedWithOriginals`).
func requiredVariants(for asset: AssetDescriptor, selection: ExportVersionSelection)
  -> Set<ExportVariant>
{
  switch selection {
  case .edited:
    return asset.hasAdjustments ? [.edited] : [.original]
  case .editedWithOriginals:
    return asset.hasAdjustments ? [.original, .edited] : [.original]
  }
}
