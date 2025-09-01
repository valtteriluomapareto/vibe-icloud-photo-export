import Foundation

enum ExportStatus: String, Codable, Equatable {
  case pending
  case inProgress
  case done
  case failed
}

struct ExportRecord: Codable, Equatable {
  let id: String  // PHAsset.localIdentifier
  var year: Int
  var month: Int  // 1…12
  var relPath: String  // e.g., "2025/02/"
  var filename: String?  // final exported filename
  var status: ExportStatus
  var exportDate: Date?
  var lastError: String?
}

struct ExportRecordMutation: Codable, Equatable {
  enum Operation: String, Codable {
    case upsert
    case delete
  }

  let op: Operation
  let id: String
  var record: ExportRecord?

  static func upsert(_ record: ExportRecord) -> ExportRecordMutation {
    ExportRecordMutation(op: .upsert, id: record.id, record: record)
  }

  static func delete(id: String) -> ExportRecordMutation {
    ExportRecordMutation(op: .delete, id: id, record: nil)
  }
}

enum MonthExportStatus: String {
  case notExported
  case partial
  case complete
}

struct MonthStatusSummary: Equatable {
  let year: Int
  let month: Int
  let exportedCount: Int
  let totalCount: Int
  let status: MonthExportStatus
}
