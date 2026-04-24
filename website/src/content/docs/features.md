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

A toolbar picker next to the export buttons chooses which versions to write:

- **Originals** — the Photos library's original files, kept at their original filenames
  (for example `IMG_0001.HEIC`). This is the default.
- **Edited versions** — the current edited/rendered version for every asset that has edits
  in Photos. Unedited assets are skipped in this mode.
- **Originals + edited versions** — both for assets that are edited, original only for
  assets that are not.

Edited exports use an `_edited` suffix on the filename, for example `IMG_0001_edited.JPG`.
The edited file's extension comes from the bytes Photos renders the edit as, so a HEIC
original with a JPEG rendered edit writes `IMG_0001.HEIC` + `IMG_0001_edited.JPG`. Edited
output only applies to assets that have edits in Photos; unedited assets do not produce
`_edited` duplicates.

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
