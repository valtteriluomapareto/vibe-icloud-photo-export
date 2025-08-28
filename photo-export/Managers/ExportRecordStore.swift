import Foundation
import os

/// Thread-safe-ish store using a serial IO queue for disk operations and in-memory map for queries.
///
/// Persistence design:
/// - Mutations are appended to `export-records.jsonl` (one JSON object per line).
/// - On launch, we fold the JSONL log into `recordsById` and optionally overlay a snapshot `export-records.json` if present.
/// - After N mutations or at app termination, we compact into a canonical snapshot file and truncate the log.
final class ExportRecordStore {
    struct Constants {
        static let directoryName = "ExportRecords"
        static let logFileName = "export-records.jsonl"
        static let snapshotFileName = "export-records.json"
        static let compactEveryNMutations = 1000
    }

    private let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "ExportRecords")
    private let ioQueue = DispatchQueue(label: "com.valtteriluoma.photo-export.records-io", qos: .utility)

    private(set) var recordsById: [String: ExportRecord] = [:]
    private var mutationCountSinceCompact: Int = 0

    private let fileManager = FileManager.default
    private let baseDirectoryURL: URL
    private let logFileURL: URL
    private let snapshotFileURL: URL

    init() {
        let appSupport = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleId = Bundle.main.bundleIdentifier ?? "com.valtteriluoma.photo-export"
        let root = appSupport.appendingPathComponent(bundleId, isDirectory: true)
        let storeDir = root.appendingPathComponent(Constants.directoryName, isDirectory: true)
        self.baseDirectoryURL = storeDir
        self.logFileURL = storeDir.appendingPathComponent(Constants.logFileName)
        self.snapshotFileURL = storeDir.appendingPathComponent(Constants.snapshotFileName)
        createDirectoryIfNeeded(storeDir)
    }

    // MARK: - Lifecycle
    func loadOnLaunch() throws {
        recordsById = [:]
        // Prefer snapshot if available, then apply log mutations after
        if fileManager.fileExists(atPath: snapshotFileURL.path) {
            do {
                let data = try Data(contentsOf: snapshotFileURL)
                let decoded = try JSONDecoder().decode([String: ExportRecord].self, from: data)
                recordsById = decoded
            } catch {
                logger.error("Failed to read snapshot: \(String(describing: error), privacy: .public)")
            }
        }
        if fileManager.fileExists(atPath: logFileURL.path) {
            do {
                let handle = try FileHandle(forReadingFrom: logFileURL)
                defer { try? handle.close() }
                while let lineData = handle.readLineData() {
                    do {
                        let mutation = try JSONDecoder().decode(ExportRecordMutation.self, from: lineData)
                        apply(mutation)
                    } catch {
                        // Skip broken lines but log
                        logger.error("Failed to decode mutation line: \(String(describing: error), privacy: .public)")
                    }
                }
            } catch {
                logger.error("Failed to read log file: \(String(describing: error), privacy: .public)")
            }
        }
        mutationCountSinceCompact = 0
    }

    // MARK: - Public API (mutations)
    func markExported(assetId: String, year: Int, month: Int, relPath: String, filename: String, exportedAt: Date) {
        var record = recordsById[assetId] ?? ExportRecord(id: assetId, year: year, month: month, relPath: relPath, filename: nil, status: .pending, exportDate: nil, lastError: nil)
        record.year = year
        record.month = month
        record.relPath = relPath
        record.filename = filename
        record.status = .done
        record.exportDate = exportedAt
        record.lastError = nil
        append(.upsert(record))
    }

    func markFailed(assetId: String, error: String, at date: Date) {
        var record = recordsById[assetId] ?? ExportRecord(id: assetId, year: 0, month: 0, relPath: "", filename: nil, status: .pending, exportDate: nil, lastError: nil)
        record.status = .failed
        record.exportDate = date
        record.lastError = error
        append(.upsert(record))
    }

    func markInProgress(assetId: String, year: Int, month: Int, relPath: String, filename: String?) {
        var record = recordsById[assetId] ?? ExportRecord(id: assetId, year: year, month: month, relPath: relPath, filename: filename, status: .pending, exportDate: nil, lastError: nil)
        record.year = year
        record.month = month
        record.relPath = relPath
        record.filename = filename
        record.status = .inProgress
        append(.upsert(record))
    }

    func remove(assetId: String) {
        append(.delete(id: assetId))
    }

    // MARK: - Public API (queries)
    func isExported(assetId: String) -> Bool {
        recordsById[assetId]?.status == .done
    }

    func exportInfo(assetId: String) -> ExportRecord? {
        recordsById[assetId]
    }

    func monthSummary(year: Int, month: Int, totalAssets: Int) -> MonthStatusSummary {
        let exportedCount = recordsById.values.reduce(0) { partial, rec in
            partial + ((rec.year == year && rec.month == month && rec.status == .done) ? 1 : 0)
        }
        let status: MonthExportStatus
        if exportedCount == 0 { status = .notExported }
        else if exportedCount < totalAssets { status = .partial }
        else { status = .complete }
        return MonthStatusSummary(year: year, month: month, exportedCount: exportedCount, totalCount: totalAssets, status: status)
    }

    // MARK: - Internals
    private func append(_ mutation: ExportRecordMutation) {
        apply(mutation)
        ioQueue.async { [self] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(mutation)
                try appendLine(data: data, to: logFileURL)
                mutationCountSinceCompact += 1
                if mutationCountSinceCompact >= Constants.compactEveryNMutations {
                    try compactSnapshot()
                    mutationCountSinceCompact = 0
                }
            } catch {
                logger.error("Failed to persist mutation: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func apply(_ mutation: ExportRecordMutation) {
        switch mutation.op {
        case .upsert:
            if let record = mutation.record { recordsById[mutation.id] = record }
        case .delete:
            recordsById.removeValue(forKey: mutation.id)
        }
    }

    private func compactSnapshot() throws {
        let tmpURL = snapshotFileURL.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recordsById)
        try data.write(to: tmpURL, options: .atomic)
        // Replace snapshot
        if fileManager.fileExists(atPath: snapshotFileURL.path) {
            try fileManager.removeItem(at: snapshotFileURL)
        }
        try fileManager.moveItem(at: tmpURL, to: snapshotFileURL)
        // Truncate log
        try Data().write(to: logFileURL, options: .atomic)
    }

    private func createDirectoryIfNeeded(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            do { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) } catch {
                logger.error("Failed to create store directory: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - FileHandle line reading
private extension FileHandle {
    /// Reads a line terminated by \n and returns Data without the trailing newline.
    func readLineData() -> Data? {
        var buffer = Data()
        while true {
            let chunk = try? self.read(upToCount: 1)
            guard let byte = chunk, !byte.isEmpty else {
                return buffer.isEmpty ? nil : buffer
            }
            if byte[0] == 0x0A { // \n
                return buffer
            } else {
                buffer.append(byte)
            }
        }
    }
}

private func appendLine(data: Data, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.write(contentsOf: Data([0x0A])) // newline
    try handle.synchronize()
}
