# IMPLEMENTED_FEATURES.md

## Apple Photos Backup App — Implemented Features

Below are the features that have been completed and verified as implemented. These were moved from `IMPLEMENTATION_TASKS.md` to keep the implementation list focused on open work.

---

### 1. Project Initialization

- [x] Initialize a new Xcode project for a macOS app (Swift, SwiftUI).
- [x] Set deployment target to the latest stable macOS version.
- [x] Set up recommended folder structure: `Models`, `ViewModels`, `Views`, `Managers`, `Resources`, `SupportingFiles`.

---

### 2. Photos Library Access

- [x] Implement user authorization request for Photos library access using the Photos framework.
- [x] Implement a `PhotoLibraryManager` class to query assets from the Photos library.
  - [x] Provide functions to fetch all photo and video assets, grouped by year and month.
  - [x] Extract asset metadata: creation date, media type, local identifier.
  - [x] Implement utility for filtering by media type (photos/videos).
  - [x] Make APIs asynchronous as needed.

---

### 3. Export Destination Management

- [x] Implement UI for users to select a root export folder using the standard macOS folder picker.
- [x] Persist the chosen export folder path using user defaults or app storage.
- [x] Display the currently selected export folder in the main UI.

---

### 4. Export Folder Structure

- [x] Implement logic to generate export paths in the format: `<root>/<year>/<month>/`.
- [x] Ensure folder structure is automatically created as needed during export.

---

### 5. Export Record and Status Tracking

- [x] Implement an `ExportRecordStore` (e.g., lightweight database or local JSON/plist).
  - [x] Store which assets (by Photos local identifier) have been exported, with year/month, export path, and export date.
  - [x] Load export records at app start; save updates after each export.
- [x] Implement logic to detect:
  - [x] Which months/years have been fully exported.
  - [x] Which months have new or changed photos needing export.

---

### 6. UI Implementation (Completed parts)

- [x] Export folder selection section in the main view.
- [x] List or grid of available years and months, showing export status (not exported, partially exported, exported).
- [x] Month view: Provide a preview pane for the selected asset (large photo/video).
- [x] Month view: Show unexported assets visually (uses `ExportRecordStore`).

---

### 7. Export Functionality (Completed parts)

- [x] Implement export actions: Allow user to export all assets in a month or a year (MVP).
- [x] Only copy assets which have not yet been exported (based on export records).
- [x] Copy asset files into the correct export subfolder.
  - [x] Handle both images and videos.
- [x] Update the export records after a successful export.
- [x] Track and display export progress and status in the UI.
  - [x] Sidebar controls: pause/resume, clear pending, cancel & clear
  - [x] Queue status indicator in sidebar (Export Process section)

---

### 8. Performance & UX Improvements (Completed)

- [x] Concurrency kept serial for MVP; plan bounded parallelism post-MVP.
- [x] Fast thumbnail loading and in-memory caching for grids.
- [x] Pause/disable thumbnail networking during export to reduce contention.
- [x] Ensure image previews display quickly and at suitable size.
- [x] Add loading indicators where appropriate.

---

### 9. Fault Tolerance (Completed)

- [x] Graceful handling of failures:
  - [x] Photos library access denied.
  - [x] Export folder unavailable or write-protected.
  - [x] Individual asset export failure (skip, record, continue).

---

These items reflect the current MVP baseline delivered so far.
