# IMPLEMENTATION_TASKS.md

## Apple Photos Backup App — Implementation Tasks

This project is a macOS app for backing up the Apple Photos library to
local/external storage, exporting assets into an organized folder hierarchy. The
app uses **Swift** and **SwiftUI**, and targets the latest macOS versions.

Below are the concrete, explicit development tasks. Each task should be
committed independently.

---

### 1. Project Initialization

- [ ] Initialize a new Xcode project for a macOS app (Swift, SwiftUI).
- [ ] Set deployment target to the latest stable macOS version.
- [ ] Set up recommended folder structure: `Models`, `ViewModels`, `Views`,
      `Managers`, `Resources`, `SupportingFiles`.

---

### 2. Photos Library Access

- [ ] Implement user authorization request for Photos library access using the
      Photos framework.
- [ ] Implement a `PhotoLibraryManager` class to query assets from the Photos
      library.
  - [ ] Provide functions to fetch all photo and video assets, grouped by year
        and month.
  - [ ] Extract asset metadata: creation date, media type, local identifier.
  - [ ] Implement utility for filtering by media type (photos/videos).
  - [ ] Make APIs asynchronous as needed.

---

### 3. Export Destination Management

- [ ] Implement UI for users to select a root export folder using the standard
      macOS folder picker.
- [ ] Persist the chosen export folder path using user defaults or app storage.
- [ ] Display the currently selected export folder in the main UI.

---

### 4. Export Folder Structure

- [ ] Implement logic to generate export paths in the format:
      `<root>/<year>/<month>/`.
- [ ] Ensure folder structure is automatically created as needed during export.

---

### 5. Export Record and Status Tracking

- [ ] Implement an `ExportRecordStore` (e.g., lightweight database or local
      JSON/plist).
  - [ ] Store which assets (by Photos local identifier) have been exported, with
        year/month, export path, and export date.
  - [ ] Load export records at app start; save updates after each export.
- [ ] Implement logic to detect:
  - [ ] Which months/years have been fully exported.
  - [ ] Which months have new or changed photos needing export.

---

### 6. UI Implementation

- [ ] Implement the main SwiftUI view with:
  - [ ] Export folder selection section.
  - [ ] List or grid of available years and months, showing export status (not
        exported, partially exported, exported).
- [ ] Implement a month view:
  - [ ] Display a grid of thumbnails for all assets in the month, filterable by
        media type.
  - [ ] Provide a preview pane for the selected asset (large photo/video).
- [ ] Implement filter controls:
  - [ ] Toggle to show only photos, only videos, or both.
- [ ] Delineate which assets are new/unexported visually in the asset grid.

---

### 7. Export Functionality

- [ ] Implement export actions:
  - [ ] Allow user to export all assets in a month, year, or custom selection.
  - [ ] Only copy assets which have not yet been exported (based on export
        records).
- [ ] Copy asset files into the correct export subfolder.
  - [ ] Handle both images and videos.
- [ ] Update the export records after a successful export.
- [ ] Track and display export progress and status in the UI.

---

### 8. Incremental Export & Rescanning

- [ ] On app launch or manual refresh, rescan Photos library and cross-check
      with existing exports.
- [ ] Identify and visually indicate newly added assets for partially exported
      months.
- [ ] Support incremental export, exporting only the new assets for any selected
      month.

---

### 9. Thumbnail and Preview Handling

- [ ] Implement fast thumbnail loading and in-memory caching for asset grids.
- [ ] Ensure previews for images and videos display quickly and at suitable
      size.

---

### 10. Error Handling & Robustness

- [ ] Gracefully handle failures:
  - [ ] Photos library access denied.
  - [ ] Export folder unavailable or write-protected.
  - [ ] Individual asset export failure.
- [ ] Display clear error messages in the UI where needed.
- [ ] Allow user to retry failed exports.

---

### 11. Preferences & Persistence

- [ ] Persist app settings, including last used export folder and filter
      choices.
- [ ] Remember window state and last viewed month/year.

---

### 12. UI/UX Polish

- [ ] Ensure the UI follows macOS human interface guidelines.
- [ ] Add animations and loading indicators where appropriate.
- [ ] Ensure good accessibility for all interactive elements.

---

### 13. Code Review and Documentation

- [ ] Keep code modular and well-commented.
- [ ] Document all public classes and methods in source files.
- [ ] Write a short README for building, running, and using the app.

---

## Notes

- **No extra features** beyond the ones listed above.
- Use only official Apple frameworks.
- Target only latest Mac hardware and OS.
- Focus on usability, clarity, and reliability.

---

When all tasks are checked, the app’s MVP is considered complete.\
For any clarifications, refer to the purpose and features at the top of this
document.

---
