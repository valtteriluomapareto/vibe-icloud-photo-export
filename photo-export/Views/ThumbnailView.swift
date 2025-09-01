import AppKit
import Photos
import SwiftUI

struct ThumbnailView: View {
  let asset: PHAsset
  let thumbnail: NSImage?
  let isSelected: Bool
  let isExported: Bool

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
