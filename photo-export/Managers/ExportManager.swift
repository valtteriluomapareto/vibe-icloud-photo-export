import AppKit
import Foundation
import Photos
import SwiftUI
import os

@MainActor
final class ExportManager: ObservableObject {
    struct ExportJob: Equatable {
        let assetLocalIdentifier: String
        let year: Int
        let month: Int
    }

    // MARK: - Published State
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var queueCount: Int = 0
    @Published private(set) var isPaused: Bool = false

    // MARK: - Dependencies
    private let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Export")
    private let photoLibraryManager: PhotoLibraryManager
    private let exportDestinationManager: ExportDestinationManager
    private let exportRecordStore: ExportRecordStore

    // MARK: - Internals
    private var pendingJobs: [ExportJob] = []
    private var isProcessing: Bool = false
    private var currentTask: Task<Void, Never>? = nil

    init(
        photoLibraryManager: PhotoLibraryManager,
        exportDestinationManager: ExportDestinationManager, exportRecordStore: ExportRecordStore
    ) {
        self.photoLibraryManager = photoLibraryManager
        self.exportDestinationManager = exportDestinationManager
        self.exportRecordStore = exportRecordStore
    }

    // MARK: - Public API
    func startExportMonth(year: Int, month: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await enqueueMonth(year: year, month: month)
                processQueueIfNeeded()
            } catch {
                logger.error(
                    "Failed to enqueue month export: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    func startExportYear(year: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await enqueueYear(year: year)
                processQueueIfNeeded()
            } catch {
                logger.error(
                    "Failed to enqueue year export: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    func cancelAndClear() {
        logger.info("Cancelling current export and clearing queue due to destination change")
        pendingJobs.removeAll()
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        isRunning = false
        isPaused = false
        updateQueueCount()
    }

    func pause() {
        guard isRunning else { return }
        isPaused = true
        logger.info("Export queue paused")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        logger.info("Export queue resumed")
        processQueueIfNeeded()
    }

    func clearPending() {
        let removed = pendingJobs.count
        pendingJobs.removeAll()
        updateQueueCount()
        logger.info("Cleared \(removed) pending export jobs")
    }

    // MARK: - Queue Handling
    private func enqueueMonth(year: Int, month: Int) async throws {
        guard photoLibraryManager.isAuthorized else { return }
        let assets = try await photoLibraryManager.fetchAssets(year: year, month: month)
        let unexported = assets.filter { asset in
            !(exportRecordStore.isExported(assetId: asset.localIdentifier))
        }
        let newJobs = unexported.map {
            ExportJob(assetLocalIdentifier: $0.localIdentifier, year: year, month: month)
        }
        pendingJobs.append(contentsOf: newJobs)
        updateQueueCount()
        logger.info("Enqueued \(newJobs.count) assets for export for \(year)-\(month)")
    }

    private func enqueueYear(year: Int) async throws {
        guard photoLibraryManager.isAuthorized else { return }
        let assets = try await photoLibraryManager.fetchAssets(year: year, month: nil)
        let calendar = Calendar.current
        var newJobs: [ExportJob] = []
        newJobs.reserveCapacity(assets.count)
        for asset in assets {
            guard let created = asset.creationDate else { continue }
            let m = calendar.component(.month, from: created)
            if !exportRecordStore.isExported(assetId: asset.localIdentifier) {
                newJobs.append(
                    ExportJob(assetLocalIdentifier: asset.localIdentifier, year: year, month: m))
            }
        }
        pendingJobs.append(contentsOf: newJobs)
        updateQueueCount()
        logger.info("Enqueued \(newJobs.count) assets for export for year \(year)")
    }

    private func processQueueIfNeeded() {
        guard !isProcessing else { return }
        guard !isPaused else { return }
        guard !pendingJobs.isEmpty else { return }
        isProcessing = true
        isRunning = true
        processNext()
    }

    private func processNext() {
        if isPaused {
            isProcessing = false
            isRunning = false
            updateQueueCount()
            logger.info("Queue paused; not starting next job")
            return
        }
        guard !pendingJobs.isEmpty else {
            isProcessing = false
            isRunning = false
            updateQueueCount()
            logger.info("Export queue drained")
            return
        }
        let job = pendingJobs.removeFirst()
        updateQueueCount()
        currentTask = Task { [weak self] in
            await self?.export(job: job)
            await MainActor.run { [weak self] in
                self?.processNext()
            }
        }
    }

    private func updateQueueCount() {
        queueCount = pendingJobs.count + (isProcessing ? 1 : 0)
    }

    // MARK: - Export Logic
    private func export(job: ExportJob) async {
        do {
            // Resolve PHAsset from local identifier
            let fetchResult = PHAsset.fetchAssets(
                withLocalIdentifiers: [job.assetLocalIdentifier], options: nil)
            guard let asset = fetchResult.firstObject else {
                exportRecordStore.markFailed(
                    assetId: job.assetLocalIdentifier, error: "Asset not found", at: Date())
                logger.error(
                    "Asset not found for id: \(job.assetLocalIdentifier, privacy: .public)")
                return
            }

            // Determine destination directory
            let destDir = try exportDestinationManager.urlForMonth(
                year: job.year, month: job.month, createIfNeeded: true)
            let relPath = "\(job.year)/" + String(format: "%02d", job.month) + "/"

            // Select primary resource (prefer photo/video original)
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = selectPrimaryResource(from: resources) else {
                exportRecordStore.markFailed(
                    assetId: asset.localIdentifier, error: "No exportable resource", at: Date())
                logger.error(
                    "No exportable resource for id: \(asset.localIdentifier, privacy: .public)")
                return
            }

            // Prepare filename and target URLs
            let (baseName, ext) = splitFilename(resource.originalFilename)
            let finalURL = uniqueFileURL(in: destDir, baseName: baseName, ext: ext)
            let tempURL = finalURL.appendingPathExtension("tmp")

            exportRecordStore.markInProgress(
                assetId: asset.localIdentifier, year: job.year, month: job.month, relPath: relPath,
                filename: finalURL.lastPathComponent)

            // Ensure security-scoped access for destination during write and move
            let didStart = exportDestinationManager.beginScopedAccess()
            defer { if didStart { exportDestinationManager.endScopedAccess() } }
            guard didStart else {
                throw NSError(
                    domain: "Export", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to access export folder (security scope)"
                    ])
            }

            // Clean up any stale temp file at destination
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }

            try await writeResource(resource, to: tempURL)

            // Atomic move to final location (off main)
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try FileIOService.moveItemAtomically(from: tempURL, to: finalURL)
                        continuation.resume(returning: ())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Apply timestamps based on asset creation date (off main)
            if let createdAt = asset.creationDate {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        FileIOService.applyTimestamps(creationDate: createdAt, to: finalURL)
                        continuation.resume()
                    }
                }
            }

