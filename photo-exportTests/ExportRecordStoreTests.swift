import Foundation
import Testing

@testable import photo_export

@MainActor
struct ExportRecordStoreTests {
    @Test func testLoadEmptyStore() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        #expect(store.recordsById.isEmpty)
    }

    @Test func testUpsertAndQuery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        let id = "asset-1"
        store.markExported(
            assetId: id, year: 2025, month: 2, relPath: "2025/02/", filename: "IMG_0001.JPG",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(assetId: id))
        let info = store.exportInfo(assetId: id)
        #expect(info?.filename == "IMG_0001.JPG")
        #expect(info?.year == 2025)
        #expect(info?.month == 2)
    }

    @Test func testMonthSummary() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        store.markExported(
            assetId: "a1", year: 2025, month: 1, relPath: "2025/01/", filename: "A.jpg",
            exportedAt: Date())
        store.markExported(
            assetId: "a2", year: 2025, month: 1, relPath: "2025/01/", filename: "B.jpg",
            exportedAt: Date())
        store.markFailed(assetId: "a3", error: "disk full", at: Date())  // wrong year/month defaults
        store.flushForTesting()
        let s1 = store.monthSummary(year: 2025, month: 1, totalAssets: 5)
        #expect(s1.exportedCount == 2)
        #expect(s1.totalCount == 5)
        #expect(s1.status == .partial)
        let s2 = store.monthSummary(year: 2025, month: 2, totalAssets: 3)
        #expect(s2.exportedCount == 0)
        #expect(s2.status == .notExported)
    }

    @Test func testFailureUpsert() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        let id = "asset-fail"
        store.markFailed(assetId: id, error: "network", at: Date())
        store.flushForTesting()
        let info = store.exportInfo(assetId: id)
        #expect(info?.status == .failed)
        #expect(info?.lastError == "network")
    }

    @Test func testPersistenceAcrossLaunchesAndDeletion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store1 = ExportRecordStore(baseDirectoryURL: tempDir)
        store1.configure(for: "destA")
        store1.markInProgress(
            assetId: "x1", year: 2025, month: 3, relPath: "2025/03/", filename: nil)
        store1.markExported(
            assetId: "x2", year: 2025, month: 3, relPath: "2025/03/", filename: "X2.jpg",
            exportedAt: Date())
        store1.remove(assetId: "x1")
        store1.flushForTesting()

        // New instance, same root and destination id
        let store2 = ExportRecordStore(baseDirectoryURL: tempDir)
        store2.configure(for: "destA")
        #expect(store2.exportInfo(assetId: "x2")?.status == .done)
        #expect(store2.exportInfo(assetId: "x1") == nil)
    }

    @Test func testInProgressToDoneTransition() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        store.markInProgress(
            assetId: "t1", year: 2025, month: 4, relPath: "2025/04/", filename: "tmp.mov")
        store.flushForTesting()
        #expect(store.exportInfo(assetId: "t1")?.status == .inProgress)
        store.markExported(
            assetId: "t1", year: 2025, month: 4, relPath: "2025/04/", filename: "final.mov",
            exportedAt: Date())
        store.flushForTesting()
        let rec = store.exportInfo(assetId: "t1")
        #expect(rec?.status == .done)
        #expect(rec?.filename == "final.mov")
    }

    @Test func testCorruptedLogLineIsSkipped() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        let destId = "destA"
        store.configure(for: destId)
        store.markExported(
            assetId: "ok", year: 2025, month: 5, relPath: "2025/05/", filename: "OK.jpg",
            exportedAt: Date())
        store.flushForTesting()
        // Append an invalid line to the destination-specific log
        let logURL = tempDir.appendingPathComponent(destId, isDirectory: true)
            .appendingPathComponent("export-records.jsonl")
        let invalid = "{ this is not valid json }\n".data(using: .utf8)!
        try invalid.append(to: logURL)

        // Reload - invalid line should be skipped, valid records preserved
        let store2 = ExportRecordStore(baseDirectoryURL: tempDir)
        store2.configure(for: destId)
        #expect(store2.exportInfo(assetId: "ok")?.status == .done)
    }

    @Test func testPerDestinationIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: root)

        store.configure(for: "destA")
        store.markExported(
            assetId: "a1", year: 2025, month: 6, relPath: "2025/06/", filename: "A1.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(assetId: "a1"))

        store.configure(for: "destB")
        #expect(!store.isExported(assetId: "a1"))
        store.markExported(
            assetId: "b1", year: 2025, month: 6, relPath: "2025/06/", filename: "B1.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(assetId: "b1"))

        store.configure(for: "destA")
        #expect(store.isExported(assetId: "a1"))
        #expect(!store.isExported(assetId: "b1"))
    }

    @Test func testNilDestinationShowsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: root)

        store.configure(for: "destA")
        store.markExported(
            assetId: "a1", year: 2025, month: 7, relPath: "2025/07/", filename: "A1.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(assetId: "a1"))

        store.configure(for: nil)
        #expect(!store.isExported(assetId: "a1"))
        #expect(store.monthSummary(year: 2025, month: 7, totalAssets: 1).exportedCount == 0)
    }

    @Test func testMutationCounterCoalescedNotifications() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destC")
        let baseline = store.mutationCounter
        // Burst of mutations
        for i in 0..<5 {
            store.markInProgress(
                assetId: "c\(i)", year: 2025, month: 8, relPath: "2025/08/", filename: nil)
        }
        // Wait for debounce (200ms) to fire once
        try await Task.sleep(nanoseconds: 600_000_000)
        let delta = store.mutationCounter - baseline
        #expect(delta == 1)
    }

    @Test func testDoneCountTracksTransitionsAndMoves() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destD")
        // Export to month 9
        store.markExported(
            assetId: "t", year: 2025, month: 9, relPath: "2025/09/", filename: "A.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.monthSummary(year: 2025, month: 9, totalAssets: 10).exportedCount == 1)
        // Mark failed -> should decrement month 9
        store.markFailed(assetId: "t", error: "oops", at: Date())
        store.flushForTesting()
        #expect(store.monthSummary(year: 2025, month: 9, totalAssets: 10).exportedCount == 0)
        // Re-export same id to month 10 -> counts move
        store.markExported(
            assetId: "t", year: 2025, month: 10, relPath: "2025/10/", filename: "B.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.monthSummary(year: 2025, month: 9, totalAssets: 10).exportedCount == 0)
        #expect(store.monthSummary(year: 2025, month: 10, totalAssets: 10).exportedCount == 1)
    }
}

extension Data {
    fileprivate func append(to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
        try handle.synchronize()
    }
}
