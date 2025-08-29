# IMPLEMENTATION_TASKS.md

## Apple Photos Backup App — Implementation Tasks

This project is a macOS app for backing up the Apple Photos library to
local/external storage, exporting assets into an organized folder hierarchy. The
app uses **Swift** and **SwiftUI**, and targets the latest macOS versions.

Below are the concrete, explicit development tasks. Each task should be
committed independently.

---

### 1. Project Initialization

- [x] Initialize a new Xcode project for a macOS app (Swift, SwiftUI).
- [x] Set deployment target to the latest stable macOS version.
- [x] Set up recommended folder structure: `Models`, `ViewModels`, `Views`,
      `Managers`, `Resources`, `SupportingFiles`.

---

### 2. Photos Library Access

- [x] Implement user authorization request for Photos library access using the
      Photos framework.
- [x] Implement a `PhotoLibraryManager` class to query assets from the Photos
      library.
  - [x] Provide functions to fetch all photo and video assets, grouped by year
        and month.
  - [x] Extract asset metadata: creation date, media type, local identifier.
  - [x] Implement utility for filtering by media type (photos/videos).
  - [x] Make APIs asynchronous as needed.

---

### 3. Export Destination Management

- [x] Implement UI for users to select a root export folder using the standard
      macOS folder picker.
- [x] Persist the chosen export folder path using user defaults or app storage.
- [x] Display the currently selected export folder in the main UI.

---

### 4. Export Folder Structure

- [x] Implement logic to generate export paths in the format:
      `<root>/<year>/<month>/`.
- [x] Ensure folder structure is automatically created as needed during export.

---

### 5. Export Record and Status Tracking

- [x] Implement an `ExportRecordStore` (e.g., lightweight database or local
      JSON/plist).
  - [x] Store which assets (by Photos local identifier) have been exported, with
        year/month, export path, and export date.
  - [x] Load export records at app start; save updates after each export.
- [x] Implement logic to detect:
  - [x] Which months/years have been fully exported.
  - [x] Which months have new or changed photos needing export.

---

### 6. UI Implementation

- [ ] Implement the main SwiftUI view with:
  - [x] Export folder selection section.
  - [x] List or grid of available years and months, showing export status (not
        exported, partially exported, exported).
- [ ] Implement a month view:
  - [ ] Display a grid of thumbnails for all assets in the month, filterable by
        media type.
  - [x] Provide a preview pane for the selected asset (large photo/video).
  - [x] Show unexported assets visually (uses `ExportRecordStore`).
- [ ] Implement filter controls:
  - [ ] Toggle to show only photos, only videos, or both.
- [ ] Delineate which assets are new/unexported visually in the asset grid.

---

### 7. Export Functionality

- [ ] Implement export actions:
  - [x] Allow user to export all assets in a month (MVP).
  - [ ] Allow user to export all assets in a year, or custom selection.
  - [x] Only copy assets which have not yet been exported (based on export
        records).
- [x] Copy asset files into the correct export subfolder.
  - [x] Handle both images and videos.
- [x] Update the export records after a successful export.
- [x] Track and display export progress and status in the UI.
- [ ] Concurrency: keep serial for MVP; add bounded parallel exports post-MVP.

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
