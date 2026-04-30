# Collections Export Plan

Date: 2026-04-30
Status: Proposed (revised after triple-review)

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
placement parameter. Realistic effort: 5–8 weeks, dominated by Phase 1.

## Goals

- Add a top-level two-state UI selector: `Timeline` and `Collections`.
- Keep the current year/month sidebar under `Timeline`.
- Under `Collections`, show:
  - `Favorites`
  - `Albums`
  - one row per user album, preserving folder nesting when available.
- Allow queueing exports from months, years, favorites, and individual albums in one session.
- Write collections under `Collections/Favorites/` and `Collections/Albums/...`.
- Keep timeline and collection export completion state completely independent.
- Preserve the existing edited/originals export-version behavior for every export placement.
- Migrate existing users' export state through a one-time, crash-safe v1 → v2 conversion.
- Keep PhotoKit types behind protocol/model boundaries so views and the export pipeline remain testable.

## Non-Goals

- Restoring album membership back into Photos.
- Exporting smart albums beyond `Favorites` in the first pass.
- Recreating Photos metadata sidecars for albums/favorites.
- Automatically deleting or moving files when an album is renamed or removed in Photos.
- De-duplicating files across timeline and collection folders (no hardlinks/clones — see Risks).
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

- **Migration is the highest-risk step.** v2 must be written atomically with an `export-records-v2.complete`
  sentinel. v1 fallback is only legal when the marker is missing. If the marker is present but v2 fails to decode,
  the store fails closed in read-only repair mode rather than silently downgrading to v1 (which lacks all
  post-migration state). v1 files are never written after migration. (See *Migration*.)
- **Album rename re-exports the album.** Because the placement id includes the album's display path, a renamed album
  is a new placement, and the next collection-export run writes the entire album again to the new folder. A 5,000-
  photo album renamed costs ~5,000 new files. We accept this cost rather than hide it; the UI must warn before the
  re-export starts. (See *Product Behavior → Album Rename UX*.)
- **Placement ID stability and `relativePath` immutability.** The placement id hashes the *unsanitized* display path,
  not the sanitized output. Path policy can be revised without rotating every placement id and forcing a global
  re-export. Crucially, the `relativePath` recorded on a placement is **immutable** for the lifetime of that
  placement: improving the path policy does not retroactively rewrite where existing exports live on disk. New
  placements created after a policy bump use the new policy; existing placements keep their original `relativePath`.
  Anything else lets records drift away from the bytes on disk and silently orphans files.
- **Manual filesystem edits are not detected.** Records are the source of truth for "what is exported where." If a
  user moves, renames, or deletes folders or files in the destination through Finder, the next export will write to
  the path the records remember, which may surprise the user. `Import Existing Backup` is the only recovery path,
  and it covers timeline only.
- **Duplicate files multiply disk usage.** A heavy user (50k assets, 100 albums, ~10% in Favorites) can grow
  on-destination disk use 3–5×. We accept this because dedupe across timeline/collections breaks state independence
  and external-drive users frequently move/restore folders independently. Hardlinks and APFS clones were considered
  and rejected: external drives are usually exFAT/NTFS where neither exists, and APFS clone-aware tools break copy
  semantics that matter for backup workflows. The first collection export shows a one-time confirmation that
  collection export creates additional copies.
- **`ExportManager` refactor is invasive.** ~981 lines today, queue keyed by year/month strings, jobs carry year/month
  inline. Phase 1 rewires the queue and persistence to placement-keyed even though only timeline placements exist
  yet. This is unavoidable — bolting collections on top of an asset-scoped store creates cross-scope corruption.
- **Album titles and folder paths are unstable and lossy.** Sibling-name collisions, Unicode normalization mismatches,
  reserved Windows/exFAT names, trailing dots, and per-component length caps all need a deterministic policy. Without
  it, two distinct albums silently land in the same folder. (See *Path Policy*.)
