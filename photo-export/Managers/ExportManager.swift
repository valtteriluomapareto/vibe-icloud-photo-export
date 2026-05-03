import AppKit
import Foundation
import Photos
import SwiftUI
import os

@MainActor
final class ExportManager: ObservableObject {
  /// User-facing persistence key for the active version selection.
  static let versionSelectionDefaultsKey = "exportVersionSelection"

  /// How long the "already exported" toolbar message stays visible before it auto-clears.
  /// Long enough to read, short enough that subsequent work doesn't show stale state.
  static let emptyRunMessageDuration: TimeInterval = 6

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

  /// Active render activity for the asset currently in flight. Surfaces in
  /// the toolbar so a long edited-video render does not look like a hang.
  /// `nil` whenever no render is active (the default for static-resource
  /// writes).
  @Published private(set) var renderActivity: RenderActivity?

  /// Transient toolbar feedback for the case where the user clicked Export Month / Year /
  /// All against an already-complete library (zero new jobs enqueued). Cleared on any new
  /// `startExport*` call, version-selection change, `cancelAndClear`, or after
  /// `Self.emptyRunMessageDuration`.
  @Published private(set) var emptyRunMessage: String?
  private var emptyRunMessageTask: Task<Void, Never>?

  /// Which variants the pipeline writes for each asset. Persisted to `UserDefaults` so the
  /// choice survives restart and stays globally consistent regardless of destination.
  @Published var versionSelection: ExportVersionSelection {
    didSet {
      UserDefaults.standard.set(
        versionSelection.rawValue, forKey: Self.versionSelectionDefaultsKey)
      // The "already exported" copy is scoped to the previous selection — under a new
      // selection the user may have new work, so the message would be misleading.
      clearEmptyRunMessage()
    }
  }

  /// Toolbar/onboarding-friendly view of `versionSelection`. Off ↔ `.edited`, on ↔
  /// `.editedWithOriginals`. Mutations route back through `versionSelection` so
  /// `@Published` observation and `UserDefaults` persistence flow through one source.
  var includeOriginals: Bool {
    get { versionSelection == .editedWithOriginals }
    set { versionSelection = newValue ? .editedWithOriginals : .edited }
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
  // `var` rather than `let` so we can rebind it at the end of `init` with a
  // callback that captures `self` weakly. Swift forbids referencing `self`
  // (even weakly) before all stored properties are assigned, so the
  // production renderer is wired in two steps: a provisional no-op
  // callback during initialisation, then a live callback once `self` is
  // ready. Functionally a `let`; the `var` is purely for the init order.
  // DO NOT change this back to `let` without re-examining the closure
  // capture in `init` — the rebind is the whole point.
  private(set) var mediaRenderer: any MediaRenderer
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
    mediaRenderer: (any MediaRenderer)? = nil,
    fileSystem: any FileSystemService = FileIOService()
  ) {
    self.photoLibraryService = photoLibraryService
    self.exportDestination = exportDestination
    self.exportRecordStore = exportRecordStore
    self.assetResourceWriter = assetResourceWriter
    self.fileSystem = fileSystem
    // Provisional renderer — gives `self.mediaRenderer` a value so all
    // stored properties are initialised before we capture `self` below.
    if let mediaRenderer {
      self.mediaRenderer = mediaRenderer
    } else {
      self.mediaRenderer = ProductionMediaRenderer { _ in }
    }
    if let raw = UserDefaults.standard.string(forKey: Self.versionSelectionDefaultsKey),
      let saved = ExportVersionSelection(rawValue: raw)
    {
      self.versionSelection = saved
    } else {
      self.versionSelection = .edited
    }
    // `self` is fully initialised now — rebind the default renderer with
    // a callback that routes render activity back to `renderActivity`.
    if mediaRenderer == nil {
      self.mediaRenderer = ProductionMediaRenderer { @Sendable [weak self] activity in
        Task { @MainActor [weak self] in
          self?.renderActivity = activity
        }
      }
    }
  }

