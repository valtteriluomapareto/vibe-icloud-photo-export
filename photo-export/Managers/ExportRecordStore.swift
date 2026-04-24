import Combine
import Foundation
import os

/// Thread-safe-ish store using a serial IO queue for disk operations and in-memory map for queries.
///
/// Persistence design:
/// - Mutations are appended to `export-records.jsonl` (one JSON object per line) under a destination-specific directory.
/// - On configure/load, we fold the JSONL log into `recordsById` and optionally overlay a snapshot `export-records.json` if present.
/// - After N mutations or at app termination, we compact into a canonical snapshot file and truncate the log.
///
/// Schema:
/// - Current records carry per-variant state in `ExportRecord.variants` keyed by `ExportVariant`.
/// - Legacy flat records (single filename/status fields) decode into a synthesized `.original` variant.
/// - On load, any variant left as `.inProgress` is converted to `.failed` with `ExportVariantRecovery.interruptedMessage`
///   because no in-progress state survives app restart.
@MainActor
final class ExportRecordStore: ObservableObject {
  struct Constants {
    static let directoryName = "ExportRecords"
    static let logFileName = "export-records.jsonl"
    static let snapshotFileName = "export-records.json"
    static let compactEveryNMutations = 1000
  }

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ExportRecords")
  private let ioQueue = DispatchQueue(
    label: "com.valtteriluoma.photo-export.records-io", qos: .utility)

  private(set) var recordsById: [String: ExportRecord] = [:]
  private var mutationCountSinceCompact: Int = 0

  // Published bump used to notify SwiftUI of logical changes
  @Published private(set) var mutationCounter: Int = 0
  private var notifyWorkItem: DispatchWorkItem?

  private let fileManager = FileManager.default
  private let storeRootURL: URL
  private var currentStoreDirURL: URL?