- **Stale album placements accumulate.** Deleting or renaming an album in Photos leaves orphan placement records in
  the store. Disk cost is negligible (a few KB per record). We accept it for the MVP. Stale records are not displayed
  in the sidebar (the descriptor tree drives display, not the record store) but are intentionally load-bearing for
  rename detection (the dialog needs to find the prior placement) and for path collision detection (a reinstated
  album must not silently steal the deleted album's folder). Cleanup is out of scope.
- **Storage scaling.** With normalized placements (placement metadata stored once, records reference by id),
  snapshot size is dominated by `Σ placements records`, not `placements × assets`. Compaction threshold (currently
  1000 mutations) stays unchanged; profile during Phase 1 and tune if snapshot writes on slow USB targets become
  noticeable. Worst-case a 50k-asset / 100-album library is on the order of single-digit MB.
- **Auto-sync interaction.** When auto-sync ships, it enumerates timeline placements only. This keeps a renamed-album
  re-export from being triggered silently in the background.
- **`ContentView` is too coupled to do this in place.** Sidebar logic moves out before adding the Collections branch.

## PhotoKit API Shape

Use app-owned descriptors at the protocol boundary. `PHAssetCollection`, `PHCollection`, and `PHCollectionList` must
not appear in SwiftUI views or `ExportManager`.

Relevant PhotoKit routes:

- Favorites can be fetched either with a `PHFetchOptions` predicate (`favorite == YES`) or through the smart album
  (`PHAssetCollectionSubtype.smartAlbumFavorites`). Use the predicate for the MVP — the desired output placement is
  fixed and we do not need smart-album metadata.
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
  - `Albums`
    - `<album rows, nested by folder path where possible>`
- Selecting `Favorites` shows its asset grid and an `Export Favorites` action.
- Selecting an album shows its asset grid and an `Export Album` action.
- Albums that resolve to the same display title under different folders remain distinct in state and on disk.

### First-Use Confirmation

The first time the user starts a collection export against a destination, show a confirmation:

> Collection exports create additional copies on disk. Photos that are already in your timeline export will be
> exported again under `Collections/`. This is intentional — collection and timeline exports are independent.

Persist the acknowledgement in `UserDefaults` under key `collectionsExportAcknowledged.<destinationId>`. UserDefaults
is per-machine, which matches the dialog's intent (one acknowledgment per `(machine, destination)` pair). Do not
store this in the v2 record store — it is UI affordance state, not export state.

### Album Rename UX

Album-rename behavior is structural (renaming creates a new placement, old folder is left alone), and the disk cost
is large enough to require explicit consent.

- **When to show.** A prior placement record exists for the same `collectionLocalIdentifier` with a different
  `relativePath`, **and** that prior placement has at least one variant in `.done` status. Suppress the dialog when
  the prior placement has no `.done` variants (e.g. the user cancelled immediately last time) — there are no files
  in the old folder to mention.
- **Which prior path to show.** If multiple prior placements exist (multi-rename chain), show only the most recent
  prior path.
- **Copy:**

  > This album was renamed (was "<most recent prior display path>"). Exporting will write up to <N> new files to
  > `Collections/Albums/<new path>/`. Existing files in the previous folder, if any are still there, will not be
  > moved or removed.

- **Confirm or cancel.** Cancelling does not affect any prior placement records.

Hidden filesystem mutation is never an option. The state model says: export state is about a concrete placement on
disk, not about an album identity.

### Queueing

The queue may contain timeline-month, timeline-year (which expands to N timeline-month jobs), favorites, and album
jobs. The queue shows one global progress state, but per-row queued counts are keyed by **placement id**, not by
year-month string.

### Destination Layout

Relative directories:

```text
timeline month:      <YYYY>/<MM>/
favorites:           Collections/Favorites/
album:               Collections/Albums/<sanitized folder path>/<sanitized album title>/
```

The destination must reject any `relativePath` that escapes the export root after canonicalization (no `..`, no
absolute paths, no symlink traversal at write time).

## Path Policy

The previous wishlist ("strip control characters and confusing names") is replaced with a concrete spec. All album
and folder names go through `ExportPathPolicy.sanitizeComponent(_:)` before becoming a path component.

### Per-component rules

1. **Banned characters** — replaced with `_`:
   - path separators: `/` `\`
   - Windows/exFAT bans: `<` `>` `:` `"` `|` `?` `*`
   - control characters: `0x00`–`0x1F`, `0x7F`

2. **Reserved names** (case-insensitive, on the whole component, ignoring extension): `CON`, `PRN`, `AUX`, `NUL`,
   `COM1`–`COM9`, `LPT1`–`LPT9`. Suffix with `_` (`AUX` → `AUX_`).

3. **Whitespace and dots**:
   - Trim leading and trailing whitespace.
   - Strip trailing dots.
   - If empty after trimming, replace with `_`.

4. **Unicode normalization**: NFC.

5. **Length cap**: 200 UTF-8 bytes per component (leaves headroom for the disambiguation suffix and stays under the
   255-byte component limit on common filesystems). Truncate at a code-point boundary.

6. **Empty input**: `""` → `_`.

7. **Dot-only components**: after trimming, if the component is exactly `.` or `..`, replace with `_`. (Defense in
   depth; the destination's relative-path validator is the primary guard against `..` traversal — `sanitizeComponent`
   only ever sees individual components, never multi-segment paths.)

### Disambiguation

After per-component sanitization, a collision is any two distinct collections that resolve to the same full sanitized
relative path under `Collections/Albums/`. Detection runs against the **whole** sanitized `Collections/Albums/` tree,
not just sibling sets, to handle cases where folder sanitization causes a non-sibling collision.

The collision key is the **NFC, case-folded, slash-joined relative path**. NFC + case-fold reflects what the
filesystems we care about treat as identical (APFS and exFAT are case-insensitive by default; Unicode-equivalent
forms collide on most filesystems). Comparing case-sensitively would let `Family` and `family` write to the same
folder on disk while looking distinct in the records.

Collision detection runs against existing placement records as well as collections currently in the descriptor tree.
When a new placement would collide with an existing placement's `relativePath`, the **new** placement gets the
disambiguation suffix; the existing placement's `relativePath` is never altered. First claimant keeps the bare path.
Stale placements from deleted albums are treated as live claimants for collision purposes, so reinstating an album
later does not silently steal a path.

Suffix format:

```text
<sanitized leaf> [<hash4>]
```

where `<hash4>` is the first 4 hex characters of `SHA256(collectionLocalIdentifier)`. If `[<hash4>]` itself collides
with another existing record, extend to `[<hash8>]` and then `[<hash16>]`. Format is fixed; changes require bumping
`pathPolicyVersion`.

### Test cases

`ExportPathPolicyTests` covers at least:

1. ASCII passthrough.
2. Forward slash → `_`.
3. Backslash → `_`.
4. Reserved name `AUX` → `AUX_`; case-insensitive.
5. Trailing dot stripped (`Family.` → `Family`).
6. Leading/trailing whitespace trimmed.
7. Empty input → `_`.
8. NFC normalization: input `"Cafe\u{0301}"` (NFD: e + combining acute) → output `"Caf\u{00E9}"` (NFC: precomposed).
   Both render as `Café` but differ in bytes; the on-disk form is NFC.
9. Length cap with multi-byte truncation safe at code-point boundary.
10. Two albums with identical titles under the same folder → distinct paths via `[hash4]` suffix.
11. Two albums whose sanitized paths collide across different folders → still distinct via suffix.
12. Component `..` → `_`. Component `.` → `_`. Path-traversal strings like `../foo` are not valid input to
    `sanitizeComponent` (it operates on individual components); the destination's relative-path validator rejects any
    path containing `..` or absolute segments before sanitization runs.
13. NFC + case-fold collision: an album titled `"Caf\u{00E9}"` (NFC) and an album titled `"Cafe\u{0301}"` (NFD) must
    collide. An album titled `"Family"` and an album titled `"family"` must also collide.

### Policy versioning

`pathPolicyVersion` is an `Int` constant baked into `ExportPathPolicy`. Each *collection* placement record stores
the version it was created under, as diagnostic metadata. The recorded `relativePath` is **immutable** for the
lifetime of the placement; bumping the policy version does not retroactively rewrite existing placements. Future
placements created after the bump use the new policy. Improving sanitization does not retroactively fix existing
exports on disk — old paths are user data.

Timeline placements use a fixed `<YYYY>/<MM>/` path that no policy revision will touch. Their `pathPolicyVersion`
is recorded as `0`.

The initial published policy version is `1` (`ExportPathPolicy.currentVersion = 1`). Bumps are monotonic and only
land in plans that explicitly declare them. `0` is reserved for timeline placements.

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
  case album(collectionId: String)
}

