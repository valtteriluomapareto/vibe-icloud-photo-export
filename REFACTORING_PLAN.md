# Photo Export — Refactoring Plan (v10)

## Context

This plan prioritizes correctness, strict-concurrency pre-adaptation, and executable verification with proportionate process for a solo project.

Primary goals:
1. Pre-adapt to Swift 6 strict-concurrency constraints now.
2. Preserve export correctness (no silent data loss, no duplicate queue effects).
3. Keep high-risk changes testable at the point they are introduced.

## Locked Decisions

- Authorization revocation policy: pause queue and require explicit re-auth resume.
- `PhotoLibraryManager` becomes and remains `@MainActor`.
- Nonisolated protocols expose only Sendable/domain wrappers (no `PHAsset` / `PHAssetResource` in protocol signatures).
- Export queue uses one serialized state owner plus run-generation guard.
- Destination dependency is split into:
  - `@MainActor` control plane (selection/UI state)
  - nonisolated export session API for export-time operations
- Security-scoped access is balanced through one API boundary (`withExportScope`) in export pipeline code.
- `resourceToken` remains ephemeral and in-memory only for now (no structured/versioned persistence work in this plan).
- Characterization tests must pass before `ExportManager` rewrite.

---

## Toolchain + Baseline Prerequisites

### P0.1 — Toolchain and test plan pinning

**Requirements**:
- Pin CI toolchain to one exact version (for example, Xcode 15.3).
- Use checked-in test plan:
  - `photo-export.xcodeproj/xcshareddata/xctestplans/photo-export.xctestplan`

**Exit criteria**:
- CI and local test commands run through the same `.xctestplan`.

### P0.2 — Strict-concurrency baseline policy

**Files**:
- `photo-export.xcodeproj/project.pbxproj`

**Changes**:
1. Keep `SWIFT_VERSION = 5.0` for now.
2. Enable strict concurrency diagnostics in Debug/Test configs.
3. Record baseline warnings from a clean build.
4. Add CI check: fail on any new concurrency warning identity (file/line/diagnostic), not just count.

**Exit criteria**:
- Baseline recorded.
- CI enforces no-new-warning policy.

### P0.3 — Mandatory actor isolation correction + compile-order dependency fix

**Files**:
- `photo-export/Managers/PhotoLibraryManager.swift`
- `photo-export/Views/MonthContentView.swift`

**Changes**:
1. Add class-level `@MainActor` to `PhotoLibraryManager`.
2. Remove fallback `PhotoLibraryManager()` construction path from `MonthContentView` immediately in this step.
3. Apply required call-site actor hops/async fixes.

**Reason**:
- This avoids the known compile break if fallback removal is delayed to later cleanup.

**Exit criteria**:
- Build passes with `@MainActor` annotation and no fallback construction path.

### P0.4 — Test seams required for early bug-fix verification

**Files**:
- `photo-export/Managers/ExportManager.swift`
- `photo-export/Managers/PhotoLibraryManager.swift`
- `photo-export/Managers/FileIOService.swift`
- `photo-export/Protocols/*.swift` (new)

**Add seams**:
1. `FileIOProviding` for move/timestamp/temp checks.
2. `ImageRequesting` for `PHImageManager.requestImage`.
3. `ResourceWriting` for `PHAssetResourceManager.writeData`.
4. Destination seam protocols with final intended shape now (not redefined later):
   - `@MainActor ExportDestinationControlProviding`
   - nonisolated `ExportDestinationSessionProviding` with `withExportScope(...)`.

**Exit criteria**:
- Phase 1 deterministic tests are implementable without Photos mocking hacks.
- Add seam smoke suite: `photo-exportTests/TestSeamContractTests`.

### P0.5 — ExportRecordStore strict-concurrency cleanup

**Files**:
- `photo-export/Managers/ExportRecordStore.swift`
- `photo-exportTests/ExportRecordStoreTests.swift`

**Changes**:
1. Replace `DispatchQueue.main.asyncAfter` coalescing with Task-based flow plus injected debounce/clock seam.
2. Remove `@MainActor` captures in `ioQueue.async` closures via nonisolated helper boundaries.
3. Replacement pattern: perform IO in nonisolated helpers, then marshal state updates back via `await MainActor.run`.
4. Make debounce and compaction threshold injectable.

