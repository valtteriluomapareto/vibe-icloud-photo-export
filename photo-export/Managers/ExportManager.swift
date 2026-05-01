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
    /// The placement this job is exporting under. Drives:
    /// - Which on-disk folder the asset lands in (`placement.relativePath`).
    /// - Which record store records the result (timeline → `exportRecordStore`,
    ///   `.favorites`/`.album` → `collectionExportRecordStore`); see *Routing record
    ///   mutations to the right store* in the plan.
    let placement: ExportPlacement
    /// Selection snapshot at enqueue time. Deterministic within a single job even if the user
    /// toggles selection mid-run.
    let selection: ExportVersionSelection

    /// Year derived from the placement. Defined for timeline jobs; returns `0` for
    /// `.favorites`/`.album` placements (which are unreachable in Phase 1 production code
    /// — collection jobs land in Phase 3 along with the `urlForRelativeDirectory` wiring
    /// that obsoletes year/month for collection sites).
    var year: Int { placement.timelineYearMonth?.year ?? 0 }
    var month: Int { placement.timelineYearMonth?.month ?? 0 }
  }

  // MARK: - Published State (Export)
  @Published private(set) var isRunning: Bool = false
  @Published private(set) var queueCount: Int = 0
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var totalJobsEnqueued: Int = 0
  @Published private(set) var totalJobsCompleted: Int = 0
  @Published private(set) var currentAssetFilename: String?

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
  let collectionExportRecordStore: CollectionExportRecordStore
  let assetResourceWriter: any AssetResourceWriter
  let fileSystem: any FileSystemService

  /// True when the **timeline** store is ready to accept writes. Timeline `startExport*`
  /// methods short-circuit when false, preventing the silent-false-success case where the
  /// pipeline would write files to disk while the store's `append` silently no-ops because
  /// `state != .ready` (either `.unconfigured` or `.failed`).
  ///
  /// Phase 3 adds `canExportCollection` for the `.favorites`/`.album` start methods. The
  /// two are deliberately independent so a `.failed` collection store does not block
  /// timeline export and vice versa — the disjoint-key-spaces rationale (a failed
  /// favorites export can't corrupt timeline records) extends to the start-side guards.
  var canExportTimeline: Bool {
    exportRecordStore.state == .ready
  }

  /// True when the **collection** store is ready. Used by Phase 3's
  /// `startExportFavorites`/`startExportAlbum` start methods.
  var canExportCollection: Bool {
    collectionExportRecordStore.state == .ready
  }

  // MARK: - Internals
  private(set) var pendingJobs: [ExportJob] = []
  private var isProcessing: Bool = false
  private var currentTask: Task<Void, Never>?
  private(set) var currentJobAssetId: String?
  private(set) var currentJobVariant: ExportVariant?
  /// The placement of the job currently in flight. Set in `processNext()` *before*
  /// `currentJobAssetId` and reset everywhere `currentJobAssetId` is reset, so any
  /// cancellation cleanup that observes `currentJobAssetId` is guaranteed to see the
  /// matching placement. Used by both the `cancelAndClear` and run-loop catch-block
  /// cleanup paths to route the `removeVariant` call to the correct store via
  /// `placement.kind`.
  private(set) var currentJobPlacement: ExportPlacement?
  private(set) var generation: Int = 0
  private(set) var isEnqueueingAll: Bool = false
  private(set) var queuedCountsByPlacementId: [String: Int] = [:]
  private var importTask: Task<Void, Never>?

  init(
    photoLibraryService: any PhotoLibraryService,
    exportDestination: any ExportDestination,
    exportRecordStore: ExportRecordStore,
    collectionExportRecordStore: CollectionExportRecordStore? = nil,
    assetResourceWriter: any AssetResourceWriter = ProductionAssetResourceWriter(),
    fileSystem: any FileSystemService = FileIOService()
  ) {
    self.photoLibraryService = photoLibraryService
    self.exportDestination = exportDestination
    self.exportRecordStore = exportRecordStore
    // Default to a fresh collection store backed by the same on-disk root as the timeline
    // store. Tests typically pass `nil` and get a default-rooted store; production wires
    // an injected one from `photo_exportApp` so both stores share the destination's
    // `<App Support>/<bundleId>/ExportRecords/<destinationId>/` directory.
    self.collectionExportRecordStore = collectionExportRecordStore ?? CollectionExportRecordStore()
    self.assetResourceWriter = assetResourceWriter
    self.fileSystem = fileSystem
    if let raw = UserDefaults.standard.string(forKey: Self.versionSelectionDefaultsKey),
      let saved = ExportVersionSelection(rawValue: raw)
    {
      self.versionSelection = saved
    } else {
      self.versionSelection = .edited
    }
  }

  // MARK: - Public API
  func startExportMonth(year: Int, month: Int) {
    guard canExportTimeline else {
      logger.error(
        "startExportMonth ignored: timeline store state=\(String(describing: self.exportRecordStore.state), privacy: .public) (need .ready)"
      )
      return
    }
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
    guard canExportTimeline else {
      logger.error(
        "startExportYear ignored: timeline store state=\(String(describing: self.exportRecordStore.state), privacy: .public)"
      )
      return
    }
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
    guard canExportTimeline else {
      logger.error(
        "startExportAll ignored: timeline store state=\(String(describing: self.exportRecordStore.state), privacy: .public)"
      )
      return
    }
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
      let inFlightPlacement = currentJobPlacement
    {
      // Route the cleanup to the correct store by `placement.kind`. In Phase 1 only
      // `.timeline` jobs reach here in production; the `.favorites`/`.album` cases land
      // when collection exports start in Phase 3. The store-side `removeVariant` is a
      // no-op when the variant is not `.inProgress`, so the cross-store check that used
      // to live here is now baked into the store call.
      switch inFlightPlacement.kind {
      case .timeline:
        if exportRecordStore.exportInfo(assetId: inFlightId)?.variants[inFlightVariant]?.status
          == .inProgress
        {
          exportRecordStore.removeVariant(assetId: inFlightId, variant: inFlightVariant)
        }
      case .favorites, .album:
        if collectionExportRecordStore.exportInfo(
          assetId: inFlightId, placement: inFlightPlacement)?.variants[inFlightVariant]?.status
          == .inProgress
        {
          collectionExportRecordStore.removeVariant(
            assetId: inFlightId, placement: inFlightPlacement, variant: inFlightVariant)
        }
      }
    }
    currentJobAssetId = nil
    currentJobVariant = nil
    currentJobPlacement = nil
    generation += 1
    pendingJobs.removeAll()
    queuedCountsByPlacementId.removeAll()
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
    queuedCountsByPlacementId.removeAll()
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
    let placement = ExportPlacement.timeline(year: year, month: month)
    let newJobs: [ExportJob] = assets.compactMap { asset in
      guard !exportRecordStore.isExported(asset: asset, selection: selection) else {
        return nil
      }
      return ExportJob(
        assetLocalIdentifier: asset.id, placement: placement, selection: selection)
    }
    pendingJobs.append(contentsOf: newJobs)
    totalJobsEnqueued += newJobs.count
    queuedCountsByPlacementId[placement.id, default: 0] += newJobs.count
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
      let placement = ExportPlacement.timeline(year: year, month: m)
      newJobs.append(
        ExportJob(
          assetLocalIdentifier: asset.id, placement: placement, selection: selection))
    }
    pendingJobs.append(contentsOf: newJobs)
    totalJobsEnqueued += newJobs.count
    for job in newJobs {
      queuedCountsByPlacementId[job.placement.id, default: 0] += 1
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
      currentJobPlacement = nil
      currentAssetFilename = nil
      updateQueueCount()
      logger.info("Export queue drained")
      return
    }
    let job = pendingJobs.removeFirst()
    let key = job.placement.id
    queuedCountsByPlacementId[key, default: 1] -= 1
    if queuedCountsByPlacementId[key, default: 0] <= 0 {
      queuedCountsByPlacementId.removeValue(forKey: key)
    }
    // Set placement *before* assetId per the plan's ordering rule (any cancellation that
    // observes assetId must also see the matching placement).
    currentJobPlacement = job.placement
    currentJobAssetId = job.assetLocalIdentifier
    currentJobVariant = nil
    updateQueueCount()
    let currentGen = generation
    currentTask = Task { [weak self] in
      await self?.export(job: job, generation: currentGen)
      await MainActor.run { [weak self] in
        self?.currentJobAssetId = nil
        self?.currentJobVariant = nil
        self?.currentJobPlacement = nil
        guard let self, self.generation == currentGen else { return }
        self.totalJobsCompleted += 1
        self.processNext()
      }
    }
  }

  /// Reads the queue depth for `(year, month)` by resolving the synthetic timeline
  /// placement id and looking it up in the placement-keyed dict. Existing call sites use
  /// `(year, month)` and stay unchanged.
  func queuedCount(year: Int, month: Int) -> Int {
    let placementId = ExportPlacement.timeline(year: year, month: month).id
    return queuedCountsByPlacementId[placementId, default: 0]
  }

  private func resetProgressCounters() {
    totalJobsEnqueued = 0
    totalJobsCompleted = 0
    currentAssetFilename = nil
    queuedCountsByPlacementId.removeAll()
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
        recordVariantFailed(
          assetId: job.assetLocalIdentifier, placement: job.placement, variant: .original,
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
          from: resources, mediaType: descriptor.mediaType),
        let editedRes = ResourceSelection.selectEditedResource(
          from: resources, mediaType: descriptor.mediaType)
      {
        let baseStem = splitFilename(originalRes.originalFilename).base
        let originalExt = (originalRes.originalFilename as NSString).pathExtension
        let editedExt = (editedRes.originalFilename as NSString).pathExtension
        groupStem = allocatePairedGroupStem(
          baseStem: baseStem, editedExt: editedExt, originalExt: originalExt, destDir: destDir)
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
          recordVariantFailed(
            assetId: descriptor.id, placement: job.placement, variant: variant,
            error: error.localizedDescription, at: Date())
          inFlight = nil
        }
      }
    } catch is CancellationError {
      logger.info(
        "Export cancelled for id: \(job.assetLocalIdentifier, privacy: .public)")
      if let inFlight, self.generation == gen {
        // Route the cancellation cleanup by the in-flight job's placement kind.
        switch job.placement.kind {
        case .timeline:
          if exportRecordStore.exportInfo(assetId: inFlight.assetId)?.variants[inFlight.variant]?
            .status == .inProgress
          {
            exportRecordStore.removeVariant(assetId: inFlight.assetId, variant: inFlight.variant)
          }
        case .favorites, .album:
          if collectionExportRecordStore.exportInfo(
            assetId: inFlight.assetId, placement: job.placement)?.variants[inFlight.variant]?
            .status == .inProgress
          {
            collectionExportRecordStore.removeVariant(
              assetId: inFlight.assetId, placement: job.placement, variant: inFlight.variant)
          }
        }
      }
    } catch {
      guard self.generation == gen else { return }
      logger.error(
        "Export failed for id: \(job.assetLocalIdentifier, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      recordVariantFailed(
        assetId: job.assetLocalIdentifier, placement: job.placement, variant: .original,
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
      case .edited: errMsg = ExportVariantRecovery.editedResourceUnavailableMessage
      }
      recordVariantFailed(
        assetId: descriptor.id, placement: job.placement, variant: variant, error: errMsg,
        at: Date())
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
    recordVariantInProgress(
      assetId: descriptor.id, placement: job.placement, variant: variant,
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

    recordVariantExported(
      assetId: descriptor.id, placement: job.placement, variant: variant,
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
    resource: ResourceDescriptor,
    resources: [ResourceDescriptor],
    destDir: URL,
    groupStem: String?,
    pairOriginalWithSuffix: Bool
  ) throws -> (URL, String) {
    switch variant {
    case .original:
      let origExt = (resource.originalFilename as NSString).pathExtension
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
      let (origStem, _) = splitFilename(resource.originalFilename)
      let finalURL = uniqueFileURL(in: destDir, baseName: origStem, ext: origExt)
      return (finalURL, finalURL.deletingPathExtension().lastPathComponent)

    case .edited:
      let editedExt = (resource.originalFilename as NSString).pathExtension
      if let stem = groupStem {
        let filename = ExportFilenamePolicy.editedFilename(
          stem: stem, editedResourceFilename: resource.originalFilename)
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
        baseStem = splitFilename(resource.originalFilename).base
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

  // MARK: Record-mutation routing

  /// Routes a `markVariantFailed` to the right store based on `placement.kind`. In Phase 1,
  /// only `.timeline` paths are reachable in production; `.favorites`/`.album` are wired
  /// for Phase 3's collection-export work but won't be exercised until then.
  private func recordVariantFailed(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    error: String, at date: Date
  ) {
    switch placement.kind {
    case .timeline:
      exportRecordStore.markVariantFailed(
        assetId: assetId, variant: variant, error: error, at: date)
    case .favorites, .album:
      collectionExportRecordStore.markVariantFailed(
        assetId: assetId, placement: placement, variant: variant, error: error, at: date)
    }
  }

  private func recordVariantInProgress(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    relPath: String, filename: String?
  ) {
    switch placement.kind {
    case .timeline:
      let (year, month) = placement.timelineYearMonth ?? (0, 0)
      exportRecordStore.markVariantInProgress(
        assetId: assetId, variant: variant,
        year: year, month: month, relPath: relPath, filename: filename)
    case .favorites, .album:
      collectionExportRecordStore.markVariantInProgress(
        assetId: assetId, placement: placement, variant: variant, filename: filename)
    }
  }

  private func recordVariantExported(
    assetId: String, placement: ExportPlacement, variant: ExportVariant,
    relPath: String, filename: String, exportedAt: Date
  ) {
    switch placement.kind {
    case .timeline:
      let (year, month) = placement.timelineYearMonth ?? (0, 0)
      exportRecordStore.markVariantExported(
        assetId: assetId, variant: variant,
        year: year, month: month, relPath: relPath,
        filename: filename, exportedAt: exportedAt)
    case .favorites, .album:
      collectionExportRecordStore.markVariantExported(
        assetId: assetId, placement: placement, variant: variant,
        filename: filename, exportedAt: exportedAt)
    }
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
    // Gate the import on a `.ready` timeline store. Otherwise the scanner would happily
    // run, the bulkImportRecords call would silently drop every record (its `.ready`
    // guard short-circuits on `.unconfigured`/`.failed`), and the user would see a
    // success report with the matched counts despite nothing being persisted. This is
    // the same hazard `canExportTimeline` guards on the export-start side.
    guard exportRecordStore.state == .ready else {
      logger.error(
        "Cannot import: timeline record store state=\(String(describing: self.exportRecordStore.state), privacy: .public) (need .ready)"
      )
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
