# Auto-Sync and Background Sync Plan

Date: 2026-04-29
Status: Proposed

## Summary

Simple auto-sync is feasible without a new process, but it should not be implemented as "call `startExportAll()` whenever something changes." The safe version needs a few foundations first:

- a stable destination identity that does not change when bookmark data is refreshed,
- an awaitable export-run API with run context, export scope, and result reporting,
- Photos persistent-change tracking that drives targeted asset re-evaluation where possible,
- an auto-sync state reducer that reacts to manager state instead of scattered callbacks,
- retry/backoff and destination-unavailable behavior that are distinct from manual cancel.

True closed-app background sync remains possible, but it is a different architecture. It should come later through a login item or LaunchAgent registered with Service Management, preferably as a helper that wakes or signals the main app rather than directly exporting Photos content in a headless process.

## Current App Fit

The app already has useful building blocks:

- `ExportManager` can scan the library and enqueue only missing required variants for the current destination and version selection.
- `ExportDestinationManager` restores a security-scoped bookmark, validates reachability/writability, and observes `NSWorkspace.didMountNotification` / `NSWorkspace.didUnmountNotification`.
- `PhotoLibraryManager` registers as a `PHPhotoLibraryChangeObserver`, but currently only invalidates caches when the library changes.
- `ExportRecordStore` isolates export history by destination and recovers interrupted in-progress variants after restart.

The current APIs are not enough for auto-sync as-is:

- `ExportManager.startExportAll()` is fire-and-forget, user-visible, and mutates toolbar/progress state. Auto-sync needs a run context and an awaitable result.
- `destinationId` was previously derived from bookmark data (which can change when a stale bookmark is re-saved). The collections-export Phase 0 work replaced this with a hash of `volumeUUID || U+0000 || volumeRelativePath`, so the same folder produces the same id across stale-bookmark refreshes; auto-sync should adopt this `destinationId` directly rather than re-derive it from bookmarks.
- `PHPhotoLibraryChangeObserver` can fire for many changes that do not require a library-wide export scan. Auto-sync needs persistent-change tracking, targeted asset re-evaluation, and backpressure before it falls back to full reconciliation. Note: the collections feature now also surfaces a `PhotoLibraryManager.libraryRevision` published counter and a `CollectionCountCache` actor that is invalidated on the same observer callback — both are useful prior art for auto-sync's targeted invalidation work.

## Scope for Simple Auto-Sync

### Goals

- Add explicit user opt-in for automatic export.
- Automatically export missing assets when:
  - the app launches and the saved destination is available,
  - the selected destination becomes reachable/writable again,
  - Photos reports inserted or updated asset identifiers,
  - a destination is newly selected and passes safety checks,
  - the export-version selection changes in a way that creates new required work.
- Reuse the existing record store so auto-sync never overwrites existing files and only exports missing required variants.
- Keep manual export controls working and avoid auto-sync stomping toolbar messages or manual progress state.
- Make automatic runs observable through `os.Logger`, compact UI state, and persisted last-run summaries.
- Keep the first version process-local: no helper, no launch agent, no closed-app wakeup.

### Non-Goals

- Running after the user quits the app.
- Waking the app when no app/helper process is running.
- Detecting whether an already-exported edited photo changed and replacing the prior export.
- Building a conflict-resolution system for deleted, moved, or manually edited destination files.
- Adding a cloud-backup service or networking.
- Using `BGTaskScheduler`; the macOS SDK marks the BackgroundTasks scheduler unavailable on macOS.
- Preventing iCloud downloads or gating on network type. Automatic export is expected to download originals when PhotoKit needs to fetch them.

## Product Behavior

### User-Facing Model

Add a setting:

> Automatically export new photos when Photo Export is open or running in the background.

Recommended default: off.

When enabled, the app exports to the currently selected destination using the existing export-version setting:

- `Edited` mode: one user-visible version per asset.
- `Edited with originals` mode: edited assets also get the `_orig` companion.

If the destination is disconnected, auto-sync waits. When the drive containing the selected destination is mounted again and the folder is reachable/writable, auto-sync schedules a run after a short debounce.

If Photos access is limited, auto-sync applies only to the visible limited library. Settings/status copy must say this explicitly; "new photos" means new photos visible to this app.

Auto-sync must never present the limited-library picker automatically. Expanding limited Photos access is allowed only from an explicit user action in the UI, not from a scheduled/background run.

Auto-sync may download originals from iCloud because the export feature is intended to produce a complete local backup. This should be stated in settings/docs, but it is not a blocker or a network-type guard.

### First-Run UX

Offer the setting after the user has:

1. granted Photos access,
2. selected an export destination,
3. completed the initial manual export or explicitly opted into auto-sync.

Do not silently enable auto-sync just because a destination exists.

For an existing non-empty destination with no matching record store, block automatic runs until the user imports existing backup state or confirms that this destination is safe for auto-sync.

### State Model

Keep current state separate from history.

Current state:

- `disabled`
- `waiting(reason)`
- `idle`
- `scheduled(reason, fireAt)`
- `blocked(reason)`
- `running(runId, reason)`

Reasons:

- `photosAccessMissing`
- `limitedPhotosAccess`
- `destinationMissing`
- `destinationUnavailable`
- `destinationUnsafe`
- `manualExportActive`
- `importActive`
- `retryBackoff`

History:

- `lastRunSummary`
- `lastFailureSummary`
- `lastNoOpSummary`
- `lastRelevantPhotosChangeAt`
- `lastDestinationAvailableAt`

