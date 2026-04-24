import Foundation

/// Parsed shape of a candidate `_edited` filename produced by this app.
struct ParsedEditedFilename: Equatable {
  /// Stem used to tie variants for one exported asset together. Includes any
  /// app-added collision suffix that was part of the group (e.g. "IMG_0001 (1)").
  var groupStem: String
  /// Original resource stem without any app-added collision suffix
  /// (e.g. "IMG_0001").
  var canonicalOriginalStem: String
  /// Trailing per-file collision suffix that was added because the exact edited
  /// filename already existed (e.g. `(1)` in "IMG_0001_edited (1).JPG"). Nil
  /// when the edited filename itself had no added suffix.
  var fileCollisionSuffix: Int?
  /// Extension as it appeared on disk. Preserves casing.
  var fileExtension: String
}

/// Classification of a filename once scanner-side original checks have failed.
enum ExportFilenameClassification: Equatable {
  case original(filename: String, fileCollisionSuffix: Int?)
  case edited(ParsedEditedFilename)
}

/// Filename rules shared by the export pipeline and the backup scanner so both
/// sides agree about what an `_edited` companion looks like.
enum ExportFilenamePolicy {
  static let editedSuffix = "_edited"

  /// Original export uses the original resource filename unchanged.
  static func originalFilename(for originalResourceFilename: String) -> String {
    originalResourceFilename
  }

  /// Edited export builds its basename from the selected group stem (which may
  /// include an app-added collision suffix like " (1)") and takes its extension
  /// from the edited resource filename so it reflects the bytes being written.
  static func editedFilename(
    originalGroupStem: String,
    editedResourceFilename: String
  ) -> String {
    let editedExt = (editedResourceFilename as NSString).pathExtension
    let stem = originalGroupStem + editedSuffix
    return editedExt.isEmpty ? stem : "\(stem).\(editedExt)"
  }

  /// Pure filename parsing: detects the "_edited" marker, strips any final
  /// `(N)` collision suffix, and derives the group and canonical original
  /// stems. Returns nil when the filename is not an edited-form candidate.
  ///
  /// Does not consult any asset metadata. The backup scanner combines this
  /// with fingerprint data to confirm an edited classification.
  static func parseEditedCandidate(filename: String) -> ParsedEditedFilename? {
    let ns = filename as NSString
    let ext = ns.pathExtension
    let stem = ns.deletingPathExtension

    // Strip a trailing file-collision suffix like " (1)" if present.
    let (afterFileCollision, fileCollisionSuffix) = stripTrailingCollisionSuffix(from: stem)

    // Require the "_edited" marker on the resulting stem.
    guard afterFileCollision.hasSuffix(editedSuffix) else { return nil }

    let groupStem = String(afterFileCollision.dropLast(editedSuffix.count))
    guard !groupStem.isEmpty else { return nil }

    // Strip any app-added group collision suffix to recover the canonical
    // original stem (e.g. "IMG_0001 (1)" -> "IMG_0001").
    let (canonicalOriginalStem, _) = stripTrailingCollisionSuffix(from: groupStem)

    return ParsedEditedFilename(
      groupStem: groupStem,
      canonicalOriginalStem: canonicalOriginalStem,
      fileCollisionSuffix: fileCollisionSuffix,
      fileExtension: ext
    )
  }

  /// Strips a trailing ` (N)` suffix from a stem. Returns the stripped stem
  /// and the parsed N, or nil when no suffix was present.
  static func stripTrailingCollisionSuffix(from stem: String) -> (stripped: String, suffix: Int?) {
    guard let regex = try? NSRegularExpression(pattern: #" \((\d+)\)$"#) else {
      return (stem, nil)
    }
    let range = NSRange(stem.startIndex..., in: stem)
    guard let match = regex.firstMatch(in: stem, range: range),
      let matchRange = Range(match.range, in: stem),
      let numberRange = Range(match.range(at: 1), in: stem)
    else {
      return (stem, nil)
    }
    let stripped = String(stem[stem.startIndex..<matchRange.lowerBound])
    let number = Int(stem[numberRange])
    return (stripped, number)
  }
}