            exportRecordStore.markExported(
                assetId: asset.localIdentifier, year: job.year, month: job.month, relPath: relPath,
                filename: finalURL.lastPathComponent, exportedAt: Date())
            logger.info(
                "Exported \(finalURL.lastPathComponent, privacy: .public) -> \(finalURL.deletingLastPathComponent().path, privacy: .public)"
            )
        } catch {
            // Attempt cleanup of temp file if exists
            logger.error("Export failed: \(String(describing: error), privacy: .public)")
            exportRecordStore.markFailed(
                assetId: job.assetLocalIdentifier, error: error.localizedDescription, at: Date())
        }
    }

    // MARK: - Helpers
    private func selectPrimaryResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        if let photo = resources.first(where: { $0.type == .photo }) { return photo }
        if let video = resources.first(where: { $0.type == .video }) { return video }
        if let alternatePhoto = resources.first(where: { $0.type == .alternatePhoto }) {
            return alternatePhoto
        }
        if let fullSize = resources.first(where: { $0.type == .fullSizePhoto }) { return fullSize }
        return resources.first
    }

    private func splitFilename(_ filename: String) -> (base: String, ext: String) {
        let url = URL(fileURLWithPath: filename)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return (base, ext)
    }

    func uniqueFileURL(in directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var index = 1
        while fm.fileExists(atPath: candidate.path) {
            let nextName = "\(baseName) (\(index))"
            candidate = directory.appendingPathComponent(nextName).appendingPathExtension(ext)
            index += 1
            if index > 10_000 { break }
        }
        return candidate
    }

    private func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            // Write directly to the provided URL
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
