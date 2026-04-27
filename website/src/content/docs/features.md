---
title: Features
description: What Photo Export can do today.
---

Photo Export is a focused macOS app for exporting and tracking Apple Photos backups. These are the core capabilities available today.

## Library browsing

- Year/month sidebar navigation with asset counts
- Export status indicators at both year and month level (not started, in progress with percentage, fully exported with checkmark)
- Fast thumbnail grid with in-memory caching
- Full-size preview for any selected photo or video
- Detail panel showing original filename, creation date, dimensions, file size, media type, and export status

## Export

- One-click export for a single month, a year, or the entire library
- Only copies assets that haven't been exported yet
- Automatic folder creation in `<year>/<month>/` structure
- Handles both images and videos
- Real-time progress tracking in the toolbar (count and current filename)

### Version selection

A toolbar toggle next to the export buttons chooses what to write:

- **Off (default)** — one file per photo, in the version Photos shows. Edited photos
  export the edit; unedited photos export the original. The file lands at the original
  Photos filename with the extension of the bytes being written, e.g. a HEIC original with
  a JPEG-rendered edit writes `IMG_0001.JPG`.
- **On — Include originals** — same as off, plus a `_orig` companion for any photo with
  edits in Photos. The companion holds the unmodified original bytes alongside the
  user-visible edit. For an edited HEIC + JPEG-rendered edit the destination ends up with
  `IMG_0001.JPG` (the edit) and `IMG_0001_orig.HEIC` (the original).

Unedited photos never produce a `_orig` companion — there is nothing to pair with.

## Export destination

- Standard macOS folder picker for selecting the export root
- Works with local folders, external drives, or mounted network volumes
- Selection persists across app launches via security-scoped bookmarks
- Drive status indicator in the toolbar (connected/disconnected)

## Tracking and resume

- Every exported asset is tracked by its Photos library identifier
- Per-destination tracking — switching destinations reconfigures automatically
- Resume-safe: interrupted exports pick up where they left off without re-copying
- Sidebar badges update as exports complete

## Queue controls

- Pause and resume the export queue at any time
- Cancel and clear the entire batch
- Queue progress visible in the toolbar

## Existing backup import

- Rebuild local export state from an existing backup folder via **File → Import Existing Backup...** (Cmd+Shift+I)
- Four-stage process: scan backup folder, read Photos library, match files, rebuild state
- Shows a detailed report with matched, ambiguous, and unmatched file counts
- Continue exporting on a fresh install without re-copying known assets

## Error handling

- Graceful handling when Photos library access is denied or limited
- Export folder unavailable or write-protected detection
- Individual asset failures are skipped and recorded — the batch continues
- Failed assets are logged with error details

## Current boundaries

- macOS only (15.0+)
- Export folder structure is fixed to year/month hierarchy
- Exports run sequentially (one asset at a time)
