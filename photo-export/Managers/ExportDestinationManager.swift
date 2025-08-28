import AppKit
import Foundation
import os
import SwiftUI

@MainActor
final class ExportDestinationManager: ObservableObject {
    // MARK: - Published State
    @Published private(set) var selectedFolderURL: URL?
    @Published private(set) var isAvailable: Bool = false
    @Published private(set) var isWritable: Bool = false
    @Published private(set) var statusMessage: String?

    // MARK: - Keys & Logger
    private let bookmarkDefaultsKey = "ExportDestinationBookmark"
    private let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "ExportDestination")

    private var volumeObservers: [NSObjectProtocol] = []

    // MARK: - Lifecycle
    init() {
        restoreBookmarkIfAvailable()
        observeVolumeChanges()
    }

    deinit {
        for observer in volumeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.message = "Select a folder where your photos and videos will be exported."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            setSelectedFolder(url)
        }
    }

    func revealInFinder() {
        guard let url = selectedFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearSelection() {
        selectedFolderURL = nil
        isAvailable = false
        isWritable = false
        statusMessage = "No export folder selected"
        UserDefaults.standard.removeObject(forKey: bookmarkDefaultsKey)
        logger.info("Cleared export destination selection")
    }

    /// Call before performing file operations that require access
    /// The caller is responsible for calling `endScopedAccess()` afterwards
    /// when the operation is complete.
    func beginScopedAccess() -> Bool {
        guard let url = selectedFolderURL else { return false }
        return url.startAccessingSecurityScopedResource()
    }

    func endScopedAccess() {
        selectedFolderURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Internal Helpers
    private func setSelectedFolder(_ url: URL) {
        logger.info("User selected export folder: \(url.path, privacy: .public)")
        guard saveBookmark(for: url) else {
            statusMessage = "Failed to save access to selected folder"
            return
        }
        selectedFolderURL = url
        validate(url: url)
    }

    private func saveBookmark(for url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkDefaultsKey)
            return true
        } catch {
            logger.error("Failed to create bookmark: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func restoreBookmarkIfAvailable() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else {
            statusMessage = "No export folder selected"
            return
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                logger.info("Bookmark data is stale; attempting to re-save")
                _ = saveBookmark(for: url)
            }
            selectedFolderURL = url
            validate(url: url)
        } catch {
            logger.error("Failed to restore bookmark: \(String(describing: error), privacy: .public)")
            statusMessage = "Export folder permission needs to be re-selected"
            selectedFolderURL = nil
            isAvailable = false
            isWritable = false
        }
    }

    private func validate(url: URL) {
        // Temporarily acquire access for validation
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Check reachability
        var reachable = false
        do {
            reachable = try url.checkResourceIsReachable()
        } catch {
            reachable = false
        }

        // Ensure it is a directory
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = resourceValues?.isDirectory == true

        // Determine writability (best-effort)
        let writable = FileManager.default.isWritableFile(atPath: url.path)

        isAvailable = reachable && isDirectory
        isWritable = isAvailable && writable

        if !isDirectory {
            statusMessage = "Selected path is not a folder"
        } else if !reachable {
            statusMessage = "Export folder is not reachable (drive unplugged?)"
        } else if !writable {
            statusMessage = "Export folder is read-only"
        } else {
            statusMessage = nil
        }
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let mountObs = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let url = self.selectedFolderURL else { return }
                self.validate(url: url)
            }
        }
        let unmountObs = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let url = self.selectedFolderURL else { return }
                self.validate(url: url)
            }
        }
        volumeObservers = [mountObs, unmountObs]
    }
}
