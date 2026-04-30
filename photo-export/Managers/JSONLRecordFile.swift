import Foundation
import os

/// Reusable persistence component that backs both the timeline `ExportRecordStore` and the
/// new `CollectionExportRecordStore`. Owns the JSONL+snapshot machinery (atomic writes, log
/// replay with malformed-line skip, compaction at a mutation-count threshold) and leaves the
/// record shape and apply-log-op dispatch to the composing store.
///
/// Boundaries:
/// - **Generic owns:** snapshot read/write (atomic via `.tmp` + rename + parent-dir fsync),
///   log append (with `fsync(handle)`), log replay (with malformed-line skip), compaction
///   trigger at the mutation-count threshold, snapshot/log file-rename rotation.
/// - **Composing store owns:** the in-memory record dictionary, the apply-log-op dispatch
///   on each loaded op, the in-flight recovery pass, the `@Published` `mutationCounter`,
///   and the `RecordStoreState` machine.
///
/// Phase 0/1 of `docs/project/plans/collections-export-plan.md` motivates this extraction.
/// Two stores compose one each; both inherit the corrected fsync discipline (the existing
/// timeline `writeSnapshotAndTruncate` skipped both renames' parent-dir fsyncs, which under
/// power loss could leave a snapshot durable while the log still contained pre-snapshot
/// mutations — replaying mutations already in the snapshot on next load).
final class JSONLRecordFile<Snapshot: Codable & Sendable, LogOp: Codable & Sendable> {
  enum Constants {
    static var compactEveryNMutations: Int { 1000 }
  }

  // MARK: - Configuration

  let snapshotURL: URL
  let logURL: URL
  private let ioQueue: DispatchQueue
  private let logger: Logger
  private let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
  private let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy
  private let fileManager = FileManager.default

  // MARK: - Mutation-count state

  private var mutationCountSinceCompact: Int = 0

  // MARK: - Init

  init(
    snapshotURL: URL,
    logURL: URL,
    ioQueue: DispatchQueue,
    logger: Logger,
    dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601,
    dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .iso8601
  ) {
    self.snapshotURL = snapshotURL
    self.logURL = logURL
    self.ioQueue = ioQueue
    self.logger = logger
    self.dateEncodingStrategy = dateEncodingStrategy
    self.dateDecodingStrategy = dateDecodingStrategy
  }

  // MARK: - Load

  /// Outcome of reading the snapshot file. The composing store branches its load path on
  /// this — a corrupt snapshot transitions the store to `.failed` per *Recovery on
  /// Corruption*, while an absent snapshot is normal (legitimate before the first
  /// compaction).
  enum SnapshotStatus: Equatable {
    /// No snapshot file on disk. Normal first-launch / pre-first-compaction state.
    case absent
    /// Snapshot file present and decoded. The decoded value is in `LoadResult.snapshot`.
    case loaded
    /// Snapshot file present but failed to decode. **The file is left in place** —
    /// composing-store code transitions the store to `.failed` and only `resetToEmpty()`
    /// renames the file out of the way. This is the load-bearing detail that makes
    /// "Quit" non-destructive: a quit-and-relaunch finds the same corrupt file and
    /// re-fails, never silently resetting to an empty store.
    case corrupt
  }

  struct LoadResult: Sendable {
    let snapshot: Snapshot?
    let snapshotStatus: SnapshotStatus
    let ops: [LogOp]
    let malformedLineCount: Int
  }

