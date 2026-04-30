# Collections Export Plan

Date: 2026-04-30
Status: Proposed (simplified after triple-review)

## Summary

Add a second export surface alongside the existing timeline export:

```text
<destination>/
  2026/
    04/
      IMG_0001.HEIC

  Collections/
    Favorites/
      IMG_0001.HEIC
    Albums/
      Album_1/
        IMG_0001.HEIC
      Folder/
        Album_2/
          IMG_0001.HEIC
```

Timeline and collection exports must be independent. Exporting an asset to `2026/04/` must not mark it exported in
`Collections/Favorites/` or `Collections/Albums/<album>/`, and exporting from a collection must not affect timeline
progress. Duplicate physical files are intentional when the same Photos asset appears in multiple export placements.

The architectural change is a v2 record store: state moves from asset-scoped to placement-scoped. v1 records are keyed
by `PHAsset.localIdentifier`; v2 records are keyed by a `(placementId, assetId)` tuple, with variants nested inside the
record. A one-time, crash-safe migration converts existing v1 timeline records to v2 timeline records; v1 files remain
on disk as a frozen backup.

This plan is bigger than it first appears. Phase 1 alone touches `ExportManager`, `ExportRecordStore`,
`BackupScanner`, and most of the test suite, because every place that currently keys by asset id has to gain a
placement parameter. Phase 0 (stable destination identity) is a prerequisite: today's bookmark-hash-based
`destinationId` can change on bookmark refresh and silently orphan the record store, which is acceptable
pre-collections (recoverable via `Import Existing Backup`) but not after (collection state is not on-disk-
recoverable). Realistic effort: 6–9 weeks across all phases.

## Goals

- Add a top-level two-state UI selector: `Timeline` and `Collections`.
- Keep the current year/month sidebar under `Timeline`.
- Under `Collections`, show:
  - `Favorites`
  - `Recent` (the Photos "Recently Added" smart album)
  - `Albums`
  - one row per user album, preserving folder nesting when available.
- Allow queueing exports from months, years, favorites, recent, and individual albums in one session.
- Write collections under `Collections/Favorites/`, `Collections/Recent/`, and `Collections/Albums/...`.
- Keep timeline and collection export completion state completely independent.
- Preserve the existing edited/originals export-version behavior for every export placement.
- Use APFS file clones to avoid disk-doubling when both timeline and a collection contain the same asset and the
  destination is on APFS; copy on non-APFS filesystems.
- Write a JSON sidecar (`_album.json`) inside each collection placement folder (Favorites, Recent, every album)
  so collection membership is preserved alongside the photos themselves.
- Migrate existing users' export state through a one-time v1 → v2 conversion.
- Keep PhotoKit types behind protocol/model boundaries so views and the export pipeline remain testable.

## Non-Goals

- Restoring album membership back into Photos automatically (the JSON sidecar is enough metadata for a future
  "restore to Photos" tool, but writing such a tool is out of scope).
- Exporting smart albums beyond `Favorites` and `Recently Added` in the first pass.
- Automatically deleting files when an album is removed in Photos.
- Adding a new closed-app background export process.
- Changing the existing timeline folder layout.
- Auto-sync of collections. Auto-sync (per `auto-sync-background-sync-plan.md`) remains timeline-only.
- Supporting downgrade from a v2 build back to a pre-collections build (v2 is one-way; v1 files are frozen post-
  migration as a passive backup but no compatibility is claimed).
- `Export All` covering collections. `Export All` remains timeline-scoped. A future `Export All Collections` action,
  if added, will be explicit.
- Backfilling collection placement records from existing files via `Import Existing Backup`. Import remains
  timeline-only and ignores `Collections/`.

## Risks and Decisions

This plan's value lives in this section. Each item below changed the design.

- **Migration is the highest-risk step.** v2 is written atomically (`.tmp` + rename + fsync). v1 files are preserved
  untouched and become read-only post-migration; the v2 store never writes to v1. If v2 fails to decode at startup,
  the loader surfaces an error alert with the file path and disables exports until the user removes the corrupted
  file (whereupon the migration re-runs from v1, which is still intact). (See *Migration*.)
- **Album rename moves the folder, by default.** Renaming an album in Photos is a user-initiated rename; the
  expected behavior is for the corresponding folder on disk to follow. The rename dialog defaults to "Rename
  existing folder," which moves `Collections/Albums/<old>/` to `Collections/Albums/<new>/` and rewrites placement
  records to point at the new path. The secondary action ("Create new folder, leave old") is the previous behavior
  for users who want it. Records and on-disk layout stay in sync. (See *Product Behavior → Album Rename UX*.)
- **Manual filesystem edits are not detected.** Records are the source of truth for "what is exported where." If a
  user moves, renames, or deletes folders or files in the destination through Finder, the next export will write to
  the path the records remember, which may surprise the user. `Import Existing Backup` is the only recovery path,
  and it covers timeline only.
- **Duplicate files are mostly free on APFS (best-effort optimization).** When source and destination are on the
  same APFS volume, modern macOS makes `FileManager.copyItem(at:to:)` perform copy-on-write at the filesystem
  layer, so the duplicate uses no extra bytes until either copy is modified. On exFAT/NTFS, duplication is always
  a real copy and a 50k-asset / 100-album library can grow disk use 3–5×. The plan does not depend on cloning
  succeeding — if a macOS regression ever made `copyItem` always copy, exports still work; they just use more
  disk on APFS than expected. Verified at test time via volume free-space delta.
- **`ExportManager` refactor is invasive.** ~981 lines today, queue keyed by year/month strings, jobs carry year/month
  inline. Phase 1 rewires the queue and persistence to placement-keyed even though only timeline placements exist
  yet. This is unavoidable — bolting collections on top of an asset-scoped store creates cross-scope corruption.
- **Album titles can produce path collisions.** Sibling collisions (two albums named the same in the same parent
  folder) are detected and disambiguated with a `_2` / `_3` numeric suffix. We do not detect cross-tree case-fold
  collisions in the MVP — they are vanishingly rare in personal libraries and the cost of building reliable
  cross-tree detection (NFC + case-fold over the whole sanitized tree) outweighs the user-visible value. (See
  *Path Policy*.)
- **Stale album placements accumulate from album deletions only.** Renaming no longer creates a stale placement
  (the rename action moves files and rewrites records). Deleting an album in Photos still leaves the placement
  record behind; disk cost is negligible (a few KB) and the descriptor tree drives sidebar display. Cleanup of
  deleted-album placements is out of scope for the MVP.
- **Storage scaling.** With normalized placements (placement metadata stored once, records reference by id),
  snapshot size is dominated by `Σ placements records`, not `placements × assets`. Compaction threshold (currently
  1000 mutations) stays unchanged; profile during Phase 1 and tune if snapshot writes on slow USB targets become
  noticeable. Worst-case a 50k-asset / 100-album library is on the order of single-digit MB.
- **Auto-sync interaction.** When auto-sync ships, it enumerates timeline placements only. Collection exports —
  which can prompt for rename confirmation and write large numbers of files — stay user-triggered.
- **Destination identity must be stable before this ships.** Today `destinationId` is a SHA-256 of the bookmark
  data (`ExportDestinationManager.swift:218`). When a bookmark is refreshed (e.g. after the OS regenerates it),
  the hash changes and the entire record store appears to be a fresh empty destination. Pre-collections, the
  user could re-run `Import Existing Backup` to recover. Post-collections, that path is timeline-only — collection
  state cannot be reconstructed from disk. A bookmark refresh would silently orphan the user's collection
  records. The `auto-sync-background-sync-plan.md` already calls this out as a prerequisite for that feature; it
  is now a prerequisite for this one too. **Phase 0 (below) addresses it before any v2 work begins.**
- **`ContentView` is too coupled to do this in place.** Sidebar logic moves out before adding the Collections branch.

## PhotoKit API Shape

Use app-owned descriptors at the protocol boundary. `PHAssetCollection`, `PHCollection`, and `PHCollectionList` must
not appear in SwiftUI views or `ExportManager`.

Relevant PhotoKit routes:

- Favorites can be fetched either with a `PHFetchOptions` predicate (`favorite == YES`) or through the smart album
  (`PHAssetCollectionSubtype.smartAlbumFavorites`). Use the predicate for the MVP — the desired output placement is
  fixed and we do not need smart-album metadata.
- Recently Added is the smart album `PHAssetCollectionSubtype.smartAlbumRecentlyAdded`. Fetch via the smart-album
  API (no predicate equivalent). Photos defines the lookback window (~30 days) and may shift it; the export simply
  writes whatever Photos currently returns at the time of each run. The placement is `Collections/Recent/`. **The
  folder accumulates over time:** each export run adds whatever Photos currently considers Recently Added; files
  are not removed when an asset falls out of the window. After a year of monthly Recent exports, the folder
  reflects "all assets that were ever Recently Added at the times you exported," not "currently Recently Added."
  The `_album.json` sidecar makes this transparent — it lists what is on disk now, derived from the placement's
  `.done` records. This is documented behavior, not auto-cleaned.
- User albums are `PHAssetCollection` values with `assetCollectionType == .album`.
- Fetch album contents with `PHAsset.fetchAssets(in:options:)`.
- Fetch top-level folders/albums with `PHCollection.fetchTopLevelUserCollections(with:)`.
- Recurse folders with `PHCollection.fetchCollections(in:options:)`.
- Moments are not used (deprecated/unavailable on macOS).

Fetch options match existing timeline behavior:

- Sort assets by `creationDate` ascending for deterministic output.
- Hidden assets stay excluded by default.
- Source-type behavior unchanged. If shared albums are added later, that decision is explicit.

`PhotoLibraryManager` already conforms to `PHPhotoLibraryChangeObserver` and calls `invalidateCache()` on library
changes. Extend `invalidateCache()` to also clear:

- the cached collection descriptor tree,
- per-placement count and adjusted-count caches.

Cache invalidation also cancels any in-flight count tasks (see *PhotoLibraryService → off-main counting*), so
observers do not return stale results after a Photos library mutation.

Without this, sidebar collection rows go stale until app restart.

## Product Behavior

### Navigation

Add a segmented control at the top of the main UI:

```text
[ Timeline | Collections ]
```

`Timeline` selected:

- Render the current `Photos by Year` sidebar with unchanged behavior.
- Selecting a month shows the existing thumbnail grid and `Export Month` action.
- Existing `Export Year` / `Export All` toolbar behavior stays timeline-scoped.

`Collections` selected:

