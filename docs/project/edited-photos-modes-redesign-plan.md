# Edited Photos Export — Mode Redesign

Date: 2026-04-27
Issue: https://github.com/valtteriluomapareto/photo-export/issues/13
Branch: `issue-13-support-exporting-edited-photos`
Supersedes: `archive/support-edited-photos-export-plan.md` (the original
three-mode design) and `archive/edited-photos-p2-followups-plan.md` (the
P2 polish layer on top of it). Both are archived as part of this
redesign because the underlying mode shape they assumed no longer
exists; their decisions about non-mode concerns (PhotoKit usage,
ExportRecord schema, scanner architecture, accessibility patterns,
recovery messaging, etc.) carry forward and are still in force.

## Status

Plan only. No code yet. Authored after manual testing of the as-built
feature surfaced two distinct UX problems that cannot be polished away
within the original three-mode design.

## Why we are redoing this

The feature shipped on this branch with three modes — **Originals**,
**Edited**, **Both** — and an `_edited` suffix on edited-bytes filenames.
Manual testing exposed that the model itself is misaligned with how
users actually think about their library:

1. **Originals** mode produces "wrong-looking" files for any photo the
   user has touched in Photos (orientation, crop, exposure, colour),
   because the unmodified original is what's written. This is rarely
   what someone actually wants from a "back up my photos" tool.
2. **Edited** mode silently drops the bulk of the library because
   unedited photos have no required variants under the current
   semantic. The user clicks "Edited", sees three files in the
   destination instead of three thousand, and concludes the app is
   broken.
3. **Both** mode produces what looks to the user like duplicates: the
   sideways original and the corrected edit side by side, indexed in
   Finder as two separate photos. For a user whose "edits" are
   minor metadata fixes (orientation, auto-enhance), this feels like
   the app is wasting disk and confusing their library.

The thing every user actually wants is: **one file per photo, looking
the way the photo looks in Photos.app.** Some users, additionally, want
to keep RAW backups of the original bytes when an edit was applied.
That's it. The current three-mode design forces the user to reason
about a tri-state when their mental model is binary.

This plan redesigns the modes to match the binary mental model.

## Out of scope

- Live Photos paired-video export.
- RAW+JPEG dual-format assets (other than what falls out of the
  `.fullSizePhoto` / `.photo` resource selection we already do).
- Per-asset selection of "include original" — the toggle is global.
- Any change to the destination folder layout (`YYYY/MM/`).
- Localisation of the new strings beyond English; same posture as the
  rest of the app.

# Design

## Modes

Two modes, surfaced as **one** toolbar control: a toggle button.

| Toggle state | Mode | Per-asset output |
|---|---|---|
| **Off** (default) | "Edited" | One file per asset. Edited bytes if Photos has an edit applied; otherwise the original bytes. |
| **On** | "Edited + keep originals" | One file per asset as above, plus a `_orig` companion for assets where Photos has an edit. |

The toggle replaces the three-segment `Originals / Edited / Both`
picker entirely. There is no third state for "originals only" — that
use case is already covered by Apple Photos's own
**File → Export → Export Unmodified Original** and is not a
recurring need for an automated backup tool.

### `ExportVersionSelection`

Collapses to two cases:

```swift
enum ExportVersionSelection: String, Codable, CaseIterable, Sendable {
  /// One file per asset: edited bytes if Photos has an edit, original bytes
  /// otherwise. The user sees what they see in Photos.app.
  case edited
  /// `edited` plus a `_orig` companion for any asset that has Photos edits.
  /// Lets the user keep RAW or pre-edit backups alongside the user-visible
  /// rendering.
  case editedWithOriginals
}
```

The previous case names (`originalOnly`, `editedOnly`, `originalAndEdited`)
are gone.

### `requiredVariants(for:selection:)`

```swift
func requiredVariants(for asset: AssetDescriptor, selection: ExportVersionSelection)
  -> Set<ExportVariant>
{
  switch selection {
  case .edited:
    // Adjusted asset: write the edit. Unedited asset: write the original.
    // In both cases, exactly one variant.
    return asset.hasAdjustments ? [.edited] : [.original]
  case .editedWithOriginals:
    // Adjusted asset: write both, paired. Unedited asset: original only,
    // since there's nothing to pair with.
    return asset.hasAdjustments ? [.original, .edited] : [.original]
  }
}
```

The "nothing applicable" branch from the previous design — a month full
of unedited photos under `editedOnly` — disappears. Every asset is
applicable in every mode. The toolbar's
"This destination has no edited versions to export." message becomes
unreachable and is removed.

## Filename convention

One rule replaces the two-rule `_edited` suffix policy.

> The `.edited` variant is always written at `<stem>.<editedExt>`. The
> `.original` variant is written at `<stem>_orig.<origExt>` when `.edited`
> is also exported for the same asset; otherwise at `<stem>.<origExt>`.

`<stem>` is the asset's original Photos filename without extension.
`<editedExt>` is the extension Photos renders the edit as.
`<origExt>` is the extension on the original resource.

### Examples

| Scenario | Mode | Files in destination |
|---|---|---|
| Plain JPEG, no edits | Edited (default) | `IMG_0001.JPG` |
| Plain JPEG, no edits | Edited + originals | `IMG_0001.JPG` |
| HEIC with JPEG-rendered edit | Edited (default) | `IMG_0001.JPG` |
| HEIC with JPEG-rendered edit | Edited + originals | `IMG_0001.JPG` + `IMG_0001_orig.HEIC` |
| JPEG with JPEG-rendered edit | Edited (default) | `IMG_0001.JPG` |
| JPEG with JPEG-rendered edit | Edited + originals | `IMG_0001.JPG` + `IMG_0001_orig.JPG` |
| Edited video | Edited (default) | `IMG_0010.MOV` |
| Edited video | Edited + originals | `IMG_0010.MOV` + `IMG_0010_orig.MOV` |

### Implications

1. **No `_edited` suffix anywhere in new exports.** Every file at the
   "natural" stem is the user-visible version (edit if available, else
   original).
2. The user-visible filename is always at the original Photos stem with
   the extension matching the bytes — exactly what Apple Photos does
   when exporting a single asset.
3. The `_orig` companion is the *exception*, only present when the user
   explicitly chose to keep originals AND the asset is adjusted.

## Group stem and collision behaviour

The pairing rule (collision suffix follows both files of a pair) stays
intact — only the suffix conventions move. For two adjusted JPEG
photos that happen to share the original Photos filename `IMG_TEST.JPG`,
both edited in Photos:

| | Unsuffixed primary | `_orig` companion |
|---|---|---|
| First asset | `IMG_TEST.JPG` (edit) | `IMG_TEST_orig.JPG` |
| Second asset | `IMG_TEST (1).JPG` (edit) | `IMG_TEST (1)_orig.JPG` |

The collision suffix `(1)` rides on the group stem. The companion
inherits its asset's resolved stem.

### Step-1 fail-path

