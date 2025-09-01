import AppKit
import Photos
import SwiftUI

/// Manages access to the Photos library, including authorization and asset fetching
final class PhotoLibraryManager: ObservableObject {
    /// Published properties to track authorization status
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isAuthorized: Bool = false

    /// Errors that can occur in the Photo Library Manager
    enum PhotoLibraryError: Error {
        case authorizationDenied
        case fetchFailed
        case assetUnavailable
    }

    /// Shared caching image manager for thumbnails
    private static let cachingImageManager = PHCachingImageManager()

    init() {
        // Check if Info.plist contains photos usage description
        verifyPhotoLibraryPermissions()

        // Initialize with current authorization status
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        isAuthorized = authorizationStatus == .authorized
    }

    /// Verify that Photos usage description is properly set in Info.plist
    private func verifyPhotoLibraryPermissions() {
        let bundleDict = Bundle.main.infoDictionary
        if bundleDict?["NSPhotoLibraryUsageDescription"] == nil {
            print("WARNING: NSPhotoLibraryUsageDescription not found in Info.plist")
            print("Available keys: \(bundleDict?.keys.joined(separator: ", ") ?? "none")")
        } else {
            print("Found NSPhotoLibraryUsageDescription in Info.plist")
        }
    }

    /// Request authorization to access the Photos library
    func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)

        await MainActor.run {
            self.authorizationStatus = status
            self.isAuthorized = status == .authorized
        }

        return status == .authorized
    }

    /// Fetch all assets grouped by year and month
    func fetchAssetsByYearAndMonth() async throws -> [Int: [Int: [PHAsset]]] {
        guard isAuthorized else {
            throw PhotoLibraryError.authorizationDenied
        }

        // Create fetch options
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        // Fetch all photo and video assets
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)

        // Group assets by year and month
        var assetsByYearAndMonth: [Int: [Int: [PHAsset]]] = [:]

        // Process in batches to avoid loading everything into memory at once
        let totalAssets = fetchResult.count
        let batchSize = 500

        for index in 0..<totalAssets {
            autoreleasepool {
                guard let creationDate = fetchResult.object(at: index).creationDate else {
                    return
                }

                let calendar = Calendar.current
                let year = calendar.component(.year, from: creationDate)
                let month = calendar.component(.month, from: creationDate)

                if assetsByYearAndMonth[year] == nil {
                    assetsByYearAndMonth[year] = [:]
                }

                if assetsByYearAndMonth[year]?[month] == nil {
                    assetsByYearAndMonth[year]?[month] = []
                }

                assetsByYearAndMonth[year]?[month]?.append(fetchResult.object(at: index))
            }

            // Yield to main thread periodically
            if index % batchSize == 0 && index > 0 {
                try await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            }
        }

        return assetsByYearAndMonth
    }

    /// Fetch assets for a specific year and month
    func fetchAssets(year: Int, month: Int? = nil, mediaType: PHAssetMediaType? = nil) async throws
        -> [PHAsset]
    {
        guard isAuthorized else {
            throw PhotoLibraryError.authorizationDenied
        }

        // Create date predicates for filtering
        let calendar = Calendar.current
        var startDateComponents = DateComponents()
        startDateComponents.year = year
        startDateComponents.month = month ?? 1
        startDateComponents.day = 1

        var endDateComponents = DateComponents()
        endDateComponents.year = month == nil ? year + 1 : year
        endDateComponents.month = month == nil ? 1 : (month! + 1)
        endDateComponents.day = 1

        guard let startDate = calendar.date(from: startDateComponents),
            let endDate = calendar.date(from: endDateComponents)
        else {
            throw PhotoLibraryError.fetchFailed
        }

        // Create fetch options
        let fetchOptions = PHFetchOptions()

        // Create date predicate
        fetchOptions.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
            endDate as NSDate)

        // Add media type filter if specified
        if let mediaType = mediaType {
            let mediaTypePredicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)

            if let existingPredicate = fetchOptions.predicate {
                fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    existingPredicate, mediaTypePredicate,
                ])
            } else {
                fetchOptions.predicate = mediaTypePredicate
            }
        }

        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        // Fetch assets
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        var assets: [PHAsset] = []

        // Process in batches to avoid loading everything into memory at once
        let totalAssets = fetchResult.count
        let batchSize = 500

        for index in 0..<totalAssets {
            autoreleasepool {
                assets.append(fetchResult.object(at: index))
            }

            // Yield to main thread periodically
            if index % batchSize == 0 && index > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            }
        }

        return assets
    }

    /// Fast count of assets in a given year/month without loading them into memory
    func countAssets(year: Int, month: Int) throws -> Int {
        guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
        let calendar = Calendar.current
        var start = DateComponents()
        start.year = year
        start.month = month
        start.day = 1
        var end = DateComponents()
        end.year = year
        end.month = month + 1
        end.day = 1
        guard let startDate = calendar.date(from: start), let endDate = calendar.date(from: end)
        else {
            throw PhotoLibraryError.fetchFailed
        }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
            endDate as NSDate)
        let result = PHAsset.fetchAssets(with: opts)
        return result.count
    }

    /// Fast count of assets in a given year
    func countAssets(year: Int) throws -> Int {
        guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }
        let calendar = Calendar.current
        var start = DateComponents()
        start.year = year
        start.month = 1
        start.day = 1
        var end = DateComponents()
        end.year = year + 1
        end.month = 1
        end.day = 1
        guard let startDate = calendar.date(from: start), let endDate = calendar.date(from: end)
        else {
            throw PhotoLibraryError.fetchFailed
        }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@", startDate as NSDate,
            endDate as NSDate)
        let result = PHAsset.fetchAssets(with: opts)
        return result.count
    }

    /// Returns descending list of years that have at least one asset
    func availableYears() throws -> [Int] {
        guard isAuthorized else { throw PhotoLibraryError.authorizationDenied }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: opts)
        let count = result.count
        guard count > 0 else { return [] }

        guard let firstDate = result.object(at: 0).creationDate,
            let lastDate = result.object(at: count - 1).creationDate
        else {
            return []
        }

        let calendar = Calendar.current
        let startYear = calendar.component(.year, from: firstDate)
        let endYear = calendar.component(.year, from: lastDate)
        guard startYear <= endYear else { return [] }

        // Build descending list
        return Array(stride(from: endYear, through: startYear, by: -1))
            .filter { (try? self.countAssets(year: $0)) ?? 0 > 0 }
    }

    /// Extract asset metadata into a structured format
    func extractAssetMetadata(from asset: PHAsset) -> AssetMetadata {
        return AssetMetadata(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            mediaType: asset.mediaType,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite
        )
    }

    /// Start caching thumbnails for assets
    func startCachingThumbnails(
        for assets: [PHAsset], size: CGSize = CGSize(width: 200, height: 200),
        contentMode: PHImageContentMode = .aspectFill
    ) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        PhotoLibraryManager.cachingImageManager.startCachingImages(
            for: assets, targetSize: size, contentMode: contentMode, options: options)
    }

    /// Stop caching thumbnails for assets
    func stopCachingThumbnails(
        for assets: [PHAsset], size: CGSize = CGSize(width: 200, height: 200),
        contentMode: PHImageContentMode = .aspectFill
    ) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        PhotoLibraryManager.cachingImageManager.stopCachingImages(
            for: assets, targetSize: size, contentMode: contentMode, options: options)
    }

    /// Load thumbnail for an asset
    @MainActor
    func loadThumbnail(
        for asset: PHAsset, size: CGSize = CGSize(width: 200, height: 200),
        contentMode: PHImageContentMode = .aspectFill,
        allowNetwork: Bool = true
    ) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = allowNetwork
            options.resizeMode = .fast

            // Add a flag to track whether we've already resumed
            var hasResumed = false

            PhotoLibraryManager.cachingImageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: contentMode,
                options: options
            ) { image, _ in
                // Only resume once
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Request a full-size image for an asset
    func requestFullImage(for asset: PHAsset) async throws -> NSImage {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image = image else {
                    continuation.resume(throwing: PhotoLibraryError.assetUnavailable)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }
}