Do not model `lastRunCompleted` or `lastRunFailed` as current states. They are persisted summaries displayed alongside the current state.

## Phase 0: Blocking Foundations

These must land before any automatic trigger can start exports.

### Stable Destination Identity

Replace bookmark-data hash identity with a stable destination fingerprint computed from the resolved folder under security scope.

Proposed model:

```swift
struct DestinationFingerprint: Codable, Hashable {
  let schemaVersion: Int
  let volumeUUIDString: String?
  let volumeRootPath: String?
  let relativePathFromVolumeRoot: String
  let standardizedPath: String
  let identityConfidence: DestinationIdentityConfidence
}

/// In-memory hints collected at fingerprint computation time. Never persisted —
/// `fileResourceIdentifierKey` and `volumeIdentifierKey` are not stable across launches
/// and only support same-session comparisons and diagnostics.
struct LiveDestinationIdentityHints {
  let fileResourceIdentifier: String?
  let volumeIdentifier: String?
}
```

Implementation notes:

- Read resource values for the destination folder using keys such as `volumeUUIDStringKey`, `volumeURLKey`, `canonicalPathKey`, `fileResourceIdentifierKey`, and `volumeIdentifierKey`.
- Normalize the folder URL with `standardizedFileURL`.
- Produce the record-store id from stable identity components:
  - if `volumeUUIDString` and a relative path from `volumeURLKey` are available, hash `schemaVersion + volumeUUIDString + relativePathFromVolumeRoot`,
  - otherwise fall back to the canonical/standardized path and mark the identity confidence as low.
- `fileResourceIdentifierKey` and `volumeIdentifierKey` are useful same-session comparison hints captured into `LiveDestinationIdentityHints`. They are not persistent across restarts and must not be encoded into `DestinationFingerprint` or used as the primary record-store identity.
- Keep `standardizedPath` in the fingerprint for diagnostics, display, and low-confidence fallback.
- Keep bookmark data as access material only, not identity.
- After this change, `ExportDestinationManager.destinationId` is the stable fingerprint hash. The old bookmark-data hash becomes private migration input only and should disappear from the public API.
- Store the last successful fingerprint next to the bookmark only on explicit folder selection and confirmed stale-bookmark refresh. Routine mount/unmount validation can recompute a transient fingerprint for comparison, but must not overwrite the persisted fingerprint automatically.
- If a stale bookmark is re-saved but resolves to the same fingerprint, keep the same record store.
- If a folder appears to have moved but persistent identity components still match, migrate transparently. Same-session resource identifiers can support diagnostics but are not enough on their own for durable migration.
- If the app cannot prove the new resolved folder is the same destination, block auto-sync and ask for confirmation/import.
- Low-confidence path-based identities may be used for manual export, but automatic first-run export requires an empty destination or explicit user confirmation.

Migration:

- On first launch after this change, read the saved bookmark data before any code path can resolve a stale bookmark and mutate `UserDefaults`.
- Compute the legacy destination id with the old algorithm: `SHA256(bookmarkData)`.
- Resolve the bookmark under security scope, compute the new stable fingerprint, and derive the new destination id.
- If `<storeRoot>/<legacyId>/` exists and `<storeRoot>/<newStableId>/` does not, rename/move the legacy directory to the stable id.
- If both legacy and stable directories exist, do not merge automatically. Enter a visible migration-conflict state: block auto-sync, log a diagnostic, and show recovery options in settings such as importing existing backup state, keeping the stable store, or exporting diagnostics for support.
- A migration conflict must not silently disable auto-sync forever; it needs a user-visible recovery path.

Destination transitions must be fingerprint-aware:

- A stale-bookmark refresh that resolves to the same stable fingerprint is not a true destination change.
- Same-fingerprint refreshes must not call `cancelAndClear()`, reconfigure the record store, or interrupt active work.
- Only a true stable destination id change cancels export work and reconfigures `ExportRecordStore`.
- The existing destination-id `onChange` wiring in `PhotoExportApp` must move to a coordinator-level destination snapshot that compares stable fingerprints, not raw bookmark-derived ids.

### Destination Safety Model

Define "non-empty existing backup" concretely.

Ignore:

- `.DS_Store`,
- hidden `.photo-export*` lock/metadata files,
- empty directories.

Treat as non-empty/unsafe for automatic first run:

- any non-hidden file under a `YYYY/MM/` directory,
- any recognized image or video file under the destination root,
- any existing Photo Export sidecar/record metadata added in the future.

Detection should reuse `BackupScanner`'s `YYYY/MM` enumeration for known backup layout and use `UniformTypeIdentifiers` for root-level image/video detection instead of maintaining a hand-written extension list. The scan only decides whether auto-sync can start automatically; it is not a replacement for the existing import/matching flow.

Persist per destination:

```swift
struct DestinationAutoSyncSafetyRecord: Codable {
  let destinationId: String
  let confirmedForAutoSyncAt: Date?
  let confirmationKind: ConfirmationKind
  let firstSeenContentSummary: DestinationContentSummary
}
```

Automatic runs are allowed only when:

- the destination has a configured record store with records, or
- the destination is empty by the rules above, or
- the user confirmed/imported the existing destination for auto-sync.

### Awaitable Export Runs

Add an export-run abstraction before wiring auto-sync.

