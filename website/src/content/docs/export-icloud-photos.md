---
title: How to Export iCloud Photos to an External Hard Drive
description: Step-by-step guide to exporting your iCloud and Apple Photos library to an external hard drive or local folder on Mac using the free Photo Export app.
---

If your iCloud Photo Library contains thousands of photos and you want a local backup on an external hard drive, Photo Export makes it simple. This guide walks you through the process.

## What you need

- A Mac running **macOS 15.0** or later
- **iCloud Photos enabled** on your Mac — go to **System Settings → Apple Account → iCloud → Photos** and make sure it's on. Photo Export reads your local Photos library through Apple's PhotoKit framework (the same API the built-in Photos app uses), so your iCloud photos need to be syncing to this Mac.
- An external hard drive, USB drive, or any local folder
- The [Photo Export app](https://github.com/valtteriluomapareto/photo-export/releases) — free on GitHub, or coming soon on the Mac App Store

## Step 1: Download and install Photo Export

**Mac App Store** — Coming soon. Install directly from the App Store for automatic updates.

**GitHub Releases (free):**

1. Download the latest `.dmg` from the [GitHub Releases page](https://github.com/valtteriluomapareto/photo-export/releases).
2. Open the DMG and drag **Photo Export** to your Applications folder.
3. Launch the app. It is signed and notarized by Apple, so it will open without Gatekeeper warnings.

## Step 2: Grant Photos library access

When you first open Photo Export, macOS will ask you to grant access to your Photos library. Click **Allow** to continue. This lets the app read your iCloud and Apple Photos library.

## Step 3: Choose your export destination

Click **Choose Folder** and select your external hard drive or any local folder. The app remembers your choice, so you only need to do this once.

## Step 4: Browse and export

Use the year/month sidebar to browse your library. You can preview thumbnails and inspect individual photos before exporting. When you're ready:

- To export a single month, navigate to it and click **Export Month**.
- To export your entire library, click **Export All** in the toolbar.

The app copies original files into an organized `Year/Month/` folder structure on your chosen drive. If any photos are stored only in iCloud, the app automatically downloads the originals during export.

## Resuming an interrupted export

If the export is interrupted — you unplug the drive, close the app, or your Mac goes to sleep — you can resume and the app will skip most already-exported files. In rare cases (e.g. a crash mid-write), a file may be copied again, but no data is lost.

## Why use Photo Export instead of manually dragging photos?

- **Organized folders**: Photos are automatically sorted into `Year/Month/` folders instead of dumped into one giant directory.
- **Tracks what's exported**: The app remembers what's been exported. Run it again and it skips already-exported photos.
- **Pause and resume**: Long exports can be paused and picked up later.
- **Open source**: No subscription, no account, no ads. MIT licensed. Free on GitHub, or support the project on the Mac App Store.