enum PhotoFetchScope: Hashable, Sendable {
  case timeline(year: Int, month: Int?)
  case favorites
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
    case album
  }

  let kind: Kind
  let id: String                        // stable, used as the placement-section key on disk
  let displayName: String
  let collectionLocalIdentifier: String?

  // Frozen at placement creation. Never recomputed — even if path policy changes.
  let relativePath: String
  let pathPolicyVersion: Int            // 0 for timeline (fixed path); current policy version for collections

  let createdAt: Date                   // diagnostic; set on first persist
}
```

All fields are `let`. There is no mutable `lastDoneAt`: "most recent done" is computed lazily by the store from
record `exportDate`s (see *Mutation API → priorPlacements*). This avoids the cross-mutation atomicity problem (a
`done` write plus a separate `touchPlacementLastDone` log line could land out of sync after a crash) and keeps the
struct safely usable in `Set` / dictionary keys.

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
album:       collections:album:<collectionIdHash16>:<displayPathHash8>
```

`collectionIdHash16` is the first 16 hex characters (64 bits) of `SHA256(collectionLocalIdentifier)`. The raw
`collectionLocalIdentifier` lives on the placement record body for diagnostics and lookups. Hashing isolates the
placement-id format from PhotoKit's opaque id alphabet (which can in principle contain any character).