```swift
enum ExportRunSource: String, Codable {
  case manual
  case autoSync
}

enum ExportRunVisibility: String, Codable {
  case userVisible
  case background
}

struct ExportRunContext: Equatable, Codable {
  let runId: UUID
  let source: ExportRunSource
  let visibility: ExportRunVisibility
  let reason: AutoSyncReason?
  let scope: ExportRunScope
  let selection: ExportVersionSelection
  let startedAt: Date
}

struct ExportRunSummary: Equatable, Codable {
  let context: ExportRunContext
  let endedAt: Date
  let enqueuedCount: Int
  let completedCount: Int
  let failedCount: Int
  let skippedCount: Int
  let cancelReason: ExportCancelReason?
  let result: ExportRunResult
}

enum ExportRunScope: Equatable, Codable {
  case fullLibrary
  case assets(Set<String>)
}

/// Snapshot of the export manager's run state, observed by `AutoSyncManager` to drive
/// reducer events without polling.
struct ExportRunState: Equatable {
  let activeContext: ExportRunContext?
  let isManualActive: Bool
  let isAutoSyncActive: Bool
}
```

Export API direction:

- Add `runExport(context:) async -> ExportRunSummary`.
- Keep `startExportAll()` as a manual UI wrapper that creates a `.manual` / `.userVisible` context with `.fullLibrary`.
- Add a targeted path for `.assets(localIdentifiers)` so Photos persistent changes do not force `availableYears()` plus full-year scans for every relevant change.
- Auto-sync uses `.autoSync` / `.background`.
- User-visible runs may reset toolbar progress counters and show empty-run messages.
- Background runs must not clear manual toolbar messages or flash "Everything in this destination is already exported."
- Export errors currently logged internally should flow into the run summary.
- Export jobs still re-fetch descriptors/resources immediately before writing; targeted IDs are only a scheduling optimization, not a guarantee that the asset still exists or needs export.

### Run Ownership Model

MVP should use a single active run gate, not mixed per-run queues.

Rules:

- `ExportManager` has at most one active `ExportRunContext`.
- `pendingJobs`, progress counters, `currentJobAssetId`, `currentJobVariant`, and `queuedCountsByYearMonth` belong to that active run.
- `runExport(context:)` resolves when that active run reaches a terminal state: completed, failed, cancelled, interrupted-for-destination-loss, or superseded.
- Manual and auto-sync jobs are not interleaved in the same queue for MVP. Per-job `runId` ownership can be introduced later if true concurrent/mixed queues are needed.
- MVP does not add `PHAssetResourceManager` request cancellation. If a manual export is requested while an auto-sync run is active, the manual request supersedes the auto-sync run, but the export manager waits for any in-flight write to finish or fail before starting the manual run. UI should show a short "stopping auto-sync..." state. If this delay proves unacceptable, writer cancellation becomes follow-up Phase 0 work before shipping.
- During supersession, the export manager stops enqueueing/starting auto-sync jobs, clears remaining auto-sync pending jobs, records `cancelReason: .supersededByManualRun`, and then starts the manual run after the in-flight write reaches that completion point.
- If auto-sync wants to run while any manual export or import is active, `AutoSyncManager` marks itself dirty and re-evaluates after manual work drains. It does not enqueue work inside `ExportManager`.
- If another manual run is requested while a manual run is active, preserve current UI gating: reject/disable the request rather than queueing a second manual run.

This keeps the awaitable API honest: a run summary describes one exclusive run, not whatever happened to be in the shared queue.

### Destination Loss Interruption

Add destination-loss handling distinct from `cancelAndClear()`.

Required behavior:

- `interruptForDestinationUnavailable()` stops starting new jobs and clears in-memory auto-sync pending jobs.
- An in-flight `PHAssetResourceManager.writeData` may still complete or fail because MVP has no cancellation plumbing.
- If the in-flight write fails due to destination loss, mark it as interrupted/transient rather than permanent.
- The interrupted run resolves with `cancelReason: .destinationUnavailable`.
- Release the destination lock as part of interruption: close the lock file descriptor, remove or mark the diagnostic metadata file as stale, and persist dirty state before resolving the run summary. The OS-on-process-death release is a safety net, not the primary path.
- Persist the interrupted scope as dirty auto-sync state. When the same destination becomes available again, revalidate identity and safety, then start a fresh targeted or full reconciliation. The record store skips work already completed before interruption.
- Manual cancel remains explicit and destructive for the current queue.

## Proposed Architecture

### Protocol Boundaries

`AutoSyncManager` should depend on narrow protocols, not concrete app managers.

```swift
@MainActor
protocol AutoSyncExportRunning: AnyObject {
  var runState: ExportRunState { get }
  func runExport(context: ExportRunContext) async -> ExportRunSummary
}

@MainActor
protocol DestinationAvailabilityProviding: AnyObject {
  var destinationId: String? { get }
  var canExportNow: Bool { get }
  var identityConfidence: DestinationIdentityConfidence { get }
  var safetyState: DestinationSafetyState { get }
}

@MainActor
protocol PhotoLibraryChangeProviding: AnyObject {
  var authorizationStatus: PHAuthorizationStatus { get }
  var latestPersistentChangeEvent: PhotoLibraryPersistentChangeEvent? { get }
}
```

Production managers should conform directly where that keeps dependencies clean. Use adapters only when direct conformance would leak unrelated API or create awkward ownership. Tests should exercise the auto-sync policy with fake protocols, not real PhotoKit or filesystem work.

### AutoSyncManager Shape

