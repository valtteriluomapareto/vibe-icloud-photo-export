import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager

  let onSkip: () -> Void

  @State private var exportAll = true
  @State private var versionSelection: ExportVersionSelection = .originalOnly

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "photo.on.rectangle.angled")
        .resizable()
        .scaledToFit()
        .frame(width: 80, height: 80)
        .foregroundColor(.accentColor)

      Text("Welcome to Photo Export")
        .font(.largeTitle)
        .fontWeight(.bold)

      Text("Back up your Photos library to any drive.")
        .font(.title3)
        .foregroundColor(.secondary)

      VStack(alignment: .leading, spacing: 16) {
        // Step 1: Select destination
        HStack(alignment: .top, spacing: 12) {
          Text("1")
            .font(.headline)
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.accentColor))

          VStack(alignment: .leading, spacing: 6) {
            Text("Select an export destination")
              .font(.headline)

            if let url = exportDestinationManager.selectedFolderURL {
              HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundColor(.green)
                Text(url.lastPathComponent)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Button("Change\u{2026}") {
                exportDestinationManager.selectFolder()
              }
              .buttonStyle(.bordered)
            } else {
              Button("Choose Folder\u{2026}") {
                exportDestinationManager.selectFolder()
              }
              .buttonStyle(.borderedProminent)
            }
          }
        }

        // Step 2: Choose scope
        HStack(alignment: .top, spacing: 12) {
          Text("2")
            .font(.headline)
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.accentColor))

          VStack(alignment: .leading, spacing: 10) {
            Text("Choose what to export")
              .font(.headline)

            Picker("", selection: $exportAll) {
              Text("Everything (Recommended)").tag(true)
              Text("Let me pick months").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
              Text("Versions to export")
                .font(.subheadline)
              Picker("Versions to export", selection: $versionSelection) {
                Text("Originals").tag(ExportVersionSelection.originalOnly)
                Text("Edited versions").tag(ExportVersionSelection.editedOnly)
                Text("Originals + edited versions")
                  .tag(ExportVersionSelection.originalAndEdited)
              }
              .pickerStyle(.menu)
              .labelsHidden()
              .frame(maxWidth: 260, alignment: .leading)
              Text(
                "Edited versions export the current Photos edits side-by-side with originals "
                  + "using an _edited suffix. You can change this later in the toolbar."
              )
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      .padding(.horizontal, 40)
      .frame(maxWidth: 440)

      HStack(spacing: 16) {
        Button("Skip") {
          onSkip()
        }
        .buttonStyle(.borderless)

        Button(exportAll ? "Start Export" : "Continue") {
          // Apply the chosen versions first so the export kicked off below uses the
          // selection the user made here, not the persisted default.
          exportManager.versionSelection = versionSelection
          if exportAll && exportDestinationManager.canExportNow {
            exportManager.startExportAll()
          }
          onSkip()
        }
        .buttonStyle(.borderedProminent)
        .disabled(exportDestinationManager.selectedFolderURL == nil)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.windowBackgroundColor))
  }
}
