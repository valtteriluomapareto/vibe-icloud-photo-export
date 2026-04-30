import Foundation
import Testing

@testable import Photo_Export

/// Phase 0 (collections-export-plan): the stable `destinationId` derivation
/// (`SHA-256(volumeUUID || U+0000 || canonicalPath)`) must survive bookmark refresh,
/// distinguish folders on the same volume, and treat the same folder as the same id no
/// matter how it was reached. The legacy bookmark-hash derivation is preserved on
/// `legacyDestinationId(from:)` for use by `ExportRecordsDirectoryCoordinator`.
@MainActor
struct ExportDestinationManagerIdentityTests {

  // MARK: - Stable derivation

  /// Re-deriving against the same folder yields the same id (no per-call randomness).
  @Test func computeDestinationIdIsDeterministic() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("DestId-Stable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id1 = ExportDestinationManager.computeDestinationId(for: dir)
    let id2 = ExportDestinationManager.computeDestinationId(for: dir)
    #expect(id1 != nil)
    #expect(id1 == id2)
  }

  /// Two distinct folders on the same volume produce different ids (path is part of the
  /// digest input).
  @Test func twoFoldersSameVolumeProduceDifferentIds() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("DestId-DifferentFolders-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let a = parent.appendingPathComponent("A", isDirectory: true)
    let b = parent.appendingPathComponent("B", isDirectory: true)
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

    let idA = ExportDestinationManager.computeDestinationId(for: a)
    let idB = ExportDestinationManager.computeDestinationId(for: b)
    #expect(idA != nil)
    #expect(idB != nil)
    #expect(idA != idB)
  }

  /// Reaching the same folder via a symlink resolves to the same id (symlinks are
  /// resolved before hashing).
  @Test func symlinkPathResolvesToSameId() throws {
    let target = FileManager.default.temporaryDirectory
      .appendingPathComponent("DestId-Target-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: target) }

    let symlinkParent = FileManager.default.temporaryDirectory
      .appendingPathComponent("DestId-Symlink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: symlinkParent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: symlinkParent) }
    let symlink = symlinkParent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

    let idDirect = ExportDestinationManager.computeDestinationId(for: target)
    let idViaSymlink = ExportDestinationManager.computeDestinationId(for: symlink)
    #expect(idDirect != nil)
    #expect(idDirect == idViaSymlink)
  }

  // MARK: - Bookmark refresh stability

  /// Plan §"Phase 0" exit criterion: a bookmark refresh on the same folder produces an
  /// unchanged `destinationId`. Save a bookmark, restore it, refresh by calling save again
  /// — the id stays the same because it derives from the volume + path, not the bookmark
  /// bytes.
  @Test func destinationIdSurvivesBookmarkRefresh() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("DestId-BookmarkRefresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let suiteName = "DestId-Refresh-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let bookmarkKey = "DestId-Refresh-Bookmark-\(UUID().uuidString)"
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let writer = ExportDestinationManager(
      skipRestore: true,
      userDefaults: defaults,
      bookmarkDefaultsKey: bookmarkKey
    )
    writer.persistSelectedFolderForTesting(dir)
    let firstId = writer.destinationId

    // "Refresh" by restoring from defaults (a fresh manager parses the bookmark again).
    let restored = ExportDestinationManager(
      userDefaults: defaults,
      bookmarkDefaultsKey: bookmarkKey
    )
    let secondId = restored.destinationId

    #expect(firstId != nil)
    #expect(firstId == secondId)
  }

  // MARK: - Legacy derivation

  /// `legacyDestinationId(from:)` is the pre-Phase-0 bookmark-hash scheme, kept around so
  /// `ExportRecordsDirectoryCoordinator` can locate `ExportRecords/<oldId>/` directories
  /// written by previous app versions. Verify it still produces a deterministic SHA-256.
  @Test func legacyDestinationIdHashesBookmarkBytes() {
    let bytes = Data("the-old-bookmark-bytes".utf8)
    let id1 = ExportDestinationManager.legacyDestinationId(from: bytes)
    let id2 = ExportDestinationManager.legacyDestinationId(from: bytes)
    #expect(id1 == id2)
    #expect(id1.count == 64)  // SHA-256 hex
    let other = ExportDestinationManager.legacyDestinationId(from: Data("different-bytes".utf8))
    #expect(id1 != other)
  }

  /// `currentLegacyDestinationId()` returns nil when no bookmark is stored, and the legacy
  /// hash of the bookmark bytes when one is.
  @Test func currentLegacyDestinationIdReadsStoredBookmark() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("DestId-Legacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let suiteName = "DestId-Legacy-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let bookmarkKey = "DestId-Legacy-Bookmark-\(UUID().uuidString)"
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let mgrEmpty = ExportDestinationManager(
      skipRestore: true,
      userDefaults: defaults,
      bookmarkDefaultsKey: bookmarkKey
    )
    #expect(mgrEmpty.currentLegacyDestinationId() == nil)

    let mgr = ExportDestinationManager(
      skipRestore: true,
      userDefaults: defaults,
      bookmarkDefaultsKey: bookmarkKey
    )
    mgr.persistSelectedFolderForTesting(dir)
    let legacyId = mgr.currentLegacyDestinationId()
    #expect(legacyId != nil)
    #expect(legacyId?.count == 64)
  }
}
