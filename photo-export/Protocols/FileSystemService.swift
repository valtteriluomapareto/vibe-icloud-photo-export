import Foundation

/// Abstracts file system operations for testability.
/// FileIOService conforms in production; tests inject a fake.
protocol FileSystemService: Sendable {
  func moveItemAtomically(from src: URL, to dst: URL) throws
  func applyTimestamps(creationDate: Date, to url: URL)
  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
  func fileExists(atPath: String) -> Bool
  func removeItem(at url: URL) throws
}
