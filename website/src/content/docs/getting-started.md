---
title: Getting Started
description: How to install and use Photo Export on your Mac.
---

Photo Export is a native macOS app that exports your Apple Photos library to local or external storage, organized by year and month.

## Prerequisites

- **macOS 15.0** or later
- **iCloud Photos enabled** — Photo Export reads your local Photos library via Apple's PhotoKit framework. It sees exactly what the built-in Photos app sees. For your iCloud photos to appear, iCloud Photos must be turned on: go to **System Settings → Apple Account → iCloud → Photos** and make sure it's enabled.

:::note
Photo Export uses only Apple's official PhotoKit API — no private APIs, no reverse engineering, no iCloud credentials. This means it works reliably across macOS updates and never accesses anything outside what the Photos app itself can see.
:::

## Download

Photo Export is available through two channels:

- **[Mac App Store](https://apps.apple.com/app/photo-export-local-backup/id6761410742)** — Automatic updates, trusted distribution. Your purchase supports development of an open-source project.
- **GitHub Releases (free)** — Download the latest `.dmg` from the [GitHub Releases page](https://github.com/valtteriluomapareto/photo-export/releases). Open the DMG and drag Photo Export to your Applications folder.

Both versions are identical in functionality, signed and notarized by Apple.

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
- Use the **Include originals** toggle in the toolbar to choose what gets written. Off
  (default) exports one file per photo, in the version Photos shows. On adds a `_orig`
  companion for any photo edited in Photos so you keep a copy of the original bytes.
- Click **Export All** in the toolbar to queue the entire library
- Use **File → Import Existing Backup...** (Cmd+Shift+I) if you already have a previous export and want to avoid re-copying those files

Export progress is shown in the toolbar. You can pause, resume, or cancel at any time.

### Troubleshooting

- **"Export folder is not reachable"** — Check that the external drive is plugged in and mounted.
- **"Export folder is read-only"** — Right-click the folder, choose Get Info, and make sure you have write permission.
- **Photos permission denied** — Open **System Settings → Privacy & Security → Photos** and enable access for Photo Export.

## Updates and distribution channels

Photo Export is distributed through two channels. Both versions are identical in functionality.

- **Mac App Store** users receive updates automatically through the App Store.
- **GitHub Releases** users should check the [Releases page](https://github.com/valtteriluomapareto/photo-export/releases) for new versions.

Both builds can be installed on the same Mac simultaneously — they use separate bundle identifiers and separate data (export history, bookmarks, preferences).

### Switching between channels

If you want to move from one channel to the other:

1. Install the new channel's build
2. Select the same export folder you used before
3. Go to **File > Import Existing Backup...** (Cmd+Shift+I) — this scans the destination folder, matches exported files to your Photos library, and rebuilds the export history so future exports skip already-exported assets

Without step 3, the new build treats the destination as fresh and may create duplicate files.

## Build from source

If you prefer to build from source or want to contribute:

```bash
git clone https://github.com/valtteriluomapareto/photo-export.git
cd photo-export
open photo-export.xcodeproj
```

Press Run (Cmd+R) with the `photo-export` scheme selected. Requires Xcode 16.2+.

See the [Contributing guide](https://github.com/valtteriluomapareto/photo-export/blob/main/CONTRIBUTING.md) for more details on development setup, running tests, and linting.
