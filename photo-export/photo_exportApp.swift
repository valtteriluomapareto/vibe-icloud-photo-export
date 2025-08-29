//
//  photo_exportApp.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import SwiftUI

@main
struct photo_exportApp: App {
    @StateObject private var exportDestinationManager: ExportDestinationManager
    @StateObject private var photoLibraryManager: PhotoLibraryManager
    private let exportRecordStore: ExportRecordStore
    @StateObject private var exportManager: ExportManager

    init() {
        // Initialize dependencies locally, then assign to stored properties and StateObjects
        let edm = ExportDestinationManager()
        let plm = PhotoLibraryManager()
        let ers = ExportRecordStore()
        self.exportRecordStore = ers
        _exportDestinationManager = StateObject(wrappedValue: edm)
        _photoLibraryManager = StateObject(wrappedValue: plm)
        _exportManager = StateObject(wrappedValue: ExportManager(photoLibraryManager: plm, exportDestinationManager: edm, exportRecordStore: ers))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(exportDestinationManager)
                .environmentObject(photoLibraryManager)
                .environmentObject(exportManager)
                .environmentObject(exportRecordStore)
                .task {
                    try? exportRecordStore.loadOnLaunch()
                }
        }
    }
}
