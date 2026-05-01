import SwiftUI

struct ExportToolbarView: ToolbarContent {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      destinationIndicator
    }

    ToolbarItem(placement: .automatic) {
      includeOriginalsToggle
    }

    ToolbarItem(placement: .automatic) {
      primaryActions
    }

    ToolbarItem(placement: .automatic) {
      progressIndicator
    }
  }

  // MARK: - Include-originals toggle

  private var includeOriginalsToggle: some View {
    // Explicit HStack rather than `Label(...)` so the icon and text always
    // render side-by-side (mirroring the Destination indicator's layout) and
    // the toolbar's "Icon Only" customization mode can't strip the label —
    // both pieces are part of the view content, not adaptive to display mode.
    Toggle(isOn: $exportManager.includeOriginals) {
      HStack(alignment: .center, spacing: 6) {
        Image(
          systemName: exportManager.includeOriginals
            ? "doc.on.doc.fill" : "doc.on.doc"
        )
        Text("Include originals")
          .font(.callout)
      }
    }
    .toggleStyle(.button)
    .tint(.accentColor)
    .disabled(exportManager.hasActiveExportWork)
    .help(includeOriginalsHelp)
    .accessibilityLabel("Include originals for edited photos")
    .accessibilityHint(
      "Off by default. Turn on to keep original-bytes copies alongside edited photos.")
  }

  private var includeOriginalsHelp: String {
    if exportManager.hasActiveExportWork {
      return "Available after the current export finishes."
    }
    switch exportManager.versionSelection {
    case .edited:
      return
        "Each photo is exported once, in the version Photos shows. "
        + "Turn on to also keep an original-bytes copy alongside edited photos."
    case .editedWithOriginals:
      return
        "Edited photos export both the user-visible version and a _orig companion "
        + "with the original bytes."
    }
  }

  // MARK: - Destination Indicator

  @ViewBuilder
  private var destinationIndicator: some View {
    if let url = exportDestinationManager.selectedFolderURL {
      HStack(alignment: .center, spacing: 8) {
        Image(
          systemName: exportDestinationManager.isAvailable
            && exportDestinationManager.isWritable
            ? "externaldrive.fill" : "externaldrive.badge.exclamationmark"
        )
        .foregroundColor(
          exportDestinationManager.isAvailable && exportDestinationManager.isWritable
            ? .green : .yellow)

        // Two-row label gives this custom toolbar item a visible title that
        // mirrors what system buttons get for free in "Icon and Text" mode.
        VStack(alignment: .leading, spacing: 1) {
          Text("Destination")
            .font(.caption2)
            .foregroundColor(.secondary)
          Text(url.lastPathComponent)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(url.path)
        }
        .frame(maxWidth: 140, alignment: .leading)

        Button("Change\u{2026}") {
          exportDestinationManager.selectFolder()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .padding(.trailing, 12)
    } else {
      Button("Select Export Folder\u{2026}") {
        exportDestinationManager.selectFolder()
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Primary Actions

  private var primaryActions: some View {
    HStack(alignment: .center, spacing: 8) {
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
    case .edited:
      return
        "Export every photo in the timeline (year/month) view, in the version Photos shows. "
        + "Use the Export Favorites or Export Album button on the Collections tab to export those."
    case .editedWithOriginals:
      return
        "Export every photo in the timeline (year/month) view, plus a _orig companion for any "
        + "photo edited in Photos. Use the Export Favorites or Export Album button on the "
        + "Collections tab to export those."
    }
  }

  // MARK: - Progress Indicator

  private var progressIndicator: some View {
    let total = exportManager.totalJobsEnqueued
    let done = exportManager.totalJobsCompleted
    let fraction = total > 0 ? Double(done) / Double(total) : 0
    let hasProgress = total > 0

    return Group {
      if hasProgress {
        HStack(alignment: .center, spacing: 8) {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .frame(width: 120)

          Text("\(done)/\(total) assets")
            .font(.caption)
            .monospacedDigit()
            .frame(width: 90, alignment: .leading)
            .help(progressCountTooltip)

          Text(exportManager.currentAssetFilename ?? "")
            .font(.caption2)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 140, alignment: .leading)
        }
      } else if let emptyMessage = exportManager.emptyRunMessage {
        // The user just clicked Export Month/Year/All against an already-complete library.
        // The progress bar slot is empty — show a transient confirmation in its place so the
        // click doesn't look dead.
        HStack(alignment: .center, spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
            .font(.caption)
          Text(emptyMessage)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: 350, alignment: .leading)
        .transition(.opacity)
      } else {
        // Reserve the progress slot's footprint so the toolbar layout doesn't jump when work
        // starts or stops.
        HStack(alignment: .center, spacing: 8) {
          ProgressView(value: 0)
            .progressViewStyle(.linear)
            .frame(width: 120)
          Text("0/0 assets")
            .font(.caption)
            .monospacedDigit()
            .frame(width: 90, alignment: .leading)
          Spacer().frame(width: 140)
        }
        .opacity(0)
      }
    }
    .animation(.default, value: exportManager.emptyRunMessage)
  }

  private var progressCountTooltip: String {
    switch exportManager.versionSelection {
    case .editedWithOriginals:
      return
        "Counts assets, not files. Each adjusted asset writes both an edited file and a "
        + "_orig companion but counts once. The filename below is whichever file is "
        + "currently being written."
    case .edited:
      return
        "Counts assets. The filename below is the file currently being written for the "
        + "asset in progress."
    }
  }
}