- Render a `Collections` sidebar:
  - `Favorites`
  - `Recent`
  - `Albums`
    - `<album rows, nested by folder path where possible>`
- Selecting `Favorites` / `Recent` shows the corresponding asset grid and an `Export Favorites` / `Export Recent`
  action.
- Selecting an album shows its asset grid and an `Export Album` action.
- Albums that resolve to the same display title under different folders remain distinct in state and on disk.

### Album Rename UX

When the user renames an album in Photos.app, the user-expected behavior is for the corresponding folder on disk to
follow. The dialog reflects that.

**When to show.** A prior placement record exists for the same `collectionLocalIdentifier` with a different
`relativePath`, **and** that prior placement has at least one variant in `.done` status. (Suppress the dialog when
the prior placement has no `.done` variants — there are no files in the old folder to worry about.) If multiple
prior placements exist (multi-rename chain), show only the most recent.

**Pre-flight checks** (run before the dialog opens; gate the primary action):

- **Any export work active (any placement)** → primary action is disabled with a tooltip "Wait for exports to
  finish or cancel them, then rename." The current `ExportManager` has a single global queue and a single
  `currentTask`/generation counter, so cancelling work for "just this placement" isn't possible without a
  placement-scoped cancellation mechanism that this plan does not introduce. Disabling rename while any work is
  in flight is the simplest correct rule for the MVP. (Per-placement cancel is a future enhancement.)
- Anything already exists at the new path on disk:
  - If it's another placement's recorded folder → primary action disabled, tooltip "<other album> already lives at
    that path."
  - If it's an unknown directory or file (e.g. user pre-created in Finder) → primary action disabled, tooltip
    "A folder/file at the new path already exists. Move or rename it in Finder before continuing."
- Old folder is missing from disk → see "States" below.

**States the dialog presents copy for:**

| Old folder on disk | Dialog primary copy |
|---|---|
| Present (normal case) | "Move <N> files from `<old>/` to `<new>/` and update records. *(Recommended)*" |
| Missing (user deleted it manually, or a prior partial rewrite already moved it) | "Update records to match the folder that already exists at `<new>/`. No files will be moved." |

**Dialog actions** (in display order; "Rename existing folder" / "Update records" is the default):

1. **Rename existing folder** *(default; primary copy varies as above)*.
   - If old folder present: `FileManager.moveItem(at: <old>, to: <new>)`, then issue a `renamePlacement` log op.
   - If old folder missing but new folder present: skip the move, issue `renamePlacement` only. Records now point
     at the on-disk reality.
   - If both old and new folders are missing: issue `renamePlacement` only; the next export will materialize the
     new folder.
2. **Create new folder, leave old**. The previous behavior. A new placement is created at the new path; the old
   placement remains; future exports go to the new folder; the old folder remains untouched on disk. Use this when
   the user wants to keep both for some reason.
3. **Cancel**. No change to records or disk.

**Atomicity.** Because the pre-flight check requires the queue to be idle for the entire app, no concurrent job
can touch the old placement during the action. The rename simply does:

1. `FileManager.moveItem(at: oldURL, to: newURL)` (or skip if old is missing on disk).
2. Append a single `renamePlacement` log line carrying the old id and the new placement metadata.
3. Rewrite the placement's `_album.json` sidecar at the new path immediately, best-effort. (Otherwise the moved
   sidecar still names the old title/path until the next export run drains.)

If the move fails, no log line is written and the dialog surfaces the error. If the log write fails after a
successful move, the next launch finds files at the new path and records still pointing at the old — the rename
detector fires again, and on re-entry the "old folder missing, new folder present" state is detected and the
dialog presents the "Update records" copy. The user confirms once more and the rewrite completes.

The detector's input is "prior placement record (`collectionLocalIdentifier` X, `relativePath` Y) and current
album in Photos with displayed path Z, where `displayPathHash8(Z) ≠ displayPathHash8(Y)`." That fires regardless
of whether the old folder is on disk; the dialog adapts copy and pre-flight checks to the disk state.

### Queueing

The queue may contain timeline-month, timeline-year (which expands to N timeline-month jobs), favorites, and album
jobs. The queue shows one global progress state, but per-row queued counts are keyed by **placement id**, not by
year-month string.

### Destination Layout

Relative directories:

```text
timeline month:      <YYYY>/<MM>/
favorites:           Collections/Favorites/
recent:              Collections/Recent/
album:               Collections/Albums/<sanitized folder path>/<sanitized album title>/
```

Each collection placement folder contains a sidecar metadata file `_album.json` (see *Album Sidecar*). The
sidecar is rewritten at the end of each export run.

The destination must reject any `relativePath` that escapes the export root after canonicalization (no `..`, no
absolute paths, no symlink traversal at write time).

### Album Sidecar

Each collection placement writes a small JSON sidecar to its folder root after export completes. This preserves
album membership alongside the photos themselves, so a backup folder is more than just a pile of files.

Filename: `_album.json`. The leading underscore puts it at the top of an alphabetical Finder listing and signals
"this is metadata for the folder."

```json
{
  "version": 1,
  "kind": "album",
  "title": "Trip 2024",
  "displayPath": "Family/Trip 2024",
  "folder": "Collections/Albums/Family/Trip 2024/",
  "phLocalIdentifier": "ABC-123-…",
  "exportedAt": "2026-04-30T14:00:00Z",
  "assets": [
    { "phLocalIdentifier": "X1/L0/001",
      "variants": { "original": "IMG_0001.HEIC" } },
    { "phLocalIdentifier": "X1/L0/002",
      "variants": { "original": "IMG_0002_orig.HEIC", "edited": "IMG_0002.HEIC" } }
  ]
}
```

The `variants` object maps variant name (`"original"` or `"edited"`) to the file's actual filename in the folder.
This survives partial success: an `editedWithOriginals` run that exports `_orig` first and then fails the edited
variant produces `{ "original": "IMG_0002_orig.HEIC" }` only, accurately. There is no `filename` /
`originalCompanion` ambiguity to resolve. The `variants` keys mirror `ExportVariant.rawValue`.

For unedited assets, the natural-stem file is the original (e.g. `IMG_0001.HEIC`), so the typical entry has
`variants.original` only. For edited assets in `editedWithOriginals` mode, the user-visible natural-stem file is
the edited rendering and the `_orig` companion (per `ExportFilenamePolicy.originalSuffix`) carries the original
bytes, so `variants.original` is the `_orig` filename and `variants.edited` is the natural-stem filename. There
is no `_edited` filename pattern in this codebase.

`kind` is one of `"album"`, `"favorites"`, `"recent"`. For `favorites` and `recent`, `phLocalIdentifier` and
`displayPath` are omitted; `title` is `"Favorites"` or `"Recent"`. The `folder` field is the placement's
on-disk path relative to the destination root and disambiguates two same-titled albums whose folders differ only
by a `_2`/`_3` collision suffix.

**Source of truth for the sidecar.** Sidecars are written from the **placement's `.done` records as of the end of
the export run**, *not* from a re-fetched Photos snapshot. Specifically, the writer iterates
`records[placementId]`, picks records with at least one `.done` variant, and emits one entry per record with the
filename(s) actually on disk. This avoids the enqueue-versus-write race (Photos can mutate the album mid-run) and
means the sidecar always describes files that actually exist alongside it.

Consequence: sidecar contents diverge from current Photos album membership over time. If a user removes a photo
from an album in Photos, the photo's `.done` record under that placement is unchanged (we don't auto-delete files
on album-membership changes), so the sidecar continues to list it. This is the documented behavior — the sidecar
is a manifest of "what was exported here," not "what is in this Photos album right now." Tools that want the
latter can query Photos themselves.

**When the sidecar is written.** The sidecar is rewritten when the export queue *drains* — there are no more
pending or in-flight jobs targeting the placement. This fires on natural completion, on cancellation (whatever
reached `.done` before the cancel), and on resume-then-completion. It does **not** fire mid-run, on pause, on
per-job failure, or on app quit mid-run. A failed run that completes draining still rewrites the sidecar; entries
reflect whichever assets reached `.done`.

Sidecars are best-effort: a failed sidecar write does not fail the export run, just logs a warning. Sidecars are
rewritten on every drain from the current placement state, so manual edits to the file are overwritten on the
next drain.

Sidecars are **not** read by the app. They are output for the user's benefit and for hypothetical future tools
(restore-to-Photos, audit, etc.). Phase 5 documents the schema.

## Path Policy

A small, deliberately boring sanitizer. The goal is "produce a usable path on common filesystems without surprising
the user." Edge cases the policy does not handle (reserved Windows device names, deep tree case-fold collisions,
extreme length) are accepted as out-of-scope: they are vanishingly rare in personal Photos libraries, and the cost
of building reliable detection outweighs the user-visible value.

All album and folder names go through `ExportPathPolicy.sanitizeComponent(_:)` before becoming a path component.

### Per-component rules

1. **Banned characters** — replaced with `_`:
   - path separators: `/` `\`
   - Windows/exFAT bans: `<` `>` `:` `"` `|` `?` `*`
   - control characters: `0x00`–`0x1F`, `0x7F`
2. **Whitespace and dots:** trim leading and trailing whitespace; strip trailing dots; if empty after trimming,
   replace with `_`.
