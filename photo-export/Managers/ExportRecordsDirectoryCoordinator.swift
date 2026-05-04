import Foundation
import os

/// Owns the lifecycle of the per-destination `ExportRecords/<destinationId>/` directory.
///
/// Phase 0 of the collections-export plan replaces the bookmark-hash-based `destinationId`
/// (`legacyId`) with a stable volume-UUID + canonical-path derivation (`newId`). On upgrade,
/// existing users have records under `ExportRecords/<legacyId>/`; this coordinator renames
/// that directory to `ExportRecords/<newId>/` once before any record store calls
/// `configure(for: newId)`.
///
/// Centralizing the rename here is load-bearing for the post-Phase-1 two-store design: with
/// two stores both calling `configure(for: newId)`, whichever ran first would create
/// `<newId>/` and cause the other store's lazy-migration check to see `<newId>` already
/// present, leaving `<legacyId>/` orphaned. Running the migration once, before any store
/// touches the directory, prevents this.
struct ExportRecordsDirectoryCoordinator {
  enum DirectoryPrepareError: Error, Equatable {
    /// Both `<newId>/` and `<legacyId>/` exist on disk. Should not happen in normal use; the
    /// coordinator does not merge or delete either, leaving `<legacyId>/` for manual
    /// inspection. Callers should proceed with `<newId>/` as-is.
    case conflict(newId: String, legacyId: String)
    /// The legacy → new directory rename failed (filesystem error). The on-disk state is
    /// unchanged; the next launch will attempt the rename again.
    case migrationFailed(message: String)
  }

  let storeRootURL: URL
  let fileManager: FileManager
  private let logger: Logger

  init(
    storeRootURL: URL,
    fileManager: FileManager = .default,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "ExportRecordsDirectory")
  ) {
    self.storeRootURL = storeRootURL
    self.fileManager = fileManager
    self.logger = logger
  }

  /// Ensures `ExportRecords/<newId>/` is the directory record stores should use.
  ///
  /// Algorithm:
  /// 1. If `<newId>/` already exists, use it. (Conflict logged if `<legacyId>/` also exists.)
  /// 2. Otherwise, if `<legacyId>/` exists, rename it to `<newId>/`.
  /// 3. Otherwise, treat the destination as fresh — record stores will create `<newId>/` on
  ///    their first write.
  ///
  /// The coordinator does not create `<newId>/` itself; that's the record store's job.
  func prepareDirectory(for newId: String, legacyId: String?) -> Result<Void, DirectoryPrepareError>
  {
    let newDir = storeRootURL.appendingPathComponent(newId, isDirectory: true)
    let legacyDir = legacyId.map { storeRootURL.appendingPathComponent($0, isDirectory: true) }
    let newDirExists = fileManager.fileExists(atPath: newDir.path)
    let legacyExists = legacyDir.map { fileManager.fileExists(atPath: $0.path) } ?? false

    // Step 1 / step 4: <newId>/ already exists.
    if newDirExists {
      if let legacyId, let legacyDir, legacyExists, legacyDir != newDir {
        logger.error(
          "Conflict: ExportRecords/\(newId, privacy: .public)/ and legacy ExportRecords/\(legacyId, privacy: .public)/ both exist; using <newId>, legacy directory left untouched."
        )
        return .failure(.conflict(newId: newId, legacyId: legacyId))
      }
      return .success(())
    }

    // Step 2: <newId>/ missing, legacy directory present → rename.
    if let legacyId, let legacyDir, legacyExists, legacyDir != newDir {
      do {
        try fileManager.moveItem(at: legacyDir, to: newDir)
        logger.info(
          "Migrated ExportRecords/\(legacyId, privacy: .public)/ → ExportRecords/\(newId, privacy: .public)/"
        )
        return .success(())
      } catch {
        logger.error(
          "Failed to migrate legacy ExportRecords directory: \(error.localizedDescription, privacy: .public)"
        )
        return .failure(.migrationFailed(message: error.localizedDescription))
      }
    }

    // Step 3 / step 5: fresh destination, no legacy state to migrate.
    return .success(())
  }
}