`displayPathHash8` is the first 8 hex characters of
`SHA256(unsanitized pathComponents joined with U+0000, then U+0000, then unsanitized title)`. Hashing the
**unsanitized** path means policy changes do not rotate ids; only display renames or folder moves do.

Identity uniqueness is provided by `collectionIdHash16`. The `displayPathHash8` segment is a *rename detector*, not
an identity component: it exists so that rename or folder move produces a new placement id.

**Collision handling.** When the resolver constructs a candidate placement id, it checks whether that id already
exists for a *different* `collectionLocalIdentifier` (for `collectionIdHash16`) or a *different* unsanitized display
path (for `displayPathHash8`). On detected collision, the offending segment is extended:
`collectionIdHash16` → `collectionIdHash24` → `collectionIdHash32`, and `displayPathHash8` → `displayPathHash12` →
`displayPathHash16`. Format is fixed; format changes require bumping `pathPolicyVersion`.

**Scale note.** 64-bit `collectionIdHash16` puts birthday-paradox 50% collision at ~4 billion albums; 32-bit
`displayPathHash8` puts it at ~65,000. The plan's worst-case scaling assumption is ≤1,000 albums per user, where
real-world collision odds are negligible. If a user ever hits a collision in practice (e.g. ≥10,000 albums), the
extension rule above produces longer ids; the format is forward-compatible.

**Concurrent collision among new placements.** When two newly-discovered albums (no existing record for either)
resolve to the same candidate path, the resolver assigns deterministically by sorting candidates lexicographically
on `collectionLocalIdentifier` (which is unique per album) and giving the bare path to the first. This makes the
result independent of PhotoKit traversal order.

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
placements. Uses `ExportPathPolicy` to compute `relativePath` for new placements and stamps the current
`pathPolicyVersion`.

Behavior:

- If an existing placement record matches the resolved `(kind, collectionLocalIdentifier, displayPathHash8)` tuple,
  the resolver returns it unchanged. No recomputation, no policy upgrade in place.
- If multiple existing placements match the same triple (which should never happen but defends against record
  corruption or a buggy past write), the resolver picks the placement with the latest `createdAt`, logs a warning,
  and continues. It does not crash.
- If the candidate `relativePath` collides with an existing placement's `relativePath` (NFC + case-folded), the
  **new** placement gets the disambiguation suffix; the existing placement is never altered.