Prefer subscription-driven re-evaluation over public "notify me this happened" entry points.

Responsibilities:

- own opt-in state,
- subscribe to source state changes,
- reduce events into `AutoSyncState`,
- debounce and coalesce triggers,
- ask the export runner to start a background run,
- persist last-run summary and per-destination auto-sync metadata.

Avoid a broad API such as `destinationAvailabilityChanged`, `photosLibraryChanged`, and `exportWorkStateChanged`. The manager should expose a small surface:

```swift
@MainActor
final class AutoSyncManager: ObservableObject {
  @Published private(set) var state: AutoSyncState
  @Published private(set) var lastRunSummary: ExportRunSummary?

  func attach(to environment: AutoSyncEnvironment)
  func setEnabled(_ enabled: Bool)
  func runNow()
}

struct AutoSyncEnvironment {
  let exportRunner: any AutoSyncExportRunning
  let destination: any DestinationAvailabilityProviding
  let photos: any PhotoLibraryChangeProviding
  let recordStore: ExportRecordStore
  let userDefaults: UserDefaults
  let clock: any Clock
}
```

`runNow()` semantics:

- Bypasses the auto-sync enabled flag and debounce delay. This makes the menu/action useful even when scheduled auto-sync is off.
- Honors Photos authorization, limited-library scope, destination availability, destination safety, destination identity confidence, destination locks, and active manual/import work.
- Bypasses transient retry timers for `photoKitTransient`, `iCloudTransient`, and `unknown` failures.
- Does not bypass hard retry blockers such as `destinationPermission`, `destinationNoSpace`, `assetMissing`, or stable `resourceMissing`. Users need an explicit normal manual export or "Retry Failed" action for those.
- If a destination lock is held by another exporter, surface that to the user immediately as a UI message ("Another exporter is using this destination") rather than entering the silent `blocked(otherExporterActive)` state used for scheduled triggers.
- Uses auto-sync visibility/status, not toolbar empty-run messages.

### State Reducer

Model auto-sync as deterministic events:

- `enabledChanged(Bool)`
- `destinationChanged(DestinationSnapshot)` where the snapshot includes destination id, availability, identity confidence, and safety state
- `safetyStateChanged(DestinationSafetyState)` if safety is updated independently of destination identity or availability
- `photosChanged(PhotoLibraryPersistentChangeEvent)`
- `versionSelectionChanged(ExportVersionSelection)`
- `exportRunStateChanged(ExportRunState)`
- `importStateChanged(isImporting: Bool)`
- `debounceFired(AutoSyncReason)`
- `retryTimerFired`
- `manualFullExportCompleted(ExportRunSummary)`

Write reducer tests for state transitions. Effects such as "schedule timer" and "start export" should be outputs from the reducer, not hidden in property observers. The reducer is invoked synchronously, once per event, with no mutation in flight; effects are emitted as a list per call and dispatched after the reducer returns. This keeps reducer tests deterministic single-event-in/state+effects-out.

### App Bootstrap

Do not add launch auto-sync work to `ContentView.task` or a view `.task` in `PhotoExportApp`.

Current store configuration is view-scoped and can rerun if scenes/windows are recreated. Before auto-sync, move app bootstrapping into a single app/coordinator object:

- create managers in `PhotoExportApp.init`,
- create an `AppLifecycleCoordinator` or similar process-lifetime `@StateObject`,
- configure `ExportRecordStore` once per destination identity,
- attach `AutoSyncManager` once,
- make repeated coordinator attachment idempotent so multi-window scene recreation is a no-op,
- keep views declarative and focused on presentation.

## Trigger and Debounce Rules

Use concrete debounce values by reason:

- app launch: 10 seconds after the app coordinator finishes initial destination/store configuration,
- destination selected: 3 seconds after successful validation and safety check,
- destination became available: 3 seconds after false-to-true `canExportNow`,
- export-version selection changed: 2 seconds,
- Photos persistent changes with inserted/updated asset identifiers: 30 seconds after the last relevant change,
- persistent-change token expired or details unavailable: 2-minute quiet window before full reconciliation,
- manual "Run Auto-Sync Now": no debounce after guard checks.

Backpressure:

- never run more than one auto-sync export at a time,
- if manual export/import is active, mark auto-sync dirty and re-evaluate after the work drains,
- cap full-library reconciliation from Photos-change fallback to at most once per 30 minutes. Targeted runs for inserted/updated IDs are not subject to this cap because they re-evaluate a bounded set of asset IDs,
- targeted persistent-change runs can happen more often because they re-evaluate a bounded set of asset IDs instead of scanning all years.

Pending reason expiry:

- `destinationBecameAvailable`, `destinationSelected`, and `versionSelectionChanged` stay pending until handled or explicitly superseded.
- Photos-change dirty flags expire after a successful auto-sync or manual full export.
- A manual month/year export does not clear a full-library pending reason; it only delays re-evaluation.
- A manual full export clears pending auto-sync work for the same destination and selection.

## Photo Library Changes

Persistent changes are MVP, not a later optimization.

Implementation direction:

