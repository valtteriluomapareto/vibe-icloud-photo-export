# IMPLEMENTATION_TASKS.md

## Apple Photos Backup App — Open Tasks (Grouped by Impact)

This project is a macOS app for backing up the Apple Photos library to local/external storage, exporting assets into an organized folder hierarchy. The app uses **Swift** and **SwiftUI**, and targets the latest macOS versions.

Completed tasks have been moved to `IMPLEMENTED_FEATURES.md`. Below are the remaining open tasks, grouped by how they affect the app.

---

### UI modification
  
- [ ] Implement a month view:
   - [ ] Display a grid of thumbnails for all assets in the month, filterable by media type.
- [ ] Delineate which assets are new/unexported visually in the asset grid.
- [ ] Identify and visually indicate newly added assets for partially exported months.

---

### New feature

- [ ] Implement export actions:
  - [ ] Allow user to export all assets in a year, or custom selection.
- [ ] On app launch or manual refresh, rescan Photos library and cross-check with existing exports.
- [ ] Support incremental export, exporting only the new assets for any selected month.

---

### Performance

- [ ] Concurrency: keep serial for MVP; add bounded parallel exports post-MVP.
- [ ] Implement fast thumbnail loading and in-memory caching for asset grids.
- [ ] Ensure previews for images and videos display quickly and at suitable size.

---

### Fault tolerance

- [ ] Gracefully handle failures:
  - [ ] Photos library access denied.
  - [ ] Export folder unavailable or write-protected.
  - [ ] Individual asset export failure.
- [ ] Display clear error messages in the UI where needed.
- [ ] Allow user to retry failed exports.

---

### Usability

- [ ] Implement filter controls:
  - [ ] Toggle to show only photos, only videos, or both.
- [ ] Ensure the UI follows macOS human interface guidelines.
- [ ] Add animations and loading indicators where appropriate.
- [ ] Ensure good accessibility for all interactive elements.
- [ ] Persist app settings, including last used export folder and filter choices.
- [ ] Remember window state and last viewed month/year.

---

### Enhancement

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
For any clarifications, refer to the purpose and features at the top of this document.

---
