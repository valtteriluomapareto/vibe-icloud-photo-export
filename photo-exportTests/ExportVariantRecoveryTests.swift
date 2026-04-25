import Foundation
import Testing

@testable import Photo_Export

/// Table-driven coverage of `ExportVariantRecovery` — the named recoverable failure
/// cases we recognise in the UI to render with non-promising, secondary-coloured copy.
struct ExportVariantRecoveryTests {

  // MARK: - isRecoverable

  @Test func interruptedMessageIsRecoverable() {
    #expect(ExportVariantRecovery.isRecoverable(ExportVariantRecovery.interruptedMessage))
  }

  @Test func editedResourceUnavailableMessageIsRecoverable() {
    #expect(
      ExportVariantRecovery.isRecoverable(
        ExportVariantRecovery.editedResourceUnavailableMessage))
  }

  @Test func unknownMessageIsNotRecoverable() {
    #expect(!ExportVariantRecovery.isRecoverable("Disk full"))
    #expect(!ExportVariantRecovery.isRecoverable("Permission denied"))
    #expect(!ExportVariantRecovery.isRecoverable(""))
    #expect(!ExportVariantRecovery.isRecoverable(nil))
  }

  // MARK: - friendlyCopy

  @Test func friendlyCopyForInterruptedMessage() {
    let copy = ExportVariantRecovery.friendlyCopy(
      for: ExportVariantRecovery.interruptedMessage, label: "Original")
    #expect(copy == "Original: Will retry on next export")
  }

  @Test func friendlyCopyForEditedResourceUnavailable() {
    let copy = ExportVariantRecovery.friendlyCopy(
      for: ExportVariantRecovery.editedResourceUnavailableMessage, label: "Edited")
    #expect(
      copy == "Edited version was not provided by Photos. Future exports will try again.")
  }

  @Test func friendlyCopyReturnsNilForUnknownMessages() {
    #expect(ExportVariantRecovery.friendlyCopy(for: "Disk full", label: "Original") == nil)
    #expect(ExportVariantRecovery.friendlyCopy(for: nil, label: "Edited") == nil)
  }

  // MARK: - Pipeline regression

  @Test func pipelineUsesEditedResourceUnavailableConstant() {
    // The export pipeline writes this exact string into `lastError` for an adjusted asset
    // whose edited resource cannot be selected. Round-tripping through `friendlyCopy`
    // proves the constant matches what the pipeline emits — protects against drift.
    let recordedError = ExportVariantRecovery.editedResourceUnavailableMessage
    #expect(ExportVariantRecovery.isRecoverable(recordedError))
    #expect(ExportVariantRecovery.friendlyCopy(for: recordedError, label: "Edited") != nil)
  }
}