The conflict guard from the original plan (don't silently overwrite
another asset's file when the paired stem is taken) keeps its shape:

- If the asset has a recorded `.edited` filename whose stem is `S`, and
  the user later toggles "include originals", the `.original` file
  must land at `S_orig.<origExt>`.
- If a different file already lives at `S_orig.<origExt>`, fail the
  `.original` variant with a clear error rather than overwriting or
  silently re-allocating a different stem.

The previous plan had this for the original-stem-taken case; the new
plan applies the same logic with `_orig` flipped onto the original
side.

## Resource selection

`ResourceSelection.selectOriginalResource` and
`ResourceSelection.selectEditedResource` keep their current behavior.
The variants they pick are unchanged. Only what we *do with the
filename* of the bytes changes.

## ExportRecord schema

The schema does not change. We continue to store:

```swift
struct ExportRecord {
  let id: String
  var year: Int
  var month: Int
  var relPath: String
  var variants: [ExportVariant: ExportVariantRecord]
}
```

Each `.original` or `.edited` variant record continues to carry its
own filename, status, exportDate, and lastError. The `filename` field
on the `.original` variant now holds either the bare-stem form or the
`_orig` form depending on which mode wrote it.

### `isExported(asset:selection:)` is strict in both modes

Earlier drafts of this plan tried to relax default-mode completion so
that a re-imported same-extension adjusted asset (whose record ended
up labeled `.original.done` despite the file actually being the edit)
would not get re-exported. Reviewer feedback established that the
relaxation conflates two distinct cases:

- **Post-edit:** an unedited asset was previously exported as
  `.original.done` at the natural stem. The user later applies an edit
  in Photos. The asset is now adjusted; the user expects the new edit
  to be exported. With a relaxed rule that accepts any natural-stem
  `.original.done`, the asset would silently be skipped — the user
  edits a photo and re-runs export, and nothing happens. Bad.
- **`vacation_orig.JPG` user filename:** an asset whose actual Photos
  filename ends with `_orig`. With a filename-only `isOrigCompanion`
  predicate driving rejection, the unedited asset would be perpetually
  re-exported because the predicate fires on the user's own filename.
  Bad too.

Both edge cases dissolve under a strict rule that uses the asset's
*current* `hasAdjustments` to decide what's required, then checks
those exact variants against the records:

```swift
func isExported(asset: AssetDescriptor, selection: ExportVersionSelection) -> Bool {
  guard let record = recordsById[asset.id] else { return false }
  let required = requiredVariants(for: asset, selection: selection)
  return required.allSatisfy { record.variants[$0]?.status == .done }
}
```

Walking the cases:

- **Unedited asset, default mode.** `requiredVariants = [.original]`.
  Check `.original.done`. The filename's shape is irrelevant — the
  asset isn't adjusted, so a `_orig`-ish filename is just the user's
  filename. ✓
- **Adjusted asset, default mode.** `requiredVariants = [.edited]`.
  Check `.edited.done`. A pre-existing `.original.done` (from when
  the asset was unedited, or from a re-import that mis-classified the
  natural-stem file as `.original`) does not satisfy. The pipeline
  re-enqueues `.edited`. ✓
- **Adjusted asset, include-originals.** `requiredVariants = [.original,
  .edited]`. Both must be done. Orphaned `_orig` companion (i.e.
  `.original.done` at `_orig` filename, but `.edited.failed`) does
  not satisfy. ✓
- **Unedited asset, include-originals.** `requiredVariants = [.original]`.
  Same as default mode for unedited. ✓

The cost of this strictness shows up in two scenarios that are now
documented limitations rather than silent skips:

- **Post-edit re-export** lands the new edit at a collision-suffixed
  path. The destination ends up with `IMG_0001.JPG` (old unedited
  bytes, recorded as `.original.done`) and `IMG_0001 (1).JPG` (new
  edit, recorded as `.edited.done`). The user has both states; the
  detail pane shows both rows. A future enhancement could implement
  *same-asset controlled overwrite* (the pipeline replaces a same-
  asset's prior `.original` file at the natural stem when writing a
  fresh `.edited` to the same path), but that's deliberately out of
  scope here — the (1)-suffixed file is a one-time cost on first
  re-export after each new edit, and no further duplicates accumulate
  on subsequent runs.
- **Re-import same-extension adjusted asset.** The scanner labels the
  natural-stem JPEG as `.original`. The next default-mode export sees
  `.edited` not done, re-exports, and lands at `IMG_0001 (1).JPG`. One
  duplicate per asset, then steady state. Same documented limitation.

`ExportFilenamePolicy.isOrigCompanion(filename:)` is **not** used in
`isExported` under this design. The predicate is still needed by the
sidebar's records-only count heuristic (see the `ExportRecordStore
API surface` section) and by the scanner's `_orig` parser, but
asset-aware completion checks consult the asset descriptor directly.

## ExportRecordStore API surface

- `markVariantInProgress / markVariantExported / markVariantFailed /
  removeVariant` — keep their signatures.
- `bulkImportRecords` — keeps the per-variant merge.

### Two evaluation paths: asset-aware vs. records-only

Completion is evaluated in two places with different inputs:

- **The export pipeline and the month-content view** have the loaded
  `AssetDescriptor` and so can call the strict, asset-aware
  `isExported(asset:selection:)`. This is the authoritative check.
- **The sidebar `YearRow` and `MonthRow`** do not have descriptors
  loaded for un-selected scopes. They evaluate completion from
  records alone, using a filename heuristic that approximates the
  asset-aware rule. This is an approximation, not a contract; the
  detail pane and the asset-aware path remain authoritative.

### Asset-aware (authoritative)

- `isExported(asset:selection:)` — strict, see the previous section.
- `monthSummary(assets:selection:)` — counts assets that satisfy
  `isExported(asset:selection:)` against the descriptor list. Used by
  `MonthContentView` because it has the descriptors loaded.

### Records-only (sidebar approximation)

The sidebar can't call `isExported(asset:selection:)` because it
doesn't have descriptors loaded for un-selected scopes. It needs an
approximation derived from the records alone — but a naive
"natural-stem `.original.done` always counts" rule overcounts in two
realistic cases:

1. **Post-edit.** An asset was previously exported as unedited
   (`.original.done` at natural stem), the user later applied an
   edit in Photos, and the asset is now adjusted. Strict completion
   says it's incomplete (under default mode, `.edited` is now
   required and isn't done). A naive rule would still count it.
2. **Same-extension re-import.** A re-imported destination has the
   adjusted asset's edit at the natural stem, mis-classified as
   `.original.done`. Strict completion says it's incomplete.

To match the asset-aware result without loading descriptors, the
sidebar uses a **filename-aware count + an
adjusted-count-based cap**. The cap reuses the lazily-loaded
`countAdjustedAssets` plumbing from the existing
`originalAndEdited` summary (which proved load-bearing for the
same reason). This is the trade-off Codex's earlier review pass
flagged but the redesign initially over-simplified away.

```swift
/// Records-only approximation of "fully exported under this
/// selection," capped by the count of unedited assets in scope so
/// that natural-stem .original.done records belonging to currently-
/// adjusted assets cannot over-contribute.
///
/// `adjustedCount` is required for both modes. Pass nil only when
/// the count hasn't loaded yet — callers should render a neutral
/// "loading" state in that case rather than treat nil as zero.
func sidebarSummary(
  year: Int, month: Int, totalCount: Int, adjustedCount: Int?,
  selection: ExportVersionSelection
) -> MonthStatusSummary?

/// Year-scope variant. Iterates each month with its (totalCount,
/// adjustedCount) pair, sums the per-month exported counts, and
/// returns the rolled-up summary. Pass nil for a month's
/// adjustedCount when it hasn't loaded; the sidebar renders the
/// year-level badge as neutral until every populated month has
/// reported.
func sidebarYearSummary(
  year: Int,
  totalCountsByMonth: [Int: Int],
  adjustedCountsByMonth: [Int: Int?],
  selection: ExportVersionSelection
) -> MonthStatusSummary?
```

Per-mode formula inside both methods, expressed against records in
scope:

```text
bothDone        = records with .original.done AND .edited.done
editedDone      = records with .edited.done (regardless of .original)
origOnlyAtStem  = records with .original.done at the natural stem
                  (i.e. !isOrigCompanion(filename:)) AND .edited NOT done
uneditedCount   = max(0, totalCount - adjustedCount)

Default mode:
  exported = editedDone + min(origOnlyAtStem, uneditedCount)

Include originals:
  exported = bothDone + min(origOnlyAtStem, uneditedCount)
```

Walking the cases the cap covers:

- **All assets correctly exported.** `editedDone` (or `bothDone`)
  picks up every adjusted asset; `origOnlyAtStem` picks up every
  unedited asset; the `min` is a no-op (both sides equal).
- **Post-edit.** When an asset becomes adjusted after export,
  `adjustedCount` increases by 1, `uneditedCount` decreases by 1,
  and the `min` cap correctly drops one record from
  `origOnlyAtStem`'s contribution. The asset's record is no longer
  counted as fully exported. ✓
- **Same-extension re-import.** Records are all
  `.original.done` at natural stem (scanner can't tell apart edit
  from original). `editedDone` is zero, `origOnlyAtStem` is high,
  but the cap pins it at `uneditedCount`. The remaining adjusted
  assets show up as not exported, prompting re-export. ✓
- **`vacation_orig.JPG` user filename, asset unedited.** Record
  is `.original.done` at `vacation_orig.JPG`. `isOrigCompanion`
  fires, so the record is **not** counted in `origOnlyAtStem`.
  Sidebar under-counts by 1. The asset-aware path is correct.
  Documented in the manual testing guide.

The undercount in the `vacation_orig` case is acceptable; it's a
one-asset error in a corner case. The post-edit and re-import
overcounts the cap prevents are common and would mislead users
into thinking work is complete that isn't.

- `recordCount(year:month:variant:status:)` — stays.
- `recordCountBothVariantsDone(year:month:)` — stays.
- A new helper `recordCount(year:month:variant:status:filenameKind:)`
  (or its inline equivalent in the formula above) computes
  `origOnlyAtStem` by filtering on `isOrigCompanion(filename:) == false`.

### Filename predicate helper

```swift
extension ExportFilenamePolicy {
  /// True when `filename`'s stem (after stripping a trailing collision
  /// suffix like ` (1)`) ends with `_orig`. Used by the sidebar's
  /// records-only count heuristic and by the scanner's `_orig` parser.
  /// **Not** used by the asset-aware `isExported(asset:selection:)`,
  /// which consults `asset.hasAdjustments` directly and so doesn't
  /// need filename inspection.
  static func isOrigCompanion(filename: String) -> Bool
}
```

## Pipeline (`ExportManager`)

`ExportJob` keeps the per-job selection snapshot.

### Group stem allocation

Three cases the pipeline must handle correctly so the pair never
splits across stems:

1. **Inherited from a prior run.** The asset already has a `.done`
   variant record. Use that variant's filename to recover the group
   stem, then enforce the step-1 fail-path (paired conflict guard).

   - Existing `.edited.done` → group stem is the unsuffixed stem of
     its filename.
   - Existing `.original.done` at natural stem → group stem is the
     unsuffixed stem of its filename. (This case happens for unedited
     assets and for include-originals exports of unedited assets.)
   - Existing `.original.done` at `_orig` form → strip the trailing
     `_orig` (and any optional `(N)` collision suffix) to recover the
     group stem.

2. **Fresh export, default mode.** Only one variant is required for
   the asset. No pairing needed; the pipeline resolves a single
   filename via `uniqueFileURL` against the one target file.

3. **Fresh export, include-originals mode for an adjusted asset.**
   Both variants are required and neither is inherited. **Allocate
   the paired group stem before writing either variant**, so the pair
   cannot end up on different stems. Concretely:

   ```swift
   private func allocatePairedGroupStem(
     baseStem: String, editedExt: String, originalExt: String, destDir: URL
   ) -> String {
     var stem = baseStem
     var index = 1
     while index < 10_000 {
       let editedTarget = destDir.appendingPathComponent(stem)
         .appendingPathExtension(editedExt)
       let origTarget = destDir.appendingPathComponent(stem + "_orig")
         .appendingPathExtension(originalExt)
       if !fileSystem.fileExists(atPath: editedTarget.path)
         && !fileSystem.fileExists(atPath: origTarget.path)
       {
         return stem
       }
       stem = "\(baseStem) (\(index))"
       index += 1
     }
     return stem
   }
   ```

   The chosen stem is then passed to *both* variant writes; the
   `.edited` lands at `<stem>.<editedExt>`, the `.original` at
   `<stem>_orig.<origExt>`, paired by construction.

   This replaces the current `allocateEditedOnlyGroupStem` (which was
   for `editedOnly` mode and is no longer reachable). Same shape, new
   suffix.

### Scenario the explicit pre-allocation prevents

Without this rule, with `.original` writing first (current order):

1. `.original` resolves to `IMG_0001_orig.HEIC` (free) and writes.
2. `.edited` then tries `IMG_0001.JPG` and finds it taken (by an
   unrelated asset in the same destination).
3. `.edited` increments to `IMG_0001 (1).JPG`.
4. Result: `IMG_0001_orig.HEIC` (companion of stem `IMG_0001`) and
   `IMG_0001 (1).JPG` (edit at stem `IMG_0001 (1)`). Pair is split.

With pre-allocation, the pipeline notices `IMG_0001.JPG` is taken
when it scans for the paired stem, increments the *whole pair* to
`IMG_0001 (1)`, and writes `IMG_0001 (1)_orig.HEIC` +
`IMG_0001 (1).JPG` together. Stems match.

Add a regression test asserting this behaviour: pre-seed the
destination with a stray file at the asset's natural-stem edited
filename and verify the paired export of a fresh include-originals
write lands at the next-available paired stem rather than splitting.

### `exportSingleVariant`

For `.edited`: filename is `<stem>.<editedExt>`. No suffix logic.

For `.original`: the pipeline knows whether `.edited` is being
written for this same job (it iterates `orderedVariants`). If yes,
use `<stem>_orig.<origExt>`. If no, use `<stem>.<origExt>`.

For fresh include-originals jobs, the stem comes from
`allocatePairedGroupStem` and is shared between the two variant
writes.

### `inheritedGroupStem(from:)`

The parser is updated:

- An existing `.edited` variant record's filename → unsuffixed
  natural stem. `splitFilename(filename).base`.
- An existing `.original` variant record's filename — call
  `parseOriginalCandidate(filename:)`. If parsed (i.e. has `_orig`),
  use the parsed `groupStem`. Otherwise the filename is at the
  natural stem; use `splitFilename(filename).base`.

The previous `_edited` recognition path is removed.

### `EnqueueOutcome`

Simplifies: the `.nothingApplicable` case goes away (no selection
produces an empty required set anymore). `enqueue*` returns
`.enqueued(Int)` or `.alreadyComplete`. The toolbar's empty-run
message correspondingly drops the "no edited versions" copy and
keeps only the "already exported" copy.

The picker-locking gate (already in place) still applies: the toggle
button must be disabled while `hasActiveExportWork` is true.

## Backup scanner

The scanner needs three small changes plus a related type cleanup.

### 1. Drop the `_edited` parser path and the classification enum

`ExportFilenamePolicy.parseEditedCandidate(filename:)` goes away —
*new* exports no longer produce `_edited` filenames, and we don't
need to support parsing them on import. (See the **Migration**
section for the on-disk implication.)

The associated `ExportFilenameClassification` enum is also removed
**in its entirety**, not just the `.edited` case. Its only purpose
was to record *how* the scanner matched a file; under the new design
the scanner has fewer paths and the only data the import flow
actually consumes from `MatchedExportFile` is `variant`,
`asset`, and `file`. Concretely:

- Delete the `ExportFilenameClassification` enum from
  `ExportFilenamePolicy.swift`.
- Drop the `classification: ExportFilenameClassification` field from
  `BackupScanner.MatchedExportFile`.
- Update the import flow in `ExportManager.startImport` (which
  previously read `matched.classification` for nothing load-bearing)
  to consume only `matched.variant`.

If a future feature needs to know the matching path for diagnostics,
re-introduce a thinner enum at that point. For this redesign, drop it.

### 2. Add a `_orig` parser

```swift
struct ParsedOriginalCandidate: Equatable {
  /// Stem before the `_orig` marker. Includes any app-added collision
  /// suffix (e.g. "IMG_0001 (1)").
  var groupStem: String
  /// `groupStem` with any trailing collision suffix stripped, used for
  /// matching against original resource stems.
  var canonicalOriginalStem: String
  /// Trailing per-file collision suffix on the `_orig` filename itself
  /// (e.g. `(1)` in `IMG_0001_orig (1).HEIC`).
  var fileCollisionSuffix: Int?
  var fileExtension: String
}

extension ExportFilenamePolicy {
  static let originalSuffix = "_orig"
  static func parseOriginalCandidate(filename: String) -> ParsedOriginalCandidate?
}
```

### 3. Updated classification order

`BackupScanner.matchSingleFile` becomes:

1. **Try `_orig` companion.** If `parseOriginalCandidate(filename:)`
   succeeds, **collect** all fingerprints that satisfy *all of*:
   - `hasAdjustments == true`,
   - file extension matches one of the fingerprint's original
     resource extensions,
   - the parsed `groupStem` matches one of the fingerprint's
     original resource stems **OR** the parsed `canonicalOriginalStem`
     matches one of those stems.

   The two-stem check is load-bearing: when a user's actual original
   filename ends with ` (N)` (e.g. they imported an asset already named
   `IMG_0001 (1).JPG`), the asset's stem in the fingerprint is
   `IMG_0001 (1)` and `groupStem` is what matches; when the suffix is
   one the app added itself, only `canonicalOriginalStem` matches.
   Mirror of the parsing pattern from the previous `_edited`
   classifier.

   If at least one candidate matches, **pass the candidate set into
   the existing `narrow(file:candidates:assetById:variant:)` helper**
   with `variant: .original`. `narrow` resolves a unique fingerprint
   by date and lazy file-metadata discriminators, the same way the
   pre-redesign `_edited` flow worked. This handles the realistic
   case where two adjusted assets share an original Photos filename
   (e.g. `IMG_TEST.JPG`) and would both match the stem check; date
   and metadata pick the right one. Returning an `.ambiguous` from
   `narrow` is also valid — that surfaces as an ambiguous import
   match, the same as it does for cross-extension edited files in
   step 4.

   If **no** candidate matches the filter, **fall through to step 2 —
   do not return early.** This guards against a real user filename
   ending in `_orig` (e.g. `vacation_orig.JPG`) being silently lost
   when there is no asset with adjustments and stem `vacation`.

2. Else if the filename exactly matches a known original resource
   filename → `.original`.
3. Else if the filename's collision-stripped form matches a known
   original resource filename → `.original`.
4. Else if the filename's stem (collision-stripped) matches a known
   original resource stem AND the asset has `hasAdjustments == true`
   AND the file extension matches one of the asset's edited resource
   extensions → `.edited`.
5. Else unmatched.

Steps 1–3 cover the unambiguous original cases. Step 4 covers the
cross-extension edited case (HEIC original + JPEG edit, exported in
either mode). The same-extension same-stem case (JPEG original + JPEG
edit, exported in default mode) is **classified as `.original` by
step 2**, not `.edited` — there is no information in the filename to
distinguish edited bytes from original bytes when both share an
extension and a stem.

This is the documented import limitation. Under the strict
asset-aware `isExported`, a same-extension adjusted asset whose
record came in as `.original.done` from a re-import will look
incomplete on the next default-mode run (because
`requiredVariants(.edited)` for an adjusted asset isn't satisfied by
a `.original` record), and the pipeline re-exports `.edited`. The
`uniqueFileURL` collision logic adds a `(1)` suffix because the
natural-stem path is taken. The destination ends up with
`IMG_0001.JPG` (the file as found by the scanner — it's the edit
bytes, but the records call it `.original`) plus `IMG_0001 (1).JPG`
(the re-exported edit, recorded as `.edited.done`). One duplicate
per same-extension adjusted asset, then steady state.

This is the trade-off the new naming convention accepts: the
scanner cannot losslessly round-trip variant identity for the
same-extension case, and the strict completion rule cannot
disambiguate without descriptor context. The duplicate is recorded
correctly and visible in the asset detail pane; future work could
add same-asset controlled overwrite to resolve it cleanly.

### Scanner regression tests to add

- A user whose actual original resource filename is `vacation_orig.JPG`
  (matching the suffix shape but not the suffix semantic). Step 1
  fails to match (no asset with `vacation` stem and adjustments) and
  the file falls through to step 2 where its exact filename matches
  the user's original resource. → `.original`. Verifies the
  fall-through, not an early return.
- An asset whose original resource filename is `IMG_0001 (1).JPG`
  (native ` (1)` in the user's filename, not app-added). The
  destination contains `IMG_0001 (1).JPG` (the edit) and
  `IMG_0001 (1)_orig.JPG` (the companion). Step 1's `groupStem`
  branch matches the companion to the fingerprint; the natural-stem
  file matches via step 2. Both classify correctly without the app
  collapsing the native suffix into a canonical stem.

### Asset fingerprint

`AssetFingerprint` no longer needs `editedResourceFilenames` for the
classification path — but we still want the edited resource extensions
as the *strong filter* in step 4. The struct stays as-is; only the
classifier changes.

## PhotoLibraryService

`countAdjustedAssets(year:month:)` and `countAdjustedAssets(year:)`
**stay**. The sidebar's records-only count rule needs an
adjusted-assets cap to avoid overcounting in the post-edit and
same-extension re-import cases (see the **Records-only sidebar
approximation** section above).

This means:

- The methods stay on `PhotoLibraryService`, `PhotoLibraryManager`,
  and the fake.
- The lazy cache (`adjustedCountByYearMonth`) and its invalidation
  on `photoLibraryDidChange` and authorization changes stay.
- `ContentView` keeps `adjustedCountsByYearMonth` state,
  `loadAdjustedCount(year:month:)`, and the
  `.task(id: "\(year)-\(month)-adjusted")` modifier on `MonthRow`.
- `YearRow`'s `yearTotal` returning `Int?` (suppresses the badge
  while any month's adjusted count is still loading) stays.

The plan's earlier "delete countAdjustedAssets" section was the
mistake — the simplification was a mirage.

## UI

### Toolbar

The segmented `Originals / Edited / Both` picker is replaced with a
toolbar `Toggle` styled `.button`:

```swift
ToolbarItem(placement: .automatic) {
  Toggle(isOn: $exportManager.includeOriginals) {
    Label("Include originals", systemImage: "doc.on.doc")
  }
  .toggleStyle(.button)
  .disabled(exportManager.hasActiveExportWork)
  .help(includeOriginalsHelp)
}
```

`exportManager.includeOriginals` is a `@Published Bool` derived from
the `ExportVersionSelection` (false → `.edited`, true → `.editedWithOriginals`).
The setter persists to UserDefaults under the existing
`exportVersionSelection` key, mapping bool to enum raw value.

The help tooltip:

- When the toggle is **off**: `"Each photo is exported once, in the version Photos shows. Turn on to also keep an original-bytes copy alongside edited photos."`
- When the toggle is **on**: `"Edited photos export both the user-visible version and a `_orig` companion with the original bytes."`
- When the toolbar is **locked** (active export): `"Available after the current export finishes."`

The button shows `Label("Include originals", systemImage: "doc.on.doc")`
in both states; SwiftUI's `.toggleStyle(.button)` handles pressed-state
visualisation. Off state reads as the unpressed default; on state shows
the macOS pressed/active accent.

### Picker accessibility

```swift
.accessibilityLabel("Include originals for edited photos")
.accessibilityHint("Off by default. Turn on to keep original-bytes copies alongside edited photos.")
```

The label disambiguates "originals" (which without context could mean
"export only originals" — the meaning we explicitly removed).

### Onboarding

Onboarding step 2's sub-picker — currently a three-segment control —
becomes the same toggle button form, off by default:

```swift
Toggle("Include originals for edited photos", isOn: $includeOriginals)
  .toggleStyle(.checkbox)
```

In onboarding, the `.checkbox` style fits the "settings list"
appearance better than a button. The help text below it shrinks to a
single sentence:

> "Off: one file per photo. On: also keep original copies for photos
> you've edited."

### Sidebar (`ContentView` `YearRow`, `MonthRow`)

The mode-qualified `"edited"` text and badge caption from the
previously-shipped feature go away — under the two new modes, every
asset is in scope, so there is no longer a denominator difference
that needs a qualifier. But the `originalAndEdited` summary's
infrastructure (lazy adjusted counts per month, `yearTotal` returning
`Int?` while counts load, the `.task(id:)` on `MonthRow`) **stays**,
because the records-only count rule still needs `adjustedCount` as
its cap (see **Records-only sidebar approximation** above).

Concretely:

- `MonthRow` calls
  `sidebarSummary(year:month:totalCount:adjustedCount:selection:)`
  on the store, passing the lazily-loaded adjusted count. While
  `adjustedCount` is nil, the row renders the neutral "…" state
  (existing pattern carries over).
- `YearRow` calls
  `sidebarYearSummary(year:totalCountsByMonth:adjustedCountsByMonth:selection:)`,
  passing the same per-month maps that `ContentView` already
  maintains. While *any* populated month's adjusted count is nil,
  the year-level badge is suppressed (existing
  `yearTotal` returns nil → no badge).
- The "edited" caption next to badges goes away. The neutral
  "…" state for missing adjusted counts stays.
- Tooltips on year/month rows simplify to a single sentence per mode:
  - default: `"<MonthName> <Year>: X of Y photos exported."`
  - includeOriginals: `"<MonthName> <Year>: X of Y photos fully exported (including original copies for edited photos)."`

What stays in `ContentView`:

- `adjustedCountsByYearMonth` state.
- `loadAdjustedCount(year:month:)`.
- `monthTotals(for:)` and `adjustedMonths(for:)` helpers.
- The `.task(id: "\(year)-\(month)-adjusted")` modifier on
  `MonthRow`.
- `YearRow.yearTotal` returning `Int?`.

What goes away:

- The mode-qualified `"edited"` caption next to badges.
- The mode-aware partial/notExported text variants.

The plan's previous draft mistakenly listed the adjusted-count
plumbing for deletion. That deletion would have produced a sidebar
that overcounts whenever a user edits a photo in Photos after a
prior export, or whenever a re-imported destination contains
same-extension adjusted assets — both cases would silently report
"100% backed up" when work was actually pending. Keeping the
plumbing keeps the sidebar honest.

Sidebar still has one residual approximation: a user-imported asset
whose actual Photos filename ends with `_orig` (e.g.
`vacation_orig.JPG`) is recorded with that filename, and
`isOrigCompanion` fires structurally, so `origOnlyAtStem` does not
include the record. Sidebar under-counts by 1 for each such asset.
The detail pane and `MonthContentView` summary remain correct via
the asset-aware path. Documented in the manual testing guide.

### `MonthContentView`

The `exportSummaryView` keeps its three-state shape (complete /
partial / not-exported) but becomes mode-agnostic in copy. The label
just says `"X/Y exported"` regardless of mode.

The thumbnail's blue dot on `ThumbnailView` keeps reacting to the
selection (toggling the toggle off → some adjusted assets that had
`_orig` companions are now "fully exported under default mode" → dot
disappears even though `_orig` files are missing; toggling it on →
those adjusted assets need `_orig` and the dot returns).

### `AssetDetailView`

Per-variant rows simplify. `Edits: Available in Photos` / `Edits: None
in Photos` stays. The variant labels (`Original` and `Edited`) stay
exactly as they are — the schema didn't change, only what their
filenames look like on disk.

### App icon / branding

No changes.

## Migration

**None needed for users.** This branch has not shipped, so no on-disk
artefacts in the wild need to survive.

The test author's branch build does have stored state to clean up,
but it's covered by ordinary code changes rather than a migration
step:

- The `ExportVersionSelection` enum drops `originalOnly`,
  `editedOnly`, and `originalAndEdited` cases. Any leftover raw value
  in `UserDefaults` from earlier testing fails to decode under the
  new two-case enum.
- The current `ExportManager.init` fallback line reads:
  `self.versionSelection = .originalOnly`. That case no longer exists
  after the enum collapses, so this line **must change** as part of
  Phase 5. New fallback:
  `self.versionSelection = .edited`.
- Any leftover destination folder containing `_edited.<ext>` files
  from prior branch testing is abandoned by the new scanner (no
  parser for that suffix). The test author switches to a fresh
  destination — same as the current "reset between scenarios"
  approach in the manual testing guide.

For the public release after this branch merges, no migration code
or user-visible note appears. The branch's prior shape was never
shipped.

## Implementation phasing

**Phases 1–6 are one compile unit, not separate commits.** Earlier
drafts of this plan said each phase should leave the tree compiling;
that was overoptimistic — collapsing the `ExportVersionSelection`
enum cases and removing filename APIs in Phase 1 immediately breaks
every callsite that pattern-matches the enum or calls the deleted
APIs (the `ExportManager.init` fallback line, the toolbar/onboarding
picker tags, every `switch selection` arm in `requiredVariants` /
`isExported` / `monthSummary` / the toolbar's empty-run scope copy,
every `editedFilename` / `parseEditedCandidate` caller). There is no
reasonable order in which the model change lands first and the
callsites later still compile.

The phases below are kept as **logical groupings for review**
purposes: a reader walking the plan finds the model changes
together, the pipeline changes together, etc. In practice they all
land in a single commit (or a tightly-stacked branch) covering the
full code surface. Then phases 7–8 (tests and docs) follow as their
own commits.

Treat the numbered phases as a checklist of what must be touched,
not a sequence of compile-clean intermediate states.

### Phase 1 — Models and policy

1. Update `ExportVersionSelection` to two cases.
2. Update `requiredVariants` body.
3. Update `ExportFilenamePolicy`:
   - Drop `editedSuffix` constant and `editedFilename(...)` function.
   - Add `originalSuffix = "_orig"`.
   - Add `originalFilename(stem:ext:withSuffix:)` helper that returns
     `<stem>_orig.<ext>` when `withSuffix == true`, else `<stem>.<ext>`.
   - The "edited filename" callable becomes
     `editedFilename(stem:editedResourceFilename:) -> String` returning
     `<stem>.<editedExt>` (no suffix).
   - Drop `parseEditedCandidate` and the entire
     `ExportFilenameClassification` enum (see Phase 3 for the
     scanner-side cleanup that this enables).
   - Add `parseOriginalCandidate(filename:) -> ParsedOriginalCandidate?`.
   - Add `isOrigCompanion(filename:) -> Bool` (predicate used by the
     sidebar's records-only count heuristic and the scanner's `_orig`
     parser — **not** by `isExported`, which stays asset-aware).

### Phase 2 — Pipeline

4. Replace `allocateEditedOnlyGroupStem` with
   `allocatePairedGroupStem(baseStem:editedExt:originalExt:destDir:)`
   that scans for a stem where both the natural-stem edited target
   and the `_orig` original target are simultaneously free.
5. Update `ExportManager.exportSingleVariant` filename derivation to
   use the new policy and the "is `.edited` paired in this run?"
   signal. For fresh include-originals jobs, the stem comes from
   `allocatePairedGroupStem` and is shared by both variant writes.
6. Update `inheritedGroupStem(from:)` to recognise both unsuffixed
   filenames (the new natural form) and `_orig`-suffixed filenames.
   Drop the `_edited` recognition path.
7. Update `EnqueueOutcome` to drop `.nothingApplicable`.
   `noApplicableCopy` and its callers go away.
8. Update `bulkImportRecords` (no signature change; it merges by
   variant; new files just have new filename shapes).

### Phase 3 — Scanner

9. Update `BackupScanner.matchSingleFile` to the new classification
   order: `_orig` (with both-stem matching and fall-through on miss)
   → exact original → collision-stripped original → cross-extension
   edited → unmatched.
10. Drop the `editedCandidates` filter path that relied on `_edited`
    parsing.
11. Update `AssetFingerprint` if any field becomes unused (it likely
    keeps `editedResourceFilenames` for the cross-extension
    classifier and the `_orig` extension check).

### Phase 4 — Record store

12. Update `isExported(asset:selection:)` to the **strict
    asset-aware** rule. The body becomes
    `requiredVariants(for: asset, selection: selection).allSatisfy { record.variants[$0]?.status == .done }`.
    No filename inspection; no use of `isOrigCompanion`. The asset's
    current `hasAdjustments` (consulted via `requiredVariants`) is
    the source of truth.
13. Update `monthSummary(assets:selection:)` — drop the `editedOnly`
    branch; the surviving two branches both call the strict
    asset-aware `isExported(asset:selection:)` per descriptor.
14. Update `sidebarSummary(year:month:totalCount:adjustedCount:selection:)` —
    keep the `adjustedCount` parameter (the cap is load-bearing).
    Body uses the records-only formula in **Records-only sidebar
    approximation**: `editedDone + min(origOnlyAtStem, uneditedCount)`
    for default mode, `bothDone + min(origOnlyAtStem, uneditedCount)`
    for include-originals. `origOnlyAtStem` filters records by
    `!isOrigCompanion(filename:)`. Drop the `editedOnly` branch.
15. Update `sidebarYearExportedCount(year:totalCountsByMonth:adjustedCountsByMonth:selection:)` —
    keep both per-month parameters. Body iterates each month and
    accumulates the per-month exported count using the rule above.
    Rename to `sidebarYearSummary` if it makes more sense to return
    a `MonthStatusSummary`-shaped value; otherwise keep as-is.

### Phase 5 — UI

16. Replace `ExportToolbarView.versionPicker` with the toggle button.
    Update tooltips and accessibility.
17. Update `OnboardingView` step 2 sub-picker to a checkbox toggle.
    Update help text.
18. Update `ExportManager.init`:
    - Change the fallback `self.versionSelection = .originalOnly`
      to `self.versionSelection = .edited`. The old case won't even
      compile after Phase 1; this edit is the bridge.
19. Update `ContentView`:
    - Keep `adjustedCountsByYearMonth` state, `loadAdjustedCount`,
      `monthTotals`, `adjustedMonths`, and the
      `.task(id: "\(year)-\(month)-adjusted")` modifier on
      `MonthRow`. They're still needed for the records-only sidebar
      cap.
    - Update `YearRow` and `MonthRow` to remove mode-qualified copy
      ("edited" caption next to badges, partial/notExported text
      variants). Update tooltips.
    - Keep `YearRow.yearTotal` returning `Int?` (suppresses badge
      while any month's adjusted count is loading).
20. Update `MonthContentView.exportSummaryView` to mode-agnostic copy.
21. Update `AssetDetailView` to remove any references to the obsolete
    "Edited only" mode in copy.

### Phase 6 — Photos service

22. **No changes.** `countAdjustedAssets(year:month:)` and
    `countAdjustedAssets(year:)` stay (along with their cache and
    invalidation paths). The plan's earlier draft listed them for
    deletion; that was the error. Phase 6 is now empty — kept here
    so the phase numbering stays aligned with earlier drafts of the
    plan.

### Phase 7 — Tests

See **Tests** below.

### Phase 8 — Documentation

23. Rewrite the **Version selection** section of
    `website/src/content/docs/features.md` to describe the toggle.
24. Rewrite the relevant section of
    `website/src/content/docs/getting-started.md`.
25. Update `website/src/content/docs/export-icloud-photos.md` for the
    same.
26. Update README's Current Capabilities bullet for the toggle.
27. Update `docs/reference/persistence-store.md` to reflect that
    filenames may carry `_orig` suffix.
28. The previous parent and P2 plans were already moved to
    `docs/project/archive/` in a prior commit on this branch; verify
    the `Supersedes` header at the top of this plan still points at
    the correct archive paths.
29. Rewrite `docs/project/edited-photos-manual-testing-guide.md`
    against the new modes (very large rewrite — most scenarios
    change).

## Tests

### Updated

- `ExportFilenamePolicyTests`: drop `_edited` cases; add `_orig`
  parser cases.
- `ResourceSelectionTests`: unchanged (resource picking didn't change).
- `ExportPipelineTests` happy path / collision tests: filenames change
  from `_edited.<ext>` to unsuffixed, `_orig` for paired originals.
- `EditedVariantExportTests`:
  - Rename the type to `EditedModeExportTests`.
  - `editedOnlySkipsUneditedAssets` → flip to
    `editedDefaultExportsUneditedAtOriginalFilename` because the
    semantic flipped.
  - `editedOnlyWritesEditedFilename` → expected filename has no
    `_edited` suffix.
  - `heicOriginalPlusJpegEditProducesEditedJpeg` → expected file is
    `IMG_0001.JPG`, no `_edited`.
  - `originalAndEditedWritesBothVariants` →
    `editedWithOriginalsWritesPrimaryAndOrigCompanion`. Filenames
    update.
  - `pairedCompanionFollowsOriginalCollisionSuffix` → new pairing
    expectations: `IMG_0001 (1).JPG` (edit) and
    `IMG_0001 (1)_orig.JPG` (companion).
  - `symmetricPairingWhenEditedExportedFirst` and
    `pairedOriginalFailsInsteadOfOverwritingAnotherAssetsFile` —
    update the failure-mode test to match the new naming flow.
  - `editedOnlyFailsWhenEditedResourceUnavailable` — keep the
    `Edited resource unavailable` recovery message; the case where the
    pipeline fails for adjusted assets still applies under default
    mode.
- `EditedVariantScannerTests`:
  - Rename to `BackupScannerVariantTests`.
  - Drop tests about `_edited` parsing.
  - Add tests about `_orig` parsing.
  - Add tests for the cross-extension-default-mode classifier (HEIC +
    JPEG edit, default mode → file `IMG_0001.JPG` matches as
    `.edited`).
  - Add a test for the same-extension-default-mode case (JPEG + JPEG
    edit, default mode → file `IMG_0001.JPG` matches as `.original`,
    documented behaviour).
- `EmptyRunMessageTests`: drop the
  "no edited versions to export" cases (no longer reachable). Keep the
  "already exported" cases.
- `ExportRecordStoreTests`, `ExportRecordStoreRecoveryTests`,
  `ExportRecordLegacyMigrationTests`: filenames in test data update
  from `_edited.JPG` to the unsuffixed/`_orig` shapes. Schema is
  unchanged so legacy migration tests still pass.
- `ExportVariantRecoveryTests`: unchanged. Recovery enum stays.

### New

- A test for `ExportFilenamePolicy.isOrigCompanion(filename:)` —
  table-driven across `IMG_0001.JPG` (false), `IMG_0001_orig.JPG`
  (true), `IMG_0001_orig (1).JPG` (true with collision suffix),
  `vacation_orig.JPG` (true — the predicate just checks the stem
  shape, not whether it's a real companion of any asset), and
  `IMG_0001 (1).JPG` (false).
- A test exercising the strict default-mode `isExported`:
  - Adjusted asset, only `.original.done` (any filename) → false.
  - Adjusted asset, `.edited.done` → true.
  - Unedited asset, `.original.done` at any filename
    (including `_orig`-shaped ones) → true.
- A test exercising the strict `isExported(asset:
  .editedWithOriginals)`:
  - Adjusted asset, only `.edited.done` → false.
  - Adjusted asset, both done → true.
  - Unedited asset, only `.original.done` → true.
- A test for the post-edit collision case: an unedited asset is
  exported in default mode (`.original.done` at natural stem); the
  test then sets `hasAdjustments == true` on the descriptor and
  re-runs export; assert that the new `.edited` lands at
  `IMG_0001 (1).JPG` and the prior `.original.done` record is
  preserved (one-time documented duplicate).
- Sidebar count tests (`sidebarSummary` /
  `sidebarYearSummary`) covering the cap behaviour:
  - All assets exported normally → `editedDone` (or `bothDone`) +
    `min(origOnlyAtStem, uneditedCount)` equals total. ✓
  - Post-edit case: a record was `.original.done` at natural stem
    when the asset was unedited; the descriptor now reports
    `hasAdjustments == true`, raising `adjustedCount` and lowering
    `uneditedCount`. The cap drops one from `origOnlyAtStem`'s
    contribution; the asset is correctly NOT counted as exported.
  - Same-extension re-import case: 100 records all
    `.original.done` at natural stem (post-import); 30 of the
    underlying assets are adjusted. Default mode count returns
    70, matching the asset-aware result.
  - Documented `vacation_orig.JPG` edge case: a record is
    `.original.done` at a `_orig`-shaped user filename; the
    sidebar under-counts by 1 (`isOrigCompanion` fires
    structurally and excludes the record from `origOnlyAtStem`).
    Assert the documented under-count rather than the asset-aware
    truth.
- A pipeline test for paired-stem pre-allocation: pre-seed the
  destination with `IMG_0001.JPG` belonging to no Photos asset, then
  run a fresh include-originals export of an adjusted asset whose
  natural-stem edit would land at `IMG_0001.JPG`. Assert the resulting
  pair lands at `IMG_0001 (1).JPG` + `IMG_0001 (1)_orig.<ext>`, both
  on the same incremented stem (no split).
- A scanner test asserting fall-through on `vacation_orig.JPG` when
  no asset has `vacation` stem with adjustments — the file matches
  via step 2 (exact original) and classifies as `.original`.
- A scanner test for native ` (N)` stems: an asset whose original
  resource filename is `IMG_0001 (1).JPG`. Destination contains
  `IMG_0001 (1).JPG` (edit) and `IMG_0001 (1)_orig.JPG`. Verify both
  classify correctly without canonical-stem stripping losing the
  native suffix.
- A scanner test for `_orig` matching with multiple candidate
  fingerprints: two adjusted assets share an original Photos
  filename (`IMG_TEST.JPG`); the destination contains
  `IMG_TEST.JPG` and `IMG_TEST_orig.JPG` for one of them. Step 1
  collects both candidates, `narrow(...)` resolves the right one
  by date / metadata. Verify the correct asset is matched, not the
  other. Add a sibling test with both candidates having identical
  dates: assert `.ambiguous` rather than a coin-flip
  classification.

### Removed

- All "no applicable assets" tests in `EmptyRunMessageTests` — the
  case is unreachable.
- Tests referring specifically to `originalOnly` mode behaviour beyond
  what `editedWithOriginals` already covers.

## Manual testing guide

The current `edited-photos-manual-testing-guide.md` is heavily
mode-aware (Group A has seven scenarios distinguishing
`originalOnly` / `editedOnly` / `originalAndEdited`; Group F asserts
mode-qualified counts; Group D's empty-run scenarios include the
"no edited versions" message). All of those need to be redone.

Approximate target shape after rewrite:

- **Group A — Default mode.** A1 plain photo, A2 edited photo, A3
  edited HEIC + JPEG render, A4 edited video.
- **Group B — Include originals toggle.** B1 toggle on for an edited
  photo produces a `_orig` companion; B2 toggle off again does not
  remove existing companions but stops creating new ones; B3 toggle
  state survives quit/relaunch.
- **Group C — Collisions.** C1 two photos with the same name, one
  edited; default mode produces `IMG_TEST.JPG` and
  `IMG_TEST (1).JPG`. C2 same setup with the toggle on adds
  `IMG_TEST_orig.JPG` and `IMG_TEST (1)_orig.JPG`. C3 step-1 fail-path
  guard (companion location taken by another asset).
- **Group D — Empty-run feedback.** D1 already-exported, D2 toggle off
  → on adds work, D3 picker locked during active export.
- **Group E — Recovery.** E1 cancel and resume, E2 force-quit and
  resume.
- **Group F — Sidebar / detail.** F1 sidebar counts mean what they
  say in both modes (no "edited" qualifier). F2 detail pane variant
  rows. F3 thumbnail dot reacts to toggle.
- **Group G — Onboarding.** G1 first-run with toggle off; G2 first-run
  with toggle on.
- **Group H — Import existing backup.** H1 default-mode export then
  import (note same-extension classifier limitation). H2 toggle-on
  export then import (lossless: `_orig` companions classify
  unambiguously).
- **Group I — Accessibility.** Toggle reads correctly under VoiceOver.
- **Group J — Library observation.** Mostly unchanged from current J1.
- **Group K — Other shipped behaviours.** Pause/resume, stale `.tmp`,
  optional paired-original conflict.

The existing testing guide will be completely rewritten in Phase 9.

## Risks / open questions

### Same-extension same-stem import ambiguity

When the original is a JPEG and the edit is also a JPEG, default-mode
exports produce a single file at `IMG_0001.JPG` containing the edited
bytes. The scanner cannot tell from the filename alone whether that
file is the original or the edit. Because `isExported` is strict
(uses `requiredVariants` against the descriptor's `hasAdjustments`),
the next default-mode run for an adjusted asset will see
`.edited.done? false` and re-export, producing a one-time
`IMG_0001 (1).JPG` companion alongside the existing `IMG_0001.JPG`.
The user has two files for that asset.

This is acceptable for a v1 of the redesign:

- The cost is one duplicate per same-extension adjusted asset, paid
  once on first re-export after re-import. Subsequent runs are
  steady-state.
- The asset detail pane shows both rows and timestamps, so the user
  can see what happened.
- The user can manually delete the older file if they want a clean
  destination.

A future enhancement could implement *same-asset controlled
overwrite* (the pipeline replaces the same asset's prior `.original`
file at the natural stem when writing a fresh `.edited` to the same
path, and updates the records). Out of scope here. Flagged as future
work, captured in this plan only as a path forward if user feedback
requests it.

### Post-edit re-export

Same shape as the import ambiguity case but triggered by the user
applying an edit in Photos after a previous export. Strict
`isExported` correctly detects "this asset's `.edited` isn't done
anymore (because the asset just became adjusted)" and re-enqueues.
The new edit lands at `IMG_0001 (1).JPG` next to the prior
`IMG_0001.JPG` (now containing the unedited bytes). One-time cost.
Same future-enhancement path applies.

### "Originals only" use case

Some users explicitly want only original RAW files exported, not
edits. We are removing this mode. If the request comes back from real
users post-release, options:

- Add a third toggle state ("Original only") — but this is exactly
  the tri-state we are simplifying away from.
- Recommend Photos.app's own export.
- Add an "Export Originals" command as a one-off action separate from
  the default behaviour.

The plan accepts that we are removing the option deliberately.

### Toggle button label

"Include originals" is the proposed label. Alternatives considered:

- "Keep originals" — implies they could be lost otherwise.
- "+ Originals" — terse but ambiguous in screen-reader output.
- "With originals" — works but reads as a noun phrase, not a verb.
- "Backup originals" — verb form, but "backup" is what the whole app
  does.

**Recommend "Include originals".** Ship it; tweak post-launch only if
real users misread it.

### Empty-run message for the toggle

Toggling the option on for a library where every adjusted asset has
already been exported with default mode will enqueue zero work in the
toggle's eyes — but the user might expect new `_orig` files to appear.

Resolution: the enqueue logic correctly enqueues those assets
(strict `isExported` for `editedWithOriginals` mode means existing
single-variant records are insufficient). The toggle does enqueue real
work in that case. The empty-run message only fires when truly
everything is done.

### Visible mid-toggle inconsistency

If a user toggles the option on mid-library — exporting half their
photos, then turning the toggle on, then exporting the rest — the
first half has no `_orig` companions and the second half does. This
is the user's choice; there is no automatic "go back and add
originals to previously exported assets" behaviour. The next
manual click of **Export All** picks up the missing companions.

We document this in the manual testing guide so testers don't flag it
as a defect.

### Failed-edit / orphaned-`_orig` recovery state

A failed `.edited` write in include-originals mode leaves the asset
with a `_orig` companion on disk and no user-visible file. Three
guards prevent this from looking "done" to the user:

1. Under default mode, `requiredVariants` for an adjusted asset is
   `[.edited]`. The `.original.done` record at the `_orig` filename
   isn't even consulted; only `.edited.done?` is checked, and it
   isn't done. The asset is incomplete.
2. Under include-originals mode, `requiredVariants` is
   `[.original, .edited]`. Both must be done. `.edited` isn't, so
   the asset is incomplete.
3. The detail pane shows `Edited: <recoverable copy>` per the existing
   `ExportVariantRecovery` enum.

Re-running export retries the failed `.edited`. No orphaned-companion
state silently passes as complete.

## Effort estimate

About a day of focused work, roughly:

- Models + policy: 1 hour.
- Pipeline filename derivation: 1.5 hours.
- Scanner classifier: 1 hour.
- Record store API simplifications: 1 hour.
- UI (toolbar toggle, onboarding, sidebar simplification, detail
  copy): 1.5 hours.
- PhotoLibraryService cleanup: 30 minutes.
- Test rewrites and additions: 2 hours.
- Documentation rewrites (website + persistence reference + archive
  moves): 1.5 hours.
- Manual testing guide rewrite: 1.5 hours.
- Apple-designer review pass + Codex review pass + addressing
  findings: 1.5 hours.

## Decisions

All five design questions are settled before implementation begins.

1. **Toggle label.** `"Include originals"`.
2. **Same-extension ambiguity.** Accepted as a documented limitation.
   No hidden config file in the destination; no extra signalling.
3. **Onboarding control style.** Checkbox in onboarding (matches the
   "settings list" idiom of the rest of the onboarding card) and
   `.toggleStyle(.button)` in the toolbar (matches the macOS toolbar
   idiom).
4. **`UserDefaults` migration.** Not needed. This branch has not
   shipped, so no live state requires a migration path.
   `ExportManager.init` falls back to `.edited` when the saved value
   can't decode, which covers any leftover branch-test value.
5. **Parent plan disposition.** The original
   `support-edited-photos-export-plan.md` and the P2 follow-up
   `edited-photos-p2-followups-plan.md` are moved to
   `docs/project/archive/`. They are superseded by this redesign and
   no longer reflect the shipped behaviour.

Implementation can proceed against the phases above without further
input.
