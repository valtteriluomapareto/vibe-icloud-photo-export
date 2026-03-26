# Refactoring Plan

## Context

This is a ~2,750-line solo macOS app with 15 Swift source files. The plan is sized accordingly: fix real bugs, clean up dead code, and make targeted improvements. No architecture astronautics.

The project uses **Swift Testing** (not XCTest) and **Swift 5**. There is currently no `.xctestplan` file — the scheme uses the `<Testables>` model directly.

## Completed Work

Phases 1–3 are done. Summary of what shipped:

- **Phase 1 — Bug fixes:** double-resume crash in `requestFullImage`, thread-unsafe `loadThumbnail` guard, temp file leak on export failure, `.limited` auth mapping, double security-scope in `urlForMonth`, fallback `PhotoLibraryManager()` in MonthContentView, stale-task guard in ExportManager.
- **Phase 2 — Dead code removal:** removed `TestPhotoAccessView`, `InfoPlist.swift`, `AssetMetadata`, unused fetch methods, deprecated `MainView` struct, empty test stub.
- **Phase 3 — Concurrency prep:** added `@MainActor` to PhotoLibraryManager, shared `MonthFormatting` helper.

## Non-Bugs Removed from Scope

These were considered and explicitly rejected:

- **State machine for ExportManager** — the sequential queue works. Bugs were fixed directly.
- **Domain wrappers (`ExportableAsset`, `resourceToken`)** — the code already passes `localIdentifier` strings via `ExportJob`.
- **`PhotoLibraryService` as a separate type** — one consumer, no polymorphism benefit.
- **Destination type split** — `ExportDestinationManager` does its job at 293 lines.
- **`SidebarViewModel` extraction** — moving code between files doesn't reduce complexity.
- **CI concurrency baseline enforcement** — solo project. When Swift 6 arrives, the compiler will flag issues.
- **Characterization tests before rewrite** — there is no rewrite.

---

## Phase 4: Test Infrastructure (Optional) — NOT STARTED

These steps add test seams for the export path. Phase 1 tests validate fix logic in isolation. Phase 4 provides end-to-end coverage through the actual ExportManager code paths by making dependencies injectable.

### 4.1 — Add `FileIOProviding` protocol

**New file**: `photo-export/Protocols/FileIOProviding.swift`

```swift
protocol FileIOProviding {
    func moveItemAtomically(from src: URL, to dst: URL) throws
    func applyTimestamps(creationDate: Date, to url: URL)
}
```

Make `FileIOService` conform. Change `ExportManager` to accept `FileIOProviding` (defaulting to `FileIOService` in production).

### 4.2 — Add `ResourceWriting` protocol

**New file**: `photo-export/Protocols/ResourceWriting.swift`

Wraps `PHAssetResourceManager.writeData(for:toFile:options:)`. Allows injecting a mock that writes known bytes to a temp file.

### 4.3 — ExportManager failure path tests

**New file**: `photo-exportTests/ExportManagerFailurePathTests.swift`

With the seams from 4.1 and 4.2, test:
- Temp file is cleaned up after write failure
- Temp file is cleaned up after move failure
- Failed export is recorded in the store
- Generation guard prevents stale `processNext()` calls
