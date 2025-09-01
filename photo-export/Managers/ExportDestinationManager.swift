import AppKit
import CryptoKit
import Foundation
import SwiftUI
import os

@MainActor
final class ExportDestinationManager: ObservableObject {
  // MARK: - Published State
  @Published private(set) var selectedFolderURL: URL?
  @Published private(set) var isAvailable: Bool = false
  @Published private(set) var isWritable: Bool = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var destinationId: String?

  // MARK: - Keys & Logger
  private let bookmarkDefaultsKey = "ExportDestinationBookmark"
  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ExportDestination")

  private var volumeObservers: [NSObjectProtocol] = []

  // MARK: - Errors
  enum ExportDestinationError: LocalizedError {
    case noSelection
    case notAvailable
    case notWritable
    case invalidYear
    case invalidMonth
    case scopeAccessDenied
    case pathTooLong
    case notDirectory(URL)
    case failedToCreateFolder(URL, underlying: Error)

    var errorDescription: String? {
      switch self {
      case .noSelection: return "No export folder selected."
      case .notAvailable: return "Export folder is not reachable (drive unplugged?)."
      case .notWritable: return "Export folder is read-only."
      case .invalidYear: return "Invalid year."
      case .invalidMonth: return "Invalid month."
      case .scopeAccessDenied:
        return "Could not access the selected folder due to sandbox restrictions."
      case .pathTooLong: return "The generated export path is too long."
      case .notDirectory(let url): return "Path exists but is not a folder: \(url.path)"
      case .failedToCreateFolder(let url, let underlying):
        return "Failed to create folder at \(url.path): \(underlying.localizedDescription)"
      }
    }
  }

  // MARK: - Public Computed
  var canExportNow: Bool { selectedFolderURL != nil && isAvailable && isWritable }

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
    destinationId = nil
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

  /// Returns the URL for the <root>/<year>/<month>/ folder, optionally creating it.
  /// Month is formatted as two digits ("01" … "12").
  /// - Parameters:
  ///   - year: e.g., 2025
  ///   - month: 1…12
  ///   - createIfNeeded: create the directory if it does not exist (default true)
  /// - Throws: ExportDestinationError on invalid state or inability to create.
  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool = true) throws -> URL {
    guard let root = selectedFolderURL else { throw ExportDestinationError.noSelection }
    guard isAvailable else { throw ExportDestinationError.notAvailable }
    guard isWritable else { throw ExportDestinationError.notWritable }
    guard year > 0 else { throw ExportDestinationError.invalidYear }
    guard (1...12).contains(month) else { throw ExportDestinationError.invalidMonth }

    let yearComponent = String(year)
    let monthComponent = String(format: "%02d", month)
    let target = root.appendingPathComponent(yearComponent, isDirectory: true)
      .appendingPathComponent(monthComponent, isDirectory: true)

    // Guard against excessively long paths (PATH_MAX ~1024 on macOS)
    if target.path.utf8.count >= 1000 { throw ExportDestinationError.pathTooLong }

    let didStart = beginScopedAccess()
    defer { if didStart { endScopedAccess() } }
    guard didStart else { throw ExportDestinationError.scopeAccessDenied }

    if createIfNeeded {
      try ensureDirectoryExists(at: target)
    } else {
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) {
        if !isDir.boolValue { throw ExportDestinationError.notDirectory(target) }
      }
    }

    return target
  }

  /// Ensures the directory exists at the given URL, creating with intermediates.
  func ensureDirectoryExists(at url: URL) throws {
    var isDir: ObjCBool = false
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
      if !isDir.boolValue { throw ExportDestinationError.notDirectory(url) }
      return
    }
    do {
      try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
      logger.info("Ensured directory: \(url.path, privacy: .public)")
    } catch {
      logger.error(
        "Failed to create directory: \(url.path, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      throw ExportDestinationError.failedToCreateFolder(url, underlying: error)
    }
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

  private func computeDestinationId(from bookmarkData: Data) -> String {
    let digest = SHA256.hash(data: bookmarkData)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func saveBookmark(for url: URL) -> Bool {
    do {
      let data = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(data, forKey: bookmarkDefaultsKey)
      destinationId = computeDestinationId(from: data)
      return true
    } catch {
      logger.error(
        "Failed to create bookmark: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  private func restoreBookmarkIfAvailable() {
    guard let data = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else {
      statusMessage = "No export folder selected"
      destinationId = nil
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
      } else {
        destinationId = computeDestinationId(from: data)
      }
      selectedFolderURL = url
      validate(url: url)
    } catch {
      logger.error(
        "Failed to restore bookmark: \(String(describing: error), privacy: .public)")
      statusMessage = "Export folder permission needs to be re-selected"
      selectedFolderURL = nil
      isAvailable = false
      isWritable = false
      destinationId = nil
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