3. **Dot-only components:** after trimming, if the component is exactly `.` or `..`, replace with `_`. (Defense in
   depth; the destination's relative-path validator is the primary guard against `..` traversal.)
4. **Unicode normalization:** NFC.
5. **Empty input:** `""` → `_`.

The policy intentionally does **not**:

- Reject reserved Windows/exFAT names like `AUX`, `CON`, `LPT1`. These are vanishingly rare album names; if a user
  hits one and exports to a Windows-formatted drive, the OS will refuse the directory creation. We surface this
  as a single placement-level failure (not 5,000 per-asset failures): `ExportManager.enqueue` calls
  `urlForRelativeDirectory(_, createIfNeeded: true)` once before enqueuing the placement's jobs; if it throws,
  the enqueue aborts, the placement is marked failed, and a single user-facing error explains which album and
  why. Per-asset failure marking is reserved for genuine per-asset failures (resource fetch, write).
- Cap component length. Common filesystems allow 255 bytes; album titles longer than that are not realistic.
- Detect cross-tree case-fold collisions. Sibling-only collisions (two albums with the same name in the same parent
  folder) are detected (next section); cross-tree case-only collisions are not. The build-up complexity of NFC +
  case-fold over the whole sanitized tree is not justified by the user-visible value. **Make the failure mode
  observable:** when a collection export's first write to its placement folder finds an existing `_album.json`
  whose `phLocalIdentifier` differs from the current placement's `collectionLocalIdentifier`, log a warning and
  surface a per-placement diagnostic in the UI ("This folder appears to belong to another album"). The export
  proceeds; the warning is informational.

### Disambiguation

A *sibling collision* is two distinct collections that, after sanitization, would produce the same full path under
the same parent folder under `Collections/Albums/`. Sibling collisions are detected against existing placement
records and against collections currently in the descriptor tree.

When a new placement collides with an existing placement's `relativePath`, the **new** placement gets a numeric
suffix; the existing placement's `relativePath` is never altered. First claimant keeps the bare path. Stale
placements from deleted albums count as live claimants so a reinstated album does not silently steal a path.

Suffix format:

```text
<sanitized leaf>_2
<sanitized leaf>_3
…
```

Suffix selection: take the smallest integer `n ≥ 2` such that `<leaf>_n` does not collide with any existing
placement. For two newly-discovered colliding albums (neither persisted yet), candidates are sorted
lexicographically by `collectionLocalIdentifier` and the bare path goes to the first; the second gets `_2`.

### Test cases

`ExportPathPolicyTests` covers at least:

1. ASCII passthrough.
2. Forward slash → `_`.
3. Backslash → `_`.
4. Trailing dot stripped (`Family.` → `Family`).
5. Leading/trailing whitespace trimmed.
6. Empty input → `_`.
7. NFC normalization: input `"Cafe\u{0301}"` (NFD: e + combining acute) → output `"Caf\u{00E9}"` (NFC: precomposed).
8. Component `..` → `_`. Component `.` → `_`.
9. Two newly-discovered albums with identical titles under the same folder produce paths `Trip/` and `Trip_2/`,
   ordered by `collectionLocalIdentifier`.
10. New album collides with an existing-recorded placement → new gets `_2`; existing path is unchanged.
11. `Trip_2` is taken → next collision yields `Trip_3`.

## Architecture

### Selection and Scope Models

```swift
enum LibrarySection: String, Codable, Sendable {
  case timeline
  case collections
}

enum LibrarySelection: Hashable, Sendable {
  case timelineMonth(year: Int, month: Int)
  case favorites
  case recent
  case album(collectionId: String)
}

enum PhotoFetchScope: Hashable, Sendable {
  case timeline(year: Int, month: Int?)
  case favorites
  case recent
  case album(collectionId: String)
}
```

`LibrarySelection` is UI state. `PhotoFetchScope` is a Photos query. They stay separate so the UI can represent
headers and empty states without implying an exportable query.

### Collection Descriptors

```swift
struct PhotoCollectionDescriptor: Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case favorites
    case recent
    case album
    case folder
  }

  let id: String
  let localIdentifier: String?
  let title: String
  let kind: Kind
  let pathComponents: [String]   // unsanitized display hierarchy
  let estimatedAssetCount: Int?
  let children: [PhotoCollectionDescriptor]
}
```

- `Favorites` is a synthetic descriptor with no PhotoKit collection id.
- Album descriptors carry `PHAssetCollection.localIdentifier`.
- Folder descriptors carry `PHCollectionList.localIdentifier` only for tree identity; folders are not directly
  exportable.
- `pathComponents` is the unsanitized display hierarchy. Sanitization happens in `ExportPathPolicy`, not here.

### PhotoLibraryService

Add scope-based APIs alongside the existing timeline-only APIs:

```swift
func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws -> [AssetDescriptor]
func countAssets(in scope: PhotoFetchScope) async throws -> Int
func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int
func fetchCollectionTree() throws -> [PhotoCollectionDescriptor]
func collectionDescriptor(id: String) -> PhotoCollectionDescriptor?
```

Existing methods become wrappers:

```swift
func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws -> [AssetDescriptor] {
  try await fetchAssets(in: .timeline(year: year, month: month), mediaType: mediaType)
}
```

**Off-main counting.** The `PhotoLibraryService` protocol stays `@MainActor`. Two new methods are explicitly
declared `nonisolated`:

```swift
@MainActor protocol PhotoLibraryService {
  // existing main-actor methods unchanged
  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int
  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int
}
```

Implementations build a `PHFetchResult` inside `Task.detached` and iterate without crossing any `PHAsset` instance
back to the main actor. Returned values are `Sendable` (`Int`). Fakes mirror the same `nonisolated async`
signatures. All other protocol methods retain their main-actor isolation; existing call sites are unaffected.

A `CollectionCountCache` actor owns per-placement-id `Task<Int, Error>?` handles. It exposes
`count(for: placementId, fetch: () async throws -> Int) async -> Int`, replacing any in-flight task for the same id
(cancelling the prior). Cache invalidation (`invalidateAll()`) cancels every in-flight task rather than stranding
them. Invalidation is called from the existing `PHPhotoLibraryChangeObserver` callback.

If `Task.detached` proves incompatible with PhotoKit threading in measured tests, the fallback is to keep the work
`@MainActor` and yield (`Task.yield()`) every 50 assets. Default to detached; revisit only if Phase 2 measurement
forces it.

`AssetDescriptor` does **not** gain an `isFavorite` field in this plan. Adding it is speculative (no current UI uses
it). Add it when a favorite affordance lands, not before.

### Export Placement

```swift
struct ExportPlacement: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case timeline
    case favorites
    case recent
    case album
  }

  let kind: Kind
  let id: String                        // stable, used as the placement-section key on disk
  let displayName: String
  let collectionLocalIdentifier: String?

  // Frozen at placement creation. Never recomputed.
  let relativePath: String

  let createdAt: Date                   // diagnostic; set on first persist
}
```

All fields are `let`. There is no mutable `lastDoneAt`: "most recent done" is computed lazily by the store from
record `exportDate`s (see *Mutation API → priorPlacements*). This avoids the cross-mutation atomicity problem (a
`done` write plus a separate `touchPlacementLastDone` log line could land out of sync after a crash) and keeps the
struct safely usable in `Set` / dictionary keys.

There is no stored `pathPolicyVersion`. The path policy is committed-to and frozen for this plan; if it ever
changes, the change will land in a future plan that explicitly handles existing placements. Today, `relativePath`
on every record *is* the placement's recorded path — that's all we need.

For belt-and-braces clarity: `ExportPlacement`'s identity is `id`. The synthesized `Hashable` and `Equatable` over
all `let` fields is consistent because no field can drift after construction; if a future change adds a mutable
field, switch to manual conformances over `id` only.

**`displayName` rules.** This is the only string the rename dialog and diagnostic logs show to the user;
`relativePath` is sanitized and `id` is opaque, so neither is suitable.

- Timeline: `"<year>/<MM>"` (e.g. `"2025/02"`).
- Favorites: `"Favorites"`.
- Album: the unsanitized full display path joined with `/` (e.g. `"Family/Trip 2024"` for an album titled
  `"Trip 2024"` inside a folder named `"Family"`). Album titles that contain `/` characters are preserved verbatim
  in `displayName` — the U+0000-separated hash in the placement id is what disambiguates structural nesting from
  an in-title slash.

Albums whose titles contain `/` produce ambiguous `displayName` strings (the rename dialog cannot tell whether
`A/B` means "nested folder A containing album B" or "single album with `/` in its title"). This is accepted as a
niche edge case rather than introducing escape syntax — the placement id (which uses U+0000 separators) keeps the
underlying state correct; only the human-readable display in the rename dialog is ambiguous in this corner.

### Placement IDs

```text
timeline:    timeline:<YYYY>-<MM>
favorites:   collections:favorites
recent:      collections:recent
album:       collections:album:<collectionIdHash16>:<displayPathHash8>
```

`collectionIdHash16` is the first 16 hex characters (64 bits) of `SHA256(collectionLocalIdentifier)`. The raw
`collectionLocalIdentifier` lives on the placement record body for diagnostics and lookups. Hashing isolates the
placement-id format from PhotoKit's opaque id alphabet (which can in principle contain any character).

`displayPathHash8` is the first 8 hex characters of
`SHA256(unsanitized pathComponents joined with U+0000, then U+0000, then unsanitized title)`.

Identity uniqueness is provided by `collectionIdHash16`. The `displayPathHash8` segment is a *rename detector*: it
changes when the album is renamed or moved between folders, so the resolver can spot a rename. Identity itself does
not depend on path.

**Collision handling.** Hash collisions are vanishingly rare at personal-library scale (64-bit at ~4 billion
albums for birthday 50%; 32-bit at ~65,000). The plan's worst-case scaling assumption is ≤1,000 albums per user.
If a hash collision is ever detected at id construction (the candidate id already exists under a *different*
`collectionLocalIdentifier`), the offending hash segment is extended in 8-hex-char increments
(`collectionIdHash16` → `collectionIdHash24` → `…32`, and the same for `displayPathHash`). The format is forward-
compatible.

**Concurrent collision among new placements.** When two newly-discovered albums (no existing record for either)
resolve to the same candidate path, the resolver sorts candidates lexicographically by `collectionLocalIdentifier`
and gives the bare path to the first. The result is independent of PhotoKit traversal order.

### `ExportPlacementResolver`

```swift
struct ExportPlacementResolver {
  func placement(
    for selection: LibrarySelection,
    collections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) throws -> ExportPlacement
}
```

Pure with respect to `(selection, collections, existingPlacements)`. The only code that maps selections to
placements. Uses `ExportPathPolicy` to compute `relativePath` for new placements.

Behavior:

- If an existing placement record matches the resolved `(kind, collectionLocalIdentifier, displayPathHash8)` tuple,
  the resolver returns it unchanged.
- If multiple existing placements match the same triple (which should never happen but defends against record
  corruption or a buggy past write), the resolver picks the placement with the latest `createdAt`, logs a warning,
  and continues.
- If the candidate `relativePath` collides with an existing placement's `relativePath` at the same parent folder,
  the **new** placement gets a numeric suffix (`_2`, `_3`, …); the existing placement is never altered.
- If two *newly-discovered* placements (neither has an existing record) resolve to the same candidate path, the
  resolver sorts candidates lexicographically by `collectionLocalIdentifier` before assigning bare/suffixed paths.

### Reuse-Source Copy Path (APFS clone as optimization)

When a collection export needs `(asset, variant)` and the same `(asset, variant)` already has a `.done` record
under another placement, we copy the existing file rather than refetching from PhotoKit. On APFS, modern macOS
makes `FileManager.copyItem(at:to:)` use copy-on-write at the filesystem layer, so the duplicate is effectively
free. On non-APFS, it's a real copy.

This is an **optimization**, not a correctness pillar. The plan does not depend on cloning succeeding; if a future
macOS regression makes `copyItem` always do a real copy, exports still work — they just use more disk on APFS than
expected.

**Source lookup.** When the writer is about to export `(assetId, variant)` for placement P:

1. Look up *any existing `.done` record* for this `(assetId, variant)` across all placements in the store —
   timeline first, then other collection placements (deterministic order so tests are repeatable). The source can
   be any prior `.done` write; album-first / timeline-second works as well as timeline-first / album-second.
2. If found, the source URL is `<destination root>/<placement.relativePath>/<variant.filename>` from that record.
3. Resolve the *destination* filename independently using the existing `ExportFilenamePolicy` +
   `uniqueFileURL(_:in:)` against P's directory. **The destination filename is not assumed to equal the source
   filename** — collision suffixes (`IMG_0001 (2).HEIC` vs `IMG_0001.HEIC`) can differ between placements
   depending on what each directory already contains.
4. Call `try FileManager.default.copyItem(at: sourceURL, to: destURL)`.
5. On error, narrow the fallback by what failed:
   - **Source-side error** (`NSFileNoSuchFileError`, source unreadable): the prior `.done` record is stale. Fall
     back to PhotoKit re-export. The stale `.done` record is *not* modified by this export — that placement's
     corruption surfaces on its next export run.
   - **Destination-side error** (target permission, `NSFileWriteOutOfSpaceError`, target volume removed): mark the
     variant `.failed` for placement P with the underlying error. **Do not** retry via PhotoKit — it would hit the
     same destination problem and double the work. The variant retries on the next export run.

**Capability detection.** Query `URLResourceKey.volumeSupportsFileCloningKey` on the destination root URL once per
mount and log the result for diagnostics. The flag is informational; `copyItem` works either way.

**Tests:**

- APFS same volume, known-size source (10 MB): post-copy, the volume's
  `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` drops by less than ~64 KB (clone succeeded). Add a
  behavioral check: write to one of the two files, verify the other is unchanged.
- Non-APFS destination: post-copy, free space drops by approximately the source size (real copy ran).
- Source missing (any prior `.done` record's file deleted by user): falls back to PhotoKit re-export; the stale
  `.done` record is unchanged.
- Destination out of space: variant marked `.failed` with the destination error; PhotoKit is not invoked.
- Variant-level decision: timeline has only `.edited`; collection requests both variants. `.edited` is reused from
  the timeline file; `.original` is fetched from PhotoKit. Each variant independently consults the source-lookup.
- Album-first then timeline: timeline export of an asset already in an album reuses from the album record, not
  PhotoKit. Same lookup order ("any prior `.done`"), no special-casing.
- Source filename and destination filename differ (because each directory had different prior collisions): the
  destination record stores the *destination* filename; reads find the right file.

`st_blocks` is **not** a reliable signal for cloning (both files report full blocks after a clone since they
share at the filesystem layer). Use volume free-space delta and behavioral divergence.

If APFS measurement ever shows `copyItem` is doing a real copy (regression or unexpected platform behavior), Phase
3 has the option to drop in `clonefile(2)` as an explicit fallback. The contract surface (`copyItem`) does not
change in that scenario; the implementation gains an explicit pre-step.

State independence is preserved — placement records still record their own `.done` status independently — but
bytes on disk are shared on APFS.

### Export Destination

```swift
protocol ExportDestination {
  func urlForRelativeDirectory(_ relativePath: String, createIfNeeded: Bool) throws -> URL
}
```

`urlForMonth(year:month:createIfNeeded:)` becomes a wrapper around `urlForRelativeDirectory` for the duration of the
migration. The implementation must reject any relative path that escapes the export root.

**Path validation timing.** Validation runs in `urlForRelativeDirectory` on every write. It also runs at record
**load** time: any `ExportPlacement` whose `relativePath` fails validation is logged and the placement (and its
records) are skipped — treated as if absent. This makes a corrupted record visible immediately at startup rather
than at the first export attempt.

`ExportRecordStore.configure(for:)` today takes only a `destinationId` for store-directory lookup; load-time
validation needs the actual destination root URL (held by `ExportDestinationManager`). The configure signature
gains a closure parameter:

```swift
func configure(for destinationId: String, validate: (String) -> Bool)
```

`ExportManager` constructs the closure by capturing the current `ExportDestination` and asking it via
`urlForRelativeDirectory(_, createIfNeeded: false)` (catching escape errors as `false`). When the destination
root is unavailable (drive disconnected, scoped access not yet started), validation is permissive — placements
load with their recorded paths intact, and the next write will fail loudly instead of silently dropping records.

Rejected inputs (tested in `ExportDestinationTests`):

- absolute paths (leading `/`),
- paths containing `..` segments after canonicalization,
- paths whose canonical resolution lands outside the export root,
- paths whose parent contains a symlink that escapes the root,
- paths where a non-directory exists at one of the intermediate components,
- paths exceeding the platform's max path length.

### Export Jobs and ExportManager

`ExportJob` is placement-scoped:

```swift
struct ExportJob: Equatable {
  let assetLocalIdentifier: String
  let placement: ExportPlacement
  let selection: ExportVersionSelection
}
```

Public `ExportManager` API:

```swift
func startExportMonth(year: Int, month: Int)
func startExportYear(year: Int)             // resolves to N timeline placements internally
func startExportAll()                        // timeline-only; resolves to M timeline placements
func startExportFavorites()
func startExportRecent()
func startExportAlbum(collectionId: String)
func startExport(selection: LibrarySelection)
```

Internally there is **no** single `enqueue(scope:placement:)` for year/all. Year and All resolve to a *list* of
(scope, placement) pairs and call the per-placement enqueue path once per pair:

```swift
private func enqueue(scope: PhotoFetchScope, placement: ExportPlacement, selection: ExportVersionSelection, generation: Int)
```

This is the correctness fix: the previous draft's signature could not represent a year export.

Queue counts: `queuedCountsByYearMonth: [String: Int]` → `queuedCountsByPlacementId: [String: Int]`. Timeline row
helpers ask through a wrapper that resolves the timeline placement id from year/month.

### Mutation API on `ExportRecordStore`

Every read **and** mutation that currently keys by asset id gains a placement parameter. This is non-negotiable: a
failed favorites export must not corrupt the timeline record for the same asset.

```swift
// Placement metadata
func upsertPlacement(_ placement: ExportPlacement)
func deletePlacement(id: String)
func placement(id: String) -> ExportPlacement?
func placements(matching kind: ExportPlacement.Kind) -> [ExportPlacement]
func priorPlacements(for collectionLocalIdentifier: String) -> [ExportPlacement]
func lastDoneAt(for placementId: String) -> Date?

// Record writes (placement must exist)
func upsert(_ record: ScopedExportRecord)
func markVariantInProgress(assetId: String, placement: ExportPlacement, variant: ExportVariant, filename: String?)
func markVariantExported(assetId: String, placement: ExportPlacement, variant: ExportVariant,
                         filename: String, exportedAt: Date)
func markVariantFailed(assetId: String, placement: ExportPlacement, variant: ExportVariant,
                       error: String, at: Date)
func removeVariant(assetId: String, placement: ExportPlacement, variant: ExportVariant)
func remove(assetId: String, placement: ExportPlacement)
func bulkImport(placements: [ExportPlacement], records: [ScopedExportRecord])

// Reads
func exportInfo(assetId: String, placement: ExportPlacement) -> ScopedExportRecord?
func isExported(asset: AssetDescriptor, placement: ExportPlacement, selection: ExportVersionSelection) -> Bool

// Scoped queries
enum PlacementScope {
  case timeline                     // all timeline:*
  case favorites
  case recent
  case album(collectionLocalId: String)
  case anyCollection                // favorites + recent + albums
}
func recordCount(in scope: PlacementScope) -> Int
func summary(for placement: ExportPlacement) -> PlacementSummary

// Atomic rename — moves all records from old placement id to new, replaces metadata
func renamePlacement(from oldId: String, to newPlacement: ExportPlacement)
```

`PlacementSummary` reuses the existing `MonthExportStatus` enum (`notExported` / `partial` / `complete`):

```swift
struct PlacementSummary: Sendable, Equatable {
  let placementId: String
  let exportedCount: Int          // assets with at least one .done variant for this placement
  let totalCount: Int             // distinct assets with any record under this placement
  let status: MonthExportStatus
  let lastDoneAt: Date?           // computed via lastDoneAt(for:)
}
```

**Naming.** `markVariantExported` matches the existing method name (`ExportRecordStore.markVariantExported`). The
plan keeps it instead of renaming to `markVariantDone` — the rename would touch six test files and a production
call site for no real gain.

**`lastDoneAt(for:)`** is computed on demand: the maximum `exportDate` across `.done` variants of every record under
the placement. Cost is O(records under that placement); for a typical album with hundreds of records this is
microseconds. There is no stored `lastDoneAt` field; no `touchPlacementLastDone` log op; nothing to keep in sync
across log lines. This eliminates the cross-mutation atomicity hazard a stored field would create.

**`priorPlacements(for:)`** returns every distinct `ExportPlacement` whose `kind == .album` and
`collectionLocalIdentifier` matches, ordered by `lastDoneAt(for:)` descending (`nil` last). The album-rename UX
consumes the first entry that has a non-nil `lastDoneAt` (i.e., at least one `.done` record) as the "most recent
prior placement." If no prior placement has `lastDoneAt`, the dialog is suppressed.

The function is `.album`-only by construction. Favorites and Recent placements have no `collectionLocalIdentifier`
and use fixed placement ids (`collections:favorites`, `collections:recent`); they cannot be "renamed" in any sense
visible to the app. The rename-detection codepath is wired to consult `priorPlacements` only for `.album`
selections; an assertion in the resolver guards against a future refactor accidentally invoking rename detection
on synthetic kinds.

To keep `priorPlacements` lookup O(1) over the placement set, the store maintains a secondary index
`placementsByCollectionLocalId: [String: Set<String>]` (values are placement ids). The index is built during load
and updated on every `upsertPlacement` / `deletePlacement`. The `lastDoneAt(for:)` sort scans records under each
candidate placement, but candidates per album are small (usually 1, occasionally 2–3 after renames).

**`removeVariant`** (variant-level) is distinct from **`remove`** (whole `(assetId, placement)` record). Cancellation
today removes the in-flight variant only — other variants on the same asset record may still be `.done` and must
survive.

**`markVariantPending`** is intentionally absent: the existing pipeline transitions directly
`inProgress → done | failed` without a persisted `pending` write.

**`bulkImport(placements:records:)`** writes a single `bulkImport` log op (see *v2 Record Store: On-Disk Format →
Log format*) carrying both arrays. The single-line encoding makes the operation atomic from the recovery
perspective: either the line is fully written and replayed, or it is truncated mid-line and discarded by the
malformed-line skip. There is no partial-bulk-import state. Import flow constructs the timeline placements per
`(year, month)` it encounters and passes both arrays in one call. A record whose `placementId` is not present in
the supplied `placements` is rejected and logged.

**`renamePlacement(from:to:)`** is the atomic rewrite used by the album-rename UX. It records the change as a
single log line; on replay, the loader moves `records[oldId]` to `records[newPlacement.id]`, deletes the old
placement entry, and writes the new one. The corresponding on-disk file move is performed by `ExportManager`
*before* `renamePlacement` is called; if the file move fails, no `renamePlacement` is issued. (See *Album Rename
UX* for atomicity discussion.)

**Load state and mutation guard.** The store carries a minimal `ExportRecordStoreState` enum
(`.unconfigured | .ready | .failed(LoadError)`). All write entry points (`upsert`, `upsertPlacement`,
`markVariant…`, `removeVariant`, `remove`, `bulkImport`, `renamePlacement`, `deletePlacement`) check
`state == .ready` and no-op otherwise (with `assertionFailure` in debug; release silently drops the call to avoid
crashing the app on a benign race during state transitions). Reads return empty results when not `.ready`. UI
disables export controls based on `state`. See *Migration → Loader* for how state transitions on corruption.

**Surviving timeline read APIs.** The current store has ~10 year/month-shaped read methods
(`monthSummary(year:month:totalAssets:)`, `monthSummary(assets:selection:)`, `yearExportedCount(year:)`,
`sidebarSummary(year:month:totalCount:adjustedCount:selection:)`,
`sidebarYearExportedCount(year:totalCountsByMonth:adjustedCountsByMonth:selection:)`,
`recordCount(year:month:variant:status:)`, `recordCountBothVariantsDone(year:month:)`,
`recordCountEditedDone(year:month:)`, `recordCountOriginalDoneAtNaturalStem(year:month:)`,
`isExported(assetId:)`). Almost all of these are preserved with **unchanged signatures** as wrappers that resolve
the timeline placement id from `(year, month)` and route through the placement-scoped store internally. This is
what makes Phase 1's "all existing timeline behavior preserved" exit criterion achievable without an N-call-site
rewrite.

One exception: **`monthSummary(assets:selection:)`** today derives `(year, month)` from `assets.first?` or falls
back to `Date()`. That fallback worked in v1 (where records were keyed by asset id, not placement) but is invalid
under v2 — there is no general "is this asset exported under any timeline month?" mapping that doesn't leak across
scopes. The signature gains explicit `year` and `month` parameters:

```swift
func monthSummary(year: Int, month: Int, assets: [AssetDescriptor], selection: ExportVersionSelection) -> MonthStatusSummary
```

The single call site (`MonthContentView`) already owns both values and updates trivially. This is the only timeline
read-API signature change in Phase 1.

There is intentionally no "is this asset exported anywhere?" API. It invites cross-scope coupling and makes the
independence guarantee leak.

### v2 Record Store: On-Disk Format

The v2 format **normalizes** placement metadata out of records. Placements live once in a top-level dictionary;
records reference placements by id. This avoids per-record placement duplication (~200 bytes/record), gives stale
placements a first-class home (rename detection, collision checking), and replaces delimiter-parsed string keys
with a nested dictionary structure (no `<placementId>::<assetId>` join-and-split, no asset-id encoding gymnastics).

Files (alongside the legacy v1 files, which remain as a frozen backup):

```text
ExportRecords/<destinationId>/
  export-records.json            # v1 snapshot — frozen post-migration
  export-records.jsonl           # v1 log — frozen post-migration
  export-records-v2.json         # v2 snapshot
  export-records-v2.jsonl        # v2 append-only log
  export-records-v2.complete     # marker file; presence means migration finished cleanly
```

**Snapshot format** (`export-records-v2.json`):

```json
{
  "version": 2,
  "placements": {
    "timeline:2025-02": {
      "kind": "timeline",
      "displayName": "2025/02",
      "collectionLocalIdentifier": null,
      "relativePath": "2025/02/",
      "createdAt": "2025-02-01T10:00:00Z"
    },
    "collections:album:abc123def4567890a:9876fedc": {
      "kind": "album",
      "displayName": "Family/Trip 2024",
      "collectionLocalIdentifier": "ABC-123-…",
      "relativePath": "Collections/Albums/Family/Trip 2024/",
      "createdAt": "2026-04-01T10:00:00Z"
    }
  },
  "records": {
    "timeline:2025-02": {
      "ABCDE-F-12345/L0/001": {
        "variants": { "original": { "filename": "IMG_0001.HEIC", "status": "done",
                                    "exportDate": "2025-02-15T12:00:00Z", "lastError": null } }
      }
    },
    "collections:album:abc123def4567890a:9876fedc": {}
  }
}
```

The outer `records` dictionary is keyed by placement id; the inner dictionary by `PHAsset.localIdentifier`. No
delimiter parsing — PhotoKit's opaque asset ids are stored verbatim as JSON keys. JSON requires only that keys be
strings, which `localIdentifier` always is.

Top-level `placements` is the canonical placement metadata. Each record carries only `variants`; `assetId` is the
inner-key, `placementId` is the outer-key. `ScopedExportRecord` (in-memory) joins these with the placement object
for callers, but on disk the placement is referenced once.

**Placement Codable.** `ExportPlacement` always encodes `id` inside its JSON body, in both the snapshot's
`placements` map *and* in `bulkImport` log array elements. The dict key in the snapshot duplicates the value's
`id` field; the encoder asserts `key == value.id` and the decoder treats the value's `id` as authoritative
(logging if they differ). This costs ~30 bytes per placement (~3 KB at 100 placements) — much less than the
complexity of two parallel encodings (one with `id`, one without). Standard Codable synthesis applies; no special
encoder.

A round-trip test asserts encode-then-decode produces identical placements.

There is no stored `lastDoneAt`; "most recent done" is computed lazily from record `exportDate`s on demand (see
*Mutation API → `lastDoneAt(for:)`*).

A placement entry may exist with no records (e.g. cancelled before first export). Stale placement entries from
deleted albums remain until explicit cleanup; they are intentionally load-bearing for collision detection and
rename history.

JSON dictionary key ordering is undefined (Swift dictionaries are unordered). Byte-identity is asserted only on v1
files; v2 snapshots may re-encode equivalent state with different key order.

**Log format** (`export-records-v2.jsonl`), one mutation per line. Placements and records mutate independently:

```json
{ "op": "upsertPlacement", "placementId": "<placementId>", "placement": { ExportPlacementRecord JSON } }
{ "op": "deletePlacement", "placementId": "<placementId>" }
{ "op": "upsertRecord",    "placementId": "<placementId>", "assetId": "<assetId>",
                           "record": { "variants": { ... } } }
{ "op": "deleteRecord",    "placementId": "<placementId>", "assetId": "<assetId>" }
{ "op": "renamePlacement", "fromId": "<oldPlacementId>", "to": { ExportPlacementRecord JSON } }
{ "op": "bulkImport",      "placements": [ { ExportPlacementRecord JSON, "id": "<placementId>" }, … ],
                           "records":    [ { "placementId": "...", "assetId": "...", "variants": { … } }, … ] }
```

Loader applies log entries in order:

- An `upsertRecord` referencing an unknown `placementId` is logged and skipped (defends against truncated logs).
- A `renamePlacement` moves `records[fromId]` to `records[to.id]`, deletes the old placement entry, and writes the
  new one. If `fromId` does not exist (e.g. log truncated), the op is treated as `upsertPlacement(to)`.
- A `bulkImport` is applied as a single transaction: all placements first, then all records. A record whose
  `placementId` is not in the supplied placements is logged and skipped. Encoded as one JSON line so it is either
  fully present (after the line's terminating newline) or fully absent (truncated mid-line on a crash, where the
  malformed-line skip rule discards it).

There is no `touchPlacementLastDone` op. Variant `exportDate`s are persisted on the record itself (existing
behavior) and `lastDoneAt(for:)` derives from them lazily; this side-steps the cross-mutation atomicity that a
separate touch op would have introduced.

`ExportRecordKey` remains as an in-memory ergonomic tuple `(placementId, assetId)`. It is not persisted.

### Atomic Snapshot Writes

Every snapshot write — including the first one produced by migration — uses a `.tmp` + atomic rename pattern with
explicit fsyncs:

1. Write snapshot bytes to `<name>.tmp`.
2. `fsync(<name>.tmp)`.
3. Rename `<name>.tmp` → `<name>`.
4. `fsync(<parent dir>)` so the rename is durable.

The migration additionally writes `export-records-v2.complete` last, with the same `.tmp` + rename + fsync(parent)
pattern, only after the v2 snapshot and an empty log are durable.

## Migration

### Storage Files

Keep the destination-specific store directory:

```text
Application Support/.../ExportRecords/<destinationId>/
```

After migration:

- v2 files are the source of truth.
- v1 files are preserved untouched (passive backup). The v2 store **never writes** to v1 files. This is an invariant
  with a unit test.

### Loader

`ExportRecordStore.configure(for:)`. The marker file `export-records-v2.complete` is the source of truth for whether
v2 is authoritative. v1 fallback is only legal when the marker is missing.

**Snapshot rotation.** Compaction rotates *both* the snapshot and the log so a usable prior v2 state is preserved
without gap:

1. Write `export-records-v2.json.tmp`, fsync.
2. If `export-records-v2.json` exists, rename it to `export-records-v2.json.bak` (atomic). The previous `.bak`,
   if any, is replaced.
3. If `export-records-v2.jsonl` exists and is non-empty, rename it to `export-records-v2.jsonl.bak` (atomic).
   Otherwise leave any prior `.jsonl.bak` alone.
4. Rename `.tmp` to `export-records-v2.json`, fsync parent dir.
5. Create a fresh empty `export-records-v2.jsonl`, fsync parent dir.

After rotation: `.json` + `.jsonl` is the current state, `.json.bak` + `.jsonl.bak` is the prior compaction's
snapshot plus the mutations that happened between it and the current snapshot. Recovering from the `.bak` pair
yields the same logical state as the corrupted current pair *up to the moment of the last compaction* — no gap.

The disk cost is one extra log file (sized at most by the compaction window, ~1000 mutations × small JSON each)
for the duration of the next compaction window. Negligible.

### Loader

`ExportRecordStore.load(...)`. The marker file `export-records-v2.complete` is the source of truth for whether v2
is authoritative. v1 fallback is only legal when the marker is absent.

The store exposes a minimal load-state enum so callers (mainly `ExportManager`) can distinguish "configured and
ready" from "configured but unable to load":

```swift
enum ExportRecordStoreState: Sendable {
  case unconfigured
  case ready
  case failed(LoadError)            // see cases below
}
```

All write entry points check `state == .ready` and no-op otherwise (with an `assertionFailure` in debug). UI
checks `state` to enable/disable export controls. There is no extra "repair mode" UI surface beyond an alert.

**1. Marker present, snapshot decodes.** Overlay `export-records-v2.jsonl`, skipping malformed log lines with
logging. Run `recoverInProgressVariants()` on the loaded records. State → `.ready`. Done.

**2. Marker present, snapshot fails to decode (or is missing).**

  a. If the snapshot exists, rename `export-records-v2.json` to `export-records-v2.json.broken-<ISO8601>` for
     inspection. If the rename fails, delete the file directly; the bytes are lost but recovery proceeds.
  b. If `export-records-v2.json.bak` exists and decodes: promote it (rename `.bak` → `.json`) and overlay
     `export-records-v2.jsonl.bak` first, then `export-records-v2.jsonl` (in that order — the log files cover
     contiguous mutation windows). State → `.ready`. Surface a soft notice:

  > Recovered the previous version of your export records. Existing files on disk are intact; the next export run
  > will re-check anything that changed since.

  c. If `.bak` is missing or also fails to decode: state → `.failed(.snapshotsCorrupted)`. **Do not delete the
     marker; do not auto-rebuild from v1.** Surface an alert with explicit user actions:

  > Couldn't load export records for this destination. The corrupted file is preserved as
  > `export-records-v2.json.broken-…` for inspection. Pick one:
  >
  > • **Rebuild from legacy backup** — discards post-migration state (any collection exports and any timeline
  >   exports made since the original migration); rebuilds v2 from v1. Files on disk are untouched.
  > • **Import from folder** — runs `Import Existing Backup` to rebuild timeline placements from files on disk.
  >   Collection placements are not recoverable from disk and must be re-exported.
  > • **Quit** — leave everything in place; investigate the broken file manually.

  Choosing "Rebuild from legacy backup" or "Import from folder" deletes the marker as part of the action, then
  re-runs the loader. "Quit" leaves `state == .failed`; on next launch the same alert appears. There is no silent
  auto-rebuild.

**3. Marker absent** (cold start, partial migration crash).

  a. Discard any partial v2 files (`export-records-v2.json`, `export-records-v2.jsonl`, both `.bak` files) —
     except `*.broken-…` files, which stay for the user to inspect.
  b. Load the legacy v1 snapshot and log via the existing decode path.
  c. **If v1 also fails to decode:** state → `.failed(.legacyCorrupted)`. Surface an alert:

  > Both the current and legacy export records are unreadable for this destination. Existing files on disk are
  > untouched. Run **Import Existing Backup** once the destination is reachable to rebuild timeline placements
  > from disk. Collection placements are not recoverable from disk and must be re-exported.

  If the destination is currently disconnected, the alert additionally says: "Reconnect the drive before running
  Import Existing Backup."

  Like case 2c, the user must take an explicit action; there is no silent reset. Provided actions: "Import from
  folder," "Reset to empty" (writes a clean empty v2 + marker; explicit destructive action), "Quit."

  d. (v1 decoded successfully) Run `recoverInProgressVariants()` on the in-memory legacy records.
  e. Construct v2 placements (one timeline placement per distinct `(year, month)`) and v2 records (one per
     legacy `ExportRecord`).
  f. Write `export-records-v2.json.tmp`, fsync, rename to `export-records-v2.json`, fsync parent dir.
  g. Truncate or create empty `export-records-v2.jsonl`, fsync, fsync parent dir.
  h. **Last:** write `export-records-v2.complete.tmp`, fsync, rename, fsync parent dir. State → `.ready`.

If the process crashes anywhere between 3a and 3h, the next launch finds no `.complete` marker, discards any
partial v2 files, and re-runs migration from v1. v1 files were never touched, so the migration is idempotent.

**v1 read-only invariant.** Once `export-records-v2.complete` exists, the v2 store never re-encodes v1, never
compacts v1, never appends to the v1 log, and (per the migration test) does not even open v1 for reading on
subsequent launches. The `recoverInProgressVariants()` pass during migration mutates only the in-memory copy used to
build v2 records; that in-memory copy is discarded once v2 is durable. A unit test reads `export-records.json` and
`export-records.jsonl` via `Data(contentsOf:)` before and after migration and asserts byte equality.

### Legacy Record Conversion

Migration walks v1 records once and produces:

- a top-level `placements` map with one timeline placement per distinct `(year, month)` seen,
- a `records` map keyed first by placement id then by asset id.

For each legacy `ExportRecord` where `month` is `1...12` and `year` is reasonable:

```swift
let placementId = "timeline:\(year)-\(String(format: "%02d", month))"

// Reuse or create the placement (one per distinct (year, month)).
let placement = placements[placementId] ?? ExportPlacement(
  kind: .timeline,
  id: placementId,
  displayName: "\(year)/\(String(format: "%02d", month))",
  collectionLocalIdentifier: nil,
  relativePath: String(format: "%04d/%02d/", year, month),
  createdAt: Date()
)
placements[placementId] = placement

records[placementId, default: [:]][record.id] = ScopedRecordBody(variants: record.variants)
```

There is no `lastDoneAt` to compute or carry forward — record `exportDate`s on the `.done` variants are preserved
as-is by migration, and the lazy `lastDoneAt(for:)` accessor reads them on demand.

Records with invalid timeline placement are skipped and the count is logged. Migration does not fail because of one
bad record.

### Backward-Compatibility Invariants

Tested as exit criteria for Phase 1:

- Existing completed timeline exports show as exported after upgrading.
- Existing partially exported and failed variants preserve their status.
- Existing in-progress variants recover to failed with the current recoverable message.
- Existing timeline file paths on disk are unchanged.
- Users do not need to re-run `Import Existing Backup` after upgrading.
- v1 files are byte-identical before and after migration (`sha256(v1.json)` and `sha256(v1.jsonl)` unchanged).
- New collection exports never mutate or delete v1 files.

### `Import Existing Backup`

`BackupScanner` continues to scan only `<YYYY>/<MM>/` and ignores `Collections/`.
`ExportRecordStore.bulkImport(placements:records:)` accepts both arrays and writes placements before records
atomically. The Import flow constructs one timeline placement per `(year, month)` it encounters, builds records
referencing those placement ids, and passes both into a single call. A record whose `placementId` is not in the
supplied placements is rejected and logged. Import only ever produces `.timeline` placements; collection-folder
backfill is out of scope. UI copy states explicitly: "Import scans timeline backups (`YYYY/MM/`) only."

### Migration Tests

A new file `ExportRecordV1ToV2MigrationTests` covers:

- legacy snapshot only → v2 timeline records,
- legacy log only → v2 timeline records,
- legacy snapshot plus log overlay → v2 timeline records with latest mutations,
- legacy flat records → v2 records with synthesized `.original` variant,
- legacy `.inProgress` → v2 `.failed` with recovery message,
- invalid legacy placement skipped and logged,
- v2 marker present and decode succeeds → v2 used; v1 untouched,
- v2 marker missing but v2 files present → v2 discarded; v1 re-migrated,
- v2 marker missing and v2 files corrupt → v2 discarded; v1 re-migrated,
- v2 marker present but v2 snapshot malformed, `.bak` exists and decodes → `.bak` snapshot promoted to `.json`,
  `.jsonl.bak` overlay applied first then current `.jsonl`; soft notice surfaced; state ends `.ready`. **No
  mutations are dropped between the prior compaction and the corruption** because both log files are present.
- v2 marker present but v2 snapshot malformed, `.bak` missing or also corrupt → state stays
  `.failed(.snapshotsCorrupted)`; alert offers Rebuild-from-legacy / Import-from-folder / Quit; marker is **not**
  deleted automatically; choosing a destructive action triggers the rebuild and explicitly deletes the marker.
- v2 marker present, snapshot file absent → same as malformed (try `.bak` first; if also missing, alert with
  explicit user actions).
- v2 marker present and snapshot decodes but log has malformed lines → bad lines skipped and logged; snapshot+good
  log lines applied,
- v2 marker present, snapshot decodes, log file absent → snapshot loads as authoritative, no overlay attempted,
- v2 marker present, v2 valid, v1 also present → loader reads v2 only; assert via `FakeFileSystem` call counts
  that v1 paths are never opened on subsequent loads,
- v1 corrupt + v2 marker absent → state ends `.failed(.legacyCorrupted)`; alert offers Import-from-folder /
  Reset-to-empty / Quit; v1 file bytes preserved on disk; no silent reset.
- compaction rotation: 1500 mutations cause one compaction (S1 → S2 with `.bak` files preserved). Add 50 more
  mutations to the new `.jsonl`. Corrupt S2. Restart. Verify recovery yields S1 from `.bak` + `.jsonl.bak` (the
  1000-ish mutations between S1 and S2) + the 50 new mutations from the current `.jsonl` = full state, no gap.
- v2 mutations log replay across simulated restart produces correct state,
- `renamePlacement` log op replays as: records moved from old id to new, old placement deleted, new placement
  written; partial-replay (interrupted mid-rename) is handled via the `fromId-not-found → upsertPlacement(to)`
  fallback,
- store mutations on `.failed` no-op (with `assertionFailure` in debug; release silently drops),
- timeline completion after migration does not mark favorites or albums exported,
- v1 files byte-identical before and after migration.

The existing `ExportRecordLegacyMigrationTests` is left in place — it covers v0 → v1 (decode-time legacy flat-record
migration inside `ExportRecord.init(from:)`), which is a different migration. The names are intentionally distinct.

## UI Plan

### `ContentView` Split

`ContentView` is too broad for this addition. Sidebar and content branching move out:

```text
Views/
  LibraryRootView.swift          // segmented Timeline/Collections selector and NavigationSplitView composition
  TimelineSidebarView.swift      // current year/month list, extracted from ContentView
  CollectionsSidebarView.swift   // favorites/albums tree
  AssetGridContentView.swift     // generalized MonthContentView
  CollectionRow.swift
  TimelineRows.swift             // existing YearRow/MonthRow moved out of ContentView
```

`ContentView` can remain the environment-object entry point.

### Generalized Asset Grid

Replace `MonthViewModel` with a scope-based view model:

```swift
final class AssetGridViewModel: ObservableObject {
  func loadAssets(in scope: PhotoFetchScope) async
}
```

The grid receives: title, export summary, export button title, fetch scope, export placement.

Asset selection (used for the detail view) carries both asset and placement:

```swift
struct AssetSelection: Hashable {
  let asset: AssetDescriptor
  let placement: ExportPlacement
}
```

`AssetDetailView` (currently asset-scoped — it reads export info by asset id only) takes `AssetSelection` and
queries `exportInfo(assetId:placement:)`. Without this, the detail pane would show timeline export status when
viewing the same asset under a collection.

### Sidebar Counts and Progress

Timeline:

- Preserve current behavior and badges; route through timeline placements internally.

Collections:

- Show asset counts and adjusted counts per row for `Favorites`, `Recent`, and `Albums`.
- Show completion badges for **Favorites and Albums only**. Recent does **not** get a completion badge: Photos
  defines its asset set on a sliding window (~30 days) so today's "all exported" badge would be misleading next
  week when the asset set has shifted. Instead, the Recent row shows a subtitle "Last exported <relative date>"
  derived from `lastDoneAt(for: "collections:recent")`, or "Not yet exported" when there is no `.done` variant.
- Compute counts off the main actor; cache by placement id; invalidate on `PHPhotoLibraryChangeObserver` ticks.
- Cancel in-flight count work for rows that scroll out of view (or for the whole sidebar if the user switches to
  Timeline).
- A neutral loading state until counts arrive is acceptable, matching current timeline behavior.

### Toolbar

Existing global controls keep their meaning:

- pause, resume, cancel/clear,
- `Include originals` toggle,
- queue/progress status.

`Export All` stays timeline-only. No automatic "Export All Collections" in the MVP.

## Implementation Phases

Each phase has narrow exit criteria and is independently shippable behind a feature flag (with the caveat that
Phase 1 ships persistence changes for *every* user — see *Feature flag scope*).

### Phase 0: Stable destination identity (prerequisite)

`destinationId` is a SHA-256 hash of the security-scoped bookmark data today, and bookmark data changes when the
OS regenerates a stale bookmark or when the user re-grants access via the open panel. Each change orphans the
record store. Pre-collections, `Import Existing Backup` is a recovery path; post-collections, it isn't (collection
state is not on-disk-recoverable). This phase makes destination identity stable before v2 ships.

**Identity derivation.** `destinationId = SHA-256(volume UUID || U+0000 || canonical-folder-path)` where:

- *volume UUID* is read from `URLResourceKey.volumeUUIDStringKey` on the destination root. Falls back to
  `URLResourceKey.volumeIdentifierKey` if the platform omits the UUID (rare).
- *canonical-folder-path* is the destination root's URL after `.resolvingSymlinksInPath()`, expressed as a path
  string in the volume's coordinate system.

This survives bookmark refresh on the same drive. It changes when:

- The volume is reformatted (different volume UUID).
- The folder is moved/copied to a different volume.
- The user duplicates the folder via Finder and selects the duplicate.

All three are user-initiated actions that arguably should produce a new logical destination. The records under the
old id remain on disk; selecting the original folder again finds them via the lazy migration below.

**Lazy per-destination migration.** Migration runs in `ExportRecordStore.configure(for: <newId>)`, not at app
launch:

1. If `ExportRecords/<newId>/` already exists, use it. Done.
2. Otherwise, re-derive `<oldId>` from the destination's *current* bookmark bytes using the legacy SHA-256 scheme
   (the pre-Phase-0 derivation, kept around as a one-shot helper).
3. If `ExportRecords/<oldId>/` exists, rename it to `ExportRecords/<newId>/`. Log the migration. Done.
4. If `<newId>` already exists *and* `<oldId>` also exists (which shouldn't happen but defends against bugs), log
   both directories as a conflict and use `<newId>` as-is. The `<oldId>` directory is left untouched for manual
   inspection.
5. If `<oldId>` does not exist, treat the destination as fresh.

The migration only touches the *active* destination (the one being configured). Historical destinations that the
user never reconnects under the new build are left at their `<oldId>` directory; reconnecting them later runs the
same lazy migration at that point. There is no app-launch sweep across all `ExportRecords/*` directories.

Tests:

- Bookmark refresh on the same folder produces an unchanged `destinationId`.
- Same folder accessed via two different bookmark grants resolves to one `destinationId`.
- Two different folders on the same volume produce different ids.
- Two folders with the same name on different volumes produce different ids.
- Lazy migration: configure D1; verify legacy `<oldId>` directory is renamed to `<newId>`. Skip configuring D2
  (offline). Months later, configure D2; verify its legacy directory is renamed at *that* moment, not at first
  launch.
- A folder on an unmounted volume: derivation fails; the configure call returns an unconfigured state and waits
  for the drive to mount; no data is touched.
- Conflict case: pre-create both `<newId>` and `<oldId>` directories; verify the loader keeps `<newId>` and logs
  `<oldId>` as a conflict (no merge, no delete).

Exit criteria:

- A bookmark-refresh test that previously orphaned the record store now resolves to the same `destinationId`.
- Lazy migration test passes for both the just-after-upgrade and reconnected-months-later cases.
- Cross-reference in `auto-sync-background-sync-plan.md`: that plan can drop its "stable destinationId" prerequisite.

**Effort:** ~3–5 days.

### Feature flag scope

`AppFlags.enableCollections` gates **UI surface** (the `Timeline` / `Collections` segmented control, the
`Collections` sidebar, the new export actions). It does **not** gate the persistence change. Phase 1 runs the v1 →
v2 migration on every launch for every user, and it is a one-way migration (v1 files become read-only after,
preserved as backup). There is no downgrade path. The feature flag exists to keep the user-visible surface stable
while the persistence layer is rewired; it is *not* a kill switch.

### Phase 1: v2 store, timeline-only end-to-end (highest risk)

Goal: replace v1 with v2 internally. User-visible surface is unchanged.

- Add `LibrarySelection`, `PhotoFetchScope`, `ExportPlacement`, `ExportRecordKey`, `ScopedExportRecord`,
  `PlacementScope`.
- Add `ExportPathPolicy` and `ExportPlacementResolver` (timeline-only resolver paths in this phase; collection paths
  defined but unreachable until Phase 2).
- Add v2 snapshot/log atomic write + `export-records-v2.complete` marker.
- Implement v1 → v2 migration with crash-safe ordering.
- Make every `ExportRecordStore` mutation and read placement-scoped.
- Update `ExportManager`: `ExportJob` carries placement, queued counts keyed by placement id, year/all enumerate
  placements.
- Update `ExportRecordStore.bulkImport(placements:records:)` to accept both arrays. Update the Import flow in
  `ExportManager` to build per-`(year, month)` timeline placements and matching records before calling.
- Update `ExportRecordStore.configure(for:)` to take a `validate: (String) -> Bool` closure for load-time path
  validation; `ExportManager` constructs the closure from the current `ExportDestination`.
- Change one timeline read-API signature: `monthSummary(assets:selection:)` →
  `monthSummary(year:month:assets:selection:)`. Update `MonthContentView`'s single call site. All other timeline
  read APIs keep their current signatures and become wrappers internally.
- Add `ExportRecordStoreState` and the `.ready`-guard on every write entry point.
- **Rewrite `writeSnapshotAndTruncate`** to follow the *Atomic Snapshot Writes* + rotation discipline: write
  `.tmp`, fsync, rotate `.json` → `.json.bak` and `.jsonl` → `.jsonl.bak`, rename `.tmp` → `.json`, fsync parent
  dir, create empty `.jsonl`, fsync parent dir. The current implementation
  (`ExportRecordStore.swift:602`) skips parent-dir fsyncs; without them, a power loss between the rename and the
  log truncation can leave the snapshot durable but the log un-truncated, producing a state where applying the
  log replays mutations already in the snapshot.
- Update `FakePhotoLibraryService`, `FakeExportDestination`, and all existing tests to the new APIs.
- Add `ExportRecordV1ToV2MigrationTests`, `ExportPathPolicyTests`.
- Add `enum AppFlags { static var enableCollections = false }` in `photo-export/AppFlags.swift`. Phase 4 flips it
  to `true`. Removed in a follow-up cleanup once the feature stabilizes.

Exit criteria:

- All existing functional tests pass through v2 path.
- Existing timeline file paths unchanged.
- Crash-during-migration test passes (no marker → v1 reload).
- v1-file-byte-identity test passes.
- `AppFlags.enableCollections == false`; user-visible surface is timeline-only.

### Phase 2: PhotoKit collection discovery

- Add `PhotoCollectionDescriptor` and `fetchCollectionTree()`.
- Implement `fetchAssets(in:)`, `countAssets(in:)`, `countAdjustedAssets(in:)` for `.favorites`, `.recent`, and
  `.album` scopes. Counts in this phase are uncached; callers re-fetch on every access.
- Wire collection-tree invalidation into the existing `PHPhotoLibraryChangeObserver` callback.
- Add collection fixtures to `FakePhotoLibraryService`.
- Activate the collection paths in `ExportPlacementResolver` and add resolver tests.

Exit criteria:

- PhotoKit isolated; no `PHAssetCollection` leaks past `PhotoLibraryManager`.
- Collection-tree mapping tests pass.
- Resolver produces correct placement and `relativePath` for nested folders, sibling collisions, and the three
  collection kinds (`favorites`, `recent`, `album`).

### Phase 3: ExportManager and destination collection-aware

- Add `urlForRelativeDirectory` to `ExportDestination` and back `urlForMonth` with it.
- Add destination escape-protection tests (absolute paths, `..`, symlinked parent escaping root, intermediate file,
  path length).
- Add `startExportFavorites()`, `startExportRecent()`, and `startExportAlbum(collectionId:)`.
- Wire collection scopes through the queue and record store.
- Implement the **reuse-source copy path** (see *Reuse-Source Copy Path*): when any prior `.done` record (timeline
  or collection) points at an existing source file, copy it to the destination via `FileManager.copyItem` (auto-
  clones on APFS as a free optimization); fall back to PhotoKit re-export only on source-side errors. Destination-
  side errors fail the variant directly.
- Implement the **album sidecar writer**: at the end of every successful collection export run, write
  `_album.json` to the placement folder.
- Add `CollectionCountCache` actor with per-id `Task` handles, cancellation, and `PHPhotoLibraryChangeObserver`
  invalidation. (Phase 2 counts were uncached; this phase introduces the cache.)
- Add the album-rename dialog with three actions (rename folder / create new / cancel; default rename folder).
- Add the `renamePlacement` log op + handler.

Exit criteria:

- Timeline export still writes exactly to `YYYY/MM/`.
- Favorites export writes to `Collections/Favorites/`; Recent to `Collections/Recent/`; Album to
  `Collections/Albums/...`.
- On APFS, a collection export of an asset already exported elsewhere (timeline *or* another collection) results
  in a CoW clone via `FileManager.copyItem` (verified by `volumeAvailableCapacityForImportantUsageKey` delta below
  ~64 KB for a 10 MB known-size file, plus a write-then-divergence behavioral check). Source lookup is "any prior
  `.done` record," not timeline-only.
- On non-APFS, the same export produces a real copy.
- Each placement folder contains a valid `_album.json` after a successful export.
- Cross-scope failure isolation: a failure marking on favorites does not mutate timeline state for the same asset;
  in-flight cleanup on Album A does not mutate Album B records. (Queue cancellation remains global; per-placement
  cancel is out of scope for this plan.)
- Album-rename dialog default ("Rename existing folder") moves the folder on disk and rewrites records via the
  `renamePlacement` log op; cancellation makes no changes; "Create new folder" preserves the previous behavior.
- Album-rename pre-flight gates the primary action when: any export work is in flight (single global queue); new
  path is occupied (by another placement, or an unknown disk artifact). Old folder missing on disk produces the
  "Update records" copy variant rather than blocking the action. After a successful rename, the placement's
  `_album.json` sidecar at the new path is rewritten immediately (best-effort) so it doesn't carry the old
  title/path forward until the next export run.

### Phase 4: UI

- Extract timeline sidebar rows from `ContentView`.
- Add the top `Timeline` / `Collections` segmented selector.
- Add `CollectionsSidebarView` with rows for Favorites, Recent, and Albums.
- Generalize `MonthViewModel` / `MonthContentView` into scope-based asset grid pieces.
- Add export actions for favorites, recent, and albums.
- Empty states: no favorites; no recent; no albums; selected album unavailable; limited Photos access may hide
  some assets.
- Flip the `enableCollections` feature flag on.

Exit criteria:

- Current timeline workflow remains familiar.
- Collection browsing and export are available without a separate window.
- Sidebar remains responsive on a 100-album fixture.

### Phase 5: Docs

Update:

- root `README.md` (current capabilities).
- `docs/reference/persistence-store.md` — v2 schema, key format, migration, atomic write order, fallback rules.
- New `docs/reference/album-sidecar.md` — `_album.json` schema and what tools can do with it.
- `AGENTS.md` — placement vocabulary, do-not-mutate-v1 invariant.
- Website export feature/architecture docs.
- Manual testing guide for collections export, including timeline/collection independence and rename behavior.
- Cross-reference in `auto-sync-background-sync-plan.md`: auto-sync is timeline-scoped.

Exit criteria:

- User-facing docs match new behavior.
- Manual test guide covers independence and rename.
- Persistence reference matches the v2 on-disk format exactly.

## Testing Plan

### Unit Tests

Path policy (`ExportPathPolicyTests`) — the cases listed in *Path Policy → Test cases*.

Placement resolver:

- timeline selection → correct placement id and relative path,
- favorites → `collections:favorites`, `Collections/Favorites/`,
- album with nested folder → correct unsanitized hash and sanitized path,
- two albums with identical title under same folder → distinct placement ids and paths,
- folder rename produces a new placement id,
- album title rename produces a new placement id,
- new placement collides with existing placement → new gets the `_2` suffix; existing path is unchanged ("first
  claimant wins"),
- three newly-discovered colliding albums lex-sorted by `collectionLocalIdentifier` produce `Trip/`, `Trip_2/`,
  `Trip_3/` deterministically,
- a new placement collides with an existing `_2`-suffixed placement → resolver picks `_3`,
- `priorPlacements(for:)` is `.album`-only: `.recent` and `.favorites` selections never invoke rename detection,
- two placements with identical `collectionLocalIdentifier` but different display paths get different placement ids
  (rename-detector behavior),
- title-with-slash vs nested folder produce different placement ids: an album titled `"Family/Trip"` at root has a
  different `displayPathHash8` than an album titled `"Trip"` inside a folder named `"Family"` (confirms the U+0000
  separator),
- two newly-discovered colliding albums in shuffled descriptor order produce identical placement-id assignments
  (the lexicographic sort tiebreaker is honored),
- multiple existing placements that match the same `(kind, collectionLocalIdentifier, displayPathHash8)` triple →
  resolver picks the most-recently-created and logs a warning rather than crashing,
- placement Codable round-trip: encoding then decoding a `placements` map preserves `id` (read from the dict key on
  decode, omitted from the value on encode) and all other fields exactly.

PhotoLibraryService fakes:

- favorites fetch returns only favorite assets,
- album fetch returns only that album's assets,
- folder tree descriptors preserve nesting,
- duplicate album titles produce distinct descriptors.

Export record store:

- placement-scoped `isExported` does not leak across scopes,
- failure on placement A does not mutate placement B for the same asset,
- delete on placement A does not affect placement B,
- two albums containing the same asset are independent,
- bulk import (timeline placement) does not satisfy collection completion.

Export manager:

- month export writes timeline placement,
- year export enqueues N month placements and only timeline ids,
- export-all enqueues only timeline placements,
- favorites export writes favorites placement,
- recent export writes recent placement,
- album export writes album placement,
- queued counts are placement-scoped,
- duplicate asset in timeline and album writes two files,
- `Include originals` behavior unchanged for collection placements,
- variant-level clone: timeline has only `.edited` for asset X with `Include originals = false`; album export of
  the same asset with `Include originals = true` clones `.edited` from the timeline file and PhotoKit-fetches
  `.original` separately,
- destination filename mismatch is OK: timeline filename `IMG_0001 (2).HEIC` (collision-suffixed in `2025/02/`)
  cloned to `IMG_0001.HEIC` in `Collections/Albums/Trip/` (no collision there); the destination record stores the
  destination filename,
- on APFS, `FileManager.copyItem` produces a CoW clone (verified via volume free-space delta below ~64 KB for a
  10 MB source file, plus a write-then-divergence behavioral test); on non-APFS, `copyItem` produces a real copy
  with full free-space delta,
- album-first source: an album-then-timeline export of the same asset reuses from the album record (not PhotoKit),
  confirming the source-lookup is "any prior `.done`" not "timeline only,"
- destination out of space during reuse-copy: variant marked `.failed` with the destination error; PhotoKit is
  not invoked,
- source missing during reuse-copy (prior `.done` file deleted by user): falls back to PhotoKit re-export; the
  stale `.done` record is left unchanged,
- store load error → `ExportManager` disables export buttons and surfaces the alert; UI test asserts the buttons
  are actually disabled, not just that the alert appears,
- failure cleanup on album A does not mutate timeline state for the same asset,
- failure marking on favorites does not touch timeline state for the same asset.

Migration (`ExportRecordV1ToV2MigrationTests`) — full list in *Migration → Migration Tests*.

### Manual Tests

- Fresh destination, export one timeline month.
- Export Favorites containing an already-exported timeline asset; on APFS, verify the new file is a clone (no new
  used-bytes on disk); on exFAT, verify a real copy. Verify `_album.json` is written.
- Export Recent (Recently Added smart album); verify it lands in `Collections/Recent/` with sidecar.
- Export an album containing the same asset; verify a copy under `Collections/Albums/<album>/`.
- Restart app; verify all placements show completed independently.
- Rename an album in Photos.app; reopen the app; verify the rename dialog appears with "Rename existing folder"
  highlighted; confirm; verify the folder on disk has been moved and no re-export occurs.
- Repeat with the secondary action ("Create new folder"); verify a fresh folder is created and the old folder is
  left untouched.
- Cancel the rename dialog; verify nothing changes on disk or in records.
- Create duplicate album titles in different folders; verify folders do not collide on disk and both rows show
  correct counts.
- Run migration from a pre-collections record store; verify existing timeline progress remains and no re-export is
  needed.
- Force-quit the app during migration (simulate by killing after v1 read but before v2 marker); verify next launch
  re-runs migration cleanly.
- Corruption recovery: manually corrupt `export-records-v2.json` (truncate to invalid JSON); launch the app; verify
  the load alert appears and `*.broken-<ISO8601>` is created; quit and relaunch; verify a clean v2 is rebuilt from
  v1 and no exports are lost vs. the v1 baseline.
- Limited Photos access: verify only visible albums/assets appear and copy does not promise full-library collections.
- 100-album fixture: verify sidebar remains responsive while counts load.

## Effort Estimate

Honest sizing, dominated by Phase 1 record-store and `ExportManager` rewires plus test refactors.

- Phase 0 (stable destination identity): ~3–5 days. Cheapest phase, highest leverage.
- Phase 1 (v2 store, timeline-only end-to-end): ~3 weeks. (~22 test files need updating to placement-aware APIs;
  migration crash-safety tests are new; placement normalization is non-trivial work even with the simpler lazy
  `lastDoneAt` approach.)
- Phase 2 (PhotoKit collection discovery, path policy): ~1 week.
- Phase 3 (ExportManager collection-aware, count caching, sidecars, reuse-source copy path, rename UX):
  ~1.5–2 weeks. Larger than the previous estimate: the rename UX with pre-flight is multi-day; the reuse-source
  copy path with proper free-space-delta tests is another 1–2 days; the sidecar writer with drain trigger is its
  own piece.
- Phase 4 (UI): ~1–2 weeks.
- Phase 5 (Docs): ~3 days.

Total: 6–9 weeks. Phase 1 is the highest-risk and largest piece; Phase 3 is the largest user-visible piece.
Time the later phases against Phase 1's actuals before committing to a release date.

## Open Questions

- Should shared albums be included in `Albums` in the MVP, or only regular user-library albums?
- Should collection export support a future metadata manifest so album membership can be reconstructed without
  relying on duplicated folder copies? (Probably yes, but out of scope here.)