**Exit criteria**:
- No new strict-concurrency warnings in ExportRecordStore path.
- Store tests are deterministic without wall-clock sleep assumptions.

---

## Phase 1: Critical Correctness Fixes (Fully Testable)

### 1.1 — Continuation resume race-safety for all `PHImageManager` callbacks

**File**: `photo-export/Managers/PhotoLibraryManager.swift`

**Scope**:
- `loadThumbnail(...)` and `requestFullImage(...)`.

**Problem**:
- Both currently rely on plain boolean resume guards that are race-prone under concurrent callback delivery.

**Fix**:
- Use lock/atomic gate (`OSAllocatedUnfairLock<Bool>` or equivalent) around terminal resume decision in both methods.

**Test gate**:
- `photo-exportTests/PhotoLibraryManagerImageRequestTests`
- Assertions:
  - opportunistic/degraded/final/error callback permutations still cause exactly one terminal resume.

### 1.2 — Temp cleanup on export failure (assert outcomes, not attempts)

**File**: `photo-export/Managers/ExportManager.swift`

**Fix**:
1. Cleanup ownership is `defer` while export scope is active.
2. Validate postcondition: `.tmp` file absent after write/move/timestamp/cancel failures.

**Test gate**:
- `photo-exportTests/ExportManagerFailurePathTests`

### 1.3 — Crash-safe compaction + restart recovery validation

**File**: `photo-export/Managers/ExportRecordStore.swift`

**Fix**:
- Existing snapshot: `replaceItemAt`.
- First snapshot: `moveItem`.
- Add fault-injection seams around compaction boundaries.

**Test gate**:
- `photo-exportTests/ExportRecordStoreCompactionTests`
- Assertions:
  - restart after injected failures recovers records correctly.
  - no snapshot loss window across replace/move/truncate boundaries.

### 1.4 — `AssetDetailView` export status wiring fix

**Files**:
- `photo-export/Views/TestPhotoAccessView.swift` (delete)
- `photo-export/Views/AssetDetailView.swift`
- `photo-export/ContentView.swift`

**Fix**:
1. Migrate to `@EnvironmentObject ExportRecordStore`.
2. Remove optional-chain calls (`exportRecordStore?.`) at call sites.
3. Remove dead custom `EnvironmentKey` path.

**Test gate**:
- `photo-exportTests/AssetDetailViewIntegrationTests`

### 1.5 — Authorization mapping correctness moved early

**Files**:
- `photo-export/Managers/PhotoLibraryManager.swift`
- `photo-export/ContentView.swift`

**Fix**:
- `.authorized` and `.limited` map to `isAuthorized == true`.
- Maintain `isLimited` explicitly for UI.

**Test gate**:
- `photo-exportTests/PhotoLibraryManagerAuthorizationTests`

---

## Phase 2: Dead Code Sweep (Single Proportionate Cleanup Step)

### 2.1 — Remove dead/unused paths in one commit

**Remove**:
- `fetchAssetsByYearAndMonth()`
- deprecated `MainView`
- `InfoPlist.swift`
- `AssetMetadata` + `extractAssetMetadata()`
- unused `isShowingAuthorizationView`
- empty test stub `photo_exportTests.swift`

**Test gate**:
- build + targeted UI/view-model regression suites
- assertions:
  - no references to removed symbols
  - runtime behavior for month/detail views unchanged

---

## Phase 3: UI/VM Concurrency Hardening Only

### 3.1 — Shared month formatting helper

**New file**: `photo-export/Helpers/MonthFormatting.swift`

**Fix**:
- shared helper with static cached formatter.

### 3.2 — Extract sidebar orchestration to `SidebarViewModel`

**New file**: `photo-export/ViewModels/SidebarViewModel.swift`

**Fix**:
- mark `SidebarViewModel` as `@MainActor`.
- token/cancellation guards.
- local accumulation then single state commit.

### 3.3 — Deterministic out-of-order/cancel tests

**New file**: `photo-exportTests/SidebarViewModelTests.swift`

**Assertions**:
- stale tasks cannot mutate final state.
- canceled tasks commit nothing.

**Note**:
- `PhotoLibraryService.swift` is intentionally deferred to Phase 4.

---

## Phase 4: Protocol/Service Architecture Migration

### 4.1 — Domain wrappers + export protocol boundary

