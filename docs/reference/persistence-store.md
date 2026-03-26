# Export Record Persistence Store

This document explains how the app persists export status for Photos assets.

## Overview

- The app tracks exports by the Photos `PHAsset.localIdentifier`.
- Each exported asset has an `ExportRecord` containing year, month, relative path, filename, status, and timestamps.
- The store persists data using an append-only JSON Lines log and a compact snapshot.

## Files & Locations

- Directory: `~/Library/Application Support/<bundle id>/ExportRecords/`
- Files:
  - `export-records.jsonl` — append-only mutation log (one JSON object per line)
  - `export-records.json` — compacted snapshot of the current state (single JSON object mapping `id` → `ExportRecord`)

## Data Model

- `ExportRecord` (JSON):
  - `id` (String) — `PHAsset.localIdentifier`
  - `year` (Int), `month` (Int)
  - `relPath` (String) — relative export folder, e.g. `2025/02/`
  - `filename` (String?) — exported filename
  - `status` (String) — `pending` | `inProgress` | `done` | `failed`
  - `exportDate` (ISO8601 date)
  - `lastError` (String?)
- `ExportRecordMutation` (JSON Lines):
  - `op` — `upsert` | `delete`
  - `id` — asset id
  - `record` — present on `upsert`, omitted on `delete`

## Lifecycle

1. On first run, the store creates its directory.
2. On launch, the store loads the snapshot (if present), then applies each log line in order to reconstruct the latest state.
3. On updates, the store:
   - Applies the mutation to in-memory state immediately
   - Appends a JSON line to `export-records.jsonl`
   - Periodically compacts:
     - Writes a full snapshot to a temp file
     - Atomically replaces `export-records.json`
     - Truncates `export-records.jsonl`
4. On quit, any pending compaction can run; otherwise the log is replayed at next launch.

## Crash Safety

- Mutations are fsynced to the log upon append; after a crash, the log is replayed.
- Snapshot creation writes to a temporary file and atomically replaces the old snapshot to avoid corruption.

## Querying Status

- `isExported(assetId)` returns if an asset has `status == done`.
- `exportInfo(assetId)` returns the full record.
- `monthSummary(year, month, totalAssets)` computes:
  - `exportedCount`: number of `done` records for that month/year
  - `totalCount`: caller-provided total assets for the month
  - `status`: `notExported` | `partial` | `complete`

## Error Handling

- If the log contains an invalid line, it is skipped and logged. The rest of the log is still applied.
- If snapshot loading fails, the store continues from the log only.

## Migrations

- Future schema changes can be handled by reading both the snapshot and the log using compatible decoders.
- A migration step can write a new snapshot format and clear/truncate the log.

## Notes

- Checksums are not stored in MVP; we rely on `localIdentifier` and exported filename/path.
- The store is designed to move to SQLite in the future if needed; JSON files remain importable.