- If two *newly-discovered* placements (neither has an existing record) resolve to the same candidate path, the
  resolver sorts candidates lexicographically by `collectionLocalIdentifier` before assigning bare/suffixed paths.
  This makes the outcome independent of PhotoKit traversal order.

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
  case album(collectionLocalId: String)
  case anyCollection                // favorites + albums
}
func recordCount(in scope: PlacementScope) -> Int
func summary(for placement: ExportPlacement) -> PlacementSummary
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

To keep `priorPlacements` lookup O(1) over the placement set, the store maintains a secondary index
`placementsByCollectionLocalId: [String: Set<String>]` (values are placement ids). The index is built during load
and updated on every `upsertPlacement` / `deletePlacement`. The `lastDoneAt(for:)` sort scans records under each
candidate placement, but candidates per album are small (usually 1, occasionally 2–3 after renames).

**`removeVariant`** (variant-level) is distinct from **`remove`** (whole `(assetId, placement)` record). Cancellation
today removes the in-flight variant only — other variants on the same asset record may still be `.done` and must
survive.

**`markVariantPending`** is intentionally absent: the existing pipeline transitions directly
`inProgress → done | failed` without a persisted `pending` write.

**`bulkImport(placements:records:)`** writes placements first, then records, atomically as one bulk operation. A
record whose `placementId` is not present in the supplied `placements` is rejected and logged. Import flow
constructs the timeline placements per `(year, month)` it encounters and passes both arrays in one call.

**Repair-mode guard.** All write entry points check `canMutate`:

```swift
guard canMutate else {
  logger.warning("Mutation \(#function) attempted while in repair mode; ignoring")
  assertionFailure("Mutation attempted in repair mode — UI should disable this")
  return
}
```

Debug builds catch the bug via the assertion. Release builds drop the call silently — a benign race during the
transition into repair mode (e.g. a queued export task firing one frame after the loader transitioned) does not
crash the app. The unit test asserts no state change after attempting a write in repair mode.

