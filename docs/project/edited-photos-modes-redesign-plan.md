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

### `isExported(asset:selection:)` becomes mode-aware

The current "all required variants are .done" check needs a relaxation
for the default mode so that re-imports survive same-extension
ambiguity (see the **Backup scanner** section below). The relaxation
is *filename-aware* — a `.original` variant whose recorded filename is
the `_orig` companion form (i.e. only the RAW backup is on disk, not
the user-visible edit) does not satisfy the default mode by itself,
because the user-visible file is missing.

```swift
func isExported(asset: AssetDescriptor, selection: ExportVersionSelection) -> Bool {
  guard let record = recordsById[asset.id] else { return false }
  switch selection {
  case .edited:
    // The user-visible file lives at the natural stem. Either the .edited
    // variant (for adjusted assets) or the .original variant (for unedited
    // assets) writes there. A .original record whose filename is the _orig
    // companion form is a RAW backup *next to* a user-visible file —
    // never the user-visible file itself, so it must not count alone.
    if record.variants[.edited]?.status == .done { return true }
    if let original = record.variants[.original],
       original.status == .done,
       let filename = original.filename,
       !ExportFilenamePolicy.isOrigCompanion(filename: filename)
    {
      return true
    }
    return false
  case .editedWithOriginals:
    // Strict: both variants required for adjusted assets, original-only
    // for unedited. Existing required-variants logic.
    let required = requiredVariants(for: asset, selection: selection)
    return required.allSatisfy { record.variants[$0]?.status == .done }
  }
}
```

`ExportFilenamePolicy.isOrigCompanion(filename:)` is a new helper —
returns true when the filename's stem ends with `_orig` (with optional
trailing collision suffix `(N)` allowed).

