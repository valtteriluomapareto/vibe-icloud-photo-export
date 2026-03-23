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

  // MARK: - Published State
  @Published private(set) var isRunning: Bool = false
  @Published private(set) var queueCount: Int = 0
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var totalJobsEnqueued: Int = 0
  @Published private(set) var totalJobsCompleted: Int = 0
  @Published private(set) var currentAssetFilename: String?

  // MARK: - Dependencies
  private let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Export")
  private let photoLibraryManager: PhotoLibraryManager
  private let exportDestinationManager: ExportDestinationManager
  private let exportRecordStore: ExportRecordStore

  // MARK: - Internals
  private var pendingJobs: [ExportJob] = []
  private var isProcessing: Bool = false
  private var currentTask: Task<Void, Never>?
  private var currentJobAssetId: String?
  private var generation: Int = 0
  private var isEnqueueingAll: Bool = false
  private var queuedCountsByYearMonth: [String: Int] = [:]

  init(
    photoLibraryManager: PhotoLibraryManager,
    exportDestinationManager: ExportDestinationManager, exportRecordStore: ExportRecordStore
  ) {
    self.photoLibraryManager = photoLibraryManager
    self.exportDestinationManager = exportDestinationManager
    self.exportRecordStore = exportRecordStore
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
        let allYears = try photoLibraryManager.availableYears()
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
    guard photoLibraryManager.isAuthorized else { return }
    let assets = try await photoLibraryManager.fetchAssets(year: year, month: month)
    try throwIfCancelledOrStale(gen)
    let unexported = assets.filter { asset in
      !(exportRecordStore.isExported(assetId: asset.localIdentifier))
    }
    let newJobs = unexported.map {
      ExportJob(assetLocalIdentifier: $0.localIdentifier, year: year, month: month)
    }
    pendingJobs.append(contentsOf: newJobs)
    totalJobsEnqueued += newJobs.count
    queuedCountsByYearMonth["\(year)-\(month)", default: 0] += newJobs.count
    updateQueueCount()
    logger.info("Enqueued \(newJobs.count) assets for export for \(year)-\(month)")
  }

  private func enqueueYear(year: Int, generation gen: Int) async throws {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryManager.isAuthorized else { return }
    let assets = try await photoLibraryManager.fetchAssets(year: year, month: nil)
    try throwIfCancelledOrStale(gen)
    let calendar = Calendar.current
    var newJobs: [ExportJob] = []
    newJobs.reserveCapacity(assets.count)
    for asset in assets {
      guard let created = asset.creationDate else { continue }
      let m = calendar.component(.month, from: created)
      if !exportRecordStore.isExported(assetId: asset.localIdentifier) {
        newJobs.append(
          ExportJob(assetLocalIdentifier: asset.localIdentifier, year: year, month: m))
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

  private func processQueueIfNeeded() {
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

      // Resolve PHAsset from local identifier
      let fetchResult = PHAsset.fetchAssets(
        withLocalIdentifiers: [job.assetLocalIdentifier], options: nil)
      guard let asset = fetchResult.firstObject else {
        try throwIfCancelledOrStale(gen)
        exportRecordStore.markFailed(
          assetId: job.assetLocalIdentifier, error: "Asset not found", at: Date())
        logger.error(
          "Asset not found for id: \(job.assetLocalIdentifier, privacy: .public)")
        return
      }
      logger.debug(
        "Export begin id: \(asset.localIdentifier, privacy: .public) type: \(asset.mediaType.rawValue) created: \(String(describing: asset.creationDate), privacy: .public) dims: \(asset.pixelWidth)x\(asset.pixelHeight)"
      )

      // Ensure security-scoped access for destination during all filesystem work
      guard let scopedURL = exportDestinationManager.beginScopedAccess() else {
        throw NSError(
          domain: "Export", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to access export folder (security scope)"
          ])
      }
      logger.debug("Begin scoped access for: \(scopedURL.path, privacy: .public)")
      defer { exportDestinationManager.endScopedAccess(for: scopedURL) }

      // Determine destination directory
      let destDir = try exportDestinationManager.urlForMonth(
        year: job.year, month: job.month, createIfNeeded: true)
      let relPath = "\(job.year)/" + String(format: "%02d", job.month) + "/"

      // Select primary resource (prefer photo/video original)
      let resources = PHAssetResource.assetResources(for: asset)
      let resourceSummary = resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.joined(
        separator: ", ")
      logger.debug("Asset resources: \(resourceSummary, privacy: .public)")
      guard let resource = selectPrimaryResource(from: resources) else {
        try throwIfCancelledOrStale(gen)
        exportRecordStore.markFailed(
          assetId: asset.localIdentifier, error: "No exportable resource", at: Date())
        logger.error(
          "No exportable resource for id: \(asset.localIdentifier, privacy: .public)")
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
        if FileManager.default.fileExists(atPath: tempURL.path) {
          try? FileManager.default.removeItem(at: tempURL)
        }
      }

      try throwIfCancelledOrStale(gen)
      currentAssetFilename = finalURL.lastPathComponent
      exportRecordStore.markInProgress(
        assetId: asset.localIdentifier, year: job.year, month: job.month, relPath: relPath,
        filename: finalURL.lastPathComponent)
      didMarkInProgress = true

      // Clean up any stale temp file at destination
      if FileManager.default.fileExists(atPath: tempURL.path) {
        try? FileManager.default.removeItem(at: tempURL)
      }

      try await writeResource(resource, to: tempURL)
      try throwIfCancelledOrStale(gen)

      // Atomic move to final location (off main)
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          do {
            self.logger.debug(
              "Move begin: \(tempURL.lastPathComponent, privacy: .public) -> \(finalURL.lastPathComponent, privacy: .public)"
            )
            try FileIOService.moveItemAtomically(from: tempURL, to: finalURL)
            self.logger.debug("Move done -> \(finalURL.lastPathComponent, privacy: .public)")
            continuation.resume(returning: ())
          } catch {
            self.logger.error("Move failed: \(error.localizedDescription, privacy: .public)")
            continuation.resume(throwing: error)
          }
        }
      }
      try throwIfCancelledOrStale(gen)

      // Apply timestamps based on asset creation date (off main)
      if let createdAt = asset.creationDate {
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            FileIOService.applyTimestamps(creationDate: createdAt, to: finalURL)
            self.logger.debug(
              "Applied timestamps for id: \(asset.localIdentifier, privacy: .public)")
            continuation.resume()
          }
        }
        try throwIfCancelledOrStale(gen)
      }

      exportRecordStore.markExported(
        assetId: asset.localIdentifier, year: job.year, month: job.month, relPath: relPath,
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
  private func selectPrimaryResource(from resources: [PHAssetResource]) -> PHAssetResource? {
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
    let fm = FileManager.default
    var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
    var index = 1
    while fm.fileExists(atPath: candidate.path) {
      let nextName = "\(baseName) (\(index))"
      candidate = directory.appendingPathComponent(nextName).appendingPathExtension(ext)
      index += 1
      if index > 10_000 { break }
    }
    return candidate
  }

  private func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
    let start = Date()
    logger.debug(
      "writeResource begin type: \(resource.type.rawValue) filename: \(resource.originalFilename, privacy: .public) -> \(url.lastPathComponent, privacy: .public)"
    )
    return try await withCheckedThrowingContinuation { continuation in
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = true
      // Write directly to the provided URL
      PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) {
        error in
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        if let error {
          self.logger.error(
            "writeResource failed after \(elapsedMs)ms: \(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: error)
        } else {
          self.logger.debug(
            "writeResource success after \(elapsedMs)ms -> \(url.lastPathComponent, privacy: .public)"
          )
          continuation.resume(returning: ())
        }
      }
    }
  }
}