  // MARK: - Public API
  func startExportMonth(year: Int, month: Int) {
    // Snapshot the active selection synchronously so a picker flip before the async enqueue
    // lands (after `fetchAssets` returns) cannot change the mode that was visible at click
    // time. The picker in the toolbar is also gated on `hasActiveExportWork` for clarity, but
    // this snapshot is the correctness guarantee.
    let selection = versionSelection
    clearEmptyRunMessage()
    if !isRunning && !isProcessing { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.generation == gen else { return }
      do {
        let outcome = try await enqueueMonth(
          year: year, month: month, selection: selection, generation: gen)
        guard self.generation == gen else { return }
        switch outcome {
        case .enqueued, .unauthorized:
          break
        case .alreadyComplete:
          setEmptyRunMessage("This month is already exported.")
        }
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
    clearEmptyRunMessage()
    if !isRunning && !isProcessing { resetProgressCounters() }
    let gen = generation
    Task { [weak self] in
      guard let self, self.generation == gen else { return }
      do {
        let outcome = try await enqueueYear(
          year: year, selection: selection, generation: gen)
        guard self.generation == gen else { return }
        switch outcome {
        case .enqueued, .unauthorized:
          break
        case .alreadyComplete:
          setEmptyRunMessage("This year is already exported.")
        }
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
    clearEmptyRunMessage()
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
        var totalEnqueued = 0
        var sawUnauthorized = false
        for year in allYears {
          let outcome = try await enqueueYear(
            year: year, selection: selection, generation: gen)
          guard self.generation == gen else {
            self.isEnqueueingAll = false
            return
          }
          switch outcome {
          case .enqueued(let count):
            totalEnqueued += count
          case .alreadyComplete:
            break
          case .unauthorized:
            sawUnauthorized = true
          }
        }
        self.isEnqueueingAll = false
        if totalEnqueued == 0 && !sawUnauthorized {
          setEmptyRunMessage("Everything in this destination is already exported.")
        }
        processQueueIfNeeded()
      } catch {
        self.isEnqueueingAll = false
        logger.error(
          "Failed to enqueue export-all: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  /// Outcome of an enqueue scan over a month, year, or library. Either real work was
  /// queued, every asset in scope is already done, or the Photos library is not
  /// accessible and we cannot scan at all (the latter is a defensive case — the export
  /// button is gated on `isAuthorized` in the UI, so users should not reach this path).
  private enum EnqueueOutcome: Equatable {
    case enqueued(Int)
    case alreadyComplete
    case unauthorized
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
    clearEmptyRunMessage()
    updateQueueCount()
  }

  // MARK: - Empty-run message

  /// Shows a transient message in the toolbar's progress slot for `emptyRunMessageDuration`.
  /// Replaces any previously-shown message and resets the auto-clear timer.
  private func setEmptyRunMessage(_ message: String) {
    emptyRunMessage = message
    emptyRunMessageTask?.cancel()
    let duration = Self.emptyRunMessageDuration
    emptyRunMessageTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        self?.emptyRunMessage = nil
        self?.emptyRunMessageTask = nil
      }
    }
  }

  /// Clears the empty-run message immediately. Called by every code path that invalidates
  /// it: any new `startExport*`, version-selection change, `cancelAndClear`.
  private func clearEmptyRunMessage() {
    emptyRunMessage = nil
    emptyRunMessageTask?.cancel()
    emptyRunMessageTask = nil
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

  /// Scans the month and returns the enqueue outcome. Callers use the outcome to decide
  /// whether to surface the "already exported" toolbar message.
  @discardableResult
  private func enqueueMonth(
    year: Int, month: Int, selection: ExportVersionSelection, generation gen: Int
  ) async throws -> EnqueueOutcome {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryService.isAuthorized else { return .unauthorized }
    let assets = try await photoLibraryService.fetchAssets(year: year, month: month)
    try throwIfCancelledOrStale(gen)
    let newJobs: [ExportJob] = assets.compactMap { asset in
      guard !exportRecordStore.isExported(asset: asset, selection: selection) else {
        return nil
      }
      return ExportJob(
        assetLocalIdentifier: asset.id, year: year, month: month, selection: selection)
    }
    pendingJobs.append(contentsOf: newJobs)
    totalJobsEnqueued += newJobs.count
    queuedCountsByYearMonth["\(year)-\(month)", default: 0] += newJobs.count
    updateQueueCount()
    logger.info("Enqueued \(newJobs.count) assets for export for \(year)-\(month)")
    return newJobs.isEmpty ? .alreadyComplete : .enqueued(newJobs.count)
  }

  @discardableResult
  private func enqueueYear(
    year: Int, selection: ExportVersionSelection, generation gen: Int
  ) async throws -> EnqueueOutcome {
    try throwIfCancelledOrStale(gen)
    guard photoLibraryService.isAuthorized else { return .unauthorized }
    let assets = try await photoLibraryService.fetchAssets(year: year, month: nil)
    try throwIfCancelledOrStale(gen)
    let calendar = Calendar.current
    var newJobs: [ExportJob] = []
    newJobs.reserveCapacity(assets.count)
    for asset in assets {
      guard let created = asset.creationDate else { continue }
      let m = calendar.component(.month, from: created)
      guard !exportRecordStore.isExported(asset: asset, selection: selection) else {
        continue
      }
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
    return newJobs.isEmpty ? .alreadyComplete : .enqueued(newJobs.count)
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

      // Whether `.original` is paired with `.edited` for this asset. When true, the
      // `.original` file is written at `<stem>_orig.<origExt>`; otherwise at the bare stem.
      let pairOriginalWithSuffix = required.contains(.edited)

      var groupStem = inheritedGroupStem(
        from: existingRecord, descriptor: descriptor, resources: resources)

      // Pre-allocate a paired stem when we will write both variants in this run with no
      // inherited stem to anchor the pair. This guarantees the edited and `_orig` companion
      // land on the same stem instead of splitting via per-file uniqueFileURL collisions.
      if groupStem == nil, orderedVariants == [.original, .edited],
        let originalRes = ResourceSelection.selectOriginalResource(
          from: resources, mediaType: descriptor.mediaType)
      {
        let editedProducer = ResourceSelection.selectEditedProducer(
          from: resources, mediaType: descriptor.mediaType, descriptor: descriptor)
        if let editedFilename = editedProducer.originalFilename {
          let baseStem = splitFilename(originalRes.originalFilename).base
          let originalExt = (originalRes.originalFilename as NSString).pathExtension
          let editedExt = (editedFilename as NSString).pathExtension
          groupStem = allocatePairedGroupStem(
            baseStem: baseStem, editedExt: editedExt, originalExt: originalExt, destDir: destDir)
        }
      }

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
            groupStem: groupStem,
            pairOriginalWithSuffix: pairOriginalWithSuffix,
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
  /// `groupStem` is either inherited from a prior done variant record for this asset or, within
  /// the same job, pre-allocated when both variants will be written together.
  private func exportSingleVariant(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    resources: [ResourceDescriptor],
    destDir: URL,
    relPath: String,
    job: ExportJob,
    groupStem: String?,
    pairOriginalWithSuffix: Bool,
    generation gen: Int,
    inFlight: inout (assetId: String, variant: ExportVariant)?
  ) async throws -> String? {
    // Renderer activity must always be cleared on the way out of this
    // function — including on throw — so a render failure or cancel does
    // not leave the toolbar showing `(rendering…)` forever.
    defer { renderActivity = nil }

    let producer: EditedProducer = {
      switch variant {
      case .original:
        if let resource = ResourceSelection.selectOriginalResource(
          from: resources, mediaType: descriptor.mediaType)
        {
          return .resource(resource)
        }
        return .none
      case .edited:
        return ResourceSelection.selectEditedProducer(
          from: resources, mediaType: descriptor.mediaType, descriptor: descriptor)
      }
    }()

    guard let originalFilename = producer.originalFilename else {
      let errMsg: String
      switch variant {
      case .original: errMsg = "No exportable resource"
      case .edited: errMsg = ExportVariantRecovery.editedResourceUnavailableMessage
      }
      exportRecordStore.markVariantFailed(
        assetId: descriptor.id, variant: variant, error: errMsg, at: Date())
      logger.error(
        "No \(variant.rawValue, privacy: .public) byte source for id: \(descriptor.id, privacy: .public)"
      )
      return nil
    }

    let (finalURL, chosenStem) = try resolveDestination(
      variant: variant,
      descriptor: descriptor,
      originalFilename: originalFilename,
      resources: resources,
      destDir: destDir,
      groupStem: groupStem,
      pairOriginalWithSuffix: pairOriginalWithSuffix
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

    switch producer {
    case .resource(let resource):
      try await assetResourceWriter.writeResource(
        resource, forAssetId: descriptor.id, to: tempURL)
    case .render(let request):
      // Translate any renderer error (other than cancellation) into the
      // canonical recoverable failure so the persisted `lastError` is
      // stable across both "no static resource" and "render attempted
      // and failed" cases. The original error survives in the log for
      // diagnostics.
      do {
        try await mediaRenderer.render(request: request, to: tempURL)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        logger.error(
          "Render failed for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public) error: \(String(describing: error), privacy: .public)"
        )
        throw NSError(
          domain: "Export", code: 9,
          userInfo: [
            NSLocalizedDescriptionKey:
              ExportVariantRecovery.editedResourceUnavailableMessage
          ])
      }
    case .none:
      // Guarded above by `producer.originalFilename` check.
      preconditionFailure("EditedProducer.none reached the write step")
    }
    // Load-bearing: this checkpoint must run BEFORE the atomic move
    // below so that a cancel arriving during the render does not leak a
    // partially-written file into the destination. Reordering this is a
    // correctness regression — temp cleanup is handled by `defer`, but
    // only if we throw before the move.
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

  /// Resolves the final URL and the group stem for a variant. Throws when a paired-stem
  /// conflict would silently split the pair (step-1 fail-path).
  ///
  /// `groupStem` is the chosen pair stem when known: inherited from a prior `.done` record
  /// for this asset, or pre-allocated by `allocatePairedGroupStem` when both variants are
  /// being written together. When nil, only one variant is being written for this asset and
  /// the file lands at the natural stem with `uniqueFileURL` collision handling.
  ///
  /// `pairOriginalWithSuffix` is true when this asset's `.original` is paired with an
  /// `.edited` (current run or prior record) and so should be written at `<stem>_orig`.
  private func resolveDestination(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    originalFilename: String,
    resources: [ResourceDescriptor],
    destDir: URL,
    groupStem: String?,
    pairOriginalWithSuffix: Bool
  ) throws -> (URL, String) {
    switch variant {
    case .original:
      let origExt = (originalFilename as NSString).pathExtension
      if let stem = groupStem {
        let filename = ExportFilenamePolicy.originalFilename(
          stem: stem, ext: origExt, withSuffix: pairOriginalWithSuffix)
        let candidate = destDir.appendingPathComponent(filename)
        if fileSystem.fileExists(atPath: candidate.path) {
          throw NSError(
            domain: "Export", code: 5,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Paired original filename already exists on disk: \(candidate.lastPathComponent)"
            ])
        }
        return (candidate, stem)
      }
      // Fresh single-variant `.original`: no pairing, use uniqueFileURL collision handling.
      let (origStem, _) = splitFilename(originalFilename)
      let finalURL = uniqueFileURL(in: destDir, baseName: origStem, ext: origExt)
      return (finalURL, finalURL.deletingPathExtension().lastPathComponent)

    case .edited:
      let editedExt = (originalFilename as NSString).pathExtension
      if let stem = groupStem {
        let filename = ExportFilenamePolicy.editedFilename(
          stem: stem, editedResourceFilename: originalFilename)
        let (base, ext) = splitFilename(filename)
        // If the inherited natural stem is already taken (post-edit case where the prior
        // `.original.done` occupies it), uniqueFileURL splits the pair onto a `(N)`
        // suffix. This is the documented one-time cost on first re-export after each new
        // edit.
        let finalURL = uniqueFileURL(in: destDir, baseName: base, ext: ext)
        return (finalURL, finalURL.deletingPathExtension().lastPathComponent)
      }
      // Fresh single-variant `.edited` (default mode adjusted asset, no prior records).
      // Use the original-side resource's stem so the edited file lands at e.g.
      // `IMG_0001.JPG` (matching what Photos.app does for a single-asset export).
      let baseStem: String
      if let original = ResourceSelection.selectOriginalResource(
        from: resources, mediaType: descriptor.mediaType)
      {
        baseStem = splitFilename(original.originalFilename).base
      } else {
        baseStem = splitFilename(originalFilename).base
      }
      let finalURL = uniqueFileURL(in: destDir, baseName: baseStem, ext: editedExt)
      return (finalURL, finalURL.deletingPathExtension().lastPathComponent)
    }
  }

  /// Allocates a stem where both the natural-stem edited target (`<stem>.<editedExt>`) and
  /// the `_orig` companion target (`<stem>_orig.<originalExt>`) are simultaneously free.
  /// Bumps the per-pair collision suffix until both slots are available so the pair never
  /// splits across stems.
  private func allocatePairedGroupStem(
    baseStem: String, editedExt: String, originalExt: String, destDir: URL
  ) -> String {
    var stem = baseStem
    var index = 1
    while index < 10_000 {
      let editedTarget = destDir.appendingPathComponent(stem)
        .appendingPathExtension(editedExt)
      let origTarget = destDir.appendingPathComponent(
        stem + ExportFilenamePolicy.originalSuffix
      ).appendingPathExtension(originalExt)
      if !fileSystem.fileExists(atPath: editedTarget.path)
        && !fileSystem.fileExists(atPath: origTarget.path)
      {
        return stem
      }
      stem = "\(baseStem) (\(index))"
      index += 1
    }
    return stem
  }

  /// Recovers the group stem from a prior `.done` variant record so a follow-up run that
  /// adds the missing variant pairs against the same stem.
  ///
  /// `_orig` is both an app companion marker and a string a user can put in an actual
  /// original filename (e.g. `vacation_orig.JPG`). When the recorded `.original` filename
  /// exactly equals the asset's current original-side resource filename, treat it as the
  /// user's natural filename — even when its stem ends with `_orig` — so the asset stays
  /// pinned to the `vacation_orig` stem and a later edited write becomes
  /// `vacation_orig (1).<ext>` rather than `vacation.<ext>`.
  private func inheritedGroupStem(
    from record: ExportRecord?,
    descriptor: AssetDescriptor,
    resources: [ResourceDescriptor]
  ) -> String? {
    guard let record else { return nil }
    if let edited = record.variants[.edited], edited.status == .done,
      let filename = edited.filename
    {
      return splitFilename(filename).base
    }
    if let original = record.variants[.original], original.status == .done,
      let filename = original.filename
    {
      let originalResourceFilename = ResourceSelection.selectOriginalResource(
        from: resources, mediaType: descriptor.mediaType)?.originalFilename
      if let originalResourceFilename, filename == originalResourceFilename {
        return splitFilename(filename).base
      }
      if let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: filename) {
        return parsed.groupStem
      }
      return splitFilename(filename).base
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
