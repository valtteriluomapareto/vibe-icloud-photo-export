import AppKit
import Foundation
import Photos
import SwiftUI

@MainActor
final class MonthViewModel: ObservableObject {
  @Published private(set) var assets: [AssetDescriptor] = []
  @Published private(set) var thumbnailsById: [String: NSImage] = [:]
  @Published private(set) var failedThumbnailIds: Set<String> = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?

  // Selection is tracked via id to avoid retaining assets strongly across updates
  @Published var selectedAssetId: String?
  @Published private(set) var isExportRunning: Bool = false

  private let photoLibraryService: any PhotoLibraryService

  // Control initial thumbnail batch size
  private let initialThumbnailBatchSize: Int = 40

  // Track cached assets to manage PHCachingImageManager preheating
  private var cachedAssets: [AssetDescriptor] = []

  // Track which thumbnails have been upgraded to high quality
  private var highQualityIds: Set<String> = []

  // Task for background HQ upgrades so we can cancel on month change
  private var hqUpgradeTask: Task<Void, Never>?

  init(photoLibraryService: any PhotoLibraryService) {
    self.photoLibraryService = photoLibraryService
  }

  func loadAssets(forYear year: Int, month: Int) async {
    isLoading = true
    errorMessage = nil
    // Cancel any in-flight HQ upgrade work
    hqUpgradeTask?.cancel()
    hqUpgradeTask = nil
    // Stop caching for previous month
    if !cachedAssets.isEmpty {
      photoLibraryService.stopCachingThumbnails(for: cachedAssets)
      cachedAssets = []
    }
    assets = []
    thumbnailsById = [:]
    failedThumbnailIds = []
    highQualityIds = []
    selectedAssetId = nil

    do {
      let monthAssets = try await photoLibraryService.fetchAssets(year: year, month: month)
      assets = monthAssets
      // Start caching for new month
      photoLibraryService.startCachingThumbnails(for: monthAssets)
      cachedAssets = monthAssets

      // Preload an initial batch of fast thumbnails
      let initialBatch = Array(monthAssets.prefix(initialThumbnailBatchSize))
      var initialThumbs: [String: NSImage] = [:]

      for asset in initialBatch {
        if let thumb = await photoLibraryService.loadThumbnail(
          for: asset.id, allowNetwork: false)
        {
          initialThumbs[asset.id] = thumb
        } else {
          failedThumbnailIds.insert(asset.id)
        }
      }
      thumbnailsById = initialThumbs
      isLoading = false

      // Auto-select first asset if available
      if let first = monthAssets.first {
        selectedAssetId = first.id
      }

      // Load remaining fast thumbnails in background, then upgrade all to HQ
      hqUpgradeTask = Task { [weak self] in
        guard let self else { return }
        // First: load fast thumbnails for remaining assets
        for asset in monthAssets.dropFirst(self.initialThumbnailBatchSize) {
          guard !Task.isCancelled else { return }
          await self.loadAndStoreThumbnail(for: asset.id)
        }
        // Then: upgrade all to high quality
        for asset in monthAssets {
          guard !Task.isCancelled else { return }
          await self.upgradeThumbnailToHighQuality(for: asset.id)
        }
      }
    } catch {
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }

  func thumbnail(for asset: AssetDescriptor) -> NSImage? {
    thumbnailsById[asset.id]
  }

  func thumbnailState(for asset: AssetDescriptor) -> ThumbnailState {
    let id = asset.id
    if let image = thumbnailsById[id] {
      return .loaded(image)
    } else if failedThumbnailIds.contains(id) {
      return .failed
    } else {
      return .loading
    }
  }

  func retryThumbnail(for assetId: String) {
    failedThumbnailIds.remove(assetId)
    Task { [weak self] in
      guard let self else { return }
      await self.loadAndStoreThumbnail(for: assetId)
      if self.thumbnailsById[assetId] != nil {
        await self.upgradeThumbnailToHighQuality(for: assetId)
      }
    }
  }

  func select(assetId: String?) {
    selectedAssetId = assetId
  }

  func setExportRunning(_ running: Bool) {
    isExportRunning = running
  }

  private func loadAndStoreThumbnail(for assetId: String) async {
    if let thumb = await photoLibraryService.loadThumbnail(
      for: assetId, allowNetwork: false)
    {
      thumbnailsById[assetId] = thumb
    } else {
      failedThumbnailIds.insert(assetId)
    }
  }

  private func upgradeThumbnailToHighQuality(for assetId: String) async {
    guard !highQualityIds.contains(assetId) else { return }
    guard !failedThumbnailIds.contains(assetId) else { return }
    if let hqThumb = await photoLibraryService.loadThumbnailHighQuality(
      for: assetId, allowNetwork: !isExportRunning)
    {
      thumbnailsById[assetId] = hqThumb
      highQualityIds.insert(assetId)
    }
  }
}
