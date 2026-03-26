---
title: Getting Started
description: How to build and run Photo Export on your Mac.
---

Photo Export is a native macOS app that exports your Apple Photos library to local or external storage. The project currently targets people building from source with Xcode.

## Prerequisites

- **macOS 15.0+**
- **Xcode 16.2+**

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
  CODE_SIGNING_ALLOWED=NO \
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
  CODE_SIGNING_ALLOWED=NO \
  clean build

# Launch the built app
open build/Build/Products/Release/photo-export.app
```

## First launch

### 1. Grant Photos access

On first launch, macOS will prompt for **Photos library access**. Click **Grant Access** to allow the app to read your photo and video library.

If you choose **Select Photos**, the app will work with only the photos you pick. If you accidentally deny access, you can change permissions later in **System Settings → Privacy & Security → Photos**, or click the "Open System Preferences" button shown in the app.

### 2. Choose an export destination

An onboarding screen will guide you through selecting the folder where photos and videos will be exported. This can be:

- A folder on your Mac (e.g. Desktop, Documents, or a dedicated backup folder)
- An external USB or Thunderbolt drive
- A network volume (if mounted)

The folder needs to be writable. The app remembers your choice across launches using a security-scoped bookmark.

### 3. Start exporting

Once the destination is set, you'll see the main window with a **year/month sidebar** on the left and a **thumbnail grid** in the center. From here you can:

- Click a month to browse its photos
- Click **Export All** in the toolbar to queue the entire library
- Use **File → Import Existing Backup...** (Cmd+Shift+I) if you already have a previous export and want to avoid re-copying those files

Export progress is shown in the toolbar. You can pause, resume, or cancel at any time.

### Troubleshooting

- **"Export folder is not reachable"** — Check that the external drive is plugged in and mounted.
- **"Export folder is read-only"** — Right-click the folder, choose Get Info, and make sure you have write permission.
- **Photos permission denied** — Open **System Settings → Privacy & Security → Photos** and enable access for Photo Export.

## Running tests

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Run a single test class:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  -only-testing:photo-exportTests/ExportRecordStoreTests \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Documentation and Contributing

- Repository overview: [`README.md`](https://github.com/valtteriluomapareto/vibe-icloud-photo-export/blob/main/README.md)
- Contributor guide: [`CONTRIBUTING.md`](https://github.com/valtteriluomapareto/vibe-icloud-photo-export/blob/main/CONTRIBUTING.md)
- Maintainer notes: [`docs/README.md`](https://github.com/valtteriluomapareto/vibe-icloud-photo-export/blob/main/docs/README.md)
