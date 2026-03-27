import AppKit
import Foundation
import Photos
import SwiftUI
import os

@MainActor
final class ExportManager: ObservableObject {
  struct ExportJob: Equatable {
    let assetLocalIdentifier: String
    let year: Int
    let month: Int
  }

  // MARK: - Published State (Export)
  @Published private(set) var isRunning: Bool = false
  @Published private(set) var queueCount: Int = 0
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var totalJobsEnqueued: Int = 0
  @Published private(set) var totalJobsCompleted: Int = 0
  @Published private(set) var currentAssetFilename: String?

  // MARK: - Published State (Import)
  @Published private(set) var isImporting: Bool = false
  @Published private(set) var importStage: BackupScanner.ImportStage?
  @Published var importResult: ImportReport?

  /// Whether the export queue is active (has pending/in-flight work).
  var hasActiveExportWork: Bool {
    isRunning || queueCount > 0 || isEnqueueingAll
  }

  // MARK: - Dependencies
  private let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Export")
  let photoLibraryService: any PhotoLibraryService
  let exportDestination: any ExportDestination
  let exportRecordStore: ExportRecordStore
  let assetResourceWriter: any AssetResourceWriter
  let fileSystem: any FileSystemService

  // MARK: - Internals
  private(set) var pendingJobs: [ExportJob] = []
  private var isProcessing: Bool = false
  private var currentTask: Task<Void, Never>?
  private(set) var currentJobAssetId: String?
  private(set) var generation: Int = 0
  private(set) var isEnqueueingAll: Bool = false
  private(set) var queuedCountsByYearMonth: [String: Int] = [:]
  private var importTask: Task<Void, Never>?

  init(
    photoLibraryService: any PhotoLibraryService,
    exportDestination: any ExportDestination,
    exportRecordStore: ExportRecordStore,
    assetResourceWriter: any AssetResourceWriter = ProductionAssetResourceWriter(),
    fileSystem: any FileSystemService = FileIOService()
  ) {
    self.photoLibraryService = photoLibraryService
    self.exportDestination = exportDestination
    self.exportRecordStore = exportRecordStore
    self.assetResourceWriter = assetResourceWriter
    self.fileSystem = fileSystem
  }

