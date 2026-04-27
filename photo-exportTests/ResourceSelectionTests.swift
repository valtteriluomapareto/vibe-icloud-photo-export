import Foundation
import Photos
import Testing

@testable import Photo_Export

struct ResourceSelectionTests {
  private func resources(_ types: [(PHAssetResourceType, String)]) -> [ResourceDescriptor] {
    types.map { ResourceDescriptor(type: $0.0, originalFilename: $0.1) }
  }

  // MARK: - Original selection

  @Test func originalPrefersPhotoOverFullSizePhoto() {
    let r = resources([
      (.fullSizePhoto, "edit.JPG"),
      (.photo, "orig.HEIC"),
    ])
    #expect(
      ResourceSelection.selectOriginalResource(from: r, mediaType: .image)?.type == .photo)
  }

  @Test func originalFallsBackToAlternatePhoto() {
    let r = resources([
      (.alternatePhoto, "alt.JPG"),
      (.fullSizePhoto, "edit.JPG"),
    ])
    #expect(
      ResourceSelection.selectOriginalResource(from: r, mediaType: .image)?.type
        == .alternatePhoto)
  }

  @Test func originalVideoPrefersVideoResource() {
    let r = resources([
      (.fullSizeVideo, "edit.mov"),
      (.video, "orig.mov"),
    ])
    #expect(
      ResourceSelection.selectOriginalResource(from: r, mediaType: .video)?.type == .video)
  }

  @Test func originalReturnsLastResortWhenNoOriginalSideResource() {
    // Matches the existing "use whatever's there" fallback so current broken assets still get a
    // best-effort export.
    let r = resources([(.fullSizePhoto, "edit.JPG")])
    #expect(
      ResourceSelection.selectOriginalResource(from: r, mediaType: .image)?.type
        == .fullSizePhoto)
  }

  // MARK: - Edited selection

  @Test func editedPrefersFullSizePhotoForImages() {
    let r = resources([
      (.photo, "orig.HEIC"),
      (.fullSizePhoto, "edit.JPG"),
    ])
    #expect(
      ResourceSelection.selectEditedResource(from: r, mediaType: .image)?.type
        == .fullSizePhoto)
  }

  @Test func editedNeverFallsBackToPhoto() {
    let r = resources([(.photo, "orig.JPG")])
    #expect(ResourceSelection.selectEditedResource(from: r, mediaType: .image) == nil)
  }

  @Test func editedNeverFallsBackToAlternatePhoto() {
    let r = resources([(.alternatePhoto, "alt.JPG")])
    #expect(ResourceSelection.selectEditedResource(from: r, mediaType: .image) == nil)
  }

  @Test func editedVideoPrefersFullSizeVideo() {
    let r = resources([
      (.video, "orig.mov"),
      (.fullSizeVideo, "edit.mov"),
    ])
    #expect(
      ResourceSelection.selectEditedResource(from: r, mediaType: .video)?.type
        == .fullSizeVideo)
  }

  @Test func editedVideoDoesNotFallBackToVideoResource() {
    let r = resources([(.video, "orig.mov")])
    #expect(ResourceSelection.selectEditedResource(from: r, mediaType: .video) == nil)
  }
}
