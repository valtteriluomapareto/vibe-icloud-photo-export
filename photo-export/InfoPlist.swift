import Foundation

// This file provides the Info.plist values programmatically rather than relying on an external file
// SwiftUI apps can use this approach alongside the existing Info.plist or as a replacement

enum PhotoExportInfoPlist {
    static let infoDictionary: [String: Any] = [
        // The key we need for Photos access
        "NSPhotoLibraryUsageDescription": "This app needs access to your Photos library to back up your photos and videos to external storage."
    ]
    
    static func register() {
        // Add our values to the existing Info.plist at runtime
        for (key, value) in infoDictionary {
            // Bundle.main.infoDictionary?[key] = value
        }
    }
} 