- Store a `PHPersistentChangeToken` using secure coding in App Support next to the app's other durable state, not in `UserDefaults`.
- On first auto-sync enable, initialize the token and schedule one full reconciliation, because the existing library may already contain missing assets.
- If auto-sync is disabled while the app is running, the app may keep advancing the token to avoid token expiration, but enabling auto-sync after any disabled period still schedules reconciliation before relying on targeted changes.
- If the app was closed while Photos changed, the next launch reads persistent changes from the saved token. If the token is expired or unavailable, schedule the bounded full-reconciliation fallback.
- On `PHPhotoLibraryChangeObserver`, fetch persistent changes since the stored token.
- Use `changeDetailsForObjectType(.asset)` and collect `insertedLocalIdentifiers` and `updatedLocalIdentifiers`.
- Treat deleted asset IDs as non-export work for MVP. Do not delete exported files or records automatically.
- Do not assume Photos tells us whether an asset update is "content" vs "favorite/metadata". Persistent object details expose inserted/updated/deleted identifiers, not export-byte semantics.
- For inserted/updated asset IDs, schedule a targeted `.assets(ids)` run. The export pipeline re-fetches each descriptor, computes current `requiredVariants(for:selection:)`, checks the record store, and skips anything already complete.
- Ignore collection-only changes when no asset change details exist.
- If asset details cannot be read, identifiers are too numerous for a targeted run, or `fetchPersistentChanges(since:)` throws an expired/invalid token error, reset the token and schedule one bounded `.fullLibrary` reconciliation.
- Advance the token only after a dirty event has been durably recorded or after the change batch is classified as no-op. If the app crashes before recording the event, it should re-read the same token range on next launch.
- While the destination is unavailable or an auto-sync run was interrupted for destination loss, keep advancing the token only after dirty IDs/full-reconciliation intent have been durably recorded. Accumulate changed asset IDs in dirty state; if the set exceeds the targeting cost limit, collapse it to one pending full reconciliation for the destination.

This avoids a full `availableYears()` / `fetchAssets()` scan for every Photos notification while staying honest about what the persistent-change API can and cannot prove.

Targeting rules:

- Do not ship an unjustified magic threshold. Use a tunable implementation constant backed by measurement, and prefer a cost model once enough data exists: targeted estimate = changed ID count times recent per-descriptor re-evaluation cost; full estimate = recent full-reconciliation scan cost. Collapse to full reconciliation only when targeted work is likely to be slower or when a hard safety cap is exceeded.
- Cost estimates use the median of the last 10 measurements per category (per-descriptor re-evaluation, full-reconciliation scan) to keep threshold decisions stable across noisy single samples.
- The initial hard cap should be high enough for common batch imports and vacation imports; validate it with manual/performance tests before release.
- Above the threshold/cost limit, collapse to a bounded full reconciliation.
- If more targeted events arrive while a targeted run is active, union the ID sets and re-evaluate after the run completes.
- If a manual full export completes for the same destination and selection, clear pending targeted and full-library dirty flags.

## Destination Availability

Build on `ExportDestinationManager`'s existing `NSWorkspace` mount/unmount observers.

Changes:

- expose `refreshAvailability()` for explicit validation,
- observe `isAvailable` / `isWritable` at the auto-sync layer and detect false-to-true there,
- do not add a separate `availabilityChangeCounter`,
- include mounted volume URL/path from `NSWorkspace` notifications in logs,
- on unmount, call the destination-loss interruption path for auto-sync runs instead of `cancelAndClear()`.

Before running again after mount:

1. resolve the stored bookmark,
2. recompute the stable destination fingerprint,
3. verify it matches the interrupted run's destination id or the current configured destination id,
4. re-check safety state,
5. start a fresh reconciliation from persisted dirty state or block.

## Export-Version Changes

Changing `Include originals` is an explicit MVP trigger.

Rules:

- If auto-sync is enabled and the destination is safe, changing from `Edited` to `Edited with originals` schedules auto-sync after 2 seconds.
- Changing from `Edited with originals` to `Edited` does not delete previously exported `_orig` companions; it only changes future completion requirements.
- The run context snapshots the selection at run start.
- Selection changes while a run is active wait until the current run drains, then re-evaluate.

## Retry and Failure Policy

Auto-sync should not retry every non-`.done` variant forever on every launch/change.

Add failure categories to the export path or an auto-sync retry store:

- `destinationUnavailable`
- `destinationPermission`
- `destinationNoSpace`
- `assetMissing`
- `resourceMissing`
- `photoKitTransient`
- `iCloudTransient`
- `unknown`

Persisted retry-state sketch:

```swift
struct AutoSyncRetryState: Codable {
  /// Nested key is `ExportVariant.rawValue` so the persisted JSON shape stays explicit.
  var entriesByAssetId: [String: [String: RetryEntry]]
}

struct RetryEntry: Codable, Equatable {
  let category: AutoSyncFailureCategory
  let errorSignature: String
  let attemptCount: Int
  let firstFailedAt: Date
  let lastFailedAt: Date
  let nextEligibleAt: Date?
}
```

Retry counts are scoped to `assetId + variant + category + errorSignature`. A materially different error signature resets the retry entry so a resolved disk-space error does not keep blocking a later transient PhotoKit failure.

Initial automatic retry policy:

- Retry `photoKitTransient`, `iCloudTransient`, and `unknown` with exponential backoff.
- Retry `destinationUnavailable` only after destination availability changes to available.
- Do not automatically retry `destinationPermission`, `destinationNoSpace`, `assetMissing`, or stable `resourceMissing` until the user runs a manual retry or the relevant state changes.
- Cap automatic attempts per asset/variant/error signature.
- Persist retry state per destination and asset variant.

Manual "Retry Failed" or normal manual export can override backoff.