**Files**:
- `photo-export/Models/ExportableAsset.swift` (new)
- `photo-export/Protocols/PhotoLibraryExportProviding.swift` (new)

**Rule**:
- New protocol APIs return/accept wrapper types only.

**Test gate**:
- `photo-exportTests/ExportableModelMappingTests`

### 4.2 — Destination split implementation and scoped operation correctness

**Files**:
- `photo-export/Managers/ExportDestinationManager.swift`
- `photo-export/Managers/ExportManager.swift`

**API contract already introduced in P0.4**:

```swift
func withExportScope<T: Sendable>(
  year: Int,
  month: Int,
  operation: @Sendable (URL) async throws -> T
) async throws -> T
```

**Mandatory invariants**:
1. Scope closes even on thrown/cancelled operations.
2. `urlForMonth` no longer starts/stops security scope itself.
3. Heavy IO within operation is off-main.
4. Destination switch invalidates current run generation and prevents stale writes.

**Test gate**:
- `photo-exportTests/ExportDestinationSessionTests`

### 4.3 — `resourceToken` policy for ephemeral in-memory use

**Files**:
- `photo-export/Models/ExportableAsset.swift`
- `photo-export/Managers/PhotoLibraryService.swift`

**Policy**:
- Keep token format simple and explicit for in-memory handoff.
- No persistence/back-compat migration work in this plan.
- If token persistence is introduced later, add versioned format in that future change.

**Test gate**:
- `photo-exportTests/ResourceTokenRoundTripTests`
- plus negative corpus tests for malformed/unknown token inputs.

### 4.4 — Introduce `PhotoLibraryService` once with explicit ownership map

**File**: `photo-export/Managers/PhotoLibraryService.swift` (new)

**Ownership**:
- `PhotoLibraryManager` owns auth state and UI-facing authorization lifecycle.
- `PhotoLibraryService` owns export-oriented asset/resource access.
- Export path consumes only service protocols, not manager internals.

**Test gate**:
- `photo-exportTests/PhotoLibraryServiceContractTests`

### 4.5 — ExportManager characterization tests before rewrite

**File**:
- `photo-exportTests/ExportManagerCharacterizationTests.swift` (new)

**Purpose**:
- lock current queue/record behavior before rewrite.

**Gate**:
- Must pass before 4.6 starts.

### 4.6 — ExportManager state-machine migration (minimal, non-framework)

**File**: `photo-export/Managers/ExportManager.swift`

**Constraints**:
1. Single serialized owner with one ingress API (`send(event:)`).
2. Reducer implementation stays compact (target around 80 lines, no generic framework).
3. Run-generation stale completion guard retained.
4. State includes auth-blocked state explicitly; booleans derive from state.
5. `FileIOProviding` seam reused from P0.4.

**Test gate**:
- `photo-exportTests/ExportManagerStateMachineTests`

### 4.7 — Auth revoke behavior + deterministic dedupe

**File**: `photo-export/Managers/ExportManager.swift`

**Fix**:
- Stable job identity key: `(assetLocalIdentifier, year, month, destinationId)`.
- Revoke flow:
  1. cancel in-flight
  2. requeue only non-terminal interrupted job
  3. dedupe against pending keys
  4. enter blocked-by-auth state
- Resume flow must explicitly refresh auth and re-enter running only when authorized/limited.

**Test gate**:
- `photo-exportTests/ExportManagerAuthorizationBlockingTests`

### 4.8 — Composition root wiring

**File**: `photo-export/photo_exportApp.swift`

**Fix order**:
1. Wire protocol dependencies.
2. Wire auth refresh lifecycle hooks.
3. Route external signals through `send(event:)` entrypoint only.

**Test gate**:
- `photo-exportTests/AppCompositionIntegrationTests`

---

## Phase 5: Integration Verification

### 5.1 — Real filesystem export integration test

**New file**: `photo-exportTests/ExportFilesystemIntegrationTests.swift`

**Scope**:
- real `FileIOService`
- temp destination directory
- real bytes written and atomically moved
- timestamp application verified with filesystem-appropriate tolerance

---

## Mandatory Gate Matrix

All step commands use this base:

`xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export`

