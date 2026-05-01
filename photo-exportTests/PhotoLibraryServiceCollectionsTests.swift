import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Tests Phase 2's collection-discovery additions to the `PhotoLibraryService` fake. The
/// production `PhotoLibraryManager` exercises the same surface against the real Photos
/// framework; we cover that through manual testing on a populated library since unit tests
/// can't reliably create `PHAssetCollection` fixtures.
@MainActor
struct PhotoLibraryServiceCollectionsTests {

  // MARK: - Fixtures

  private func makeAsset(id: String, mediaType: PHAssetMediaType = .image, adjusted: Bool = false)
    -> AssetDescriptor
  {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: mediaType,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: adjusted
    )
  }

  // MARK: - fetchAssets(in:)

  @Test func fetchAssetsByTimelineScopeUsesYearMonth() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-2"] = [makeAsset(id: "a"), makeAsset(id: "b")]
    let assets = try await svc.fetchAssets(in: .timeline(year: 2025, month: 2), mediaType: nil)
    #expect(assets.map(\.id) == ["a", "b"])
  }

  @Test func fetchAssetsByFavoritesScopeReturnsFavorites() async throws {
    let svc = FakePhotoLibraryService()
    svc.favoritesAssets = [makeAsset(id: "fav-1"), makeAsset(id: "fav-2")]
    svc.assetsByYearMonth["2025-1"] = [makeAsset(id: "tl-1")]
    let assets = try await svc.fetchAssets(in: .favorites, mediaType: nil)
    #expect(assets.map(\.id) == ["fav-1", "fav-2"])
  }

  @Test func fetchAssetsByAlbumScopeReturnsAlbumAssets() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByAlbumLocalId["album-A"] = [makeAsset(id: "alb-1"), makeAsset(id: "alb-2")]
    svc.assetsByAlbumLocalId["album-B"] = [makeAsset(id: "alb-3")]
    let a = try await svc.fetchAssets(in: .album(collectionId: "album-A"), mediaType: nil)
    let b = try await svc.fetchAssets(in: .album(collectionId: "album-B"), mediaType: nil)
    #expect(a.map(\.id) == ["alb-1", "alb-2"])
    #expect(b.map(\.id) == ["alb-3"])
  }

  @Test func fetchAssetsScopeFiltersByMediaType() async throws {
    let svc = FakePhotoLibraryService()
    svc.favoritesAssets = [
      makeAsset(id: "img", mediaType: .image),
      makeAsset(id: "vid", mediaType: .video),
    ]
    let images = try await svc.fetchAssets(in: .favorites, mediaType: .image)
    let videos = try await svc.fetchAssets(in: .favorites, mediaType: .video)
    #expect(images.map(\.id) == ["img"])
    #expect(videos.map(\.id) == ["vid"])
  }

  // MARK: - countAssets(in:)

  @Test func countAssetsByTimelineScope() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-2"] = [makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")]
    let count = try await svc.countAssets(in: .timeline(year: 2025, month: 2))
    #expect(count == 3)
  }

  @Test func countAssetsByYearAcrossMonths() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth["2025-2"] = [makeAsset(id: "a"), makeAsset(id: "b")]
    svc.assetsByYearMonth["2025-7"] = [makeAsset(id: "c")]
    let count = try await svc.countAssets(in: .timeline(year: 2025, month: nil))
    #expect(count == 3)
  }

  @Test func countAssetsByFavoritesScope() async throws {
    let svc = FakePhotoLibraryService()
    svc.favoritesAssets = (0..<5).map { makeAsset(id: "fav-\($0)") }
    let count = try await svc.countAssets(in: .favorites)
    #expect(count == 5)
  }

  @Test func countAssetsByAlbumScope() async throws {
    let svc = FakePhotoLibraryService()
    svc.assetsByAlbumLocalId["album-X"] = [makeAsset(id: "x1"), makeAsset(id: "x2")]
    let count = try await svc.countAssets(in: .album(collectionId: "album-X"))
    #expect(count == 2)
    let missing = try await svc.countAssets(in: .album(collectionId: "missing"))
    #expect(missing == 0)
  }

  // MARK: - countAdjustedAssets(in:)

  @Test func countAdjustedAssetsByScope() async throws {
    let svc = FakePhotoLibraryService()
    svc.favoritesAssets = [
      makeAsset(id: "f1", adjusted: false),
      makeAsset(id: "f2", adjusted: true),
      makeAsset(id: "f3", adjusted: true),
    ]
    let count = try await svc.countAdjustedAssets(in: .favorites)
    #expect(count == 2)
  }

  // MARK: - fetchCollectionTree

  @Test func fetchCollectionTreeReturnsCannedTree() throws {
    let svc = FakePhotoLibraryService()
    let tree: [PhotoCollectionDescriptor] = [
      PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites", kind: .favorites,
        pathComponents: [], estimatedAssetCount: 12, children: []),
      PhotoCollectionDescriptor(
        id: "folder:family", localIdentifier: "family-id", title: "Family", kind: .folder,
        pathComponents: [], estimatedAssetCount: nil,
        children: [
          PhotoCollectionDescriptor(
            id: "album:trip", localIdentifier: "trip-id", title: "Trip 2024", kind: .album,
            pathComponents: ["Family"], estimatedAssetCount: 50, children: [])
        ]),
    ]
    svc.collectionTree = tree
    let result = try svc.fetchCollectionTree()
    #expect(result.count == 2)
    #expect(result[0].kind == .favorites)
    #expect(result[1].kind == .folder)
    #expect(result[1].children.count == 1)
    #expect(result[1].children[0].kind == .album)
    #expect(result[1].children[0].pathComponents == ["Family"])
  }
}
