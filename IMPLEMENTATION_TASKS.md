# IMPLEMENTATION_TASKS.md

## Apple Photos Backup App — Open Tasks (Grouped by Impact)

This project is a macOS app for backing up the Apple Photos library to local/external storage, exporting assets into an organized folder hierarchy. The app uses **Swift** and **SwiftUI**, and targets the latest macOS versions.

Completed tasks have been moved to `IMPLEMENTED_FEATURES.md`. Below are the remaining open tasks, grouped by how they affect the app.

---

### UI modification
  
- [x] Implement a month view:
  - [x] Display a grid of thumbnails for all assets in the month
  - [ ] Add filter control for media type (photos/videos)
- [x] Delineate which assets are unexported visually in the asset grid.
- [ ] Identify and visually indicate newly added assets for partially exported months.

---

### New feature

- [ ] Implement export actions:
  - [ ] Allow user to export all assets in a year, or custom selection.
- [x] On app launch, rescan Photos library and cross-check with existing exports.
- [ ] Manual refresh to rescan library on demand.
- [x] Support incremental export, exporting only the new assets for any selected month.

---

### Performance

- [ ] Concurrency: keep serial for MVP; add bounded parallel exports post-MVP.
- [x] Implement fast thumbnail loading and in-memory caching for asset grids.
- [x] Reduce contention: pause/disable thumbnail networking during export (use non-network thumbnails while exporting)
- [x] Ensure image previews display quickly and at suitable size.
- [ ] Ensure video previews display quickly and at suitable size.

---

### Fault tolerance

- [x] Gracefully handle failures:
  - [x] Photos library access denied.
  - [x] Export folder unavailable or write-protected.
  - [x] Individual asset export failure (skip, record, continue).
- [ ] Display clear error messages in the UI where needed.
- [ ] Allow user to retry failed exports.

---

### Usability

- [ ] Implement filter controls:
  - [ ] Toggle to show only photos, only videos, or both.
- [ ] Ensure the UI follows macOS human interface guidelines.
- [x] Add loading indicators where appropriate.
- [ ] Add subtle animations where appropriate.
- [ ] Ensure good accessibility for all interactive elements.
- [ ] Persist app settings:
  - [x] Persist last used export folder
  - [ ] Persist filter choices
  - [ ] Persist other relevant settings
- [ ] Remember window state and last viewed month/year.

---

### Enhancement

- [ ] Keep code modular and well-commented.
- [ ] Document all public classes and methods in source files.
- [x] Write a short README for building, running, and using the app.

---

## Notes

- **No extra features** beyond the ones listed above.
- Use only official Apple frameworks.
- Target only latest Mac hardware and OS.
- Focus on usability, clarity, and reliability.

---

When all tasks are checked, the app’s MVP is considered complete.\
For any clarifications, refer to the purpose and features at the top of this document.

---
