import Photos
import Testing

struct AuthorizationMappingTests {

  /// Pure function that mirrors the authorization mapping logic in PhotoLibraryManager
  private func isAuthorized(for status: PHAuthorizationStatus) -> Bool {
    status == .authorized || status == .limited
  }

  @Test func authorizedMapsToTrue() {
    #expect(isAuthorized(for: .authorized))
  }

  @Test func limitedMapsToTrue() {
    #expect(isAuthorized(for: .limited))
  }

  @Test func deniedMapsToFalse() {
    #expect(!isAuthorized(for: .denied))
  }

  @Test func restrictedMapsToFalse() {
    #expect(!isAuthorized(for: .restricted))
  }

  @Test func notDeterminedMapsToFalse() {
    #expect(!isAuthorized(for: .notDetermined))
  }
}
