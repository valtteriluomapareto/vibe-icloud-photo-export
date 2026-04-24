import Foundation
import Testing

@testable import Photo_Export

struct ExportFilenamePolicyTests {
  // MARK: - originalFilename(for:)

  @Test func originalFilenameIsUnchanged() {
    #expect(ExportFilenamePolicy.originalFilename(for: "IMG_0001.JPG") == "IMG_0001.JPG")
    #expect(
      ExportFilenamePolicy.originalFilename(for: "some thing (weird).HEIC")
        == "some thing (weird).HEIC")
  }

  // MARK: - editedFilename(originalGroupStem:editedResourceFilename:)

  @Test func editedFilenameUsesGroupStemPlusEditedExtension() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        originalGroupStem: "IMG_0001",
        editedResourceFilename: "IMG_E0001.JPG"
      ) == "IMG_0001_edited.JPG")
  }

  @Test func editedFilenamePicksUpRenderedJpegFromHeicOriginal() {
    // The canonical example: HEIC original, JPEG rendered edit.
    #expect(
      ExportFilenamePolicy.editedFilename(
        originalGroupStem: "IMG_0001",
        editedResourceFilename: "FullSizeRender.JPG"
      ) == "IMG_0001_edited.JPG")
  }

  @Test func editedFilenamePreservesCollisionSuffixInGroupStem() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        originalGroupStem: "IMG_0001 (1)",
        editedResourceFilename: "IMG_E0001.JPG"
      ) == "IMG_0001 (1)_edited.JPG")
  }

  // MARK: - parseEditedCandidate(filename:)

  @Test func parseEditedCandidateRecognizesPlainEditedFilename() {
    let parsed = ExportFilenamePolicy.parseEditedCandidate(filename: "IMG_0001_edited.JPG")
    #expect(parsed?.groupStem == "IMG_0001")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == nil)
    #expect(parsed?.fileExtension == "JPG")
  }

  @Test func parseEditedCandidatePreservesGroupCollisionSuffix() {
    let parsed = ExportFilenamePolicy.parseEditedCandidate(
      filename: "IMG_0001 (1)_edited.JPG")
    #expect(parsed?.groupStem == "IMG_0001 (1)")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == nil)
  }

  @Test func parseEditedCandidateRecognizesFinalFileCollisionSuffix() {
    let parsed = ExportFilenamePolicy.parseEditedCandidate(filename: "IMG_0001_edited (1).JPG")
    #expect(parsed?.groupStem == "IMG_0001")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == 1)
  }

  @Test func parseEditedCandidateReturnsNilForNonEditedFilename() {
    #expect(ExportFilenamePolicy.parseEditedCandidate(filename: "IMG_0001.JPG") == nil)
    #expect(
      ExportFilenamePolicy.parseEditedCandidate(filename: "vacation_2020.JPG") == nil)
  }

  @Test func parseEditedCandidateRequiresEditedSuffixOnStem() {
    // Has "_edited" inside but not as suffix — should still return nil.
    #expect(
      ExportFilenamePolicy.parseEditedCandidate(filename: "my_edited_photo.JPG") == nil)
  }
}
