import AVFoundation
import Foundation
import Testing

@testable import Photo_Export

struct AVFileTypeMappingTests {
  @Test func mapsCanonicalIPhoneMov() {
    #expect(avFileType(forOriginalFilename: "IMG_0001.MOV") == AVFileType.mov)
  }

  @Test func mapsLowerCaseMov() {
    #expect(avFileType(forOriginalFilename: "clip.mov") == AVFileType.mov)
  }

  @Test func mapsMixedCaseMp4() {
    #expect(avFileType(forOriginalFilename: "vacation.MP4") == AVFileType.mp4)
  }

  @Test func mapsM4v() {
    #expect(avFileType(forOriginalFilename: "tv.m4v") == AVFileType.m4v)
  }

  @Test func fallsBackToMovForHeic() {
    // HEIC isn't a video type but the helper must still return a sensible default.
    #expect(avFileType(forOriginalFilename: "edit.heic") == AVFileType.mov)
  }

  @Test func fallsBackToMovForNoExtension() {
    #expect(avFileType(forOriginalFilename: "IMG_0001") == AVFileType.mov)
  }

  @Test func usesLastExtensionForMultiDotFilename() {
    #expect(avFileType(forOriginalFilename: "clip.final.mov") == AVFileType.mov)
    #expect(avFileType(forOriginalFilename: "clip.final.mp4") == AVFileType.mp4)
  }

  @Test func fallsBackToMovForUnsupportedAvi() {
    #expect(avFileType(forOriginalFilename: "old.avi") == AVFileType.mov)
  }

  @Test func fallsBackToMovForUnsupportedMkv() {
    #expect(avFileType(forOriginalFilename: "import.mkv") == AVFileType.mov)
  }

  @Test func fallsBackToMovForEmptyString() {
    #expect(avFileType(forOriginalFilename: "") == AVFileType.mov)
  }
}
