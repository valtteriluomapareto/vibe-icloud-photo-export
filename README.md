# Photo Export (macOS)

A macOS app to back up the Apple Photos library to local or external storage, exporting assets into an organized folder hierarchy.

- App target: `photo-export`
- Unit tests: `photo-exportTests`
- UI tests: `photo-exportUITests` (currently skipped by default)
- Shared scheme: `photo-export`

See `IMPLEMENTATION_TASKS.md` for open work and `IMPLEMENTED_FEATURES.md` for completed features.

---

## Prerequisites

- macOS (latest stable; project currently targets macOS 15.x)
- Xcode 16.x (includes `xcodebuild`)
- CocoaPods/SwiftPM: not required (uses system frameworks only)

Optional:
- `xcpretty` for nicer CLI output (`gem install xcpretty`)

---

## Project Layout

- `photo-export/` — App sources (Swift, SwiftUI)
- `photo-exportTests/` — Unit tests
- `photo-exportUITests/` — UI tests
- `SWIFT_SWIFTUI_BEST_PRACTICES.md` — Code style and patterns
- `IMPLEMENTATION_TASKS.md` — Open tasks
- `IMPLEMENTED_FEATURES.md` — Completed features
- `FUTURE_ENHANCEMENTS.md` — Non-MVP ideas

---

## Permissions and First Run

The app uses the Photos framework. On first run, macOS will prompt for Photos library access. If access is denied, the app should handle it gracefully (see best practices doc). You can change permissions in System Settings → Privacy & Security → Photos.

---

## Build from Command Line

From the repository root:

```bash
# Clean, then build Debug for macOS
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  clean build
```

Notes:
- Use `-configuration Release` for release builds.
- On Apple Silicon, you can be explicit with `-destination 'platform=macOS,arch=arm64'`.

### Standalone Release build (runnable outside Xcode)

```bash
# Build a Release app bundle to ./build
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  clean build

# Launch the built app (no Xcode needed)
open build/Build/Products/Release/photo-export.app
```

> To distribute to other Macs, sign with Developer ID and notarize. See `PUBLIC_DEPLOYMENT_PLAN.md`.

---

## Run Tests from Command Line

Run unit tests (UI tests are skipped by default in the shared scheme):

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  test
```

Run a single unit test case (example):

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  -only-testing:photo-exportTests/ExportRecordStoreTests \
  test
```

Optional pretty output:

```bash
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' test | xcpretty
```

---

## Running the App

From Xcode: open the project and run the `photo-export` scheme.

From CLI (launch after build):

```bash
open photo-export.xcodeproj
```

Then press Run in Xcode. Command-line launching of the built app is also possible after locating the `.app` in `DerivedData`, but running via Xcode is recommended for debugging and permissions prompts.

---

## Development Workflow

- Follow `SWIFT_SWIFTUI_BEST_PRACTICES.md` for architecture, concurrency, Photos framework usage, and error handling.
- Keep view logic slim; move side-effects to managers and view models.
- Log with `os.Logger`. Avoid `print` in production code.
- Prefer `.task(id:)` for cancellation-aware loading.
- Track exports by `PHAsset.localIdentifier` and avoid overwrites.

---

## Troubleshooting

- Code signing: set to Automatic; no special provisioning is needed for local development.
- Photos access denied: update permissions in System Settings; ensure app handles denial gracefully.
- UI tests and permissions: UI tests are currently skipped by default in the shared scheme.
- Schemes: list available schemes if needed:

```bash
xcodebuild -list -project photo-export.xcodeproj
```

---

## License

Internal project. No public license specified.