Retry evaluation belongs at enqueue time. The export runner should ask whether each missing asset/variant is currently eligible before creating a job; ineligible variants count as `skippedCount` with a retry reason in the run summary. This keeps auto-sync from starting a run that only churns known blocked failures.

## Dirty State

Persist per-destination dirty state so accumulated work survives interruption, restart, and disable/enable cycles.

Persisted shape:

```swift
struct AutoSyncDirtyState: Codable {
  /// Asset IDs that have a pending targeted re-evaluation for this destination/selection.
  /// Bounded by the targeting cost cap; collapses to `pendingFullReconciliation = true` when
  /// adding the next ID would exceed the cap. Inline-bounded so memory and disk size stay
  /// bounded during long unmounts.
  var pendingAssetIds: Set<String>

  /// True when a token-expired/details-unavailable fallback or an over-cap targeted set
  /// requires a bounded full library reconciliation for this destination/selection.
  var pendingFullReconciliation: Bool

  /// Persistent change token observed at the time of the most recent durable record. Used to
  /// detect whether the dirty set is consistent with the current global token position when
  /// auto-sync resumes.
  var tokenAtRecord: Data?

  var lastUpdatedAt: Date
}
```

Bookkeeping rules:

- Adding an asset ID checks the targeting cost cap inline. If it would exceed, the manager replaces the set with `pendingFullReconciliation = true` and clears `pendingAssetIds`.
- A successful targeted run removes its asset IDs from the set on completion, and only records token advancement after dirty state has been written.
- A successful full reconciliation clears both `pendingAssetIds` and `pendingFullReconciliation`.
- A manual full export for the same destination/selection clears compatible dirty flags as part of the existing pending-reason expiry rules.
- Persistent change events that arrive while the destination is unavailable accumulate into `pendingAssetIds`, with the inline cap rule still applying.
- Switching the selected destination retains the previous destination's dirty state. The state is GC'd only when the destination's record store is deleted or the user explicitly clears auto-sync state from settings.

## Multi-Instance and Locking

Auto-sync should add locking before automatic writes.

Required locks:

- a per-record-store advisory lock around JSONL append/snapshot/compaction,
- a destination-level advisory lock such as `.photo-export.lock` under the selected export root while an export run is active.

The destination lock reduces duplicate-output risk across:

- two instances of the same app,
- direct and App Store builds pointed at the same destination,
- a future helper plus main app.

If the destination lock cannot be acquired, auto-sync enters `blocked(otherExporterActive)` and retries later. Manual export should show a clearer message.

Locking design:

- Prefer POSIX advisory locks (`flock`/`fcntl`) on open file descriptors held for the lifetime of the critical section. Do not use `NSDistributedLock`; stale lock files are too easy to misinterpret.
- The record-store lock lives under the app-support record-store directory and is held for each append/compaction operation.
- The destination lock lives under the selected export root, is acquired under security-scoped access, and is held for the whole export run.
- Write diagnostic metadata into the destination lock file before locking or immediately after acquiring it: app bundle id, process id, run id, destination id, and timestamp. This is for user support only; the advisory lock is the authority.
- If the process dies, the OS releases the advisory lock. A leftover lock file without an active lock must not block future exports.
- Manual export and import should obey the same destination lock policy so automatic and manual paths have one concurrency model.

## Persistence Keys

Use namespaced keys/file names and separate global from destination-scoped state.

Global `UserDefaults`:

- `AutoSync.enabled`

Global App Support:

- `AutoSync.lastGlobalStateVersion`
- `AutoSync/photo-library-change-token.data`

Per-destination App Support state:

- `AutoSync.destinations.<destinationId>.safetyRecord`
- `AutoSync.destinations.<destinationId>.lastRunSummary`
- `AutoSync.destinations.<destinationId>.retryState`
- `AutoSync.destinations.<destinationId>.dirtyState`

This avoids immediate migration work if per-destination auto-sync preferences are added later. The user preference lives in `UserDefaults`; persistence-critical tokens, safety records, retry state, and run metadata live in App Support.

## Power and iCloud Behavior

The current resource writer sets `PHAssetResourceRequestOptions.isNetworkAccessAllowed = true`, and auto-sync should keep that behavior.

MVP behavior:

- automatic export is allowed to download originals from iCloud,
- do not gate on Wi-Fi, cellular/hotspot detection, or destination type,
- explain in settings/docs that automatic export may download iCloud originals,
- do not prevent system sleep,
- use `ProcessInfo.beginActivity(options: [.background, .suddenTerminationDisabled], reason:)` only while an automatic export is active, and always end the activity.

Future optional preferences can tune timing, power, or quiet hours, but they are not required for correctness.

## Implementation Steps

### Phase 0: Safety and Export Foundations

- Implement stable destination fingerprint and explicit legacy bookmark-hash store migration.
- Make destination-change handling fingerprint-aware so same-destination bookmark refreshes do not call `cancelAndClear()` or reconfigure the store.
- Implement destination safety scan and persisted confirmation/import state.
- Add record-store and destination-level advisory locks with stale-file-safe semantics.
- Make manual export and `startImport()` acquire the same destination lock policy as auto-sync.
- Define and implement the single-active-run ownership model for `runExport`.
- Add awaitable `runExport(context:) async -> ExportRunSummary`.
- Add `ExportRunContext`, `ExportRunSource`, `ExportRunVisibility`, and `ExportRunSummary`.
- Keep manual `startExportAll()` as a user-visible wrapper.
- Add targeted export scope for explicit asset IDs.
- Add destination-loss interruption that records dirty state and starts a fresh reconciliation after the destination returns.

