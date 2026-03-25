import AppKit
import Photos
import SwiftUI

enum ThumbnailState {
  case loading
  case loaded(NSImage)
  case failed
}

struct ThumbnailView: View {
  let asset: PHAsset
  let state: ThumbnailState
  let isSelected: Bool
  let isExported: Bool
  var onRetry: (() -> Void)?

  var body: some View {
    ZStack {
      switch state {
      case .loaded(let image):
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 100, height: 100)
          .clipped()
      case .loading:
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 100, height: 100)
          .overlay(ProgressView())
      case .failed:
        Rectangle()
          .fill(Color.gray.opacity(0.2))
          .frame(width: 100, height: 100)
          .overlay(
            VStack(spacing: 4) {
              Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.secondary)
              if let onRetry {
                Button("Retry") { onRetry() }
                  .font(.caption2)
                  .buttonStyle(.borderless)
              } else {
                Text("Failed")
                  .font(.caption2)
                  .foregroundColor(.secondary)
              }
            }
          )
      }

      if !isExported {
        VStack {
          HStack {
            Circle()
              .fill(Color.accentColor.opacity(0.95))
              .frame(width: 8, height: 8)
            Spacer()
          }
          Spacer()
        }
        .padding(6)
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
