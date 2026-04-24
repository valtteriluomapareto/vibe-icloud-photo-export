import SwiftUI

struct ExportToolbarView: ToolbarContent {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      destinationIndicator
    }

    ToolbarItem(placement: .automatic) {
      versionPicker
    }

    ToolbarItem(placement: .automatic) {
      primaryActions
    }

    ToolbarItem(placement: .automatic) {
      progressIndicator
    }
  }

  // MARK: - Version Picker

  private var versionPicker: some View {
    Picker(
      "Versions",
      selection: Binding(
        get: { exportManager.versionSelection },
        set: { exportManager.versionSelection = $0 }
      )
    ) {
      Text("Originals").tag(ExportVersionSelection.originalOnly)
      Text("Edited").tag(ExportVersionSelection.editedOnly)
      Text("Originals + edited").tag(ExportVersionSelection.originalAndEdited)
    }
    .pickerStyle(.menu)
    .frame(width: 170)
    .help(versionPickerHelp)
  }

  private var versionPickerHelp: String {
    switch exportManager.versionSelection {
    case .originalOnly:
      return "Export original files using the Photos library's original filenames."
    case .editedOnly:
      return "Export only the current edited version of assets that have Photos edits."
    case .originalAndEdited:
      return
        "Export originals plus a separate _edited file for each asset that has Photos edits."
    }
  }

  // MARK: - Destination Indicator

  @ViewBuilder
  private var destinationIndicator: some View {
    if let url = exportDestinationManager.selectedFolderURL {
      HStack(spacing: 6) {
        Image(
          systemName: exportDestinationManager.isAvailable
            && exportDestinationManager.isWritable
            ? "externaldrive.fill" : "externaldrive.badge.exclamationmark"
        )
        .foregroundColor(
          exportDestinationManager.isAvailable && exportDestinationManager.isWritable
            ? .green : .yellow)

        Text(url.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 120, alignment: .leading)
          .help(url.path)

        Button("Change\u{2026}") {
          exportDestinationManager.selectFolder()
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
    } else {
      Button("Select Export Folder\u{2026}") {
        exportDestinationManager.selectFolder()
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Primary Actions

  private var primaryActions: some View {
    HStack(spacing: 8) {
      Button("Export All") {
        exportManager.startExportAll()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!exportDestinationManager.canExportNow || exportManager.isImporting)
      .help(exportAllHelpText)

      Button {
        if exportManager.isPaused {
          exportManager.resume()
        } else {
          exportManager.pause()
        }
      } label: {
        Image(systemName: exportManager.isPaused ? "play.fill" : "pause.fill")
      }
      .help(exportManager.isPaused ? "Resume export" : "Pause export")
      .opacity(exportManager.isRunning || exportManager.queueCount > 0 ? 1 : 0)
      .disabled(!(exportManager.isRunning || exportManager.queueCount > 0))

      Button {
        exportManager.cancelAndClear()
      } label: {
        Image(systemName: "xmark.circle")
      }
      .help("Cancel and clear queue")
      .opacity(exportManager.isRunning || exportManager.queueCount > 0 ? 1 : 0)
      .disabled(!(exportManager.isRunning || exportManager.queueCount > 0))
    }
  }

  private var exportAllHelpText: String {
    guard exportDestinationManager.canExportNow else {
      return "Select a writable export folder first"
    }
    switch exportManager.versionSelection {
    case .originalOnly:
      return "Export originals for all unexported assets."
    case .editedOnly:
      return "Export the edited version of all assets that have Photos edits."
    case .originalAndEdited:
      return "Export originals plus edited versions where Photos has edits."
    }
  }

  // MARK: - Progress Indicator

  private var progressIndicator: some View {
    let total = exportManager.totalJobsEnqueued
    let done = exportManager.totalJobsCompleted
    let fraction = total > 0 ? Double(done) / Double(total) : 0
    let hasProgress = total > 0

    return HStack(spacing: 8) {
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
        .frame(width: 120)

      Text("\(done)/\(total)")
        .font(.caption)
        .monospacedDigit()
        .frame(width: 60, alignment: .leading)

      Text(exportManager.currentAssetFilename ?? "")
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: 140, alignment: .leading)
    }
    .opacity(hasProgress ? 1 : 0)
  }
}
