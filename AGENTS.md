# AGENTS.md

Guidance for any AI coding agent working in this repository. Humans should read [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`docs/README.md`](docs/README.md) instead — those are the sources of truth for contributor workflow and where docs live.

If your harness loads a tool-specific file (such as `CLAUDE.md`), that file is a stub that points back here.

## Project Overview

macOS SwiftUI app that exports the Apple Photos library to local/external storage in an organized folder hierarchy. Uses system frameworks only (no CocoaPods/SwiftPM dependencies). Targets macOS 15.x with Xcode 16.x.

## Build & Test Commands

```bash
# Build (Debug)
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# Run all unit tests
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

# Run a single test class
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -only-testing:photo-exportTests/ExportRecordStoreTests CODE_SIGNING_ALLOWED=NO test

# Lint (use a workspace-local cache if your sandbox blocks ~/Library)
swiftlint --strict
swiftlint --strict --cache-path build/swiftlint-cache  # sandboxed alternative

# Format check / auto-fix
swift-format lint --recursive photo-export
swift-format format --recursive --in-place photo-export
```

UI tests exist in `photo-exportUITests/` but are skipped by default in the shared scheme.

## Architecture

**Pattern:** SwiftUI + Managers. Views are thin; logic lives in Managers and ViewModels.

Source code under `photo-export/` is organized as follows:

- `Managers/` — long-lived stateful services and pure helpers (see breakdown below)
- `Protocols/` — test seams: `PhotoLibraryService`, `AssetResourceWriter`, `FileSystemService`, `ExportDestination`. Add a new protocol here when you need to inject a fake.
- `Models/` — value types: `AssetDescriptor`, `AssetDetails`, `ExportRecord`, `ExportVariant`
- `Views/` — SwiftUI views (see list below)
- `ViewModels/` — `MonthViewModel`
- `Helpers/` — small pure utilities (`MonthFormatting`)
- `Resources/`, `SupportingFiles/`, `Assets.xcassets` — bundle resources, Info.plist, asset catalog

**App entry point** (`photo_exportApp.swift`): creates four `@StateObject` dependencies and injects them as `@EnvironmentObject` into the view hierarchy:

- **PhotoLibraryManager** — Photos framework authorization and asset fetching (thumbnails, full-size images). Uses `PHCachingImageManager`.
- **ExportDestinationManager** — manages the chosen export destination folder (security-scoped bookmarks).
- **ExportRecordStore** — tracks which assets have been exported per-destination to avoid duplicates and support resume. Reconfigures when destination changes.
- **ExportManager** — orchestrates the export queue (enqueue/pause/cancel/resume). Depends on the other three managers.

**Other code under `Managers/`:**

- `BackupScanner` — scans an existing backup folder and matches files to Photos assets (used by Import Existing Backup)
- `ExportFilenamePolicy` — pure rules for `_orig` companion filenames
- `ResourceSelection` — picks the byte source for an edited variant via the `EditedProducer` enum
- `ProductionAssetResourceWriter` — production implementation behind the `AssetResourceWriter` seam
- `ProductionMediaRenderer` — production implementation behind the `MediaRenderer` seam (edited videos)
- `FileIOService` — atomic file moves and timestamp handling (conforms to `FileSystemService`)

### Design Decisions Worth Knowing

- **Edited video export goes through `PHImageManager.requestExportSession` + `AVAssetExportSession`, not `PHAssetResource`.** PhotoKit does not pre-render edited videos as static resources, so resource enumeration finds nothing and the render path is the only way to materialise the user-visible bytes.
- **Byte-source dispatch lives in `ResourceSelection.selectEditedProducer` as a single enum** (`.resource | .render | .none`). `ExportManager` switches on that and never inlines media-kind-specific branches. Widening the render path to a new media kind is an enum-extension change in one place rather than a new boolean scattered through the pipeline.

**Views** (`photo-export/Views/`): `ContentView` is a `NavigationSplitView` with year/month sidebar. `MonthContentView` shows thumbnails for a month (each thumbnail rendered by `ThumbnailView`). `ExportToolbarView` shows export controls. `OnboardingView` handles first-run flow. `AssetDetailView` shows full-size preview. `ImportView` runs the Import Existing Backup flow. `AboutView` is the in-app about box.

**ViewModels** (`photo-export/ViewModels/`): `MonthViewModel` manages asset loading for a selected month.

## Documentation Layout

The canonical map of where docs live is [`docs/README.md`](docs/README.md). Quick reference:

- **User-facing docs** — `website/src/content/docs/` (Astro + Starlight site). Run with `cd website && npm install && npm run dev`.
- **Maintainer notes and plans** — `docs/project/`. Index in `docs/README.md`.
- **Reference material** (best practices, persistence format) — `docs/reference/`.
- **Roadmap** — only on the website (`website/src/content/docs/roadmap.md`). Do not duplicate elsewhere.

When changing user-visible behavior, update both the root `README.md` and the matching website page. The map of behavior → page is in `docs/README.md`.

## Workflow

- Open an issue or draft PR before a large feature or architecture change.
- After a non-trivial change, run a code review pass before requesting human review. If your harness exposes a slash-command or subagent for AI review (e.g. `/codex-review`, `/review`), use it; otherwise re-read your own diff against [`docs/reference/swift-swiftui-best-practices.md`](docs/reference/swift-swiftui-best-practices.md) and the conventions below.
- **Releasing:** always run `scripts/bump-version.sh <version>` before pushing a tag. Pushing a `v*` tag triggers both release pipelines (`release-direct.yml` and `release-app-store.yml`) and they validate that the tag matches `MARKETING_VERSION`. See [`docs/project/release-process.md`](docs/project/release-process.md).

## Key Conventions

- Log with `os.Logger` (subsystem `com.valtteriluoma.photo-export`), not `print`.
- The four UI-injected managers (`PhotoLibraryManager`, `ExportManager`, `ExportRecordStore`, `ExportDestinationManager`) are `@MainActor`. Pure helpers under `Managers/` (`FileIOService`, `ExportFilenamePolicy`, `ResourceSelection`, `ProductionAssetResourceWriter`, `BackupScanner`) are plain types — do not add `@MainActor` reflexively.
- Track exports by `PHAsset.localIdentifier`; never overwrite existing files.
- Use `.task(id:)` for cancellation-aware async loading in views.
- New code that touches Photos, the filesystem, or the export destination should go through the `Protocols/` seams so it can be unit-tested with fakes.
- SwiftLint config (`.swiftlint.yml`): line length 140, several rules disabled (see file). CI runs `--strict`.
- swift-format config (`.swift-format.json`): 4-space indentation, 120-char line length.
- Website uses Prettier (with `prettier-plugin-astro`) and oxlint. Run `npm run format:check` and `npm run lint` from `website/`. Both are enforced in CI.
