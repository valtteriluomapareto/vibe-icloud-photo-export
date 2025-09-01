# IMPLEMENTATION_TASKS.md

## Apple Photos Backup App — Open Tasks (Grouped by Impact)

This project is a macOS app for backing up the Apple Photos library to local/external storage, exporting assets into an organized folder hierarchy. The app uses **Swift** and **SwiftUI**, and targets the latest macOS versions.

Completed tasks have been moved to `IMPLEMENTED_FEATURES.md`. Below are the remaining open tasks, grouped by how they affect the app.

---

### UI modification
  
- [ ] Add filter control for media type (photos/videos)
- [ ] Identify and visually indicate newly added assets for partially exported months.

---

### New feature

- [ ] Allow user to export a custom selection
- [ ] Manual refresh to rescan library on demand.
- [ ] Adopt `PHPhotoLibraryChangeObserver` to live-update when the Photos library changes during app use. (Planned)

---

### Performance

- [ ] Ensure video previews display quickly and at suitable size.
- [ ] Add bounded concurrent export queue (2–3 workers) with a configurable limit. (Planned)

---

### Fault tolerance

- [ ] Display clear error messages in the UI where needed.
- [ ] Allow user to retry failed exports.

---

### Usability

- [ ] Implement filter controls:
  - [ ] Toggle to show only photos, only videos, or both.
- [ ] Ensure the UI follows macOS human interface guidelines.
- [ ] Add subtle animations where appropriate.
- [ ] Ensure good accessibility for all interactive elements.
- [ ] Persist app settings:
  - [ ] Persist filter choices
  - [ ] Persist other relevant settings
- [ ] Remember window state and last viewed month/year.

---

### Enhancement

- [ ] Keep code modular and well-commented.
- [ ] Document all public classes and methods in source files.

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
