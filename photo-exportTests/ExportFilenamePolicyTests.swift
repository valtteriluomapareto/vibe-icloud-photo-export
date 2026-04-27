import Foundation
import Testing

@testable import Photo_Export

struct ExportFilenamePolicyTests {
  // MARK: - originalFilename

  @Test func originalFilenameWithoutSuffix() {
    #expect(
      ExportFilenamePolicy.originalFilename(stem: "IMG_0001", ext: "JPG", withSuffix: false)
        == "IMG_0001.JPG")
  }

  @Test func originalFilenameWithOrigSuffix() {
    #expect(
      ExportFilenamePolicy.originalFilename(stem: "IMG_0001", ext: "HEIC", withSuffix: true)
        == "IMG_0001_orig.HEIC")
  }

  @Test func originalFilenamePreservesCollisionSuffixInStem() {
    #expect(
      ExportFilenamePolicy.originalFilename(stem: "IMG_0001 (1)", ext: "JPG", withSuffix: true)
        == "IMG_0001 (1)_orig.JPG")
  }

  // MARK: - editedFilename

  @Test func editedFilenameUsesGroupStemPlusEditedExtension() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        stem: "IMG_0001",
        editedResourceFilename: "IMG_E0001.JPG"
      ) == "IMG_0001.JPG")
  }

  @Test func editedFilenamePicksUpRenderedJpegFromHeicOriginal() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        stem: "IMG_0001",
        editedResourceFilename: "FullSizeRender.JPG"
      ) == "IMG_0001.JPG")
  }

  @Test func editedFilenamePreservesCollisionSuffixInStem() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        stem: "IMG_0001 (1)",
        editedResourceFilename: "IMG_E0001.JPG"
      ) == "IMG_0001 (1).JPG")
  }

  // MARK: - parseOriginalCandidate

  @Test func parseOriginalCandidateRecognizesPlainOrigFilename() {
    let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: "IMG_0001_orig.JPG")
    #expect(parsed?.groupStem == "IMG_0001")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == nil)
    #expect(parsed?.fileExtension == "JPG")
  }

  @Test func parseOriginalCandidatePreservesGroupCollisionSuffix() {
    let parsed = ExportFilenamePolicy.parseOriginalCandidate(
      filename: "IMG_0001 (1)_orig.JPG")
    #expect(parsed?.groupStem == "IMG_0001 (1)")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == nil)
  }

  @Test func parseOriginalCandidateRecognizesFinalFileCollisionSuffix() {
    let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: "IMG_0001_orig (1).JPG")
    #expect(parsed?.groupStem == "IMG_0001")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == 1)
  }

  @Test func parseOriginalCandidateReturnsNilForNonOrigFilename() {
    #expect(ExportFilenamePolicy.parseOriginalCandidate(filename: "IMG_0001.JPG") == nil)
    #expect(
      ExportFilenamePolicy.parseOriginalCandidate(filename: "vacation_2020.JPG") == nil)
  }

  @Test func parseOriginalCandidateRequiresOrigSuffixOnStem() {
    #expect(
      ExportFilenamePolicy.parseOriginalCandidate(filename: "my_orig_photo.JPG") == nil)
  }

  // MARK: - isOrigCompanion

  @Test func isOrigCompanionMatchesPlainAndCollisionForms() {
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001.JPG") == false)
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001 (1).JPG") == false)
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001_orig.JPG") == true)
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001_orig (1).JPG") == true)
    // The predicate is shape-only: a real user filename ending in `_orig` matches.
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "vacation_orig.JPG") == true)
  }
}