Counter-example the relaxation now correctly handles: a previous
include-originals run wrote `.original.done` at `IMG_0001_orig.HEIC`
and `.edited.failed` (e.g. iCloud render didn't materialise). The user
toggles the option off and runs **Export Month**. Without the filename
check, the asset would look "done" because `.original` is `.done`, and
the user's library would silently miss the user-visible photo. With
the check, the asset is correctly seen as incomplete; the next run
attempts `.edited` again.

## ExportRecordStore API surface

- `markVariantInProgress / markVariantExported / markVariantFailed /
  removeVariant` — keep their signatures.
- `bulkImportRecords` — keeps the per-variant merge.
- `monthSummary(assets:selection:)` — simplifies. Under both modes,
  total = total assets in the month. Under default mode, exported =
  count of assets whose `isExported(asset:selection:)` is true under
  the filename-aware relaxed rule. Under `editedWithOriginals`,
  exported = count of assets whose required variants are all done.
- `sidebarSummary(year:month:totalCount:selection:)` — the
  `adjustedCount` parameter goes away. **This is correct because
  filename inspection on the records replaces the need for adjusted
  counts**, not because adjusted counts are uninformative. Specifically:

  | Mode | "Exported in this scope" =                                           |
  |---|---|
  | Default | records where `.edited.done` OR (`.original.done` AND filename is not `_orig`) |
  | Include originals | records where (`.original.done` AND `.edited.done`) OR (`.original.done` AND filename is not `_orig`) |

  Both rules can be evaluated against the in-memory records alone
  (because the `_orig` suffix is what tells us whether the original
  record is a "backup of an edited asset" or "the only file for an
  unedited asset"). No `PHAsset.hasAdjustments` lookup needed.

- `recordCount(year:month:variant:status:)` — stays.
- `recordCountBothVariantsDone(year:month:)` — stays; remains useful
  for `editedWithOriginals` summaries.
- `sidebarYearExportedCount(year:totalCountsByMonth:selection:)` —
  the `adjustedCountsByMonth` parameter is removed.

### New helper

A small filename predicate on the policy that the store and the
scanner both consume:

```swift
extension ExportFilenamePolicy {
  /// True when `filename`'s stem (after stripping a trailing collision
  /// suffix like ` (1)`) ends with `_orig`. Used to tell the RAW backup
  /// form apart from the user-visible form when both share an extension.
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

The scanner needs three small changes.

### 1. Drop the `_edited` parser path

`ExportFilenamePolicy.parseEditedCandidate(filename:)` and the
`ExportFilenameClassification.edited` enum case go away — *new* exports
no longer produce `_edited` filenames, and we don't need to support
parsing them on import. (See the **Migration** section for the
on-disk implication.)

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
   succeeds, look for a fingerprint that satisfies *all of*:
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

   If a unique candidate matches, classify as `.original`. **If no
   candidate matches, fall through to step 2 — do not return early.**
   This guards against a real user filename ending in `_orig` (e.g.
   `vacation_orig.JPG`) being silently lost when there is no asset
   with adjustments and stem `vacation`.

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
step 2**, not `.edited`. This is intentional and is what the relaxed
`isExported` accommodates: a re-imported same-extension asset will be
recorded as `.original`, and the next default-mode export run will see
"some variant is done" via the relaxed check and skip the asset.

This means the scanner cannot losslessly round-trip variant identity
for the same-extension same-stem case. We accept this as a
documented limitation of the simplified naming.

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

`countAdjustedAssets(year:month:)` and `countAdjustedAssets(year:)` no
longer have callers — the sidebar's mode-aware denominator goes away.
Two paths:

1. Delete the methods (and their cache, and their invalidation in
   `photoLibraryDidChange` and authorization changes). Cleaner; less
   code.
2. Keep them in case future modes need them. We don't currently need
   them.

**Recommend (1).** YAGNI; we can always re-add when something else
needs adjusted counts. The cache invalidation logic stays (it
invalidates the PHAsset cache too, which is still useful).

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

The mode-qualified copy goes away. There is no longer any mode where
a count of "X out of Y" might mean different denominators. Every count
in every mode means the same thing:

- `monthSummary(assets:selection:)` counts assets that satisfy
  `isExported(asset:selection:)` against the total asset count.
- The "edited" caption next to badges goes away.
- The neutral-while-loading state goes away (no adjusted-count load
  to wait on).
- Tooltips on year/month rows simplify to a single sentence per mode:
  - default: `"<MonthName> <Year>: X of Y photos exported."`
  - includeOriginals: `"<MonthName> <Year>: X of Y photos fully exported (including original copies for edited photos)."`

`YearRow` no longer needs the `totalCountsByMonth` and
`adjustedCountsByMonth` parameters at all — `yearExportedCount(year:)`
on the store is sufficient. The whole "lazy-load adjusted counts on
month-row appearance" mechanism in `ContentView` deletes:

- `adjustedCountsByYearMonth` state goes away.
- `loadAdjustedCount(year:month:)` goes away.
- `monthTotals(for:)` and `adjustedMonths(for:)` helpers go away.
- The `.task(id: "\(year)-\(month)-adjusted")` modifier on `MonthRow`
  goes away.
- `yearTotal` returning `Int?` becomes `Int` — no more
  "wait for monthly adjusted counts" race.

This is a sizable simplification of `ContentView`.

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

**None needed.** This branch has not shipped — no real users, no
on-disk artefacts that need to survive. The test build the author has
been using can be discarded (a fresh destination + fresh
`UserDefaults` for the app on the test Mac is the entire migration
surface).

`ExportManager.init` already falls back to `.edited` when it can't
decode the saved selection raw value, so any leftover `editedOnly` /
`originalOnly` / `originalAndEdited` values from earlier branch
testing simply hit the fallback after the enum is collapsed. The
fallback line stays as-is; we don't need a special migration step.

## Implementation phasing

Order is chosen so that the working tree compiles and tests pass at
the end of each phase.

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
   - Drop `parseEditedCandidate` and `ExportFilenameClassification.edited`.
   - Add `parseOriginalCandidate(filename:) -> ParsedOriginalCandidate?`.
   - Add `isOrigCompanion(filename:) -> Bool` (predicate used by both
     the store's `isExported` and the sidebar's count rules).

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

12. Update `isExported(asset:selection:)` to the filename-aware
    default-mode rule (uses `ExportFilenamePolicy.isOrigCompanion`).
13. Update `monthSummary(assets:selection:)` — drop the `editedOnly`
    branch; the surviving two branches use the filename-aware rule.
14. Update `sidebarSummary(year:month:totalCount:selection:)` —
    remove the `adjustedCount` parameter. Both modes derive their
    "exported" count from records using the filename-aware rule.
15. Update `sidebarYearExportedCount(year:totalCountsByMonth:selection:)`
    — drop the `adjustedCountsByMonth` parameter.

### Phase 5 — UI

16. Replace `ExportToolbarView.versionPicker` with the toggle button.
    Update tooltips and accessibility.
17. Update `OnboardingView` step 2 sub-picker to a checkbox toggle.
    Update help text.
18. Update `ContentView`:
    - Drop `adjustedCountsByYearMonth` state.
    - Drop `loadAdjustedCount`, `monthTotals`, `adjustedMonths`.
    - Update `YearRow` and `MonthRow` to remove mode-qualified copy
      and adjusted-count plumbing. Update tooltips.
    - Update `MonthRow.task(id:)` modifier — remove the adjusted-count
      task.
19. Update `MonthContentView.exportSummaryView` to mode-agnostic copy.
20. Update `AssetDetailView` to remove any references to the obsolete
    "Edited only" mode in copy.

### Phase 6 — Photos service

21. Delete `countAdjustedAssets(year:month:)` and `countAdjustedAssets(year:)`
    from the protocol and `PhotoLibraryManager`. Drop
    `adjustedCountByYearMonth` cache and its invalidation. Remove the
    fake's implementations.

### Phase 7 — Tests

See **Tests** below.

### Phase 8 — Documentation

20. Rewrite the **Version selection** section of
    `website/src/content/docs/features.md` to describe the toggle.
21. Rewrite the relevant section of
    `website/src/content/docs/getting-started.md`.
22. Update `website/src/content/docs/export-icloud-photos.md` for the
    same.
23. Update README's Current Capabilities bullet for the toggle.
24. Update `docs/reference/persistence-store.md` to reflect that
    filenames may carry `_orig` suffix.
25. Move `docs/project/support-edited-photos-export-plan.md` and
    `docs/project/edited-photos-p2-followups-plan.md` to
    `docs/project/archive/` — they're superseded by this redesign.
    `git mv` so history follows.
26. Rewrite `docs/project/edited-photos-manual-testing-guide.md`
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
- A test exercising the filename-aware default-mode `isExported`
  branch: a record with only `.original.done` at a `_orig` filename
  does NOT satisfy default mode (because the user-visible file is
  missing). A record with only `.original.done` at a natural-stem
  filename DOES satisfy default mode (unedited asset case).
- A test exercising the strict `isExported(asset:
  .editedWithOriginals)` branch: a record with only `.original.done`
  does NOT satisfy an adjusted asset under that mode.
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

### Same-extension import ambiguity

When the original is a JPEG and the edit is also a JPEG, default-mode
exports produce a single file at `IMG_0001.JPG` containing the edited
bytes. The scanner cannot tell from the filename alone whether that
file is the original or the edit. The relaxed `isExported` and a
documented limitation cover the export-skip-on-re-run case. The
edge case the user can hit:

1. Export in default mode.
2. Lose the records (fresh install / different Mac / corrupted store).
3. Run **Import Existing Backup**. Records say `.original` is done.
4. Toggle on "include originals."
5. Re-run export. The app sees that the asset's `.original` is "done"
   but actually the file on disk is the edited bytes. The app writes
   `.edited` (no problem, distinct file at a different stem? no — same
   stem, same ext). Collision suffix added to the second write. Both
   files are the edited bytes; no original is preserved. The original
   bytes are silently absent.

The user thinks they have RAW backups; they don't. This is the
worst-case manifestation. Mitigations:

- The relaxed `isExported` for default mode means most users in this
  flow never hit the toggle and thus never trigger the bad case.
- Documenting the limitation in the manual testing guide and the
  website features page so power users who care about RAW
  preservation know to keep their export records intact.
- A future enhancement: write a small `.photo-export-config.plist` in
  the destination root carrying the mode used. Then the scanner can
  disambiguate. **Not** part of this redesign; flagged as future
  work.

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

1. The filename-aware `isExported(asset: .edited)` rule does not count
   `.original.done` at a `_orig` filename as satisfying the asset.
2. The `requiredVariants(.editedWithOriginals)` rule keeps
   `.edited` in the required set, so the strict completion check on
   include-originals also reports the asset as incomplete.
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
