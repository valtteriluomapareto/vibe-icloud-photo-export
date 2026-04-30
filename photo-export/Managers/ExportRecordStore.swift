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

  /// Per-store load state. See `RecordStoreState` for semantics. The corruption alert UI
  /// that drives `resetToEmpty()` lives in Phase 4; before then, a `.failed` state is
  /// observable in logs and tests but not surfaced to the user.
  @Published private(set) var state: RecordStoreState = .unconfigured

  // Published bump used to notify SwiftUI of logical changes
  @Published private(set) var mutationCounter: Int = 0
  private var notifyWorkItem: DispatchWorkItem?

  private let fileManager = FileManager.default
  /// Base directory containing per-destination subdirectories
  /// (`<App Support>/<bundleId>/ExportRecords/`). Exposed for
  /// `ExportRecordsDirectoryCoordinator`, which needs to manage
  /// the per-destination subdirectory before this store configures.
  let storeRootURL: URL
  private var currentStoreDirURL: URL?
  /// JSONL persistence for the currently configured destination. `nil` when the store is
  /// unconfigured (no destination selected). Reconstructed on every `configure(for:)`.
  private var jsonl: JSONLRecordFile<[String: ExportRecord], ExportRecordMutation>?

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

    guard let destinationId else {
      currentStoreDirURL = nil
      jsonl = nil
      state = .unconfigured
      mutationCounter &+= 1
      return
    }

    let dir = storeRootURL.appendingPathComponent(destinationId, isDirectory: true)
    createDirectoryIfNeeded(dir)
    currentStoreDirURL = dir
    let file = JSONLRecordFile<[String: ExportRecord], ExportRecordMutation>(
      snapshotURL: dir.appendingPathComponent(Constants.snapshotFileName),
      logURL: dir.appendingPathComponent(Constants.logFileName),
      ioQueue: ioQueue,
      logger: logger
    )
    jsonl = file

    let loaded = file.load()
    switch loaded.snapshotStatus {
    case .corrupt:
      // Deferred-rename rule: leave the corrupt snapshot at its original path on disk so
      // a Quit-and-relaunch reproduces this `.failed` state instead of silently
      // initializing empty. `resetToEmpty()` is the only path that renames the file out
      // of the way; the alert UI that calls it lands in Phase 4.
      logger.error(
        "Timeline records snapshot at \(dir.appendingPathComponent(Constants.snapshotFileName).path, privacy: .public) failed to decode; store transitioning to .failed."
      )
      state = .failed
    case .absent, .loaded:
      if let snapshot = loaded.snapshot {
        recordsById = snapshot
      }
      for op in loaded.ops {
        apply(op)
      }
      recoverInProgressVariants()
      state = .ready
    }
    mutationCounter &+= 1
  }

  /// Renames a corrupt snapshot to `<name>.broken-<ISO8601>` and reinitializes the store
  /// with an empty snapshot + log. Called from the Phase 4 corruption alert UI's "Reset to
  /// empty" action; in Phase 1 there is no UI for it and tests are the only caller.
  ///
  /// Transitions `state` from `.failed` back to `.ready` on success. Only valid to call
  /// when `state == .failed` (otherwise it is a no-op so callers can wire it through a
  /// generic alert handler without first checking).
  func resetToEmpty() {
    guard state == .failed else { return }
    guard let jsonl else { return }
    do {
      try jsonl.resetToEmpty(emptySnapshot: [:])
      recordsById = [:]
      state = .ready
      mutationCounter &+= 1
    } catch {
      logger.error(
        "resetToEmpty failed: \(String(describing: error), privacy: .public). Store remains .failed."
      )
    }
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

  /// Strict, asset-aware completion check for a single asset.
  ///
  /// Consults the asset's current `hasAdjustments` (via `requiredVariants`) and verifies
  /// every required variant is `.done`. No filename inspection — a `.original.done` row at
  /// any filename satisfies an unedited asset's requirement, and an adjusted asset is only
  /// satisfied when `.edited.done` (and `.original.done` under `editedWithOriginals`).
  func isExported(asset: AssetDescriptor, selection: ExportVersionSelection) -> Bool {
    let required = requiredVariants(for: asset, selection: selection)
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
    for asset in assets where isExported(asset: asset, selection: selection) {
      exported += 1
    }
    return makeSummary(year: year, month: month, exported: exported, total: assets.count)
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
  /// `.done`. These records are definitely fully complete under `editedWithOriginals`
  /// regardless of whether the asset is currently adjusted.
  func recordCountBothVariantsDone(year: Int, month: Int) -> Int {
    recordsById.values.reduce(0) { sum, record in
      guard record.year == year, record.month == month else { return sum }
      let originalDone = record.variants[.original]?.status == .done
      let editedDone = record.variants[.edited]?.status == .done
      return sum + (originalDone && editedDone ? 1 : 0)
    }
  }

  /// Count of records in `year`/`month` whose `.edited` variant is `.done`. Used by the
  /// records-only sidebar formula for the default mode.
  func recordCountEditedDone(year: Int, month: Int) -> Int {
    recordCount(year: year, month: month, variant: .edited, status: .done)
  }

  /// Count of records in `year`/`month` with `.original.done` at a natural-stem filename
  /// (i.e. not a `_orig` companion) AND `.edited` not `.done`. Used by the records-only
  /// sidebar formula to estimate "unedited asset, exported once" rows without loading
  /// descriptors.
  func recordCountOriginalDoneAtNaturalStem(year: Int, month: Int) -> Int {
    recordsById.values.reduce(0) { sum, record in
      guard record.year == year, record.month == month else { return sum }
      guard let original = record.variants[.original], original.status == .done,
        let filename = original.filename
      else { return sum }
      if record.variants[.edited]?.status == .done { return sum }
      return sum + (ExportFilenamePolicy.isOrigCompanion(filename: filename) ? 0 : 1)
    }
  }

  /// Records-only approximation of "fully exported under this selection," capped by the
  /// count of unedited assets in scope so that natural-stem `.original.done` records
  /// belonging to currently-adjusted assets cannot over-contribute past the number of
  /// assets that could legitimately be original-only.
  ///
  /// `adjustedCount` is required for both modes. Pass nil when the count hasn't loaded yet —
  /// callers should render a neutral "loading" state in that case rather than treat nil as
  /// zero.
  func sidebarSummary(
    year: Int, month: Int, totalCount: Int, adjustedCount: Int?,
    selection: ExportVersionSelection
  ) -> MonthStatusSummary? {
    guard let adjustedCount else { return nil }
    let uneditedCount = max(0, totalCount - adjustedCount)
    let origOnlyAtStem = recordCountOriginalDoneAtNaturalStem(year: year, month: month)
    switch selection {
    case .edited:
      let editedDone = recordCountEditedDone(year: year, month: month)
      let exported = editedDone + min(origOnlyAtStem, uneditedCount)
      return makeSummary(year: year, month: month, exported: exported, total: totalCount)
    case .editedWithOriginals:
      let bothDone = recordCountBothVariantsDone(year: year, month: month)
      let exported = bothDone + min(origOnlyAtStem, uneditedCount)
      return makeSummary(year: year, month: month, exported: exported, total: totalCount)
    }
  }

  /// Year-scope variant. Iterates each month with its (totalCount, adjustedCount) pair, sums
  /// the per-month exported counts, and returns the rolled-up total. Months whose
  /// adjustedCount is nil contribute zero to the total — callers should suppress the
  /// year-level badge until all populated months have reported.
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
  ///
  /// Bails early when the store isn't `.ready` — otherwise the per-record `append` would
  /// trip a debug assertion on every iteration. The caller (Import Existing Backup flow)
  /// should only invoke this when the store has loaded successfully; the early return is a
  /// belt-and-braces no-op for unexpected states.
  func bulkImportRecords(_ records: [ExportRecord]) {
    guard state == .ready else { return }
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
    // RecordStoreState guard: writes only land when `.ready`. `.failed` means the snapshot
    // is corrupt (deferred-rename rule); `.unconfigured` means no destination is selected.
    // Either case: no-op. Debug builds trip an `assertionFailure` so a routing bug shows up
    // in tests; release silently drops to avoid crashing on a benign race during state
    // transitions.
    guard state == .ready else {
      assertionFailure(
        "ExportRecordStore.append called while state == \(state); ExportManager should have routed via canExport."
      )
      return
    }

    apply(mutation)
    // Coalesce notifications to avoid excessive UI churn during exports
    scheduleCoalescedNotify()

    // If not configured to any destination, do not persist
    guard let jsonl else { return }
    jsonl.append(mutation, currentSnapshot: { self.recordsById })
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
