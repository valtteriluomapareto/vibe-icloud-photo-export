## Future Enhancements

This document outlines potential improvements to evolve the Apple Photos backup/export app. Each item includes a short rationale to clarify the value.

### Export Pipeline, Reliability, and Performance
- **Bounded concurrent export queue**: Implement an async semaphore–backed task queue to export multiple assets in parallel with a configurable limit. Improves throughput while keeping memory and I/O under control. Keep MVP serial to reduce complexity; enable concurrency under a preference later.
- **Atomic writes with robust temp handling**: Always write to a temporary file and atomically move to the final location; add verification of file size/date to reduce risk of partial or corrupt files after interruptions.
- **Crash-resume semantics**: Persist in-progress states more granularly (e.g., “copying”, “verifying”, “done”) to resume precisely where the app left off after a crash or power loss.
- **Progress UI with pause/cancel**: Add user controls to pause/resume/cancel export jobs and show per-asset and overall progress. Improves transparency and control for long-running exports.
- **Preflight destination checks**: Before starting a job, verify available space, permissions, and mount status to fail fast with actionable guidance.

### Data & Persistence
- **Migrate `ExportRecordStore` to SQLite**: Switch from JSONL to SQLite when scaling to very large libraries (10k–100k+). Gains efficient queries (e.g., month aggregations), transactional updates, and better long-term performance.
- **Snapshot/compaction cadence & health checks**: Add background scheduling for compaction and store integrity verification to keep JSONL logs small and healthy.
- **Monthly asset count cache**: Cache per-month totals to avoid repeated Photos count queries, improving sidebar performance on large libraries.

### Photos Integration & Media Support
- **Live Photos and paired assets**: Ensure image+video pairs (Live Photos) export together coherently; use `PHAssetResourceManager` for original resources where appropriate for fidelity.
- **iCloud originals handling**: Expose settings to allow network downloads of originals (with progress) or skip remote-only assets when offline, avoiding export stalls.
- **Library change observation**: Adopt `PHPhotoLibraryChangeObserver` to live-update month lists and badges when the Photos library changes during app use.

### File System & Naming
- **Flexible naming scheme**: Allow user-configurable naming (e.g., `YYYYMMDD_HHMMSS_originalName.ext`), sanitize characters, and ensure collision-safe unique suffixing. Increases portability and predictability.
- **Folder manifests**: Optionally emit a small JSON/CSV manifest per month folder listing asset IDs → exported filenames. Aids auditing and external processing.
- **Path length and invalid name defenses**: Centralize and harden path validation with fallbacks for long/invalid names to prevent export failures on edge cases.

### Metadata & Privacy
- **Optional metadata sidecars**: Export per-asset sidecar JSON or XMP with EXIF/IPTC/timezone/location (with a privacy toggle). Enables richer offline usage and external tooling.
- **Location privacy controls**: Provide an option to strip or retain GPS data in exported images where applicable.

### UI/UX
- **Filter and search**: Add filters (photos/videos/favorites/edited) and basic search (by date range, filename) to improve navigation in large libraries.
- **Badges and legends**: Show a concise legend for month badges and allow toggling counts to reduce visual noise on small screens.
- **Preferences window**: Centralize settings: default export destination, parallelism, naming scheme, metadata/privacy options, and “download iCloud originals”.
- **Accessibility**: Improve VoiceOver labels, focus order, and dynamic type responsiveness for key screens.

### Observability & Diagnostics
- **Structured logging & signposts**: Expand `os.Logger` categories (Auth, Fetch, Thumbs, Export, Store) and add signposts to profile export stages in Instruments.
- **Diagnostics bundle export**: One-click collection of logs, store snapshots, and environment info to a ZIP to help with bug reports.

### Testing & Quality
- **Integration tests for export jobs**: Use a temporary directory to simulate full exports, including unplugged drive scenarios and partial resumes.
- **Performance tests**: Measure time and memory for month loads and bulk exports; guard against regressions.
- **Property-based tests for store**: Fuzz sequences of upsert/delete mutations to validate `ExportRecordStore` compaction and replay correctness.

### Internationalization
- **Localization**: Localize UI strings (e.g., English, Finnish) and ensure date/number formats respect locale. Broadens user reach and usability.

### Future Platform Considerations
- **Multiple destinations**: Support more than one export root (e.g., internal drive + external archive), with per-destination status and conflict resolution.
- **Background agent / helper**: Optional background process to continue long exports when the main UI is closed, with notifications on completion/errors.
