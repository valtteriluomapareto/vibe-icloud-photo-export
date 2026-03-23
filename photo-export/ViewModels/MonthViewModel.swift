import AppKit
import Foundation
import Photos
import SwiftUI

@MainActor
final class MonthViewModel: ObservableObject {
  @Published private(set) var assets: [PHAsset] = []
  @Published private(set) var thumbnailsById: [String: NSImage] = [:]
  @Published private(set) var failedThumbnailIds: Set<String> = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?

  // Selection is tracked via id to avoid retaining PHAsset strongly across updates
  @Published var selectedAssetId: String?
  @Published private(set) var isExportRunning: Bool = false

  private let photoLibraryManager: PhotoLibraryManager

  // Control initial thumbnail batch size
  private let initialThumbnailBatchSize: Int = 40

  // Track cached assets to manage PHCachingImageManager preheating
  private var cachedAssets: [PHAsset] = []

  // Track which thumbnails have been upgraded to high quality
  private var highQualityIds: Set<String> = []

  // Task for background HQ upgrades so we can cancel on month change
  private var hqUpgradeTask: Task<Void, Never>?

  init(photoLibraryManager: PhotoLibraryManager) {
    self.photoLibraryManager = photoLibraryManager
  }

  func loadAssets(forYear year: Int, month: Int) async {
    isLoading = true
    errorMessage = nil
    // Cancel any in-flight HQ upgrade work
    hqUpgradeTask?.cancel()
    hqUpgradeTask = nil
    // Stop caching for previous month
    if !cachedAssets.isEmpty {
      photoLibraryManager.stopCachingThumbnails(for: cachedAssets)
      cachedAssets = []
    }
    assets = []
    thumbnailsById = [:]
    failedThumbnailIds = []
    highQualityIds = []
    selectedAssetId = nil

    do {
      let monthAssets = try await photoLibraryManager.fetchAssets(year: year, month: month)
      assets = monthAssets
      // Start caching for new month
      photoLibraryManager.startCachingThumbnails(for: monthAssets)
      cachedAssets = monthAssets

      // Preload an initial batch of fast thumbnails
      let initialBatch = Array(monthAssets.prefix(initialThumbnailBatchSize))
      var initialThumbs: [String: NSImage] = [:]

      for asset in initialBatch {
        if let thumb = await photoLibraryManager.loadThumbnail(
          for: asset, allowNetwork: false)
        {
          initialThumbs[asset.localIdentifier] = thumb
        } else {
          failedThumbnailIds.insert(asset.localIdentifier)
        }
      }
      thumbnailsById = initialThumbs
      isLoading = false

      // Auto-select first asset if available
      if let first = monthAssets.first {
        selectedAssetId = first.localIdentifier
      }

      // Load remaining fast thumbnails in background, then upgrade all to HQ
      hqUpgradeTask = Task { [weak self] in
        guard let self else { return }
        // First: load fast thumbnails for remaining assets
        for asset in monthAssets.dropFirst(self.initialThumbnailBatchSize) {
          guard !Task.isCancelled else { return }
          await self.loadAndStoreThumbnail(for: asset)
        }
        // Then: upgrade all to high quality
        for asset in monthAssets {
          guard !Task.isCancelled else { return }
          await self.upgradeThumbnailToHighQuality(for: asset)
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

  func thumbnailState(for asset: PHAsset) -> ThumbnailState {
    let id = asset.localIdentifier
    if let image = thumbnailsById[id] {
      return .loaded(image)
    } else if failedThumbnailIds.contains(id) {
      return .failed
    } else {
      return .loading
    }
  }

  func retryThumbnail(for asset: PHAsset) {
    let id = asset.localIdentifier
    failedThumbnailIds.remove(id)
    Task { [weak self] in
      guard let self else { return }
      await self.loadAndStoreThumbnail(for: asset)
      if self.thumbnailsById[id] != nil {
        await self.upgradeThumbnailToHighQuality(for: asset)
      }
    }
  }

  func select(asset: PHAsset?) {
    selectedAssetId = asset?.localIdentifier
  }

  func setExportRunning(_ running: Bool) {
    isExportRunning = running
  }

  private func loadAndStoreThumbnail(for asset: PHAsset) async {
    if let thumb = await photoLibraryManager.loadThumbnail(
      for: asset, allowNetwork: false)
    {
      thumbnailsById[asset.localIdentifier] = thumb
    } else {
      failedThumbnailIds.insert(asset.localIdentifier)
    }
  }

  private func upgradeThumbnailToHighQuality(for asset: PHAsset) async {
    let id = asset.localIdentifier
    guard !highQualityIds.contains(id) else { return }
    guard !failedThumbnailIds.contains(id) else { return }
    if let hqThumb = await photoLibraryManager.loadThumbnailHighQuality(
      for: asset, allowNetwork: !isExportRunning)
    {
      thumbnailsById[id] = hqThumb
      highQualityIds.insert(id)
    }
  }
}
