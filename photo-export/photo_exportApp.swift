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
          exportRecordStore.configure(for: exportDestinationManager.destinationId)
        }
        .onChange(of: exportDestinationManager.destinationId) { _, newId in
          // Cancel any in-flight exports and reconfigure the per-destination store
          exportManager.cancelAndClear()
          exportRecordStore.configure(for: newId)
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