  private var logFileURL: URL? {
    currentStoreDirURL?.appendingPathComponent(Constants.logFileName)
  }
  private var snapshotFileURL: URL? {
    currentStoreDirURL?.appendingPathComponent(Constants.snapshotFileName)
  }

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
    self.storeRootURL = storeDir
    createDirectoryIfNeeded(storeDir)
  }

  // Test-only/init-injection: allow specifying a base directory for the store root
  init(baseDirectoryURL: URL) {
    self.storeRootURL = baseDirectoryURL
    createDirectoryIfNeeded(baseDirectoryURL)
  }

  // MARK: - Destination configuration
  /// Points the store at a specific destination id (subdirectory). Passing nil clears state (shows empty).
  func configure(for destinationId: String?) {
    // Reset in-memory state
    recordsById = [:]
    mutationCountSinceCompact = 0

    guard let destinationId else {
      currentStoreDirURL = nil
      mutationCounter &+= 1
      return
    }

    let dir = storeRootURL.appendingPathComponent(destinationId, isDirectory: true)
    createDirectoryIfNeeded(dir)
    currentStoreDirURL = dir

    // Load snapshot and log from the current directory
    loadFromCurrentDirectory()
    mutationCounter &+= 1
  }

  private func loadFromCurrentDirectory() {
    guard let snapshotURL = snapshotFileURL, let logURL = logFileURL else { return }
    recordsById = [:]
    // Prefer snapshot if available, then apply log mutations after
    if fileManager.fileExists(atPath: snapshotURL.path) {
      do {
        let data = try Data(contentsOf: snapshotURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([String: ExportRecord].self, from: data)
        recordsById = decoded
      } catch {
        logger.error(
          "Failed to read snapshot: \(String(describing: error), privacy: .public)")
      }
    }
    if fileManager.fileExists(atPath: logURL.path) {
      do {
        let handle = try FileHandle(forReadingFrom: logURL)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while let lineData = handle.readLineData() {
          do {
            let mutation = try decoder.decode(ExportRecordMutation.self, from: lineData)
            apply(mutation)
          } catch {
            // Skip broken lines but log
            logger.error(
              "Failed to decode mutation line: \(String(describing: error), privacy: .public)"
            )
          }
        }
      } catch {
        logger.error(
          "Failed to read log file: \(String(describing: error), privacy: .public)")
      }
    }

    recoverInProgressVariants()
  }

  /// Converts any variant left as `.inProgress` after load into `.failed` with the interrupted
  /// message. No in-progress state survives app restart; `.pending` is preserved as-is.
  private func recoverInProgressVariants() {
    for (id, record) in recordsById {
      var mutated = record
      var changed = false
      for (variant, variantRecord) in record.variants where variantRecord.status == .inProgress {
        var next = variantRecord
        next.status = .failed
        next.lastError = ExportVariantRecovery.interruptedMessage
        mutated.variants[variant] = next
        changed = true
      }
      if changed {
        recordsById[id] = mutated
      }
    }
  }

  // MARK: - Public API (variant mutations)

  /// Marks a variant `.inProgress`. Creates the record if missing and upserts the variant.
  func markVariantInProgress(
    assetId: String,
    variant: ExportVariant,
    year: Int,
    month: Int,
    relPath: String,
    filename: String?
  ) {
    var record =
      recordsById[assetId]
      ?? ExportRecord(
        id: assetId, year: year, month: month, relPath: relPath)
    record.year = year
    record.month = month
    record.relPath = relPath
    var variantRecord =
      record.variants[variant]
      ?? ExportVariantRecord(
        filename: filename, status: .pending, exportDate: nil, lastError: nil)
    variantRecord.filename = filename
    variantRecord.status = .inProgress
    variantRecord.lastError = nil
    record.variants[variant] = variantRecord
    append(.upsert(record))
  }

  /// Marks a variant `.done` with a final filename. Creates the record if missing.
  func markVariantExported(
    assetId: String,
    variant: ExportVariant,
    year: Int,
    month: Int,
    relPath: String,
    filename: String,
    exportedAt: Date
  ) {
    var record =
      recordsById[assetId]
      ?? ExportRecord(
        id: assetId, year: year, month: month, relPath: relPath)
    record.year = year
    record.month = month
    record.relPath = relPath
    let variantRecord = ExportVariantRecord(
      filename: filename, status: .done, exportDate: exportedAt, lastError: nil)
    record.variants[variant] = variantRecord
    append(.upsert(record))
  }

  /// Marks a variant `.failed`. Creates the record if missing; preserves year/month/relPath
  /// for existing records.
  func markVariantFailed(
    assetId: String,
    variant: ExportVariant,
    error: String,
    at date: Date
  ) {
    var record =
      recordsById[assetId]
      ?? ExportRecord(
        id: assetId, year: 0, month: 0, relPath: "")
    var variantRecord =
      record.variants[variant]
      ?? ExportVariantRecord(
        filename: nil, status: .pending, exportDate: nil, lastError: nil)
    variantRecord.status = .failed
    variantRecord.exportDate = date
    variantRecord.lastError = error
    record.variants[variant] = variantRecord
    append(.upsert(record))
  }

  /// Removes a single variant from an asset record. If no variants remain, removes the record.
  func removeVariant(assetId: String, variant: ExportVariant) {
    guard var record = recordsById[assetId] else { return }
    guard record.variants[variant] != nil else { return }
    record.variants.removeValue(forKey: variant)
    if record.variants.isEmpty {
      append(.delete(id: assetId))
    } else {
      append(.upsert(record))
    }
  }

  // MARK: - Public API (legacy wrappers, route to .original)

  func markExported(
    assetId: String,
    year: Int,
    month: Int,
    relPath: String,
    filename: String,
    exportedAt: Date
  ) {
    markVariantExported(
      assetId: assetId, variant: .original, year: year, month: month, relPath: relPath,
      filename: filename, exportedAt: exportedAt)
  }

  func markFailed(assetId: String, error: String, at date: Date) {
    markVariantFailed(assetId: assetId, variant: .original, error: error, at: date)
  }

  func markInProgress(
    assetId: String, year: Int, month: Int, relPath: String, filename: String?
  ) {
    markVariantInProgress(
      assetId: assetId, variant: .original, year: year, month: month, relPath: relPath,
      filename: filename)
  }

  func remove(assetId: String) {
    append(.delete(id: assetId))
  }

  // MARK: - Public API (queries)

  /// Whether the `.original` variant for this asset is `.done`. Kept as a cheap asset-ID shim for
  /// legacy call sites and tests; new code should use `isExported(asset:selection:)`.
  func isExported(assetId: String) -> Bool {
    recordsById[assetId]?.variants[.original]?.status == .done
  }

  /// Selection-aware completion check for a single asset.
  func isExported(asset: AssetDescriptor, selection: ExportVersionSelection) -> Bool {
    let required = requiredVariants(for: asset, selection: selection)
    if required.isEmpty { return true }
    guard let record = recordsById[asset.id] else { return false }
    return required.allSatisfy { record.variants[$0]?.status == .done }
  }

  func exportInfo(assetId: String) -> ExportRecord? {
    recordsById[assetId]
  }

  /// Total number of assets in `year` whose `.original` variant is `.done`. Matches legacy
  /// yearly progress counting for unadjusted libraries.
  func yearExportedCount(year: Int) -> Int {
    recordsById.values.reduce(0) { sum, record in
      guard record.year == year, record.variants[.original]?.status == .done else { return sum }
      return sum + 1
    }
  }

  /// Legacy month summary that counts `.original` done records. Preserved for call sites that
  /// have not yet adopted `monthSummary(assets:selection:)`.
  func monthSummary(year: Int, month: Int, totalAssets: Int) -> MonthStatusSummary {
    let exportedCount = recordsById.values.reduce(0) { sum, record in
      guard record.year == year, record.month == month,
        record.variants[.original]?.status == .done
      else { return sum }
      return sum + 1
    }
    return makeSummary(year: year, month: month, exported: exportedCount, total: totalAssets)
  }

  /// Selection-aware month summary. Caller supplies the month's loaded asset descriptors so the
  /// evaluator can consult each asset's `hasAdjustments`.
  func monthSummary(assets: [AssetDescriptor], selection: ExportVersionSelection)
    -> MonthStatusSummary
  {
    let year =
      assets.first.map { Calendar.current.component(.year, from: $0.creationDate ?? Date()) }
      ?? 0
    let month =
      assets.first.map { Calendar.current.component(.month, from: $0.creationDate ?? Date()) }
      ?? 0

    var exported = 0
    var total = 0
    for asset in assets {
      let required = requiredVariants(for: asset, selection: selection)
      if required.isEmpty { continue }
      total += 1
      let record = recordsById[asset.id]
      let allDone = required.allSatisfy { record?.variants[$0]?.status == .done }
      if allDone { exported += 1 }
    }
    return makeSummary(year: year, month: month, exported: exported, total: total)
  }

  /// Count of records in `year`/`month` whose variant matches the requested `variant` with the
  /// requested `status`. Used by selection-aware sidebar summaries that do not have access to the
  /// loaded asset descriptors.
  func recordCount(
    year: Int, month: Int, variant: ExportVariant, status: ExportStatus
  ) -> Int {
    recordsById.values.reduce(0) { sum, record in
      guard record.year == year, record.month == month,
        record.variants[variant]?.status == status
      else { return sum }
      return sum + 1
    }
  }

  /// Count of records in `year`/`month` whose `.original` and `.edited` variants are both
  /// `.done`. These records are definitely fully complete under `originalAndEdited` regardless
  /// of whether the asset is currently adjusted.
  func recordCountBothVariantsDone(year: Int, month: Int) -> Int {
    recordsById.values.reduce(0) { sum, record in
      guard record.year == year, record.month == month else { return sum }
      let originalDone = record.variants[.original]?.status == .done
      let editedDone = record.variants[.edited]?.status == .done
      return sum + (originalDone && editedDone ? 1 : 0)
    }
  }

  /// Selection-aware summary for a sidebar row that does not have loaded `AssetDescriptor`s.
  /// `adjustedCount` must be supplied by the caller from `PhotoLibraryService.countAdjustedAssets`
  /// except for `originalOnly` where it is not consulted; pass nil to indicate the count has not
  /// finished loading so the view can show a neutral state.
  func sidebarSummary(
    year: Int, month: Int, totalCount: Int, adjustedCount: Int?,
    selection: ExportVersionSelection
  ) -> MonthStatusSummary? {
    switch selection {
    case .originalOnly:
      let done = recordCount(year: year, month: month, variant: .original, status: .done)
      return makeSummary(year: year, month: month, exported: done, total: totalCount)
    case .editedOnly:
      guard let adjustedCount else { return nil }
      let done = recordCount(year: year, month: month, variant: .edited, status: .done)
      return makeSummary(year: year, month: month, exported: done, total: adjustedCount)
    case .originalAndEdited:
      guard let adjustedCount else { return nil }
      // An adjusted asset is complete only when both variants are done. An unedited asset is
      // complete when its `.original` is done. Records with `.original` done but `.edited` not
      // done could be either (unedited and complete) or (adjusted with the edited variant still
      // missing or failed); the approximation caps that ambiguous set at the total unedited
      // asset count so we never claim a fully-done asset we don't have evidence for.
      let bothDone = recordCountBothVariantsDone(year: year, month: month)
      let originalDone = recordCount(
        year: year, month: month, variant: .original, status: .done)
      let originalOnlyDone = max(0, originalDone - bothDone)
      let uneditedCount = max(0, totalCount - adjustedCount)
      let exported = bothDone + min(originalOnlyDone, uneditedCount)
      return makeSummary(year: year, month: month, exported: exported, total: totalCount)
    }
  }

  /// Aggregate year-wide exported count under the active selection. Uses the same approximation
  /// rules as `sidebarSummary` and sums across months.
  func sidebarYearExportedCount(
    year: Int,
    totalCountsByMonth: [Int: Int],
    adjustedCountsByMonth: [Int: Int?],
    selection: ExportVersionSelection
  ) -> Int {
    var total = 0
    for month in 1...12 {
      let monthTotal = totalCountsByMonth[month] ?? 0
      if monthTotal == 0 { continue }
      let monthAdjusted = adjustedCountsByMonth[month].flatMap { $0 }
      guard
        let summary = sidebarSummary(
          year: year, month: month, totalCount: monthTotal,
          adjustedCount: monthAdjusted, selection: selection)
      else { continue }
      total += summary.exportedCount
    }
    return total
  }

  private func makeSummary(year: Int, month: Int, exported: Int, total: Int)
    -> MonthStatusSummary
  {
    let status: MonthExportStatus
    if total == 0 {
      status = .notExported
    } else if exported == 0 {
      status = .notExported
    } else if exported < total {
      status = .partial
    } else {
      status = .complete
    }
    return MonthStatusSummary(
      year: year, month: month, exportedCount: exported, totalCount: total, status: status)
  }

  // MARK: - Bulk import (for backup import)

  /// Imports a batch of records from the backup-scan flow, merging per variant. An existing
  /// `.done` for a given asset+variant is preserved; weaker statuses may be replaced by an imported
  /// `.done` variant.
  func bulkImportRecords(_ records: [ExportRecord]) {
    var importedVariants = 0
    var skippedVariants = 0
    for incoming in records {
      var merged =
        recordsById[incoming.id]
        ?? ExportRecord(
          id: incoming.id, year: incoming.year, month: incoming.month, relPath: incoming.relPath)
      merged.year = incoming.year
      merged.month = incoming.month
      merged.relPath = incoming.relPath
      var changed = false
      for (variant, variantRecord) in incoming.variants {
        if let existing = merged.variants[variant], existing.status == .done {
          skippedVariants += 1
          continue
        }
        merged.variants[variant] = variantRecord
        importedVariants += 1
        changed = true
      }
      if changed {
        append(.upsert(merged))
      }
    }
    logger.info(
      "Bulk imported \(importedVariants) variants (skipped \(skippedVariants) already-done variants)"
    )
  }

  // MARK: - Internals
  private func append(_ mutation: ExportRecordMutation) {
    apply(mutation)
    // Coalesce notifications to avoid excessive UI churn during exports
    scheduleCoalescedNotify()

    // If not configured to any destination, do not persist
    guard
      let storeDirURL = self.currentStoreDirURL,
      let logURL = self.logFileURL,
      let snapshotURL = self.snapshotFileURL
    else { return }

    // Prepare data for log write off the main actor
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let mutationData: Data
    do { mutationData = try encoder.encode(mutation) } catch {
      logger.error(
        "Failed to encode mutation: \(String(describing: error), privacy: .public)")
      return
    }
    let nextMutationCount = mutationCountSinceCompact + 1
    let recordsSnapshot: [String: ExportRecord]?
    if nextMutationCount >= Constants.compactEveryNMutations {
      // Capture a COW snapshot now and serialize it later on the IO queue after
      // this append is durable, so newer mutations cannot slip in before log truncation.
      recordsSnapshot = recordsById
      mutationCountSinceCompact = 0
    } else {
      recordsSnapshot = nil
      mutationCountSinceCompact = nextMutationCount
    }

    ioQueue.async { [weak self] in
      guard let self else { return }
      do {
        try appendLine(data: mutationData, to: logURL)
      } catch {
        self.logger.error(
          "Failed to persist mutation: \(String(describing: error), privacy: .public)")
        Task { @MainActor [weak self] in
          self?.restoreMutationCountAfterPersistenceFailure(
            for: storeDirURL,
            restoredCount: nextMutationCount - 1
          )
        }
        return
      }

      guard let recordsSnapshot else { return }
      do {
        let snapshotData = try encoder.encode(recordsSnapshot)
        try writeSnapshotAndTruncate(
          snapshotData: snapshotData,
          snapshotFileURL: snapshotURL,
          logFileURL: logURL
        )
      } catch {
        self.logger.error(
          "Failed to compact snapshot: \(String(describing: error), privacy: .public)"
        )
        Task { @MainActor [weak self] in
          self?.restoreMutationCountAfterPersistenceFailure(
            for: storeDirURL,
            restoredCount: Constants.compactEveryNMutations - 1
          )
        }
      }
    }
  }

  private func restoreMutationCountAfterPersistenceFailure(for storeDirURL: URL, restoredCount: Int)
  {
    guard currentStoreDirURL == storeDirURL else { return }
    mutationCountSinceCompact = max(mutationCountSinceCompact, restoredCount)
  }

  private func apply(_ mutation: ExportRecordMutation) {
    switch mutation.op {
    case .upsert:
      if let record = mutation.record {
        recordsById[mutation.id] = record
      }
    case .delete:
      recordsById.removeValue(forKey: mutation.id)
    }
  }

  private func createDirectoryIfNeeded(_ url: URL) {
    if !fileManager.fileExists(atPath: url.path) {
      do { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) } catch {
        logger.error(
          "Failed to create store directory: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  private func scheduleCoalescedNotify() {
    notifyWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.mutationCounter &+= 1
    }
    notifyWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
  }

  // MARK: - Testing helpers
  /// Blocks until all pending IO operations are flushed.
  func flushForTesting() {
    ioQueue.sync {}
  }
}

// Non-actor helper to write snapshot and truncate log safely
private func writeSnapshotAndTruncate(snapshotData: Data, snapshotFileURL: URL, logFileURL: URL)
  throws
{
  let fileManager = FileManager.default
  let tmpURL = snapshotFileURL.appendingPathExtension("tmp")
  try snapshotData.write(to: tmpURL, options: .atomic)
  if fileManager.fileExists(atPath: snapshotFileURL.path) {
    try fileManager.removeItem(at: snapshotFileURL)
  }
  try fileManager.moveItem(at: tmpURL, to: snapshotFileURL)
  try Data().write(to: logFileURL, options: .atomic)
}

// MARK: - FileHandle line reading
extension FileHandle {
  /// Reads a line terminated by \n and returns Data without the trailing newline.
  fileprivate func readLineData() -> Data? {
    var buffer = Data()
    while true {
      let chunk = try? self.read(upToCount: 1)
      guard let byte = chunk, !byte.isEmpty else {
        return buffer.isEmpty ? nil : buffer
      }
      if byte[0] == 0x0A {  // \n
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
  try handle.write(contentsOf: Data([0x0A]))  // newline
  try handle.synchronize()
}
