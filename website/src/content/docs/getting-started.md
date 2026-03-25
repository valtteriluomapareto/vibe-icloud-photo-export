---
title: Getting Started
description: How to build and run Photo Export on your Mac.
---

Photo Export is a native macOS app that backs up your Apple Photos library to local or external storage. It uses system frameworks only — no CocoaPods, no SwiftPM dependencies.

## Prerequisites

- **macOS 15.0+** (latest stable release)
- **Xcode 16.x** (includes `xcodebuild`)

Optional tools for development:

- [SwiftLint](https://github.com/realm/SwiftLint) — `brew install swiftlint`
- [swift-format](https://github.com/swiftlang/swift-format) — `brew install swift-format`
- [xcpretty](https://github.com/xcpretty/xcpretty) — `gem install xcpretty`

## Build from source

Clone the repository and build with Xcode:

```bash
git clone https://github.com/valtteriluomapareto/vibe-icloud-photo-export.git
cd vibe-icloud-photo-export
```

**Option A: Open in Xcode**

```bash
open photo-export.xcodeproj
```

Then press Run (Cmd+R) with the `photo-export` scheme selected.

**Option B: Build from the command line**

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

### Standalone Release build

To build a runnable `.app` bundle outside of Xcode:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  clean build

# Launch the built app
open build/Build/Products/Release/photo-export.app
```

## Permissions and first run

On first launch, macOS will prompt for **Photos library access**. The app needs read access to browse and export your photos.

If you deny access, the app handles it gracefully and shows guidance. You can change permissions later in **System Settings → Privacy & Security → Photos**.

## Running tests

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  test
```

Run a single test class:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  -only-testing:photo-exportTests/ExportRecordStoreTests \
  test
```