  /// Reads the snapshot (if any) and the log file (if any). The composing store applies
  /// `ops` in order via its own dispatch logic. Malformed lines are skipped and logged but
  /// do not abort the load. A missing snapshot is not an error (returns `.absent`); a
  /// present-but-undecodable snapshot is reported as `.corrupt` with the file untouched.
  func load() -> LoadResult {
    var snapshot: Snapshot?
    var snapshotStatus: SnapshotStatus = .absent
    if fileManager.fileExists(atPath: snapshotURL.path) {
      do {
        let data = try Data(contentsOf: snapshotURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        snapshot = try decoder.decode(Snapshot.self, from: data)
        snapshotStatus = .loaded
      } catch {
        snapshotStatus = .corrupt
        logger.error(
          "Failed to read snapshot at \(self.snapshotURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
      }
    }

    var ops: [LogOp] = []
    var malformedLineCount = 0
    if fileManager.fileExists(atPath: logURL.path) {
      do {
        let handle = try FileHandle(forReadingFrom: logURL)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        while let lineData = handle.readJSONLLineData() {
          do {
            let op = try decoder.decode(LogOp.self, from: lineData)
            ops.append(op)
          } catch {
            malformedLineCount += 1
            logger.error(
              "Skipping malformed log line in \(self.logURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
          }
        }
      } catch {
        logger.error(
          "Failed to read log at \(self.logURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
      }
    }

    return LoadResult(
      snapshot: snapshot, snapshotStatus: snapshotStatus, ops: ops,
      malformedLineCount: malformedLineCount)
  }

  /// Renames the corrupt snapshot to `<name>.broken-<ISO8601>` and writes a fresh empty
  /// snapshot + log. Used by composing stores' `resetToEmpty()` paths after the user picks
  /// the destructive Reset action in the corruption alert (the alert UI lives in Phase 4;
  /// in Phase 1 there is no UI for this and the store remains `.failed` with the corrupt
  /// file intact until `resetToEmpty()` is called from a test).
  func resetToEmpty(emptySnapshot: Snapshot) throws {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]
    let timestamp = isoFormatter.string(from: Date())
    if fileManager.fileExists(atPath: snapshotURL.path) {
      let brokenURL =
        snapshotURL
        .deletingPathExtension()
        .appendingPathExtension("broken-\(timestamp)")
      do {
        try fileManager.moveItem(at: snapshotURL, to: brokenURL)
        logger.info(
          "Reset corrupt snapshot to \(brokenURL.lastPathComponent, privacy: .public)")
      } catch {
        logger.error(
          "Failed to rename corrupt snapshot \(self.snapshotURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        // Fall through and try to write the empty snapshot anyway; if the rename failed
        // because of permissions, the empty write probably will too, and the throw below
        // surfaces it.
      }
    }
    try writeSnapshot(emptySnapshot)
  }

  // MARK: - Append + compaction

  /// Persists `op` to the JSONL log. When the mutation count crosses
  /// `compactEveryNMutations`, the calling actor's `currentSnapshot` closure is invoked
  /// synchronously to capture the current in-memory state, and a compaction (atomic
  /// snapshot write + log truncation) is dispatched on the IO queue after the log write.
  ///
  /// This API matches the existing `ExportRecordStore.append` semantics exactly:
  /// - Encode happens on the calling actor (cheap and prevents future mutations from
  ///   slipping into the encoded bytes).
  /// - Compaction snapshot is captured synchronously *before* the IO dispatch (Swift
  ///   dictionaries are CoW; the capture is cheap) so newer mutations cannot slip in
  ///   between threshold-crossing and snapshot-encode.
  /// - On log-write failure, the mutation count is rolled back so subsequent appends
  ///   re-attempt the threshold check.
  /// - On compaction-write failure, the count is rolled back to one shy of the threshold so
  ///   the next append re-triggers compaction.
  func append(_ op: LogOp, currentSnapshot: () -> Snapshot) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = dateEncodingStrategy
    let opData: Data
    do {
      opData = try encoder.encode(op)
    } catch {
      logger.error(
        "Failed to encode log op for \(self.logURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return
    }

    let nextMutationCount = mutationCountSinceCompact + 1
    let snapshotData: Data?
    if nextMutationCount >= Constants.compactEveryNMutations {
      // Capture the snapshot synchronously and serialize it now (cheap; CoW dictionaries)
      // so the IO closure works against frozen bytes and newer mutations cannot slip in
      // between threshold-crossing and snapshot-encode.
      let snapshot = currentSnapshot()
      do {
        snapshotData = try encoder.encode(snapshot)
      } catch {
        logger.error(
          "Failed to encode compaction snapshot for \(self.snapshotURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        // Snapshot encode failed → leave the count at its threshold-1 value so the next
        // append re-triggers compaction, and proceed with a normal append (no compaction).
        mutationCountSinceCompact = nextMutationCount - 1
        ioQueue.async { [weak self] in
          do {
            try Self.appendLogLine(data: opData, to: self?.logURL ?? URL(fileURLWithPath: "/"))
          } catch {
            // Already in a degraded path; just log.
            self?.logger.error(
              "Failed to append log line during degraded path: \(String(describing: error), privacy: .public)"
            )
          }
        }
        return
      }
      mutationCountSinceCompact = 0
    } else {
      snapshotData = nil
      mutationCountSinceCompact = nextMutationCount
    }

    // Capture all values needed inside the IO queue as locals so the closure does not
    // reach back into `self` for them (keeps the dispatch closure self-contained).
    let logURL = self.logURL
    let snapshotURL = self.snapshotURL
    let logger = self.logger

    ioQueue.async { [weak self] in
      do {
        try Self.appendLogLine(data: opData, to: logURL)
      } catch {
        logger.error(
          "Failed to append log line to \(logURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        Task { @MainActor [weak self] in
          self?.rollbackMutationCount(to: nextMutationCount - 1)
        }
        return
      }

      guard let snapshotData else { return }
      do {
        try Self.writeSnapshotAndTruncate(
          snapshotData: snapshotData, snapshotURL: snapshotURL, logURL: logURL)
      } catch {
        logger.error(
          "Failed to compact \(snapshotURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        Task { @MainActor [weak self] in
          self?.rollbackMutationCount(to: Constants.compactEveryNMutations - 1)
        }
      }
    }
  }

  // MARK: - Manual snapshot

  /// Synchronously writes a snapshot and truncates the log. Used by `resetToEmpty()` paths
  /// and by tests; production compaction goes through `append(_:currentSnapshot:)`.
  func writeSnapshot(_ snapshot: Snapshot) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = dateEncodingStrategy
    let data = try encoder.encode(snapshot)
    try Self.writeSnapshotAndTruncate(
      snapshotData: data, snapshotURL: snapshotURL, logURL: logURL)
    mutationCountSinceCompact = 0
  }

  /// Removes the snapshot and log files (best effort). Used by `resetToEmpty()` after the
  /// composing store renames the corrupt snapshot to `.broken-<ISO8601>`.
  func clearOnDiskState() {
    let urls = [snapshotURL, logURL]
    for url in urls {
      do {
        if fileManager.fileExists(atPath: url.path) {
          try fileManager.removeItem(at: url)
        }
      } catch {
        logger.error(
          "Failed to remove \(url.path, privacy: .public) during reset: \(String(describing: error), privacy: .public)"
        )
      }
    }
    mutationCountSinceCompact = 0
  }

  // MARK: - Testing helpers

  /// Blocks until pending IO is flushed.
  func flushForTesting() {
    ioQueue.sync {}
  }

  // MARK: - Internal helpers

  private func rollbackMutationCount(to value: Int) {
    mutationCountSinceCompact = max(mutationCountSinceCompact, value)
  }

  /// Writes `snapshotData` atomically and truncates the log.
  ///
  /// Both renames (snapshot and log truncation) use `.tmp` + rename, and we explicitly
  /// `fsync` the parent directory after each rename so the rename itself is durable.
  /// Without the parent-dir fsync, a power loss between the snapshot rename and the log
  /// truncation could leave the snapshot durable on disk while the log still contained
  /// pre-snapshot mutations — replaying mutations already in the snapshot on next load.
  ///
  /// (`Data(...).write(to: ..., options: .atomic)` writes via `.tmp` + rename internally
  /// and fsyncs the file but **does not** fsync the parent directory.)
  private static func writeSnapshotAndTruncate(
    snapshotData: Data, snapshotURL: URL, logURL: URL
  ) throws {
    let fileManager = FileManager.default

    // 1) Write the snapshot atomically (file fsynced; parent-dir fsync after).
    let snapshotTmpURL = snapshotURL.appendingPathExtension("tmp")
    try snapshotData.write(to: snapshotTmpURL, options: .atomic)
    if fileManager.fileExists(atPath: snapshotURL.path) {
      try fileManager.removeItem(at: snapshotURL)
    }
    try fileManager.moveItem(at: snapshotTmpURL, to: snapshotURL)
    try fsyncDirectory(snapshotURL.deletingLastPathComponent())

    // 2) Truncate the log atomically (also `.tmp` + rename internally; same parent dir).
    try Data().write(to: logURL, options: .atomic)
    try fsyncDirectory(logURL.deletingLastPathComponent())
  }

  private static func fsyncDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    if fd < 0 { return }
    defer { close(fd) }
    _ = fsync(fd)
  }

  private static func appendLogLine(data: Data, to url: URL) throws {
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
}

// MARK: - FileHandle line reading

extension FileHandle {
  /// Reads a line terminated by `\n` and returns its bytes without the trailing newline.
  /// Returns `nil` at EOF when the buffer is empty. Internal: shared between
  /// `JSONLRecordFile.load()` and the historical line-reading site in
  /// `ExportRecordStore.loadFromCurrentDirectory()` (kept fileprivate to its own file
  /// during the transition).
  fileprivate func readJSONLLineData() -> Data? {
    var buffer = Data()
    while true {
      let chunk = try? self.read(upToCount: 1)
      guard let byte = chunk, !byte.isEmpty else {
        return buffer.isEmpty ? nil : buffer
      }
      if byte[0] == 0x0A {
        return buffer
      } else {
        buffer.append(byte)
      }
    }
  }
}
