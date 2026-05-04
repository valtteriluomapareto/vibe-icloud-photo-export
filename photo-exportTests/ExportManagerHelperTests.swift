import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct ExportManagerHelperTests {
  // Use a minimal ExportManager instance for testing pure helpers.
  // These tests exercise filename utilities and queue counter logic.
  private func makeManager() -> (ExportManager, ExportRecordStore) {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let recordStore = ExportRecordStore(baseDirectoryURL: tempDir)
    recordStore.configure(for: "test")
    let photoLib = PhotoLibraryManager()
    let destMgr = ExportDestinationManager(skipRestore: true)
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: destMgr,
      exportRecordStore: recordStore)
    return (manager, recordStore)
  }

  // MARK: - splitFilename

  @Test func testSplitFilenameBasic() {
    let (mgr, _) = makeManager()
    let result = mgr.splitFilename("IMG_0001.JPG")
    #expect(result.base == "IMG_0001")
    #expect(result.ext == "JPG")
  }

  @Test func testSplitFilenameMultipleDots() {
    let (mgr, _) = makeManager()
    let result = mgr.splitFilename("my.photo.file.heic")
    #expect(result.base == "my.photo.file")
    #expect(result.ext == "heic")
  }

  @Test func testSplitFilenameNoExtension() {
    let (mgr, _) = makeManager()
    let result = mgr.splitFilename("README")
    #expect(result.base == "README")
    #expect(result.ext == "")
  }

  @Test func testSplitFilenameWithSpaces() {
    let (mgr, _) = makeManager()
    let result = mgr.splitFilename("My Photo (1).png")
    #expect(result.base == "My Photo (1)")
    #expect(result.ext == "png")
  }

  // MARK: - uniqueFileURL

  @Test func testUniqueFileURLNoConflict() throws {
    let (mgr, _) = makeManager()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = mgr.uniqueFileURL(in: dir, baseName: "photo", ext: "jpg")
    #expect(url.lastPathComponent == "photo.jpg")
  }

  @Test func testUniqueFileURLWithConflicts() throws {
    let (mgr, _) = makeManager()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Create conflicting files
    FileManager.default.createFile(
      atPath: dir.appendingPathComponent("photo.jpg").path, contents: nil)
    FileManager.default.createFile(
      atPath: dir.appendingPathComponent("photo (1).jpg").path, contents: nil)

    let url = mgr.uniqueFileURL(in: dir, baseName: "photo", ext: "jpg")
    #expect(url.lastPathComponent == "photo (2).jpg")
  }

  @Test func testUniqueFileURLSequentialConflicts() throws {
    let (mgr, _) = makeManager()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Create a run of conflicts
    FileManager.default.createFile(
      atPath: dir.appendingPathComponent("IMG.heic").path, contents: nil)
    for i in 1...5 {
      FileManager.default.createFile(
        atPath: dir.appendingPathComponent("IMG (\(i)).heic").path, contents: nil)
    }

    let url = mgr.uniqueFileURL(in: dir, baseName: "IMG", ext: "heic")
    #expect(url.lastPathComponent == "IMG (6).heic")
  }

  // MARK: - Queue counter state

  @Test func testQueuedCountDictionaryStartsEmpty() {
    let (mgr, _) = makeManager()
    #expect(mgr.queuedCount(year: 2025, month: 1) == 0)
    #expect(mgr.totalJobsEnqueued == 0)
    #expect(mgr.totalJobsCompleted == 0)
  }

  @Test func testCancelAndClearResetsAllCounters() {
    let (mgr, _) = makeManager()
    // Simulate some state by calling cancelAndClear on a fresh manager
    mgr.cancelAndClear()
    #expect(mgr.totalJobsEnqueued == 0)
    #expect(mgr.totalJobsCompleted == 0)
    #expect(mgr.currentAssetFilename == nil)
    #expect(mgr.queueCount == 0)
    #expect(mgr.isRunning == false)
    #expect(mgr.isPaused == false)
  }

  @Test func testPauseAndResumeToggle() {
    let (mgr, _) = makeManager()
    // Pause on non-running manager is a no-op
    mgr.pause()
    #expect(mgr.isPaused == false)

    // Resume on non-paused manager is a no-op
    mgr.resume()
    #expect(mgr.isPaused == false)
  }

  // MARK: - canExport gates

  /// Phase 1.5 split canExport into two store-scoped readiness checks. Timeline starts
  /// must require the **timeline** store to be `.ready`; depending on the collection
  /// store would block legitimate timeline export when only the timeline store is
  /// configured (the typical pre-Phase-3 state).
  @Test func canExportTimelineRequiresTimelineReady() {
    let (mgr, _) = makeManager()
    // makeManager() configured the timeline store with a destination; collection store
    // was never configured → it stays `.unconfigured`. Timeline export should still work.
    #expect(mgr.canExportTimeline == true)
    #expect(mgr.canExportCollection == false)
  }

  /// An unconfigured timeline store blocks `startExportMonth`. Without the gate,
  /// the pipeline would write files to disk while every `markVariant*` call silently
  /// no-ops because the store's `state != .ready`.
  @Test func startExportMonthShortCircuitsWhenTimelineNotReady() {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let recordStore = ExportRecordStore(baseDirectoryURL: tempDir)
    // Intentionally skip configure(for:) — store stays `.unconfigured`.
    let photoLib = PhotoLibraryManager()
    let destMgr = ExportDestinationManager(skipRestore: true)
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: destMgr,
      exportRecordStore: recordStore)

    #expect(manager.canExportTimeline == false)
    manager.startExportMonth(year: 2025, month: 6)
    // The start was rejected: no jobs enqueued, no enqueueing-all flag set.
    #expect(manager.totalJobsEnqueued == 0)
    #expect(manager.queuedCount(year: 2025, month: 6) == 0)
  }
}