| Step | Required gate | Exact command | Key assertions |
|---|---|---|---|
| P0.1 | Test plan pinning | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export test` | command runs through pinned test plan |
| P0.2 | Concurrency baseline build | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' build` | baseline warnings recorded; CI no-new-warning check passes |
| P0.3 | Build gate | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' build` | `PhotoLibraryManager` main-actor + no fallback manager path |
| P0.4 | Seams smoke tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/TestSeamContractTests test` | new seams are injectable and callable from tests |
| P0.5 | Store determinism tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportRecordStoreTests test` | deterministic coalescing/compaction behavior |
| 1.1 | Image callback race tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/PhotoLibraryManagerImageRequestTests test` | exactly one terminal resume for both methods |
| 1.2 | Failure path tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportManagerFailurePathTests test` | temp absent + correct failed record |
| 1.3 | Compaction recovery tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportRecordStoreCompactionTests test` | restart recovery across fault boundaries |
| 1.4 | Wiring integration tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/AssetDetailViewIntegrationTests test` | export status visible via env object |
| 1.5 | Authorization mapping tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/PhotoLibraryManagerAuthorizationTests test` | `.limited` treated as authorized |
| 2.1 | Cleanup regression gate | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/AssetDetailViewIntegrationTests -only-testing:photo-exportTests/SidebarViewModelTests test` | no regressions from removals |
| 3.1 | Build gate | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' build` | shared month helper wired |
| 3.2 | Build + VM gate | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/SidebarViewModelTests test` | VM owns orchestration and main-actor state |
| 3.3 | Concurrency ordering tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/SidebarViewModelTests test` | stale/cancel safety |
| 4.1 | Wrapper mapping tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportableModelMappingTests test` | no Photos types in protocol boundaries |
| 4.2 | Destination session tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportDestinationSessionTests test` | scoped close + off-main IO + stale-run invalidation |
| 4.3 | Token tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ResourceTokenRoundTripTests test` | round-trip + malformed token handling |
| 4.4 | Service contract tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/PhotoLibraryServiceContractTests test` | ownership and wrapper contract hold |
| 4.5 | Characterization prereq | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportManagerCharacterizationTests test` | baseline locked before rewrite |
| 4.6 | State-machine tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportManagerStateMachineTests test` | transition legality + stale-ignore + idempotence |
| 4.7 | Auth-blocking tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportManagerAuthorizationBlockingTests test` | deterministic requeue + dedupe |
| 4.8 | Composition tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/AppCompositionIntegrationTests test` | single ingress wiring through `send(event:)` |
| 5.1 | Filesystem integration tests | `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export -only-testing:photo-exportTests/ExportFilesystemIntegrationTests test` | bytes/timestamps written correctly |

At end of each phase:

`xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -testPlan photo-export test`

---

## File Impact Summary (v10)

| File | Planned phases |
|---|---|
| `photo-export/Managers/PhotoLibraryManager.swift` | P0.3, P0.4, 1.1, 1.5 |
| `photo-export/Managers/ExportManager.swift` | P0.4, 1.2, 4.2, 4.6, 4.7 |
| `photo-export/Managers/ExportRecordStore.swift` | P0.5, 1.3 |
| `photo-export/Managers/ExportDestinationManager.swift` | 4.2 |
| `photo-export/Managers/PhotoLibraryService.swift` (new) | 4.3, 4.4 |
| `photo-export/Managers/FileIOService.swift` | P0.4 |
| `photo-export/Protocols/*.swift` (new) | P0.4, 4.1 |
| `photo-export/Models/ExportableAsset.swift` (new) | 4.1, 4.3 |
| `photo-export/Views/AssetDetailView.swift` | 1.4 |
| `photo-export/Views/MonthContentView.swift` | P0.3, 3.1 |
| `photo-export/Views/TestPhotoAccessView.swift` | 1.4 (delete) |
| `photo-export/ContentView.swift` | 1.4, 1.5, 2.1, 3.1, 3.2 |
| `photo-export/InfoPlist.swift` | 2.1 (delete) |
| `photo-export/Models/AssetMetadata.swift` | 2.1 (delete) |
| `photo-export/photo_exportApp.swift` | 4.8 |
| `photo-export/ViewModels/SidebarViewModel.swift` (new) | 3.2, 3.3 |
| `photo-exportTests/*` | P0.5, 1.x, 2.1, 3.3, 4.x, 5.1 |