  // MARK: - Public API
  func startExportMonth(year: Int, month: Int) {
    if !isRunning && !isProcessing { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.generation == gen else { return }
      do {
        try await enqueueMonth(year: year, month: month, generation: gen)
        guard self.generation == gen else { return }
        processQueueIfNeeded()
      } catch {
        logger.error(
          "Failed to enqueue month export: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  func startExportYear(year: Int) {
    if !isRunning && !isProcessing { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.generation == gen else { return }
      do {
        try await enqueueYear(year: year, generation: gen)
        guard self.generation == gen else { return }
        processQueueIfNeeded()
      } catch {
        logger.error(
          "Failed to enqueue year export: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  func startExportAll() {
    guard !isEnqueueingAll else { return }
    isEnqueueingAll = true
    resetProgressCounters()
    let gen = generation
    Task { [weak self] in
      guard let self, self.generation == gen else {
        self?.isEnqueueingAll = false
        return
      }
      do {
        let allYears = try photoLibraryService.availableYears()
        for year in allYears {
          try await enqueueYear(year: year, generation: gen)
          guard self.generation == gen else {
            self.isEnqueueingAll = false
            return
          }
        }
        self.isEnqueueingAll = false
        processQueueIfNeeded()
      } catch {
        self.isEnqueueingAll = false
        logger.error(
          "Failed to enqueue export-all: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  func cancelAndClear() {
    logger.info("Cancelling current export and clearing queue due to destination change")
    if let inFlightId = currentJobAssetId,
      exportRecordStore.exportInfo(assetId: inFlightId)?.status == .inProgress
    {
      exportRecordStore.remove(assetId: inFlightId)
    }
    currentJobAssetId = nil
    generation += 1
    pendingJobs.removeAll()
    queuedCountsByYearMonth.removeAll()
    currentTask?.cancel()
    currentTask = nil
    isProcessing = false
    isRunning = false
    isPaused = false
    isEnqueueingAll = false
    totalJobsEnqueued = 0
    totalJobsCompleted = 0
    currentAssetFilename = nil
    updateQueueCount()
  }

  func pause() {
    guard isRunning else { return }
    isPaused = true
    logger.info("Export queue paused")
  }

  func resume() {
    guard isPaused else { return }
    isPaused = false
    logger.info("Export queue resumed")
    processQueueIfNeeded()
  }

  func clearPending() {
    let removed = pendingJobs.count
    pendingJobs.removeAll()
    queuedCountsByYearMonth.removeAll()
    totalJobsEnqueued = max(0, totalJobsEnqueued - removed)
    updateQueueCount()
    logger.info("Cleared \(removed) pending export jobs")
  }

  // MARK: - Queue Handling
  private func enqueueMonth(year: Int, month: Int, generation gen: Int) async throws {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryService.isAuthorized else { return }
    let assets = try await photoLibraryService.fetchAssets(year: year, month: month)
    try throwIfCancelledOrStale(gen)
    let unexported = assets.filter { asset in
      !(exportRecordStore.isExported(assetId: asset.id))
    }
    let newJobs = unexported.map {
      ExportJob(assetLocalIdentifier: $0.id, year: year, month: month)
    }
    pendingJobs.append(contentsOf: newJobs)
    totalJobsEnqueued += newJobs.count
    queuedCountsByYearMonth["\(year)-\(month)", default: 0] += newJobs.count
    updateQueueCount()
    logger.info("Enqueued \(newJobs.count) assets for export for \(year)-\(month)")
  }

  private func enqueueYear(year: Int, generation gen: Int) async throws {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryService.isAuthorized else { return }
    let assets = try await photoLibraryService.fetchAssets(year: year, month: nil)
    try throwIfCancelledOrStale(gen)
    let calendar = Calendar.current
    var newJobs: [ExportJob] = []
    newJobs.reserveCapacity(assets.count)
    for asset in assets {
      guard let created = asset.creationDate else { continue }
      let m = calendar.component(.month, from: created)
      if !exportRecordStore.isExported(assetId: asset.id) {
        newJobs.append(
          ExportJob(assetLocalIdentifier: asset.id, year: year, month: m))
      }
    }
    pendingJobs.append(contentsOf: newJobs)
    totalJobsEnqueued += newJobs.count
    for job in newJobs {
      queuedCountsByYearMonth["\(job.year)-\(job.month)", default: 0] += 1
    }
    updateQueueCount()
    logger.info("Enqueued \(newJobs.count) assets for export for year \(year)")
  }

  func processQueueIfNeeded() {
    guard !isProcessing else { return }
    guard !isPaused else { return }
    guard !pendingJobs.isEmpty else { return }
    isProcessing = true
    isRunning = true
    processNext()
  }

  private func processNext() {
    if isPaused {
      isProcessing = false
      isRunning = false
      updateQueueCount()
      logger.info("Queue paused; not starting next job")
      return
    }
    guard !pendingJobs.isEmpty else {
      isProcessing = false
      isRunning = false
      currentJobAssetId = nil
      currentAssetFilename = nil
      updateQueueCount()
      logger.info("Export queue drained")
      return
    }
    let job = pendingJobs.removeFirst()
    let key = "\(job.year)-\(job.month)"
    queuedCountsByYearMonth[key, default: 1] -= 1
    if queuedCountsByYearMonth[key, default: 0] <= 0 {
      queuedCountsByYearMonth.removeValue(forKey: key)
    }
    currentJobAssetId = job.assetLocalIdentifier
    updateQueueCount()
    let currentGen = generation
    currentTask = Task { [weak self] in
      await self?.export(job: job, generation: currentGen)
      await MainActor.run { [weak self] in
        self?.currentJobAssetId = nil
        guard let self, self.generation == currentGen else { return }
        self.totalJobsCompleted += 1
        self.processNext()
      }
    }
  }

  func queuedCount(year: Int, month: Int) -> Int {
    queuedCountsByYearMonth["\(year)-\(month)", default: 0]
  }

  private func resetProgressCounters() {
    totalJobsEnqueued = 0
    totalJobsCompleted = 0
    currentAssetFilename = nil
    queuedCountsByYearMonth.removeAll()
  }

  private func updateQueueCount() {
    queueCount = pendingJobs.count + (isProcessing ? 1 : 0)
  }

  // MARK: - Export Logic
  private func throwIfCancelledOrStale(_ gen: Int) throws {
    try Task.checkCancellation()
    guard self.generation == gen else { throw CancellationError() }
  }

  private func export(job: ExportJob, generation gen: Int) async {
    var didMarkInProgress = false
    do {
      try throwIfCancelledOrStale(gen)

      // Resolve asset descriptor
      guard let descriptor = photoLibraryService.fetchAssetDescriptor(for: job.assetLocalIdentifier)
      else {
        try throwIfCancelledOrStale(gen)
        exportRecordStore.markFailed(
          assetId: job.assetLocalIdentifier, error: "Asset not found", at: Date())
        logger.error(
          "Asset not found for id: \(job.assetLocalIdentifier, privacy: .public)")
        return
      }
      logger.debug(
        "Export begin id: \(descriptor.id, privacy: .public) type: \(descriptor.mediaType.rawValue) created: \(String(describing: descriptor.creationDate), privacy: .public) dims: \(descriptor.pixelWidth)x\(descriptor.pixelHeight)"
      )

      // Ensure security-scoped access for destination during all filesystem work
      guard let scopedURL = exportDestination.beginScopedAccess() else {
        throw NSError(
          domain: "Export", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to access export folder (security scope)"
          ])
      }
      logger.debug("Begin scoped access for: \(scopedURL.path, privacy: .public)")
      defer { exportDestination.endScopedAccess(for: scopedURL) }

      // Determine destination directory
      let destDir = try exportDestination.urlForMonth(
        year: job.year, month: job.month, createIfNeeded: true)
      let relPath = "\(job.year)/" + String(format: "%02d", job.month) + "/"

      // Select primary resource (prefer photo/video original)
      let resources = photoLibraryService.resources(for: descriptor.id)
      let resourceSummary = resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.joined(
        separator: ", ")
      logger.debug("Asset resources: \(resourceSummary, privacy: .public)")
      guard let resource = selectPrimaryResource(from: resources) else {
        try throwIfCancelledOrStale(gen)
        exportRecordStore.markFailed(
          assetId: descriptor.id, error: "No exportable resource", at: Date())
        logger.error(
          "No exportable resource for id: \(descriptor.id, privacy: .public)")
        return
      }
      logger.debug(
        "Selected resource type: \(resource.type.rawValue) filename: \(resource.originalFilename, privacy: .public)"
      )

      // Prepare filename and target URLs
      let (baseName, ext) = splitFilename(resource.originalFilename)
      let finalURL = uniqueFileURL(in: destDir, baseName: baseName, ext: ext)
      let tempURL = finalURL.appendingPathExtension("tmp")
      defer {
        if fileSystem.fileExists(atPath: tempURL.path) {
          try? fileSystem.removeItem(at: tempURL)
        }
      }

      try throwIfCancelledOrStale(gen)
      currentAssetFilename = finalURL.lastPathComponent
      exportRecordStore.markInProgress(
        assetId: descriptor.id, year: job.year, month: job.month, relPath: relPath,
        filename: finalURL.lastPathComponent)
      didMarkInProgress = true

      // Clean up any stale temp file at destination
      if fileSystem.fileExists(atPath: tempURL.path) {
        try? fileSystem.removeItem(at: tempURL)
      }

      try await assetResourceWriter.writeResource(resource, forAssetId: descriptor.id, to: tempURL)
      try throwIfCancelledOrStale(gen)

      // Atomic move to final location
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .utility).async { [fileSystem] in
          do {
            self.logger.debug(
              "Move begin: \(tempURL.lastPathComponent, privacy: .public) -> \(finalURL.lastPathComponent, privacy: .public)"
            )
            try fileSystem.moveItemAtomically(from: tempURL, to: finalURL)
            self.logger.debug("Move done -> \(finalURL.lastPathComponent, privacy: .public)")
            continuation.resume(returning: ())
          } catch {
            self.logger.error("Move failed: \(error.localizedDescription, privacy: .public)")
            continuation.resume(throwing: error)
          }
        }
      }
      try throwIfCancelledOrStale(gen)

      // Apply timestamps based on asset creation date
      if let createdAt = descriptor.creationDate {
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async { [fileSystem] in
            fileSystem.applyTimestamps(creationDate: createdAt, to: finalURL)
            self.logger.debug(
              "Applied timestamps for id: \(descriptor.id, privacy: .public)")
            continuation.resume()
          }
        }
        try throwIfCancelledOrStale(gen)
      }

      exportRecordStore.markExported(
        assetId: descriptor.id, year: job.year, month: job.month, relPath: relPath,
        filename: finalURL.lastPathComponent, exportedAt: Date())
      logger.info(
        "Exported \(finalURL.lastPathComponent, privacy: .public) -> \(finalURL.deletingLastPathComponent().path, privacy: .public)"
      )
    } catch is CancellationError {
      logger.info(
        "Export cancelled for id: \(job.assetLocalIdentifier, privacy: .public)")
      if didMarkInProgress, self.generation == gen {
        exportRecordStore.remove(assetId: job.assetLocalIdentifier)
      }
    } catch {
      guard self.generation == gen else { return }
      logger.error(
        "Export failed for id: \(job.assetLocalIdentifier, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      exportRecordStore.markFailed(
        assetId: job.assetLocalIdentifier, error: error.localizedDescription, at: Date())
    }
  }

  // MARK: - Helpers
  private func selectPrimaryResource(from resources: [ResourceDescriptor]) -> ResourceDescriptor? {
    if let photo = resources.first(where: { $0.type == .photo }) { return photo }
    if let video = resources.first(where: { $0.type == .video }) { return video }
    if let alternatePhoto = resources.first(where: { $0.type == .alternatePhoto }) {
      return alternatePhoto
    }
    if let fullSize = resources.first(where: { $0.type == .fullSizePhoto }) { return fullSize }
    return resources.first
  }

  func splitFilename(_ filename: String) -> (base: String, ext: String) {
    let url = URL(fileURLWithPath: filename)
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    return (base, ext)
  }

  func uniqueFileURL(in directory: URL, baseName: String, ext: String) -> URL {
    var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
    var index = 1
    while fileSystem.fileExists(atPath: candidate.path) {
      let nextName = "\(baseName) (\(index))"
      candidate = directory.appendingPathComponent(nextName).appendingPathExtension(ext)
      index += 1
      if index > 10_000 { break }
    }
    return candidate
  }

  // MARK: - Import Existing Backup

  /// Starts the "Import Existing Backup…" flow.
  /// Scans the current export destination for YYYY/MM/ files, matches them
  /// against the Photos library, and rebuilds local export records.
  func startImport() {
    guard !isImporting else { return }
    guard !hasActiveExportWork else {
      logger.warning("Cannot import while export is active")
      return
    }
    guard let rootURL = exportDestination.selectedFolderURL else {
      logger.warning("Cannot import: no destination selected")
      return
    }

    isImporting = true
    importStage = .scanningBackupFolder
    importResult = nil

    let importGen = generation

    importTask = Task { [weak self] in
      guard let self else { return }

      do {
        // Acquire security-scoped access for the scan
        guard let scopedURL = self.exportDestination.beginScopedAccess() else {
          self.logger.error("Failed to acquire security-scoped access for import")
          self.isImporting = false
          self.importStage = nil
          return
        }
        defer { self.exportDestination.endScopedAccess(for: scopedURL) }

        // Stage 1: Scan backup folder
        self.importStage = .scanningBackupFolder
        try Task.checkCancellation()
        let scannedFiles = await Task.detached {
          BackupScanner.scanBackupFolder(at: rootURL)
        }.value

        try Task.checkCancellation()
        guard self.generation == importGen else {
          self.isImporting = false
          self.importStage = nil
          return
        }

        if scannedFiles.isEmpty {
          self.importResult = ImportReport(
            matchedCount: 0, ambiguousCount: 0, unmatchedCount: 0, totalScanned: 0)
          self.importStage = .done
          self.isImporting = false
          return
        }

        // Stage 2 & 3: Read Photos library and match
        self.importStage = .readingPhotosLibrary
        let matchResult = try await BackupScanner.matchFiles(
          scannedFiles,
          photoLibraryService: self.photoLibraryService
        ) { [weak self] stage in
          self?.importStage = stage
        }

        try Task.checkCancellation()
        guard self.generation == importGen else {
          self.isImporting = false
          self.importStage = nil
          return
        }

        // Stage 4: Rebuild local state
        self.importStage = .rebuildingLocalState

        let now = Date()
        var records: [ExportRecord] = []
        records.reserveCapacity(matchResult.matched.count)

        for (file, descriptor) in matchResult.matched {
          let year: Int
          let month: Int
          if let creationDate = descriptor.creationDate {
            let calendar = Calendar.current
            year = calendar.component(.year, from: creationDate)
            month = calendar.component(.month, from: creationDate)
          } else {
            year = file.year
            month = file.month
          }
          let relPath = "\(year)/" + String(format: "%02d", month) + "/"

          let record = ExportRecord(
            id: descriptor.id,
            year: year,
            month: month,
            relPath: relPath,
            filename: file.filename,
            status: .done,
            exportDate: now,
            lastError: nil
          )
          records.append(record)
        }

        self.exportRecordStore.bulkImportRecords(records)

        guard self.generation == importGen else {
          self.isImporting = false
          self.importStage = nil
          return
        }

        // Build report
        self.importResult = ImportReport(
          matchedCount: matchResult.matched.count,
          ambiguousCount: matchResult.ambiguous.count,
          unmatchedCount: matchResult.unmatched.count,
          totalScanned: scannedFiles.count
        )

        self.importStage = .done
        self.isImporting = false

        self.logger.info(
          "Import complete: \(matchResult.matched.count) matched, \(matchResult.ambiguous.count) ambiguous, \(matchResult.unmatched.count) unmatched out of \(scannedFiles.count) scanned"
        )
      } catch is CancellationError {
        self.logger.info("Import task cancelled")
        self.isImporting = false
        self.importStage = nil
      } catch {
        self.logger.error(
          "Import failed: \(error.localizedDescription, privacy: .public)")
        self.isImporting = false
        self.importStage = nil
      }
    }
  }

  /// Cancels an in-progress import.
  func cancelImport() {
    guard isImporting else { return }
    importTask?.cancel()
    importTask = nil
    generation += 1
    isImporting = false
    importStage = nil
    importResult = nil
    logger.info("Import cancelled")
  }
}

/// Summary report shown after the import completes.
struct ImportReport: Equatable {
  let matchedCount: Int
  let ambiguousCount: Int
  let unmatchedCount: Int
  let totalScanned: Int
}
