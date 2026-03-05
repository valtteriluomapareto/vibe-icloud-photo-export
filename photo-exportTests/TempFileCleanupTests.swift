import Foundation
import Testing

struct TempFileCleanupTests {

  @Test func tempFileIsRemovedByDeferOnFailure() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")

    // Create a temp file simulating a partial write
    FileManager.default.createFile(atPath: tempURL.path, contents: Data("partial".utf8))
    #expect(FileManager.default.fileExists(atPath: tempURL.path))

    // Simulate the defer cleanup pattern from ExportManager
    do {
      defer {
        if FileManager.default.fileExists(atPath: tempURL.path) {
          try? FileManager.default.removeItem(at: tempURL)
        }
      }
      // Simulate a failure during export
      throw NSError(domain: "Test", code: 1)
    } catch {
      // Expected
    }

    #expect(!FileManager.default.fileExists(atPath: tempURL.path))
  }

  @Test func deferIsNoOpWhenTempFileDoesNotExist() {
    let tempDir = FileManager.default.temporaryDirectory
    let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")

    // File does not exist — defer should not crash
    do {
      defer {
        if FileManager.default.fileExists(atPath: tempURL.path) {
          try? FileManager.default.removeItem(at: tempURL)
        }
      }
      // No-op
    }

    #expect(!FileManager.default.fileExists(atPath: tempURL.path))
  }
}
