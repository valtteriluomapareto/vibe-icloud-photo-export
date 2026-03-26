---
title: Getting Started
description: How to install and use Photo Export on your Mac.
---

Photo Export is a native macOS app that exports your Apple Photos library to local or external storage, organized by year and month.

## Download

Download the latest DMG from the [GitHub Releases page](https://github.com/valtteriluomapareto/vibe-icloud-photo-export/releases). Open the DMG and drag Photo Export to your Applications folder.

**Requirements:** macOS 15.0+

The app is signed and notarized by Apple, so it will open without Gatekeeper warnings.

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

## Build from source

If you prefer to build from source or want to contribute:

```bash
git clone https://github.com/valtteriluomapareto/vibe-icloud-photo-export.git
cd vibe-icloud-photo-export
open photo-export.xcodeproj
```

Press Run (Cmd+R) with the `photo-export` scheme selected. Requires Xcode 16.2+.

See the [Contributing guide](https://github.com/valtteriluomapareto/vibe-icloud-photo-export/blob/main/CONTRIBUTING.md) for more details on development setup, running tests, and linting.
