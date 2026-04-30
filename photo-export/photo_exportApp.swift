//
//  photo_exportApp.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import SwiftUI

@main
struct PhotoExportApp: App {
  @StateObject private var exportDestinationManager: ExportDestinationManager
  @StateObject private var photoLibraryManager: PhotoLibraryManager
  @StateObject private var exportRecordStore: ExportRecordStore
  @StateObject private var exportManager: ExportManager

  init() {
    // Initialize dependencies locally, then assign to stored properties and StateObjects
    let edm = ExportDestinationManager()
    let plm = PhotoLibraryManager()
    let ers = ExportRecordStore()
    _exportDestinationManager = StateObject(wrappedValue: edm)
    _photoLibraryManager = StateObject(wrappedValue: plm)
    _exportRecordStore = StateObject(wrappedValue: ers)
    _exportManager = StateObject(
      wrappedValue: ExportManager(
        photoLibraryService: plm, exportDestination: edm, exportRecordStore: ers))
  }

  var body: some Scene {
    WindowGroup("Photo Export") {
      ContentView()
        .environmentObject(exportDestinationManager)
        .environmentObject(photoLibraryManager)
        .environmentObject(exportManager)
        .environmentObject(exportRecordStore)
        .task {
          // Configure store for current destination (if any) at launch
          configureRecordStore(for: exportDestinationManager.destinationId)
        }
        .onChange(of: exportDestinationManager.destinationId) { _, newId in
          // Cancel any in-flight exports and reconfigure the per-destination store
          exportManager.cancelAndClear()
          configureRecordStore(for: newId)
        }
    }
    .commands {
      CommandGroup(replacing: .appInfo) {
        AboutCommand()
      }
      CommandGroup(after: .importExport) {
        ImportBackupCommand()
      }
    }

    Window("About Photo Export", id: "about") {
      AboutView()
    }
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)
  }

  /// Runs the per-destination directory coordinator (Phase 0 lazy migration) and then
  /// reconfigures the record store. This single hop keeps the legacy `<oldId>` → `<newId>`
  /// rename centralized so future stores (Phase 1's collection store) can configure in any
  /// order without orphaning the legacy directory.
  private func configureRecordStore(for newId: String?) {
    guard let newId else {
      exportRecordStore.configure(for: nil)
      return
    }
    let coordinator = ExportRecordsDirectoryCoordinator(
      storeRootURL: exportRecordStore.storeRootURL)
    let result = coordinator.prepareDirectory(
      for: newId,
      legacyId: exportDestinationManager.currentLegacyDestinationId()
    )
    switch result {
    case .success:
      exportRecordStore.configure(for: newId)
    case .failure(.conflict):
      // `<newId>/` already exists on disk; the legacy directory is left for inspection.
      // Configuring is safe — we adopt whatever's at `<newId>/`. Coordinator already logged.
      exportRecordStore.configure(for: newId)
    case .failure(.migrationFailed):
      // Transient I/O error during the legacy → new rename. `<legacyId>/` still has the
      // user's records; `<newId>/` does not exist yet. Configuring `for: newId` would
      // create `<newId>/` and trip the conflict-detection branch on every subsequent
      // launch, permanently stranding the legacy records. Leave the store unconfigured;
      // next launch (or the next destinationId change) retries the rename. UI will show
      // an empty record set, which the user can recover from by relaunching once the
      // transient condition clears.
      exportRecordStore.configure(for: nil)
    }
  }
}

private struct AboutCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("About Photo Export") {
      openWindow(id: "about")
    }
  }
}

// MARK: - Import Backup Command

struct ImportBackupAction {
  let callAsFunction: () -> Void
}

struct ImportBackupActionKey: FocusedValueKey {
  typealias Value = ImportBackupAction
}

extension FocusedValues {
  var importBackupAction: ImportBackupAction? {
    get { self[ImportBackupActionKey.self] }
    set { self[ImportBackupActionKey.self] = newValue }
  }
}

private struct ImportBackupCommand: View {
  @FocusedValue(\.importBackupAction) private var importAction

  var body: some View {
    Button("Import Existing Backup\u{2026}") {
      importAction?.callAsFunction()
    }
    .keyboardShortcut("i", modifiers: [.command, .shift])
    .disabled(importAction == nil)
  }
}
