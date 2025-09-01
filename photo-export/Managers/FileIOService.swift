import Foundation
import os

enum FileIOService {
  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "FileIO")

  static func moveItemAtomically(from src: URL, to dst: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: dst.path) {
      throw NSError(
        domain: "Export", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Destination already exists"])
    }
    try fm.createDirectory(
      at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: src, to: dst)
  }

  static func applyTimestamps(creationDate: Date, to url: URL) {
    do {
      var values = URLResourceValues()
      values.creationDate = creationDate
      values.contentModificationDate = creationDate
      var mutableURL = url
      try mutableURL.setResourceValues(values)
    } catch {
      logger.error(
        "Failed setting URLResourceValues timestamps: \(error.localizedDescription, privacy: .public)"
      )
    }
    do {
      try FileManager.default.setAttributes(
        [
          .creationDate: creationDate,
          .modificationDate: creationDate
        ], ofItemAtPath: url.path)
    } catch {
      logger.error(
        "Failed setting FileManager attributes timestamps: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
