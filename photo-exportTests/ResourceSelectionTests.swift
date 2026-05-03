import AVFoundation
import Foundation
import Photos
import Testing

@testable import Photo_Export

struct ResourceSelectionTests {
  private func resources(_ types: [(PHAssetResourceType, String)]) -> [ResourceDescriptor] {
    types.map { ResourceDescriptor(type: $0.0, originalFilename: $0.1) }
  }

  private func descriptor(
    id: String = "asset-id",
    mediaType: PHAssetMediaType = .image,
    hasAdjustments: Bool = false
  ) -> AssetDescriptor {
    AssetDescriptor(
      id: id, creationDate: nil, mediaType: mediaType,
      pixelWidth: 0, pixelHeight: 0, duration: 0, hasAdjustments: hasAdjustments)
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

  // MARK: - Edited producer selection

  @Test func editedProducerPrefersFullSizePhotoForImages() {
    let r = resources([
      (.photo, "orig.HEIC"),
      (.fullSizePhoto, "edit.JPG"),
    ])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true))
    if case .resource(let resource) = producer {
      #expect(resource.type == .fullSizePhoto)
    } else {
      Issue.record("Expected .resource case, got \(producer)")
    }
  }

  @Test func editedProducerNeverFallsBackToPhoto() {
    let r = resources([(.photo, "orig.JPG")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true))
    #expect(producer == .none)
  }

  @Test func editedProducerNeverFallsBackToAlternatePhoto() {
    let r = resources([(.alternatePhoto, "alt.JPG")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true))
    #expect(producer == .none)
  }

  @Test func editedProducerPrefersFullSizeVideoForVideos() {
    let r = resources([
      (.video, "orig.mov"),
      (.fullSizeVideo, "edit.mov"),
    ])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video, descriptor: descriptor(mediaType: .video, hasAdjustments: true))
    if case .resource(let resource) = producer {
      #expect(resource.type == .fullSizeVideo)
    } else {
      Issue.record("Expected .resource case, got \(producer)")
    }
  }

  @Test func editedProducerRendersAdjustedVideoWithOnlyOriginalResource() {
    // The render path is the fix for issue #18. With no .fullSizeVideo and
    // hasAdjustments=true, we must produce a render request rather than nil.
    let r = resources([(.video, "IMG_1234.MOV")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video,
      descriptor: descriptor(mediaType: .video, hasAdjustments: true))
    if case .render(let request) = producer {
      #expect(request.assetId == "asset-id")
      #expect(request.originalFilename == "IMG_1234.MOV")
      #expect(request.fileType == AVFileType.mov)
      #expect(request.kind == .video)
    } else {
      Issue.record("Expected .render case, got \(producer)")
    }
  }

  @Test func editedProducerNoneForUnadjustedVideoWithOnlyOriginalResource() {
    // hasAdjustments=false means the user has nothing to render — the
    // edited variant should never have been enqueued by the caller, but if
    // we are asked we must answer .none.
    let r = resources([(.video, "IMG_1234.MOV")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video,
      descriptor: descriptor(mediaType: .video, hasAdjustments: false))
    #expect(producer == .none)
  }

  @Test func editedProducerNoneForVideoWithNoResources() {
    let r: [ResourceDescriptor] = []
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video,
      descriptor: descriptor(mediaType: .video, hasAdjustments: true))
    #expect(producer == .none)
  }

  // MARK: - originalFilename property

  @Test func producerOriginalFilenameMirrorsResource() {
    let resource = ResourceDescriptor(type: .fullSizePhoto, originalFilename: "edit.JPG")
    #expect(EditedProducer.resource(resource).originalFilename == "edit.JPG")
  }

  @Test func producerOriginalFilenameMirrorsRenderRequest() {
    let request = MediaRenderRequest(
      assetId: "id", originalFilename: "IMG_1234.MOV", fileType: .mov, kind: .video)
    #expect(EditedProducer.render(request).originalFilename == "IMG_1234.MOV")
  }

  @Test func producerOriginalFilenameNilForNone() {
    #expect(EditedProducer.none.originalFilename == nil)
  }
}