**Surviving timeline read APIs.** The current store has ~10 year/month-shaped read methods
(`monthSummary(year:month:totalAssets:)`, `monthSummary(assets:selection:)`, `yearExportedCount(year:)`,
`sidebarSummary(year:month:totalCount:adjustedCount:selection:)`,
`sidebarYearExportedCount(year:totalCountsByMonth:adjustedCountsByMonth:selection:)`,
`recordCount(year:month:variant:status:)`, `recordCountBothVariantsDone(year:month:)`,
`recordCountEditedDone(year:month:)`, `recordCountOriginalDoneAtNaturalStem(year:month:)`,
`isExported(assetId:)`). All of these are preserved with **unchanged signatures** as wrappers that resolve the
timeline placement id from `(year, month)` and route through the placement-scoped store internally. This is what
makes Phase 1's "all existing timeline behavior preserved" exit criterion achievable without an N-call-site rewrite.

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
      "pathPolicyVersion": 0,
      "createdAt": "2025-02-01T10:00:00Z"
    },
    "collections:album:abc123def4567890a:9876fedc": {
      "kind": "album",
      "displayName": "Family/Trip 2024",
      "collectionLocalIdentifier": "ABC-123-…",
      "relativePath": "Collections/Albums/Family/Trip 2024/",
      "pathPolicyVersion": 1,
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

Top-level `placements` is the canonical placement metadata. Each placement value omits `id` because the dictionary
key is authoritative; the in-memory struct populates `id` from the key on decode (a Codable round-trip test asserts
this). Each record carries only `variants`; `assetId` is the inner-key, `placementId` is the outer-key.
`ScopedExportRecord` (in-memory) joins these with the placement object for callers, but on disk the placement is
referenced once.

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
```

Loader applies log entries in order. An `upsertRecord` referencing an unknown `placementId` is logged and skipped;
this should never happen in practice but defends against truncated logs.

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

### Loader (revised)

`ExportRecordStore.configure(for:)`. The marker file `export-records-v2.complete` is the source of truth for whether
v2 is authoritative. v1 fallback is only legal when the marker is missing.

**1. Marker present.**

  a. Decode `export-records-v2.json`. On success, overlay `export-records-v2.jsonl`, skipping malformed log lines
  with logging (do not silently downgrade). Run `recoverInProgressVariants()` on the loaded records. The store
  enters `.ready` state. Done.

  b. If `export-records-v2.json` cannot be decoded: **fail closed.** The store enters
  `.repairRequired(message, paths)` state (see *Read-only Repair Mode* below). Do **not** silently fall back to v1
  — v1 lacks all post-migration state (collections plus any later timeline updates). The user can recover via the
  Recover Records menu.

**2. Marker missing** (cold start, or partial migration crash).

  a. Discard any partial v2 files (`export-records-v2.json`, `export-records-v2.jsonl`).
  b. Load the legacy v1 snapshot and log via the existing decode path.
  c. Run `recoverInProgressVariants()` on the in-memory legacy records.
  d. Construct v2 placements (one timeline placement per distinct `(year, month)`) and v2 records (one per
     legacy `ExportRecord`).
  e. Write `export-records-v2.json.tmp`, fsync, rename to `export-records-v2.json`, fsync parent dir.
  f. Truncate or create empty `export-records-v2.jsonl`, fsync, fsync parent dir.
  g. **Last:** write `export-records-v2.complete.tmp`, fsync, rename, fsync parent dir.

If the process crashes anywhere between 2a and 2g, the next launch finds no `.complete` marker, discards any partial
v2 files, and re-runs migration from v1. v1 files were never touched, so the migration is idempotent.

**v1 read-only invariant.** Once `export-records-v2.complete` exists, the v2 store never re-encodes v1, never
compacts v1, never appends to the v1 log, and (per the migration test) does not even open v1 for reading on
subsequent launches. The `recoverInProgressVariants()` pass during migration mutates only the in-memory copy used to
build v2 records; that in-memory copy is discarded once v2 is durable. A unit test reads `export-records.json` and
`export-records.jsonl` via `Data(contentsOf:)` before and after migration and asserts byte equality.

### Read-only Repair Mode

The store exposes its load state:

```swift
enum ExportRecordStoreState {
  case ready
  case repairRequired(message: String, snapshotPath: URL, logPath: URL, legacyV1Path: URL)
}
var state: ExportRecordStoreState { get }
var canMutate: Bool { state == .ready }
```

While `state` is `.repairRequired`:

- All export buttons (`Export Month`, `Export Year`, `Export All`, `Export Favorites`, `Export Album`) are disabled
  with a tooltip pointing at the Recover Records menu.
- Sidebar shows the descriptor tree but no completion badges. Counts may still render (PhotoKit, not store-driven).
- `pause` / `resume` / `cancel/clear` are no-ops.
- `Import Existing Backup` is enabled — it is a recovery path.
- The destination indicator gains a yellow "records corrupted" warning state.
- A persistent in-window banner explains the state and links to the recovery menu.
- Mutation entry points on `ExportRecordStore` enforce `canMutate` via the soft guard pattern (see *Mutation API →
  Repair-mode guard*). A unit test verifies that mutations leave state unchanged in repair mode.

**Drive-disconnected interaction.** When both "drive disconnected" and "records corrupted" apply, the
drive-disconnected state takes precedence in the toolbar indicator (you can't recover until the drive returns). The
repair banner remains visible inside the window. When the drive reconnects, the indicator reverts to the records-
corrupted state.

**Banner copy:**

> Export records for this destination are corrupted and can't be loaded. Existing files on disk are intact, but new
> exports are paused until you recover. Choose **Recover Records…** in the destination menu.

When only the folder-scan option is available (no v1 backup), substitute:

> Choose **Recover via Folder Scan** in the destination menu to rebuild timeline records from existing files.

The Recover Records… menu offers up to two actions, depending on what's recoverable:

1. **Rebuild from v1 backup** — *shown only when `export-records.json` or `export-records.jsonl` exists in the
   destination's records directory.* Destinations created entirely after the v2 era have no v1 files; for those,
   this action is hidden. Discards the corrupted v2 files (after renaming the snapshot to
   `export-records-v2.json.broken-<ISO8601>` for inspection) and re-runs migration from the legacy v1 snapshot/log.
   Any post-migration state — collection placements and timeline mutations made after the original migration — is
   lost. A confirmation dialog enumerates what will be lost (count of timeline placements present in v1 vs.
   last-known v2 totals from the broken snapshot, if extractable).
2. **Rebuild from folder scan** — always available. Runs `Import Existing Backup` against the destination,
   reconstructing timeline placements only. Collection placements are not recoverable from disk and must be
   re-exported. Same broken-snapshot preservation as above.

Both actions require explicit user confirmation. Neither silently falls back to v1.

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
  pathPolicyVersion: 0,
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
- v2 marker present but v2 snapshot malformed → store enters read-only repair mode; v1 is **not** silently used,
- v2 marker present and snapshot decodes but log has malformed lines → bad lines skipped and logged; snapshot+good
  log lines applied,
- v2 marker present, snapshot decodes, log file absent → snapshot loads as authoritative, no overlay attempted,
  store enters `.ready`,
- v2 marker present, v2 valid, v1 also present → loader reads v2 only; assert via `FakeFileSystem` call counts that
  v1 paths are never opened on subsequent loads,
- v2 mutations log replay across simulated restart produces correct state,
- repair-mode mutations leave state unchanged: `upsert`, `markVariant…`, `removeVariant`, `remove`, `bulkImport`
  all return without effect when `canMutate == false`; `assertionFailure` fires only in debug builds,
- Recover Records → Rebuild from v1 backup is offered when v1 files exist; the action renames the corrupted v2
  files to `*.broken-<ISO8601>`, rebuilds v2 from v1, and returns the store to `.ready`,
- Recover Records → Rebuild from v1 backup is hidden when v1 files do not exist (post-v2 destination); only the
  folder-scan option is shown, with adjusted banner copy,
- Recover Records → Rebuild from folder scan: corrupted v2 files preserved; `Import Existing Backup` runs and
  rebuilds timeline placements,
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

- Show asset counts and adjusted counts per row.
- Show completion badges using placement-scoped queries.
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

Each phase has narrow exit criteria and is independently shippable behind a feature flag.

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
- Add `ExportRecordStoreState` and the `canMutate` guard pattern on every write entry point.
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
- Implement `fetchAssets(in:)`, `countAssets(in:)`, `countAdjustedAssets(in:)` for `.favorites` and `.album` scopes.
  Counts in this phase are uncached; callers re-fetch on every access.
- Wire collection-tree invalidation into the existing `PHPhotoLibraryChangeObserver` callback.
- Add collection fixtures to `FakePhotoLibraryService`.
- Activate the collection paths in `ExportPlacementResolver` and add resolver tests.

Exit criteria:

- PhotoKit isolated; no `PHAssetCollection` leaks past `PhotoLibraryManager`.
- Collection-tree mapping tests pass.
- Resolver produces correct placement and `relativePath` for nested folders, sibling collisions, and cross-tree
  collisions.

### Phase 3: ExportManager and destination collection-aware

- Add `urlForRelativeDirectory` to `ExportDestination` and back `urlForMonth` with it.
- Add destination escape-protection tests (absolute paths, `..`, symlinked parent escaping root, intermediate file,
  path length).
- Add `startExportFavorites()` and `startExportAlbum(collectionId:)`.
- Wire collection scopes through the queue and record store.
- Add `CollectionCountCache` actor with per-id `Task` handles, cancellation, and `PHPhotoLibraryChangeObserver`
  invalidation. (Phase 2 counts were uncached; this phase introduces the cache.)
- Add the first-collection-export confirmation dialog.
- Add the album-rename confirmation dialog.

Exit criteria:

- Timeline export still writes exactly to `YYYY/MM/`.
- Favorites export writes to `Collections/Favorites/`.
- Album export writes to `Collections/Albums/...`.
- Cross-scope failure isolation: a failure marking on favorites does not mutate timeline state for the same asset;
  in-flight cleanup on Album A does not mutate Album B records. (Queue cancellation remains global; per-placement
  cancel is out of scope for this plan.)
- Renamed-album dialog appears only when a prior placement for the same `collectionLocalIdentifier` exists with
  different `relativePath` *and* at least one `.done` variant; suppressed otherwise.

### Phase 4: UI

- Extract timeline sidebar rows from `ContentView`.
- Add the top `Timeline` / `Collections` segmented selector.
- Add `CollectionsSidebarView`.
- Generalize `MonthViewModel` / `MonthContentView` into scope-based asset grid pieces.
- Add export actions for favorites and albums.
- Empty states: no favorites; no albums; selected album unavailable; limited Photos access may hide some assets.
- Flip the `enableCollections` feature flag on.

Exit criteria:

- Current timeline workflow remains familiar.
- Collection browsing and export are available without a separate window.
- Sidebar remains responsive on a 100-album fixture.

### Phase 5: Docs

Update:

- root `README.md` (current capabilities).
- `docs/reference/persistence-store.md` — v2 schema, key format, migration, atomic write order, fallback rules.
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

Path policy (`ExportPathPolicyTests`) — at least the 12 cases listed in *Path Policy → Test cases*.

Placement resolver:

- timeline selection → correct placement id and relative path,
- favorites → `collections:favorites`, `Collections/Favorites/`,
- album with nested folder → correct unsanitized hash and sanitized path,
- two albums with identical title under same folder → distinct placement ids and paths,
- folder rename produces a new placement id,
- album title rename produces a new placement id,
- existing placement under old `pathPolicyVersion` is returned unchanged after policy bump (relative path is
  immutable; new placements would use the new policy),
- new placement collides with existing placement → new gets the suffix; existing is unchanged ("first claimant
  wins"),
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
- album export writes album placement,
- queued counts are placement-scoped,
- duplicate asset in timeline and album writes two files,
- `Include originals` behavior unchanged for collection placements,
- failure cleanup on album A does not mutate timeline state for the same asset,
- failure marking on favorites does not touch timeline state for the same asset.

Migration (`ExportRecordV1ToV2MigrationTests`) — full list in *Migration → Migration Tests*.

### Manual Tests

- Fresh destination, export one timeline month.
- Export Favorites containing an already-exported timeline asset; verify a second copy under
  `Collections/Favorites/` and the first-collection-export dialog appears once.
- Export an album containing the same asset; verify a third copy under `Collections/Albums/<album>/`.
- Restart app; verify all three placements show completed independently.
- Rename an album in Photos.app; reopen the app; verify the rename confirmation dialog appears before re-export, and
  declining cancels cleanly.
- Confirm the rename re-export; verify new files land in the new folder and old folder is untouched.
- Create duplicate album titles in different folders; verify folders do not collide on disk and both rows show
  correct counts.
- Run migration from a pre-collections record store; verify existing timeline progress remains and no re-export is
  needed.
- Force-quit the app during migration (simulate by killing after v1 read but before v2 marker); verify next launch
  re-runs migration cleanly.
- Limited Photos access: verify only visible albums/assets appear and copy does not promise full-library collections.
- 100-album fixture: verify sidebar remains responsive while counts load.

## Effort Estimate

Honest sizing, dominated by Phase 1 record-store and `ExportManager` rewires plus test refactors.

- Phase 1 (v2 store, timeline-only end-to-end): ~3 weeks. (~22 test files need updating to placement-aware APIs;
  migration crash-safety tests are new; placement normalization is non-trivial work even with the simpler lazy
  `lastDoneAt` approach.)
- Phase 2 (PhotoKit collection discovery, path policy): ~1 week.
- Phase 3 (ExportManager collection-aware, count caching, UX warnings): ~1 week.
- Phase 4 (UI): ~1–2 weeks.
- Phase 5 (Docs): ~3 days.

Total: 5–8 weeks. Phase 1 is the highest-risk and largest piece; it is also the only phase that touches every
existing test. Time the later phases against Phase 1's actuals before committing to a release date.

## Open Questions

- Should shared albums be included in `Albums` in the MVP, or only regular user-library albums?
- Should collection export support a future metadata manifest so album membership can be reconstructed without
  relying on duplicated folder copies? (Probably yes, but out of scope here.)
