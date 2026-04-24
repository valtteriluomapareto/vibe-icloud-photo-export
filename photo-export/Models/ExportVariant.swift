import Foundation

/// Which concrete file is being written or recorded for a given Photos asset.
enum ExportVariant: String, Codable, CaseIterable, Hashable, Sendable {
  case original
  case edited
}

/// User-facing selection that drives which variants are required per asset.
enum ExportVersionSelection: String, Codable, CaseIterable, Sendable {
  case originalOnly
  case editedOnly
  case originalAndEdited
}

/// Required variants for an asset under the active selection.
///
/// Edited export is only applicable when `asset.hasAdjustments` is true. When
/// `editedOnly` is selected and the asset has no edits, the empty set filters
/// the asset out of export work entirely.
func requiredVariants(for asset: AssetDescriptor, selection: ExportVersionSelection)
  -> Set<ExportVariant>
{
  switch selection {
  case .originalOnly:
    return [.original]
  case .editedOnly:
    return asset.hasAdjustments ? [.edited] : []
  case .originalAndEdited:
    return asset.hasAdjustments ? [.original, .edited] : [.original]
  }
}
