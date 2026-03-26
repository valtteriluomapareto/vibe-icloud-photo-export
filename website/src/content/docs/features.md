---
title: Features
description: What Photo Export can do today.
---

Photo Export is a fully functional MVP for backing up your Apple Photos library. Here's what's been implemented.

## Photos library access

- Full Photos framework integration with user authorization
- Fetches all photo and video assets, grouped by year and month
- Extracts asset metadata: creation date, media type, local identifier
- Filtering by media type (photos/videos)
- Async APIs throughout

## Library browsing

- Year/month sidebar navigation with asset counts
- Export status indicators per month (not exported, partially exported, fully exported)
- Fast thumbnail grid with in-memory caching
- Full-size asset preview for any selected photo or video

## Export destination management

- Standard macOS folder picker for selecting the export root
- Security-scoped bookmarks persist the chosen folder across app launches
- Current destination displayed in the UI

## Export functionality

- One-click export for an entire month or year
- Only copies assets that haven't been exported yet (based on export records)
- Automatic folder creation: `<root>/<year>/<month>/`
- Handles both images and videos
- Real-time progress tracking in the UI

## Export tracking

- Persistent `ExportRecordStore` tracks every exported asset by `PHAsset.localIdentifier`
- Per-destination tracking — records reconfigure when the destination changes
- Detects which months are fully exported, partially exported, or new
- Resume-safe: interrupted exports pick up where they left off

## Queue controls

- Pause and resume the export queue at any time
- Clear pending items from the queue
- Cancel and clear the entire export batch
- Queue status indicator in the sidebar

## Performance

- Fast thumbnail loading with in-memory caching
- Thumbnail networking paused during export to reduce contention
- Quick image preview display at suitable sizes
- Loading indicators where appropriate

## Error handling

- Graceful handling of Photos library access denied
- Export folder unavailable or write-protected detection
- Individual asset export failures are skipped, recorded, and the batch continues
