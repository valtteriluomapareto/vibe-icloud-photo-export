import AppKit
import Photos
import SwiftUI

struct MonthView: View {
    @EnvironmentObject var photoLibraryManager: PhotoLibraryManager
    @State private var assets: [PHAsset] = []
    @State private var selectedAsset: PHAsset?
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var selectedFullImage: NSImage?
    @State private var isLoading = false
    @State private var errorMessage: String?

    let year: Int
    let month: Int

    var body: some View {
        VStack(spacing: 0) {
            // Main image display area
            ZStack {
                if let selectedAsset = selectedAsset {
                    if let fullImage = selectedFullImage {
                        Image(nsImage: fullImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(ProgressView())
                    }

                    VStack {
                        Spacer()
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                if let date = selectedAsset.creationDate {
                                    Text(dateFormatter.string(from: date))
                                        .font(.caption)
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .background(Color.black.opacity(0.6))
                                        .cornerRadius(4)
                                }

                                Text(AssetMetadata.mediaTypeString(from: selectedAsset.mediaType))
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(6)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(4)
                            }
                            Spacer()
                        }
                        .padding()
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .overlay(
                            Text("No image selected")
                                .foregroundColor(.gray)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Thumbnail strip
            VStack {
                Divider()

                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 8) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            ThumbnailView(
                                asset: asset,
                                thumbnail: thumbnails[asset.localIdentifier],
                                isSelected: asset.localIdentifier == selectedAsset?.localIdentifier
                            )
                            .frame(width: 100, height: 100)
                            .onTapGesture {
                                selectAsset(asset)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .frame(height: 120)
                .background(Color(.windowBackgroundColor))
            }
        }
        .onAppear {
            loadAssetsForMonth()
        }
        .overlay(
            Group {
                if isLoading && assets.isEmpty {
                    ProgressView("Loading assets...")
                        .padding()
                        .background(Color(.windowBackgroundColor).opacity(0.8))
                        .cornerRadius(8)
                }

                if let errorMessage = errorMessage {
                    Text("Error: \(errorMessage)")
                        .foregroundColor(.red)
                        .padding()
                        .background(Color(.windowBackgroundColor).opacity(0.8))
                        .cornerRadius(8)
                }
            }
        )
    }

    private func loadAssetsForMonth() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Fetch assets for the specified month
                let monthAssets = try await photoLibraryManager.fetchAssets(
                    year: year, month: month)

                // Initial load of thumbnails for visible assets
                let initialBatch = Array(monthAssets.prefix(20))
                var thumbnailDict: [String: NSImage] = [:]

                for asset in initialBatch {
                    if let thumbnail = await photoLibraryManager.loadThumbnail(for: asset) {
                        thumbnailDict[asset.localIdentifier] = thumbnail
                    }
                }

                DispatchQueue.main.async {
                    self.assets = monthAssets
                    self.thumbnails = thumbnailDict
                    self.isLoading = false

                    // Select the first asset if available
                    if let firstAsset = monthAssets.first {
                        self.selectAsset(firstAsset)
                    }
                }

                // Load remaining thumbnails in the background
                for asset in monthAssets.dropFirst(20) {
                    if let thumbnail = await photoLibraryManager.loadThumbnail(for: asset) {
                        DispatchQueue.main.async {
                            self.thumbnails[asset.localIdentifier] = thumbnail
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func selectAsset(_ asset: PHAsset) {
        selectedAsset = asset
        selectedFullImage = nil

        Task {
            do {
                let image = try await photoLibraryManager.requestFullImage(for: asset)
                DispatchQueue.main.async {
                    self.selectedFullImage = image
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load full image: \(error.localizedDescription)"
                }
            }
        }
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

struct ThumbnailView: View {
    let asset: PHAsset
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        ZStack {
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 100)
                    .overlay(ProgressView())
            }

            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.blue, lineWidth: 3)
                    .frame(width: 100, height: 100)
            }

            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "video.fill")
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)

                        Spacer()
                    }
                    .padding(4)
                }
            }
        }
        .cornerRadius(4)
    }
}