### Phase 1: Photos Change Tracking

- Add persistent-change token storage.
- Add a `PhotoLibraryPersistentChangeEvent` publisher/source.
- Classify asset inserted/updated/deleted ID sets without assuming update semantics.
- Add targeted `.assets(ids)` scheduling with a threshold before full reconciliation.
- Add token-expired/details-unavailable fallback to bounded full reconciliation.
- Add storm control: dirty flag, debounce, min interval for full reconciliation.
- Add limited-access status copy/state.

### Phase 2: AutoSync State Machine

- Add protocol-backed `AutoSyncManager`.
- Implement `AutoSyncState`, reasons, reducer, and effect outputs.
- Subscribe to destination, Photos, export, import, and version-selection state through `attach(to:)`.
- Persist global and destination-scoped auto-sync state with namespaced keys.
- Add unit tests for reducer transitions and effect decisions.

### Phase 3: Retry and Run Policy

- Add failure categories or retry-state mapping.
- Implement automatic retry backoff.
- Define manual retry override.
- Ensure auto-sync empty runs update `lastRunSummary` but do not show toolbar empty-run messages.
- Ensure manual full export clears compatible pending auto-sync work.

### Phase 4: App Bootstrap and UI

- Move store configuration out of view `.task` into a one-time app lifecycle coordinator.
- Instantiate and attach `AutoSyncManager` once.
- Add settings UI for enable/disable and status.
- Show concise status: waiting, scheduled, blocked, running, last run.
- Keep toolbar controls manual-first.
- Add a required explicit `Run Auto-Sync Now` action in settings, a menu command, or both. This is the user-facing path for bypassing disabled state, debounce, and transient retry timers while still honoring safety and hard blockers.

### Phase 5: Verification and Docs

- Unit tests:
  - disabled auto-sync never runs,
  - unsafe destination blocks automatic runs,
  - stale bookmark re-save does not orphan the record store when fingerprint matches,
  - same-fingerprint bookmark refresh does not cancel active work,
  - legacy bookmark-hash store migrates by computing the old hash from saved bookmark data,
  - legacy/stable store conflict surfaces a recoverable blocked state,
  - manual export supersedes an active auto-sync run with a clear cancel reason,
  - `runNow()` bypasses debounce/enable state but honors safety and hard blockers,
  - destination false-to-true schedules one run,
  - collection-only Photos changes do not run export,
  - asset inserted/updated changes schedule targeted asset re-evaluation,
  - targeted IDs above the threshold/cost limit collapse to bounded full reconciliation,
  - token-expired fallback is bounded,
  - Photos changes while destination is unavailable are durably accumulated and exported after reconnect,
  - Photos changes coalesce,
  - import/manual export blocks auto-sync and re-evaluates later,
  - version-selection change schedules work,
  - failed variants respect retry backoff,
  - destination-unavailable interrupts auto-sync with dirty state, not `cancelAndClear()`,
  - record-store/destination lock contention blocks auto-sync.
- Manual tests:
  - app launch with available destination,
  - app launch with disconnected destination, then reconnect drive,
  - stale bookmark restore,
  - existing non-empty backup with no records,
  - add/import a new photo while app is running,
  - toggle album order or collection metadata in Photos and verify no export run,
  - toggle a favorite or other asset metadata and verify at most targeted re-evaluation with no file writes when records are already complete,
  - disconnect drive mid-export, reconnect, and verify a fresh reconciliation exports remaining work,
  - toggle include-originals before auto-sync,
  - limited Photos authorization,
  - iCloud-only asset export.
