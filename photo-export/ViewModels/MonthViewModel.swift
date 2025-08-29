import AppKit
import Foundation
import Photos
import SwiftUI

@MainActor
final class MonthViewModel: ObservableObject {
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var thumbnailsById: [String: NSImage] = [:]
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Selection is tracked via id to avoid retaining PHAsset strongly across updates
    @Published var selectedAssetId: String?

    private let photoLibraryManager: PhotoLibraryManager

    // Control initial thumbnail batch size
    private let initialThumbnailBatchSize: Int = 40

    init(photoLibraryManager: PhotoLibraryManager) {
        self.photoLibraryManager = photoLibraryManager
    }

    func loadAssets(forYear year: Int, month: Int) async {
        isLoading = true
        errorMessage = nil
        assets = []
        thumbnailsById = [:]
        selectedAssetId = nil

        do {
            let monthAssets = try await photoLibraryManager.fetchAssets(year: year, month: month)
            assets = monthAssets

            // Preload an initial batch of thumbnails
            let initialBatch = Array(monthAssets.prefix(initialThumbnailBatchSize))
            var initialThumbs: [String: NSImage] = [:]

            for asset in initialBatch {
                if let thumb = await photoLibraryManager.loadThumbnail(for: asset) {
                    initialThumbs[asset.localIdentifier] = thumb
                }
            }
            thumbnailsById = initialThumbs
            isLoading = false

            // Auto-select first asset if available
            if let first = monthAssets.first {
                selectedAssetId = first.localIdentifier
            }

            // Load remaining thumbnails in the background without blocking UI updates
            Task { [weak self] in
                guard let self else { return }
                for asset in monthAssets.dropFirst(self.initialThumbnailBatchSize) {
                    if let thumb = await self.photoLibraryManager.loadThumbnail(for: asset) {
                        self.thumbnailsById[asset.localIdentifier] = thumb
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func thumbnail(for asset: PHAsset) -> NSImage? {
        thumbnailsById[asset.localIdentifier]
    }

    func select(asset: PHAsset?) {
        selectedAssetId = asset?.localIdentifier
    }
}
