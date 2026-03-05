import Photos
import Testing
@testable import photo_export

struct AuthorizationMappingTests {

  @Test func authorizedMapsToTrue() {
    #expect(PhotoLibraryManager.isAuthorizationSufficient(.authorized))
  }

  @Test func limitedMapsToTrue() {
    #expect(PhotoLibraryManager.isAuthorizationSufficient(.limited))
  }

  @Test func deniedMapsToFalse() {
    #expect(!PhotoLibraryManager.isAuthorizationSufficient(.denied))
  }

  @Test func restrictedMapsToFalse() {
    #expect(!PhotoLibraryManager.isAuthorizationSufficient(.restricted))
  }

  @Test func notDeterminedMapsToFalse() {
    #expect(!PhotoLibraryManager.isAuthorizationSufficient(.notDetermined))
  }
}
