import Foundation
import Testing
@testable import photo_export

struct ExportRecordStoreTests {
    @Test func testLoadEmptyStore() throws {
        let store = ExportRecordStore()
        try store.loadOnLaunch()
        #expect(store.recordsById.isEmpty)
    }

    @Test func testUpsertAndQuery() throws {
        let store = ExportRecordStore()
        try store.loadOnLaunch()
        let id = "asset-1"
        store.markExported(assetId: id, year: 2025, month: 2, relPath: "2025/02/", filename: "IMG_0001.JPG", exportedAt: Date())
        // allow IO queue to flush
        usleep(50_000)
        #expect(store.isExported(assetId: id))
        let info = store.exportInfo(assetId: id)
        #expect(info?.filename == "IMG_0001.JPG")
        #expect(info?.year == 2025)
        #expect(info?.month == 2)
    }

    @Test func testMonthSummary() throws {
        let store = ExportRecordStore()
        try store.loadOnLaunch()
        store.markExported(assetId: "a1", year: 2025, month: 1, relPath: "2025/01/", filename: "A.jpg", exportedAt: Date())
        store.markExported(assetId: "a2", year: 2025, month: 1, relPath: "2025/01/", filename: "B.jpg", exportedAt: Date())
        store.markFailed(assetId: "a3", error: "disk full", at: Date()) // wrong year/month defaults
        usleep(50_000)
        let s1 = store.monthSummary(year: 2025, month: 1, totalAssets: 5)
        #expect(s1.exportedCount == 2)
        #expect(s1.totalCount == 5)
        #expect(s1.status == .partial)
        let s2 = store.monthSummary(year: 2025, month: 2, totalAssets: 3)
        #expect(s2.exportedCount == 0)
        #expect(s2.status == .notExported)
    }

    @Test func testFailureUpsert() throws {
        let store = ExportRecordStore()
        try store.loadOnLaunch()
        let id = "asset-fail"
        store.markFailed(assetId: id, error: "network", at: Date())
        usleep(50_000)
        let info = store.exportInfo(assetId: id)
        #expect(info?.status == .failed)
        #expect(info?.lastError == "network")
    }
}
