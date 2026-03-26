# Open Tasks

Remaining work items, grouped by area. Move items to GitHub Issues when practical.

## UI

- [ ] Add filter control for media type (photos/videos)
- [ ] Visually indicate newly added assets for partially exported months

## Features

- [ ] Allow user to export a custom selection
- [ ] Manual refresh to rescan library on demand
- [ ] Adopt `PHPhotoLibraryChangeObserver` to live-update when the Photos library changes

## Performance

- [ ] Ensure video previews display quickly and at suitable size
- [ ] Add bounded concurrent export queue (2–3 workers) with a configurable limit

## Fault Tolerance

- [ ] Display clear error messages in the UI where needed
- [ ] Allow user to retry failed exports

## Usability

- [ ] Filter toggle: photos only, videos only, or both
- [ ] Follow macOS Human Interface Guidelines
- [ ] Add subtle animations where appropriate
- [ ] Ensure good accessibility for all interactive elements
- [ ] Persist filter choices and other relevant settings
- [ ] Remember window state and last viewed month/year
