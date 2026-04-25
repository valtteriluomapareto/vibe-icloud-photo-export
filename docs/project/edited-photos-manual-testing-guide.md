# Manual Testing Guide — Edited Photos Export

Date: 2026-04-25
Feature: [issue #13 — Support exporting edited photos](https://github.com/valtteriluomapareto/photo-export/conversations/issues/13)
Parent plan: `support-edited-photos-export-plan.md`

## Goal

Verify by hand that the edited-photos export feature behaves correctly
across the cases unit tests cannot cover: PhotoKit integration, file
system side effects, and the full UI. Each scenario is independently
runnable. Steps are written in plain language; expected outcomes are
explicit so two testers running the same scenario will agree on
pass/fail without reading source.

## Build and install

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Then either run from Xcode (**Run** ⌘R with the `photo-export` scheme),
or open the built app from `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/Photo Export.app`.

## Prerequisites

- **macOS 15.0** or later.
- **Apple Photos** with iCloud Photos enabled. **Important:** before
  starting, confirm the assets you'll test are downloaded locally
  (right-click in Photos → **Get Info** → look for "On this Mac"). An
  iCloud-only asset whose original isn't downloaded yet may fail
  export with `"Edited version was not provided by Photos. Future
  exports will try again."` — that's not the test failing, that's
  iCloud not having sent the bytes.
- **Photo Export** built and granted Photos access.
- **Two empty folders** prepared as test destinations. We'll switch
  between them when a scenario needs a clean slate.
- **A small set of seed assets in Photos** (see below). Keep a Finder
  window open on the active destination so you can watch files appear.

### Recommended seed assets

Set these up once. Each row is one Photos asset. To verify what Photos
calls a file, right-click the asset in Photos → **Get Info** → look at
the row labeled "Original file" — that's the filename Photo Export will
use as the basis for the export.

| ID | What | How to set it up | Used in |
|---|---|---|---|
| **PA-1** | Plain photo, no edits | Take any photo or import an unedited JPEG | A1, A6, A7, F1 |
| **PA-2** | Edited photo (JPEG) | Take or import a JPEG, then in Photos: **Edit** → apply any change → **Done** | A2, A3, C1, C2, F3 |
| **PA-3** | Edited HEIC with JPEG-rendered edit | Use a HEIC from an iPhone (AirDrop one over, or take one with iPhone with iCloud Photos enabled). Apply an edit in Photos | A4 |
| **PA-4** | Edited video | Record a short video on iPhone or import any `.mov`. In Photos: **Edit** → trim or apply a filter → **Done** | A5 |
| **PA-5** | Two photos in the **same month** with the **same filename** | Easiest reliable recipe: take two photos with iPhone (they get sequential names like `IMG_1234.JPG` and `IMG_1235.JPG`). On a Mac, copy each to Desktop, rename **both** to `IMG_TEST.JPG`, then drag each into Photos one at a time. Photos accepts the duplicate name. Apply an edit to **one** of them, leave the other unedited. After import, verify in Photos → **Get Info** → "Original file" that both show `IMG_TEST.JPG`. If Photos renamed one of them, retry — sometimes restarting Photos helps. | B1 |
| **PA-6** | Photo whose real filename contains `_edited` | Make a copy of any JPEG, rename it to `vacation_edited.JPG` on the Desktop, drag it into Photos. Verify in **Get Info** that "Original file" still shows `vacation_edited.JPG` | B2, H2 |
| **PA-7** | A photo you can edit later | Just leave any unedited photo aside | C1 picker switch, J1 |

If your library is large, put all seven seed assets into one specific
month (e.g. all dated within the same month) so you can find them
quickly in the sidebar.

## Reset between scenarios

The export records are keyed **per destination folder**, so emptying a
folder is not enough — Photo Export will still remember everything it
exported there. The reliable reset is **switching to a fresh
destination**.

Steps:

1. **Click "Change…"** next to the destination indicator in the
   toolbar.
2. **Pick the second prepared empty folder.** Photo Export's records
   reset for that destination.
3. After the scenario, you can swap back to the first folder for the
   next one — alternate between the two prepared folders.

Some scenarios additionally need:

- **Onboarding reset (G1 only).** In Terminal:
  `defaults delete com.valtteriluoma.photo-export hasCompletedOnboarding`
  then relaunch the app.
- **Quit and relaunch.** Used for J1 (library observation) — the
  sidebar caches adjusted counts in memory, so a relaunch is needed to
  re-read them after editing an asset in Photos.
- **Confirm no export is running.** If a previous scenario was
  cancelled, the toolbar's progress slot may still show a transient
  "already exported" message. Wait until that message clears (it
  auto-clears in about six seconds) before starting the next scenario.

---

## Test scenarios

### Group A — Core export modes

#### A1. Originals-only export (the default)

**Goal.** A plain photo exports under its Photos filename and nothing
else.

1. Toolbar picker → **Originals**.
2. Open the month that contains **PA-1**.
3. Click **Export Month**.

**Expected.** In the destination, under `YYYY/MM/`, a single file
appears with the same filename Photos shows in **Get Info → Original
file**. No `_edited` companion. The blue dot on PA-1's thumbnail
disappears. Click the thumbnail; the detail pane shows
`Original: Exported …`.

#### A2. Edited-only mode writes only the edited file

**Goal.** Only the edit is exported; the original is not.

1. Reset to a fresh destination.
2. Toolbar picker → **Edited**.
3. Open the month that contains **PA-2**.
4. Click **Export Month**.

**Expected.** Exactly one file is written to the destination. Its
basename matches PA-2's original Photos filename with `_edited`
inserted before the extension (for example, an asset named
`IMG_1234.JPG` produces `IMG_1234_edited.JPG`; the extension may be
different if Photos renders the edit in another format). The
non-`_edited` file is **not** present. Detail pane shows
`Edited: Exported …` and no `Original` line.

#### A3. Both mode writes original and edited side by side

**Goal.** Edited assets export both files; unedited assets only export
the original.

1. Reset to a fresh destination.
2. Toolbar picker → **Both**.
3. Open the month that contains both **PA-1** (unedited) and **PA-2**
   (edited).
4. Click **Export Month**.

**Expected.**

- For PA-1: one file in the destination (its original), no
  `_edited` companion.
- For PA-2: two files — its original *plus* a sibling with `_edited`
  appended before the extension.
- Detail pane for PA-2 shows both `Original: Exported` and
  `Edited: Exported`.

#### A4. HEIC original with JPEG-rendered edit

**Goal.** The edited file's extension follows what Photos rendered, not
what the original was.

1. Reset to a fresh destination.
2. Toolbar picker → **Both**.
3. Open the month containing **PA-3**.
4. Click **Export Month**.

**Expected.** The destination contains the original (a `.HEIC` file
matching Photos' "Original file" name) **plus** a `_edited.JPG`
companion (note the different extension). Detail pane shows both
exported.

#### A5. Edited video

**Goal.** Videos follow the same naming rules as photos.

1. Reset to a fresh destination.
2. Toolbar picker → **Both**.
3. Open the month containing **PA-4**.
4. Click **Export Month**.

**Expected.** Both the original video file and a `_edited` companion
appear in the destination. The `_edited` companion's extension
matches what Photos renders the edit as (commonly `.mov`). Detail
pane shows both exported.

#### A6. Edited mode skips unedited months

**Goal.** A month with no edited photos enqueues no work and shows the
right message.

1. Reset to a fresh destination.
2. Toolbar picker → **Edited**.
3. Open a month that contains only **PA-1** (unedited only). If your
   seed assets share a month with edited ones, pick a different month
   that has only unedited photos.
4. Click **Export Month**.

**Expected.** Nothing is written to the destination. The toolbar's
progress area replaces the progress bar with a green checkmark icon
and the text `"This month has no edited versions to export."` for
about six seconds, then auto-clears.

#### A7. Both mode for an unedited photo writes only the original

**Goal.** Unedited photos do not get a fake `_edited` duplicate of
their bytes.

1. Reset to a fresh destination.
2. Toolbar picker → **Both**.
3. Open a month with only unedited photos.
4. Click **Export Month**.

**Expected.** Each photo gets exactly one file in the destination —
its original. No `_edited` companion appears for any of them.

---

### Group B — Filename rules

#### B1. Two photos sharing a filename — pairing rule

**Goal.** When two photos have the same Photos filename and one has an
edit, the edited companion follows the *paired* original's stem (with
its collision suffix), not the bare filename.

1. Reset to a fresh destination.
2. Confirm **PA-5** is set up correctly: two photos in the same month,
   both showing the same Photos filename, with an edit applied to
   exactly one of them.
3. Toolbar picker → **Both**.
4. Open the month containing PA-5.
5. Click **Export Month**.

**Expected.** Three files in the destination (only one of the two is
edited, so only one `_edited` file is produced):

```
IMG_TEST.JPG              ← whichever of the two exports first
IMG_TEST (1).JPG          ← the second one (collision-suffixed)
IMG_TEST (1)_edited.JPG   ← the edited companion, paired with whichever was the edited photo
```

If the edited photo happened to export first, the names shift:
`IMG_TEST.JPG` + `IMG_TEST_edited.JPG` for the edited one, and
`IMG_TEST (1).JPG` for the unedited one. The pairing rule is what
matters: the `_edited` file's stem must match its **own** original's
stem (`IMG_TEST` or `IMG_TEST (1)`), never `IMG_TEST_edited (1).JPG`.

#### B2. Photo whose real filename contains `_edited`

**Goal.** A user-chosen filename containing `_edited` is treated as an
original, not as the app's edited variant of something else.

1. Reset to a fresh destination.
2. Confirm **PA-6** is set up: the asset shows `vacation_edited.JPG`
   under **Get Info → Original file** in Photos. (If Photos renamed
   it, redo the import, or pick a different name with `_edited` in it
   that survives the import.)
3. Toolbar picker → **Both**.
4. Open the month containing PA-6.
5. Click **Export Month**.

**Expected.** A single file named `vacation_edited.JPG` (or whatever
Photos preserved) appears in the destination. No additional copy. The
detail pane shows `Original: Exported …` and `Edits: None in Photos`
because PA-6 wasn't edited.

---

### Group C — Selection switching

#### C1. Originals-only first, then Both — only the missing edit runs

**Goal.** Switching modes does not re-export work that's already done.

1. Reset to a fresh destination.
2. Toolbar picker → **Originals**.
3. Open the month containing **PA-2** (edited photo).
4. Click **Export Month**, wait for it to finish.
5. **Before continuing**, in Terminal capture the modification time of
   the original file (so you can prove it isn't rewritten). Replace
   the path with the file you just exported:

   ```bash
   stat -f '%m %N' "/path/to/destination/2025/05/IMG_xxxx.JPG"
   ```

6. Toolbar picker → **Both**.
7. Click **Export Month** on the same month.

**Expected.**

- A new `_edited` file appears in the destination.
- The original file's modification time, re-checked with `stat`, is
  unchanged from step 5.
- Toolbar progress shows `1/1 assets` for this run — only the missing
  edit ran, not the original.

#### C2. Edited-only first, then Both — original arrives at the paired stem

**Goal.** The pairing rule works in either order.

1. Reset to a fresh destination.
2. Toolbar picker → **Edited**.
3. Open the month containing **PA-2**.
4. Click **Export Month**, wait for it to finish.
5. Note the exact `_edited` filename written. If it's a simple
   `<stem>_edited.<ext>` (no `(1)` collision suffix), the next step's
   original will be `<stem>.<ext>`. If the destination already had a
   collision (rare — only if you didn't reset), expect the paired
   stem.
6. Toolbar picker → **Both**.
7. Click **Export Month** on the same month.

**Expected.** The original file is added to the destination using the
**same stem** as the edited file. If the edit was
`IMG_xxxx_edited.JPG`, the original arrives as `IMG_xxxx.JPG`. If for
some reason the edit was `IMG_xxxx (1)_edited.JPG`, the original
arrives as `IMG_xxxx (1).JPG`.

---

### Group D — Toolbar feedback

#### D1. "Already exported" message after re-clicking Export

**Goal.** A second click on a fully-completed scope gives visible
feedback rather than looking dead.

1. Pick any month you've already fully exported under the current
   destination + selection.
2. Click **Export Month** again.

**Expected.** In the toolbar, where the progress bar usually lives,
a small **green checkmark icon** appears next to grey/secondary text
reading `"This month is already exported."` The message stays for
about six seconds and then disappears. No files are rewritten.

#### D2. "No edited versions to export" message — distinct from "already exported"

**Goal.** Edited mode in a scope with **no** edited photos shows a
different message than "already done."

1. Reset to a fresh destination.
2. Toolbar picker → **Edited**.
3. Open a month that contains **only unedited photos** (no
   `hasAdjustments` photos at all). Browse to find one — most personal
   libraries have plenty.
4. Click **Export Month**.

**Expected.** The toolbar shows
`"This month has no edited versions to export."` (with the green
checkmark icon, secondary text). No files are written. This must be
visibly **different** from the "already exported" message — exporting
nothing because there's nothing to do is not the same as exporting
nothing because the work is done.

#### D3. Picker is locked during an active export

**Goal.** The user cannot change selection while work is running, and
the lock is explained.

1. Start a longish export — pick a month with many photos and click
   **Export Month**, or click **Export All** on a real library. As
   soon as the toolbar progress bar appears:
2. Try to click the **Originals / Edited / Both** picker.

**Expected.** The picker is greyed out and ignores clicks. Hover the
cursor over it for a moment to surface the tooltip — it should read
`"Available after the current export finishes."`

3. Wait for the queue to drain (or click the toolbar's **X** to
   cancel). Try the picker again.

**Expected.** The picker is clickable again, and its tooltip switches
back to a mode-specific help message.

---

### Group E — Recovery

#### E1. Cancel mid-flight, then re-export

**Goal.** A cancelled in-progress run leaves no garbage and the next
run resumes.

1. Reset to a fresh destination.
2. Toolbar picker → **Both**.
3. Click **Export All** on a real library (need at least 5 photos
   actively running).
4. Within a few seconds of the bar starting, click the toolbar's **X**
   button.

**Expected.** The progress bar disappears. Open the destination
folder — there should be **no `*.tmp` files left** in any year/month
subfolder. Photos that finished exporting before the cancel keep
their files; photos that were in progress have nothing.

5. Click **Export All** again.

**Expected.** Already-finished photos are skipped. Photos that hadn't
finished yet are re-attempted and complete normally.

#### E2. Force-quit during export, reopen — interrupted work shows soft "will retry"

**Goal.** A photo whose export was interrupted by a crash or app kill
recovers as a soft "will retry," not a red failure.

1. Reset to a fresh destination.
2. Toolbar picker → **Both**.
3. Click **Export All**. While the bar is moving, **force-quit** the
   app (⌘ ⌥ ⎋ → Photo Export → Force Quit).
4. Relaunch the app. Open the asset that was being exported when you
   force-quit (you can see the most-recent in-progress filename in
   Console.app filtered to `com.valtteriluoma.photo-export` if you're
   not sure which asset it was).

**Expected.** In the detail pane, the variant that was in flight
shows `"Original: Will retry on next export"` (or `"Edited: Will
retry on next export"`) in **secondary / grey** text — not red, not
"Failed".

5. Click **Export All** again.

**Expected.** The "will retry" rows are replaced by `Exported …` once
that variant finishes. No red failures appear.

#### E3. Edited resource unavailable — different soft message *(optional, hard to reproduce)*

**Goal.** When Photos genuinely cannot supply an edited rendering, the
detail pane uses a different soft message — still secondary color, but
explicitly about Photos not providing the edit.

This case is hard to provoke deliberately. It usually shows up
naturally for an iCloud-only edited asset whose rendered edit hasn't
synced. If you happen to encounter it during testing:

**Expected.** The detail pane shows
`"Edited version was not provided by Photos. Future exports will try
again."` in secondary / grey text. The original variant may still
have exported successfully alongside.

---

### Group F — Sidebar and detail UI

#### F1. Sidebar counts qualify under Edited mode

**Goal.** Counts in the sidebar say "edited" when the picker is on
Edited, and the green completion icon doesn't lie about a year that's
mostly unedited.

1. Toolbar picker → **Edited**.
2. Look at a month row that contains both edited and unedited photos.

**Expected.** The row's count uses one of these forms:

- `"X/Y edited"` (in orange) when partially exported
- `"Y edited"` (in secondary / grey) when not yet exported
- A green checkmark icon (with no extra caption) when complete

3. Switch the picker to **Originals**.

**Expected.** The same row's count drops the word "edited" (just
plain `X/Y` or `Y`), reflecting the new mode.

4. Switch to **Both**.

**Expected.** Same plain numbers — "edited" qualifier only appears
under Edited mode.

#### F2. Year row stays neutral while monthly counts load

**Goal.** Regression check for a bug where unloaded months were treated
as zero, briefly flashing a misleading 100%.

1. Quit and relaunch the app (so adjusted counts are uncached).
2. Toolbar picker → **Edited**.
3. In the sidebar, expand a year that has many months populated. Watch
   the year's badge as the months populate.

**Expected.** The year row shows **no** badge of any kind (no
percent, no checkmark) until *all* its populated months have reported
their counts. Once they have, the year shows either a percent
(orange) or a green checkmark.

#### F3. Detail pane shows per-variant status and Photos edits indicator

**Goal.** The detail pane reports each piece of the export separately
and indicates whether the asset is edited in Photos.

1. Pick **PA-2** (edited) after it's been exported in **Both** mode.
   Open its detail pane.

**Expected** (in order on the metadata stack):

- Filename, date, dimensions, file size (existing rows)
- `"Edits: Available in Photos"`
- `"Original: Exported <timestamp>"`
- `"Edited: Exported <timestamp>"`

2. Pick **PA-1** (unedited) after it's been exported.

**Expected.** `"Edits: None in Photos"` and a single
`"Original: Exported …"` row. No `Edited` row at all.

#### F4. Thumbnail blue dot reflects the active mode

**Goal.** The "not yet exported" dot on a thumbnail reflects whether
the asset is fully exported under the *current* selection.

1. Reset to a fresh destination.
2. Toolbar picker → **Originals**.
3. Open a month that contains **PA-2** (edited photo). Click
   **Export Month**, wait for completion.

**Expected.** PA-2's thumbnail has no blue dot.

4. Toolbar picker → **Both**.

**Expected.** PA-2's thumbnail gains a blue dot back (it now needs an
edited variant too). PA-1's thumbnail (unedited) stays without a dot.

5. Click **Export Month** again.

**Expected.** PA-2's blue dot disappears once the edited variant is
written.

#### F5. Sidebar tooltips describe what counts mean

**Goal.** Hovering a year or month row produces a tooltip that
explains the count under the active mode.

1. Toolbar picker → **Edited**.
2. Hover any month row in the sidebar that has a count.

**Expected.** A tooltip appears that reads roughly:
`"<MonthName> <Year>: X of Y edited versions exported. Unedited
photos are not part of this selection."` (Wording varies by mode and
state — the key thing is that it explicitly mentions that unedited
photos are not in the count when under Edited mode.)

3. Switch picker to **Originals**, hover the same row.

**Expected.** The tooltip rewords to talk about originals (no mention
of "unedited photos are not part of this selection").

---

### Group G — Onboarding

#### G1. First-run flow includes the version picker, and the choice sticks

**Goal.** A new user can pick destination, scope, and version
selection in one flow; their pick survives a relaunch.

1. Reset onboarding state. In Terminal:
   `defaults delete com.valtteriluoma.photo-export hasCompletedOnboarding`
2. Relaunch Photo Export. Grant Photos access if prompted.
3. Step 1: pick a destination folder.
4. Step 2: leave **Everything (Recommended)** selected.
5. Step 2 sub-picker: switch from **Originals** to **Both**.
6. Click **Start Export**.

**Expected.** When the main UI appears, the toolbar's
**Originals / Edited / Both** picker reads **Both**, and the
Export-All run that just kicked off is writing both originals and
`_edited` companions.

7. Quit the app, relaunch it.

**Expected.** The toolbar picker is still on **Both**.

---

### Group H — Import existing backup

#### H1. Re-importing an existing destination rebuilds per-variant records

**Goal.** A user reinstalling the app, or pointing it at an existing
backup folder, can reconstruct what was already exported without
re-copying anything.

1. Make sure your destination has a known mix from a previous scenario:
   originals only for unedited photos, originals + `_edited` for
   edited ones.
2. Quit Photo Export.
3. Relaunch and **Change…** the destination back to the same folder
   (the one with files in it).

   Right after relaunch the sidebar may show that month as not-yet-
   exported — that's expected, the records haven't been rebuilt yet.

4. **File → Import Existing Backup…** (⌘⇧I).
5. Wait for the four-stage import to finish. Note the **Files
   matched**, **Ambiguous**, and **No matching asset found** counts.
6. Click **Close**.

**Expected.** Files matched is non-zero and matches the file count in
the destination. Ambiguous and No-matching-asset-found are typically
zero. Sidebar badges now show months as exported (the badges show up
without re-copying any files). Open a previously-exported edited
asset's detail pane: both `Original: Exported …` and
`Edited: Exported …` rows are present, with the import timestamp.

#### H2. Asset whose real filename contains `_edited` is imported as original

**Goal.** Regression check that the scanner does not mistake a real
filename containing `_edited` for the app's edited variant of
something else.

1. From scenario B2, leave the destination with `vacation_edited.JPG`
   already exported.
2. Reset records by switching to a different destination, then
   switching back to this one.
3. **File → Import Existing Backup…**

**Expected.** The asset whose Photos filename is
`vacation_edited.JPG` is matched as an **Original** (no `Edited` row
in its detail pane).

#### H3. A stray file that doesn't match any asset shows up as unmatched

**Goal.** Verify the import report distinguishes "matched" from
"unmatched" so a user can spot leftover files in their backup.

1. Reset records by switching to a different destination then back, so
   the next import runs from scratch.
2. In Finder, copy any small file you have lying around (a stray
   text file works — rename it `stray.txt` if it isn't already) into
   the active destination's `YYYY/MM/` folder for any year/month.
3. **File → Import Existing Backup…**

**Expected.** The import report shows **Files matched** as before,
plus **No matching asset found: 1** (or however many strays you
added). The stray file is not added to any asset's record; sidebar
badges are unaffected.

#### H4. Import is unavailable while an export is running

**Goal.** The Import menu is gated so the user can't trigger an
import that conflicts with active export work.

1. Click **Export All** on a real library, so the queue is busy.
2. While the progress bar is moving, open the **File** menu (or press
   ⌘⇧I).

**Expected.** **Import Existing Backup…** is greyed out and the
shortcut does nothing. Once the export finishes (or you cancel), the
menu item becomes available again.

---

### Group I — Accessibility

These scenarios verify behaviour, not exact phrasing — VoiceOver's
spoken output varies between macOS minor versions.

#### I1. VoiceOver reads each thumbnail as a single coherent tile

**Goal.** A user with VoiceOver hears one description per thumbnail,
not three separate readings (image, dot, video badge).

1. Turn on VoiceOver: **System Settings → Accessibility → VoiceOver →
   On** (or ⌘ F5 from the keyboard, depending on your keyboard
   shortcut).
2. Open a month with a mix of edited and unedited photos.
3. Use VoiceOver navigation (Ctrl+Option+arrow keys) to walk through
   the thumbnails.

**Expected.** For each thumbnail, VoiceOver reads **one** description
that includes:

- the kind of media (Photo or Video)
- the date the photo was taken (if available)
- the duration in seconds (only for videos)
- the export state (`exported` or `not yet exported`)

It does **not** read the blue dot, the selection ring, or the video
badge as separate items. The thumbnail is announced as a button. The
in-tile **Retry** button on a failed thumbnail is independently
focusable (Tab into the tile, then Tab again to reach Retry).

#### I2. VoiceOver describes the toolbar picker

**Goal.** The picker has a meaningful label, hint, and locked-state
behavior.

1. With VoiceOver on, navigate to the toolbar's Versions picker.

**Expected.** VoiceOver reads, in some order, the label
`"Versions to export"`, the currently-selected segment, and the hint
`"Choose between originals, edited versions, or both."` Exact
phrasing varies; the label and hint must both be present.

2. Start an export. Re-navigate to the picker.

**Expected.** VoiceOver indicates the picker is disabled / dimmed,
and the picker still announces its label and current selection. The
hint may or may not be re-read by VoiceOver depending on macOS
version.

---

### Group J — Library observation

#### J1. Editing an asset in Photos updates the count after relaunch

**Goal.** When the user edits a photo in Apple Photos, the next time
the app reads its counts that asset is treated as edited.

> **Note.** The sidebar caches adjusted counts in memory for the
> current session. Photo Export's library-change observer clears its
> internal cache, but the sidebar's UI cache requires a relaunch to
> re-read. This scenario covers the relaunch path.

1. Open the app. Toolbar picker → **Edited**. Note the count for some
   month (e.g. it says `5 edited`).
2. Switch to **Photos.app**. In that month, pick an unedited asset
   (PA-7 will do). Apply any edit and click **Done**.
3. Quit Photo Export. Relaunch.
4. Toolbar picker → **Edited**. Look at the same month.

**Expected.** The count is now one higher (`6 edited`). Open the
month — the newly-edited asset's thumbnail has a blue dot under
**Edited** mode. Click **Export Month**: only the newly-edited photo
is enqueued; previously-exported edits are skipped.

---

### Group K — Other shipped behaviours

#### K1. Pause and resume

**Goal.** Pause halts the queue without losing it; resume picks back up
where it left off.

1. Reset to a fresh destination.
2. Toolbar picker → **Both**.
3. Click **Export All** on a real library (need at least 10 photos so
   pause has time to do something).
4. While the progress bar is moving, click the toolbar's **pause**
   button (⏸).

**Expected.** The currently-writing photo finishes, then no further
photos start. The progress bar stays put. The pause icon turns into
a **play** icon (▶).

5. Wait a few seconds — confirm no new files are appearing in the
   destination.
6. Click the **play** button.

**Expected.** Export resumes from where it left off. The number of
already-exported photos is preserved (the bar continues from the
mid-point you paused at, not zero).

#### K2. Stale `.tmp` cleanup

**Goal.** A leftover `.tmp` from a crashed previous run doesn't block
or interfere with a new export.

1. Reset to a fresh destination.
2. Identify the year/month folder where you'd export PA-1 (e.g.
   `2025/05/`). Create that folder by hand if it doesn't yet exist.
3. In Terminal, drop a fake stale temp file there:

   ```bash
   echo leftover > "/path/to/destination/2025/05/IMG_xxxx.JPG.tmp"
   ```

   The exact filename doesn't have to match a real asset, but if it
   matches the file PA-1 will export under (`<filename>.JPG.tmp`),
   you'll be testing the precise cleanup path.
4. Toolbar picker → **Originals**.
5. Open the month containing PA-1, click **Export Month**.

**Expected.** PA-1 exports normally; the destination folder afterward
contains only the `.JPG` file. The stale `.JPG.tmp` you seeded is
**gone**. No `.tmp` files remain.

#### K3. Step-1 paired-original conflict *(optional, advanced)*

**Goal.** When the app cannot place an original at its paired stem
because another file already lives there, it fails the original
variant cleanly rather than overwriting another asset's file.

This is hard to provoke without simulating two assets exporting in a
specific order. It is fully covered in unit tests; manual reproduction
is optional. If you do want to try:

1. Reset to a fresh destination.
2. Toolbar picker → **Edited**.
3. Export PA-2 (edited photo). Note the `_edited` filename, e.g.
   `IMG_xxxx (1)_edited.JPG`. The paired stem is `IMG_xxxx (1)`.
4. In Finder, *manually create* a file at `IMG_xxxx (1).JPG` in the
   same folder (e.g. `echo other > "IMG_xxxx (1).JPG"`).
5. Toolbar picker → **Both**.
6. Re-run **Export Month** on PA-2's month.

**Expected.** PA-2's edited variant remains exported. PA-2's original
variant **fails** with a soft red message in the detail pane saying
"Paired original filename already exists on disk: IMG_xxxx (1).JPG"
(or similar). The manually-created file is **not** overwritten — its
content is still `other`.

---

## Pass / fail summary template

When running the full suite, record results inline:

```
A1 Originals-only           ✅
A2 Edited-only              ✅
A3 Both                     ✅
A4 HEIC + JPEG edit         ✅
A5 Edited video             ✅
A6 Edited skips unedited    ✅
A7 Both unedited only       ✅
B1 Filename collision       ✅
B2 _edited in real name     ✅
C1 Originals → Both         ✅
C2 Edited → Both            ✅
D1 Already exported msg     ✅
D2 No edited versions       ✅
D3 Picker locked            ✅
E1 Cancel + resume          ✅
E2 Force-quit recovery      ✅
E3 Edited unavailable       ⚠ (optional)
F1 Mode-aware counts        ✅
F2 Year badge suppression   ✅
F3 Detail per-variant       ✅
F4 Thumbnail dot reacts     ✅
F5 Sidebar tooltips         ✅
G1 Onboarding flow          ✅
H1 Import rebuilds          ✅
H2 _edited as original      ✅
H3 Stray file unmatched     ✅
H4 Import gated mid-export  ✅
I1 VoiceOver thumbnails     ✅
I2 Picker accessibility     ✅
J1 Library observation      ✅
K1 Pause and resume         ✅
K2 Stale .tmp cleanup       ✅
K3 Paired conflict          ⚠ (optional)
```

If any scenario fails, file an issue with the scenario ID, the
expected vs. actual outcome, and the relevant log output from
**Console.app** filtered to the `com.valtteriluoma.photo-export`
subsystem.
