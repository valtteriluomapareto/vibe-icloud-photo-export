# Export Record Persistence Store

This document explains how the app persists export status for Photos assets.

## Overview

- The app tracks exports by the Photos `PHAsset.localIdentifier`.
- Each exported asset has an `ExportRecord` containing year, month, relative path, and a
  per-variant state dictionary. Variants are `original` and `edited`.
- The store persists data using an append-only JSON Lines log and a compact snapshot.

## Files & Locations

- Directory (sandboxed): `~/Library/Containers/<bundle id>/Data/Library/Application Support/<bundle id>/ExportRecords/<destinationId>/`
  - `destinationId` is a SHA-256 hash of the destination bookmark data, so each export destination gets its own isolated record store
- Files:
  - `export-records.jsonl` — append-only mutation log (one JSON object per line)
  - `export-records.json` — compacted snapshot of the current state (single JSON object mapping `id` → `ExportRecord`)

## Data Model

- `ExportRecord` (JSON):
  - `id` (String) — `PHAsset.localIdentifier`
  - `year` (Int), `month` (Int)
  - `relPath` (String) — relative export folder, e.g. `2025/02/`
  - `variants` (Object) — keyed by variant name (`original`, `edited`), each value an
    `ExportVariantRecord`
- `ExportVariantRecord` (JSON):
  - `filename` (String?) — final exported filename for that variant. The `.original`
    variant's filename may be the bare stem (e.g. `IMG_0001.JPG`) or the `_orig` companion
    form (e.g. `IMG_0001_orig.HEIC`) depending on whether it was paired with an `.edited`
    write.
  - `status` (String) — `pending` | `inProgress` | `done` | `failed`
  - `exportDate` (ISO8601 date)
  - `lastError` (String?)
- `ExportRecordMutation` (JSON Lines):
  - `op` — `upsert` | `delete`
  - `id` — asset id
  - `record` — present on `upsert`, omitted on `delete`

### Legacy schema migration

Records produced before per-variant state decoded as a flat object with `filename`, `status`,
`exportDate`, and `lastError` at the top level. The decoder recognises this shape and
synthesises a single `.original` variant:

- Legacy `.done` becomes `.original` done.
- Legacy `.failed` becomes `.original` failed.
- Legacy `.pending` becomes `.original` pending.
- Legacy `.inProgress` becomes `.original` failed with the message
  `Interrupted before completion`. No in-progress state survives app restart.

Any variant (new schema or migrated legacy) left as `.inProgress` at load time is also
converted to `.failed` with the same interrupted message — this keeps progress tracking
recoverable after crashes and force-quits.

Encoding always emits the current schema. Legacy fields are dropped on the next write or
compaction.

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

- `isExported(assetId:)` returns whether the `.original` variant is `done` — a convenience shim
  for legacy call sites.
- `isExported(asset:selection:)` evaluates completion strictly against
  `requiredVariants(for:selection:)` — i.e. the asset's current `hasAdjustments`. No
  filename inspection: a `.original.done` row at any filename satisfies an unedited
  asset's requirement, and an adjusted asset is only satisfied when `.edited.done` (and
  `.original.done` under `editedWithOriginals`).
- `exportInfo(assetId:)` returns the full record; callers inspect
  `record.variants[.original]` and `record.variants[.edited]` directly.
- `monthSummary(assets:selection:)` computes an asset-based summary for a selected month
  by calling the strict, asset-aware `isExported` on each descriptor.
- `sidebarSummary(year:month:totalCount:adjustedCount:selection:)` computes an approximate
  summary for sidebar rows that do not have loaded `AssetDescriptor`s. The formula is
  `editedDone + min(origOnlyAtStem, uneditedCount)` for the default mode and
  `bothDone + min(origOnlyAtStem, uneditedCount)` for include-originals, where
  `origOnlyAtStem` filters records by `!isOrigCompanion(filename:)`. The
  `adjustedCount`-derived cap prevents natural-stem `.original.done` records belonging to
  currently-adjusted assets from over-contributing past the number of assets that could
  legitimately be original-only.

## Error Handling

- If the log contains an invalid line, it is skipped and logged. The rest of the log is still applied.
- If snapshot loading fails, the store continues from the log only.

## Migrations

- Schema changes are handled by reading both the snapshot and the log using compatible
  decoders. The current decoder handles both the flat legacy record shape and the new
  per-variant shape.
- The next full compaction writes the current schema and drops legacy fields.

## Notes

- Checksums are not stored in MVP; we rely on `localIdentifier` and exported filename/path.
- The store is designed to move to SQLite in the future if needed; JSON files remain importable.