- Build:
  - `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
  - `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`

When behavior changes, update:

- root `README.md`,
- `website/src/content/docs/features.md`,
- `website/src/content/docs/getting-started.md`,
- `website/src/content/docs/roadmap.md` if this replaces or refines a roadmap item.

## Open Risks To Resolve Before Implementation

- Validate destination fingerprint behavior on at least APFS internal storage, APFS external storage, exFAT external storage, and a network/shared folder if the app allows selecting one. If persistent volume UUID plus relative path are not available on common external formats, the fallback/confirmation UX becomes part of the MVP.
- Define the error-category mapping table from `FileManager`, `PHAssetResourceManager`, security-scope, and PhotoKit errors to retry categories before implementing backoff. A vague `unknown` bucket should be temporary, observable, and capped.
- Benchmark targeted asset re-evaluation against full reconciliation before choosing the targeted/full cutoff. The threshold must be a tunable constant with telemetry/logging, not an unexplained number.
- Decide how targeted export handles assets without `creationDate`. The current year/month export path effectively skips them; targeted auto-sync should either preserve that behavior with an explicit `skippedCount` reason or introduce a separate fallback folder as a deliberate product change.
- Confirm advisory-lock behavior in sandboxed direct and App Store builds. The destination lock is only useful if both builds can create and lock the same `.photo-export.lock` file under security-scoped access.
- Validate `ProcessInfo.beginActivity` options under real long iCloud downloads. It should reduce sudden termination during active export without promising sleep prevention.
- App Store review may ask for clarifying settings copy about what "automatic export" does and when. Opt-in plus existing Photos and user-selected entitlements should make this defensible, but budget time for review questions.

## MVP Acceptance Criteria

- Enabling auto-sync cannot create duplicate exports solely because a bookmark was refreshed.
- An existing non-empty backup with no matching records cannot auto-export until imported or confirmed.
- A Photos asset insert/update while the app is running schedules a targeted re-evaluation when the ID set is bounded.
- A Photos asset inserted while the app was closed is detected on next launch through the saved persistent-change token or the bounded full-reconciliation fallback.
- A collection-only Photos change does not schedule export.
- A token-expired or too-large change batch schedules at most one bounded full reconciliation in the configured interval.
- Disconnecting the destination during an auto-sync run records transient interruption and dirty state instead of converting every remaining job into permanent failures.
- Auto-sync exposes a current state and persisted per-destination last-run summary without hijacking manual toolbar messages.
- Manual full export clears compatible pending auto-sync work for the same destination and selection.
- Direct and App Store builds pointed at the same destination cannot write concurrently.
- A failure categorized as `destinationPermission` or `destinationNoSpace` is not retried automatically until the user takes an explicit action or the relevant state changes.
- A manual export requested during an auto-sync run supersedes the auto-sync run; the summary records that cancellation reason and jobs from both runs are not mixed.

## Complexity Estimate

Simple auto-sync MVP after review:

- Phase 0 foundations: 1-2 weeks,
- Photos persistent changes and storm control: 2-4 days,
- state machine and tests: 2-3 days,
- retry/backoff: 1-2 days,
- UI/bootstrap/docs: 1-2 days.

Total: roughly 3-4 engineering weeks for a careful implementation. If stable destination identity migration or advisory locking reveals signing/sandbox surprises, expect closer to 5 weeks.

The original 4-7 day estimate is only realistic for a naive "debounced `startExportAll()`" implementation. That version is not recommended.

## High-Level Plan: True Closed-App Background Sync

### Feasibility

Possible, but not with `BGTaskScheduler` on macOS. The supported macOS mechanisms are:

- launch the main app at login with `SMAppService.mainApp`,
- bundle a login item helper app,
- bundle a LaunchAgent and register it with `SMAppService.agent(plistName:)`,
- use launchd keys such as `StartOnMount` to wake the agent on filesystem mounts.

### Recommended Path

Do not build this first. Ship simple auto-sync, gather behavior data, then decide which level is needed.

Escalation options:

1. **Launch main app at login**
   - Lowest complexity.
   - Uses `SMAppService.mainApp`.
   - The app can auto-sync after login and while still running.
   - Does not help if the user explicitly quits the app.

2. **Login item helper**
   - Medium complexity.
   - Helper stays alive after login, monitors destination availability, and launches/signals the main app.
   - Better UX than a full LaunchAgent for a user-facing app.
   - Requires shared settings and careful user approval/status handling.

3. **LaunchAgent with `StartOnMount`**
   - Highest practical complexity for this app.
   - Agent wakes on every filesystem mount, filters for the selected destination, then launches/signals the main app.
   - Requires `SMAppService.agent(plistName:)`, bundled launchd plist, code signing, re-registration on updates, and Login Items approval.

Avoid a LaunchDaemon. Photos access and user-selected destinations are per-user, privacy-scoped workflows; root/system-level background work is the wrong fit.

### Architecture Work Required

- Add an App Group for shared preferences, bookmarks, and record-store state.
- Prefer helper-wakes-main-app first; avoid direct Photos export in the helper until signed/sandboxed Photos and bookmark behavior is proven.
- If the helper ever exports directly, move export orchestration into shared code and use the same destination/record-store locks.
- Give the helper the right sandbox, Photos, bookmark, and app-group entitlements.
- Register/unregister the helper through `SMAppService`.
- Add status handling for `.enabled`, `.requiresApproval`, `.notRegistered`, and `.notFound`.
- Add UI that explains why background permission is needed and opens System Settings Login Items when approval is required.
- Add XPC or another narrow IPC mechanism if the helper signals the main app.
- Handle app updates: launch agents must be re-registered if the plist or executable changes.
- Build CI/signing changes for both direct distribution and App Store builds.

### Closed-App Sync Risks

- App Store review sensitivity around persistent background behavior.
- Helper and main app can race on the same export record files unless locking is in place.
- Security-scoped bookmark access across processes must be tested under sandboxed, signed builds.
- The helper may not have the same Photos authorization behavior as the main app.
- `StartOnMount` fires for every mounted filesystem, so filtering and debouncing are mandatory.
- If the helper launches the full app invisibly, users need an obvious way to understand and stop that behavior.

### Complexity Estimate

True closed-app background sync:

- launch-at-login main app: 2-4 days,
- login item helper that wakes/signals the app: 1-2 weeks,
- LaunchAgent with mount wakeup and helper-mediated sync: 2-4 weeks.

The large variance comes from signing, App Group migration, sandbox verification, and deciding how much export logic runs outside the main app process.

## References

- Apple Developer: `SMAppService` for login items, LaunchAgents, and LaunchDaemons.
- Apple Developer: `NSWorkspace.didMountNotification` and `NSWorkspace.didUnmountNotification`.
- Apple Developer: `PHPhotoLibraryChangeObserver`.
- Apple Developer: `PHPhotoLibrary.currentChangeToken` and `fetchPersistentChanges(since:)`.
- Apple Developer: macOS App Sandbox file access and security-scoped bookmarks.
- Local macOS SDK headers: `BackgroundTasks.framework` marks `BGTaskScheduler` and related task requests unavailable on macOS.
- `man launchd.plist`: `StartOnMount` starts a job every time a filesystem is mounted.
