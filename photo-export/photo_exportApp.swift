//
//  photo_exportApp.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import SwiftUI

@main
struct photo_exportApp: App {
    @StateObject private var exportDestinationManager = ExportDestinationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(exportDestinationManager)
        }
    }
}
