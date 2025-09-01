import AppKit
import Photos
import SwiftUI

struct AssetDetailView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @Environment(\.exportRecordStore) private var exportRecordStore

  let asset: PHAsset?

  @State private var fullImage: NSImage?
  @State private var isLoading: Bool = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 12) {
      if let asset {
        ZStack {
          if let fullImage {
            Image(nsImage: fullImage)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if isLoading {
            Rectangle()
              .fill(Color.gray.opacity(0.15))
              .overlay(ProgressView())
          } else if let errorMessage {
            Rectangle()
              .fill(Color.gray.opacity(0.15))
              .overlay(Text(errorMessage).foregroundColor(.red))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        metadataView(for: asset)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .padding(.bottom)
      } else {
        VStack {
          Spacer()
          Text("Select an image")
            .foregroundColor(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: asset?.localIdentifier) {
      await loadFullImage()
    }
  }

  private func loadFullImage() async {
    guard let asset else {
      fullImage = nil
      isLoading = false
      errorMessage = nil
      return
    }
    isLoading = true
    errorMessage = nil
    fullImage = nil
    do {
      let image = try await photoLibraryManager.requestFullImage(for: asset)
      await MainActor.run {
        fullImage = image
        isLoading = false
      }
    } catch {
      await MainActor.run {
        isLoading = false
        errorMessage = "Failed to load image: \(error.localizedDescription)"
      }
    }
  }

  private func metadataView(for asset: PHAsset) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let date = asset.creationDate {
        Text(dateFormatter.string(from: date))
      }
      Text(mediaTypeString(from: asset.mediaType))
      Text("Size: \(asset.pixelWidth) × \(asset.pixelHeight)")
      if asset.mediaType == .video {
        let durationString = String(format: "%.0fs", asset.duration)
        Text("Duration: \(durationString)")
      }
      let id = asset.localIdentifier
      if let export = exportRecordStore?.exportInfo(assetId: id) {
        switch export.status {
        case .done:
          if let when = export.exportDate {
            Text("Exported: \(dateTimeFormatter.string(from: when))")
          } else {
            Text("Exported")
          }
        case .inProgress:
          Text("Export: In progress")
        case .failed:
          Text("Export failed: \(export.lastError ?? "Unknown error")")
        case .pending:
          Text("Export: Pending")
        }
      }
    }
    .font(.footnote)
  }

  private func mediaTypeString(from type: PHAssetMediaType) -> String {
    switch type {
    case .image: return "Photo"
    case .video: return "Video"
    case .audio: return "Audio"
    case .unknown: return "Unknown"
    @unknown default: return "Unknown"
    }
  }

  private var dateFormatter: DateFormatter {
    let f = DateFormatter()
    f.dateStyle = .medium
    return f
  }

  private var dateTimeFormatter: DateFormatter {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }
}
