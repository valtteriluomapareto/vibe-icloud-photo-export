import AppKit
import Foundation
import Photos
import SwiftUI
import os

@MainActor
final class ExportManager: ObservableObject {
  /// User-facing persistence key for the active version selection.
  static let versionSelectionDefaultsKey = "exportVersionSelection"

  struct ExportJob: Equatable {
    let assetLocalIdentifier: String
    let year: Int
    let month: Int
    /// Selection snapshot at enqueue time. Deterministic within a single job even if the user
    /// toggles selection mid-run.
    let selection: ExportVersionSelection
  }

  // MARK: - Published State (Export)
  @Published private(set) var isRunning: Bool = false
  @Published private(set) var queueCount: Int = 0
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var totalJobsEnqueued: Int = 0
  @Published private(set) var totalJobsCompleted: Int = 0
  @Published private(set) var currentAssetFilename: String?

  /// Which variants the pipeline writes for each asset. Persisted to `UserDefaults` so the
  /// choice survives restart and stays globally consistent regardless of destination.
  @Published var versionSelection: ExportVersionSelection {
    didSet {
      UserDefaults.standard.set(
        versionSelection.rawValue, forKey: Self.versionSelectionDefaultsKey)
    }
  }

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
  private(set) var currentJobVariant: ExportVariant?
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
    if let raw = UserDefaults.standard.string(forKey: Self.versionSelectionDefaultsKey),
      let saved = ExportVersionSelection(rawValue: raw)
    {
      self.versionSelection = saved
    } else {
      self.versionSelection = .originalOnly
    }
  }

  // MARK: - Public API
  func startExportMonth(year: Int, month: Int) {
    // Snapshot the active selection synchronously so a picker flip before the async enqueue
    // lands (after `fetchAssets` returns) cannot change the mode that was visible at click
    // time. The picker in the toolbar is also gated on `hasActiveExportWork` for clarity, but
    // this snapshot is the correctness guarantee.
    let selection = versionSelection
    if !isRunning && !isProcessing { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.generation == gen else { return }
      do {
        try await enqueueMonth(
          year: year, month: month, selection: selection, generation: gen)
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
    let selection = versionSelection
    if !isRunning && !isProcessing { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.generation == gen else { return }
      do {
        try await enqueueYear(year: year, selection: selection, generation: gen)
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
    let selection = versionSelection
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
          try await enqueueYear(year: year, selection: selection, generation: gen)
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
    if let inFlightId = currentJobAssetId, let inFlightVariant = currentJobVariant,
      exportRecordStore.exportInfo(assetId: inFlightId)?.variants[inFlightVariant]?.status
        == .inProgress
    {
      exportRecordStore.removeVariant(assetId: inFlightId, variant: inFlightVariant)
    }
    currentJobAssetId = nil
    currentJobVariant = nil
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
  private func enqueueMonth(
    year: Int, month: Int, selection: ExportVersionSelection, generation gen: Int
  ) async throws {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryService.isAuthorized else { return }
    let assets = try await photoLibraryService.fetchAssets(year: year, month: month)
    try throwIfCancelledOrStale(gen)
    let newJobs: [ExportJob] = assets.compactMap { asset in
      guard shouldEnqueue(asset: asset, selection: selection) else { return nil }
      return ExportJob(
        assetLocalIdentifier: asset.id, year: year, month: month, selection: selection)
    }
    pendingJobs.append(contentsOf: newJobs)
    totalJobsEnqueued += newJobs.count
    queuedCountsByYearMonth["\(year)-\(month)", default: 0] += newJobs.count
    updateQueueCount()
    logger.info("Enqueued \(newJobs.count) assets for export for \(year)-\(month)")
  }

  private func enqueueYear(
    year: Int, selection: ExportVersionSelection, generation gen: Int
  ) async throws {
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
      guard shouldEnqueue(asset: asset, selection: selection) else { continue }
      newJobs.append(
        ExportJob(
          assetLocalIdentifier: asset.id, year: year, month: m, selection: selection))
    }
    pendingJobs.append(contentsOf: newJobs)
    totalJobsEnqueued += newJobs.count
    for job in newJobs {
      queuedCountsByYearMonth["\(job.year)-\(job.month)", default: 0] += 1
    }
    updateQueueCount()
    logger.info("Enqueued \(newJobs.count) assets for export for year \(year)")
  }

  /// Returns true when the asset has at least one required variant that isn't already `.done`.
  private func shouldEnqueue(asset: AssetDescriptor, selection: ExportVersionSelection) -> Bool {
    let required = requiredVariants(for: asset, selection: selection)
    if required.isEmpty { return false }
    return !exportRecordStore.isExported(asset: asset, selection: selection)
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
      currentJobVariant = nil
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
    currentJobVariant = nil
    updateQueueCount()
    let currentGen = generation
    currentTask = Task { [weak self] in
      await self?.export(job: job, generation: currentGen)
      await MainActor.run { [weak self] in
        self?.currentJobAssetId = nil
        self?.currentJobVariant = nil
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
    var inFlight: (assetId: String, variant: ExportVariant)?
    do {
      try throwIfCancelledOrStale(gen)

      guard let descriptor = photoLibraryService.fetchAssetDescriptor(for: job.assetLocalIdentifier)
      else {
        try throwIfCancelledOrStale(gen)
        exportRecordStore.markVariantFailed(
          assetId: job.assetLocalIdentifier, variant: .original,
          error: "Asset not found", at: Date())
        logger.error(
          "Asset not found for id: \(job.assetLocalIdentifier, privacy: .public)")
        return
      }
      logger.debug(
        "Export begin id: \(descriptor.id, privacy: .public) type: \(descriptor.mediaType.rawValue) hasAdjustments: \(descriptor.hasAdjustments) dims: \(descriptor.pixelWidth)x\(descriptor.pixelHeight)"
      )

      guard let scopedURL = exportDestination.beginScopedAccess() else {
        throw NSError(
          domain: "Export", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to access export folder (security scope)"
          ])
      }
      logger.debug("Begin scoped access for: \(scopedURL.path, privacy: .public)")
      defer { exportDestination.endScopedAccess(for: scopedURL) }

      let destDir = try exportDestination.urlForMonth(
        year: job.year, month: job.month, createIfNeeded: true)
      let relPath = "\(job.year)/" + String(format: "%02d", job.month) + "/"

      let resources = photoLibraryService.resources(for: descriptor.id)
      let resourceSummary = resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.joined(
        separator: ", ")
      logger.debug("Asset resources: \(resourceSummary, privacy: .public)")

      let existingRecord = exportRecordStore.exportInfo(assetId: descriptor.id)
      let required = requiredVariants(for: descriptor, selection: job.selection)
      let missing = required.filter { variant in
        existingRecord?.variants[variant]?.status != .done
      }
      if missing.isEmpty {
        logger.debug(
          "All required variants already .done for id: \(descriptor.id, privacy: .public)")
        return
      }

      // Always attempt original before edited so edited can inherit the chosen group stem.
      let orderedVariants: [ExportVariant] = [.original, .edited].filter { missing.contains($0) }
      var groupStem = inheritedGroupStem(from: existingRecord)

      for variant in orderedVariants {
        do {
          try throwIfCancelledOrStale(gen)
          let nextGroupStem = try await exportSingleVariant(
            variant: variant,
            descriptor: descriptor,
            resources: resources,
            destDir: destDir,
            relPath: relPath,
            job: job,
            inheritedGroupStem: groupStem,
            generation: gen,
            inFlight: &inFlight
          )
          if let nextGroupStem { groupStem = nextGroupStem }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          logger.error(
            "Variant \(variant.rawValue, privacy: .public) failed for id: \(descriptor.id, privacy: .public) error: \(String(describing: error), privacy: .public)"
          )
          exportRecordStore.markVariantFailed(
            assetId: descriptor.id, variant: variant,
            error: error.localizedDescription, at: Date())
          inFlight = nil
        }
      }
    } catch is CancellationError {
      logger.info(
        "Export cancelled for id: \(job.assetLocalIdentifier, privacy: .public)")
      if let inFlight, self.generation == gen,
        exportRecordStore.exportInfo(assetId: inFlight.assetId)?.variants[inFlight.variant]?
          .status == .inProgress
      {
        exportRecordStore.removeVariant(assetId: inFlight.assetId, variant: inFlight.variant)
      }
    } catch {
      guard self.generation == gen else { return }
      logger.error(
        "Export failed for id: \(job.assetLocalIdentifier, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      exportRecordStore.markVariantFailed(
        assetId: job.assetLocalIdentifier, variant: .original,
        error: error.localizedDescription, at: Date())
    }
  }

  /// Writes a single variant for an asset. Returns the chosen group stem when the variant's
  /// filename was materialised (so later variants can pair against it). Returns nil on recoverable
  /// "no resource" failures that are recorded in-store but do not change the pairing stem.
  ///
  /// `inheritedGroupStem` comes from either a prior done variant record for this asset or, within
  /// the same job, a preceding successful variant.
  private func exportSingleVariant(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    resources: [ResourceDescriptor],
    destDir: URL,
    relPath: String,
    job: ExportJob,
    inheritedGroupStem: String?,
    generation gen: Int,
    inFlight: inout (assetId: String, variant: ExportVariant)?
  ) async throws -> String? {
    let resource: ResourceDescriptor? = {
      switch variant {
      case .original:
        return ResourceSelection.selectOriginalResource(
          from: resources, mediaType: descriptor.mediaType)
      case .edited:
        return ResourceSelection.selectEditedResource(
          from: resources, mediaType: descriptor.mediaType)
      }
    }()

    guard let resource else {
      let errMsg: String
      switch variant {
      case .original: errMsg = "No exportable resource"
      case .edited: errMsg = "Edited resource unavailable"
      }
      exportRecordStore.markVariantFailed(
        assetId: descriptor.id, variant: variant, error: errMsg, at: Date())
      logger.error(
        "No \(variant.rawValue, privacy: .public) resource for id: \(descriptor.id, privacy: .public)"
      )
      return nil
    }

    let (finalURL, chosenStem) = try resolveDestination(
      variant: variant,
      descriptor: descriptor,
      resource: resource,
      resources: resources,
      destDir: destDir,
      inheritedGroupStem: inheritedGroupStem
    )

    let tempURL = finalURL.appendingPathExtension("tmp")

    // Clean up any stale .tmp sibling for this target filename. Covers crash leftovers that a
    // prior defer could not clean up.
    if fileSystem.fileExists(atPath: tempURL.path) {
      try? fileSystem.removeItem(at: tempURL)
    }
    defer {
      if fileSystem.fileExists(atPath: tempURL.path) {
        try? fileSystem.removeItem(at: tempURL)
      }
    }

    try throwIfCancelledOrStale(gen)
    currentAssetFilename = finalURL.lastPathComponent
    currentJobVariant = variant
    inFlight = (assetId: descriptor.id, variant: variant)
    exportRecordStore.markVariantInProgress(
      assetId: descriptor.id, variant: variant, year: job.year, month: job.month,
      relPath: relPath, filename: finalURL.lastPathComponent)

    try await assetResourceWriter.writeResource(resource, forAssetId: descriptor.id, to: tempURL)
    try throwIfCancelledOrStale(gen)

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .utility).async { [fileSystem] in
        do {
          self.logger.debug(
            "Move begin: \(tempURL.lastPathComponent, privacy: .public) -> \(finalURL.lastPathComponent, privacy: .public)"
          )
          try fileSystem.moveItemAtomically(from: tempURL, to: finalURL)
          self.logger.debug(
            "Move done -> \(finalURL.lastPathComponent, privacy: .public)")
          continuation.resume(returning: ())
        } catch {
          self.logger.error("Move failed: \(error.localizedDescription, privacy: .public)")
          continuation.resume(throwing: error)
        }
      }
    }
    try throwIfCancelledOrStale(gen)

    if let createdAt = descriptor.creationDate {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { [fileSystem] in
          fileSystem.applyTimestamps(creationDate: createdAt, to: finalURL)
          self.logger.debug(
            "Applied timestamps for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public)"
          )
          continuation.resume()
        }
      }
      try throwIfCancelledOrStale(gen)
    }

    exportRecordStore.markVariantExported(
      assetId: descriptor.id, variant: variant, year: job.year, month: job.month,
      relPath: relPath, filename: finalURL.lastPathComponent, exportedAt: Date())
    inFlight = nil
    logger.info(
      "Exported \(finalURL.lastPathComponent, privacy: .public) variant: \(variant.rawValue, privacy: .public) -> \(finalURL.deletingLastPathComponent().path, privacy: .public)"
    )
    return chosenStem
  }

  /// Resolves the final URL and the group stem for a variant. Implements the collision
  /// algorithm from the feature plan (steps 0–6). Throws when a step-1 pairing conflict would
  /// silently split the pair.
  private func resolveDestination(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    resource: ResourceDescriptor,
    resources: [ResourceDescriptor],
    destDir: URL,
    inheritedGroupStem: String?
  ) throws -> (URL, String) {
    switch variant {
    case .original:
      let originalFilename = ExportFilenamePolicy.originalFilename(
        for: resource.originalFilename)
      let (origStem, origExt) = splitFilename(originalFilename)
      if let inherited = inheritedGroupStem {
        let candidate = destDir.appendingPathComponent(inherited)
          .appendingPathExtension(origExt)
        if fileSystem.fileExists(atPath: candidate.path) {
          throw NSError(
            domain: "Export", code: 5,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Paired original filename already exists on disk: \(candidate.lastPathComponent)"
            ])
        }
        return (candidate, inherited)
      }
      let finalURL = uniqueFileURL(in: destDir, baseName: origStem, ext: origExt)
      let chosenStem = finalURL.deletingPathExtension().lastPathComponent
      return (finalURL, chosenStem)

    case .edited:
      let editedExt = (resource.originalFilename as NSString).pathExtension
      if let inherited = inheritedGroupStem {
        let editedFilename = ExportFilenamePolicy.editedFilename(
          originalGroupStem: inherited, editedResourceFilename: resource.originalFilename)
        let (base, ext) = splitFilename(editedFilename)
        let finalURL = uniqueFileURL(in: destDir, baseName: base, ext: ext)
        return (finalURL, inherited)
      }
      // editedOnly with no inherited stem — allocate one from the original-side resource
      // considering both original and edited companion file existence.
      let (originalStem, originalExt) = editedOnlyBaseStemAndExt(
        descriptor: descriptor, resources: resources, editedResource: resource,
        editedExt: editedExt)
      let chosenStem = allocateEditedOnlyGroupStem(
        baseStem: originalStem, originalExt: originalExt, editedExt: editedExt,
        destDir: destDir)
      let editedFilename = ExportFilenamePolicy.editedFilename(
        originalGroupStem: chosenStem, editedResourceFilename: resource.originalFilename)
      let (base, ext) = splitFilename(editedFilename)
      let finalURL = uniqueFileURL(in: destDir, baseName: base, ext: ext)
      return (finalURL, chosenStem)
    }
  }

  private func editedOnlyBaseStemAndExt(
    descriptor: AssetDescriptor,
    resources: [ResourceDescriptor],
    editedResource: ResourceDescriptor,
    editedExt: String
  ) -> (stem: String, ext: String) {
    if let original = ResourceSelection.selectOriginalResource(
      from: resources, mediaType: descriptor.mediaType)
    {
      let (s, e) = splitFilename(original.originalFilename)
      return (s, e)
    }
    // Fallback: derive from the edited resource filename when no original-side resource exists.
    let (s, _) = splitFilename(editedResource.originalFilename)
    return (s, editedExt)
  }

  private func allocateEditedOnlyGroupStem(
    baseStem: String, originalExt: String, editedExt: String, destDir: URL
  ) -> String {
    var stem = baseStem
    var index = 1
    while index < 10_000 {
      let origCandidate = destDir.appendingPathComponent(stem)
        .appendingPathExtension(originalExt)
      let editedCandidate = destDir.appendingPathComponent(
        stem + ExportFilenamePolicy.editedSuffix
      ).appendingPathExtension(editedExt)
      if !fileSystem.fileExists(atPath: origCandidate.path)
        && !fileSystem.fileExists(atPath: editedCandidate.path)
      {
        return stem
      }
      stem = "\(baseStem) (\(index))"
      index += 1
    }
    return stem
  }

  private func inheritedGroupStem(from record: ExportRecord?) -> String? {
    guard let record else { return nil }
    if let original = record.variants[.original], original.status == .done,
      let filename = original.filename
    {
      return splitFilename(filename).base
    }
    if let edited = record.variants[.edited], edited.status == .done,
      let filename = edited.filename,
      let parsed = ExportFilenamePolicy.parseEditedCandidate(filename: filename)
    {
      return parsed.groupStem
    }
    return nil
  }

  // MARK: - Helpers

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
        guard let scopedURL = self.exportDestination.beginScopedAccess() else {
          self.logger.error("Failed to acquire security-scoped access for import")
          self.isImporting = false
          self.importStage = nil
          return
        }
        defer { self.exportDestination.endScopedAccess(for: scopedURL) }

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

        self.importStage = .rebuildingLocalState

        let now = Date()
        var records: [ExportRecord] = []
        records.reserveCapacity(matchResult.matched.count)

        for matched in matchResult.matched {
          let descriptor = matched.asset
          let file = matched.file
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
            variants: [
              matched.variant: ExportVariantRecord(
                filename: file.filename,
                status: .done,
                exportDate: now,
                lastError: nil
              )
            ]
          )
          records.append(record)
        }

        self.exportRecordStore.bulkImportRecords(records)

        guard self.generation == importGen else {
          self.isImporting = false
          self.importStage = nil
          return
        }

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
