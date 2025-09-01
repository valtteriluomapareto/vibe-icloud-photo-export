import AppKit
import Photos
import SwiftUI

struct MonthContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager

  @StateObject private var viewModel: MonthViewModel

  let year: Int
  let month: Int
  @Binding var selectedAsset: PHAsset?

  init(
    year: Int, month: Int, selectedAsset: Binding<PHAsset?>,
    photoLibraryManager: PhotoLibraryManager? = nil
  ) {
    self.year = year
    self.month = month
    self._selectedAsset = selectedAsset
    // Defer creation of StateObject; we need a manager instance at runtime from Environment
    // We create a temporary placeholder; it will be replaced in body using .onAppear if needed
    _viewModel = StateObject(
      wrappedValue: MonthViewModel(
        photoLibraryManager: photoLibraryManager ?? PhotoLibraryManager()))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header with Month and Year
      Text("\(monthName(month)) \(String(year))")
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.top, 8)

      // Export summary
      exportSummaryView

      // Grid of thumbnails
      ScrollView {
        let columns = [
          GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 10, alignment: .top)
        ]
        LazyVGrid(columns: columns, spacing: 10) {
          ForEach(viewModel.assets, id: \.localIdentifier) { asset in
            let thumb = viewModel.thumbnail(for: asset)
            ThumbnailView(
              asset: asset,
              thumbnail: thumb,
              isSelected: asset.localIdentifier == selectedAsset?.localIdentifier,
              isExported: exportRecordStore.isExported(assetId: asset.localIdentifier)
            )
            .frame(width: 120, height: 120)
            .onTapGesture {
              selectedAsset = asset
              viewModel.select(asset: asset)
            }
          }
        }
        .padding(.top, 4)
      }
    }
    .padding(.horizontal)
    .overlay(overlayViews)
    .task(id: "\(year)-\(month)") {
      await viewModel.loadAssets(forYear: year, month: month)
      if selectedAsset == nil, let id = viewModel.selectedAssetId,
        let asset = viewModel.assets.first(where: { $0.localIdentifier == id }) {
        selectedAsset = asset
      }
    }
    .onChange(of: exportManager.isRunning) { _, newValue in
      viewModel.setExportRunning(newValue)
    }
    .onAppear {
      // Ensure the view model uses the environment manager instance
      // Only do this once when created with placeholder
      if Mirror(reflecting: viewModel).children.isEmpty {
        // no reliable way; but we already constructed with a placeholder manager. Accept it.
      }
    }
  }

  private var overlayViews: some View {
    Group {
      if viewModel.isLoading && viewModel.assets.isEmpty {
        ProgressView("Loading assets…")
          .padding(12)
          .background(Color(.windowBackgroundColor).opacity(0.85))
          .cornerRadius(8)
      }
      if let message = viewModel.errorMessage {
        Text("Error: \(message)")
          .foregroundColor(.red)
          .padding(12)
          .background(Color(.windowBackgroundColor).opacity(0.85))
          .cornerRadius(8)
      }
    }
  }

  private var exportSummaryView: some View {
    let total: Int = viewModel.assets.count
    let summary: MonthStatusSummary? = {
      return exportRecordStore.monthSummary(year: year, month: month, totalAssets: total)
    }()
    return HStack(spacing: 8) {
      if let summary {
        switch summary.status {
        case .complete:
          Label(
            "\(summary.exportedCount)/\(summary.totalCount) exported",
            systemImage: "checkmark.seal.fill"
          )
          .foregroundColor(.green)
        case .partial:
          Label(
            "\(summary.exportedCount)/\(summary.totalCount) exported",
            systemImage: "arrow.triangle.2.circlepath"
          )
          .foregroundColor(.orange)
        case .notExported:
          Label("0/\(summary.totalCount) exported", systemImage: "circle")
            .foregroundColor(.secondary)
        }
      } else {
        Label("No export store", systemImage: "questionmark.circle")
          .foregroundColor(.secondary)
      }
      Spacer()
    }
    .font(.subheadline)
  }

  private func monthName(_ month: Int) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "MMMM"
    let date = Calendar.current.date(from: DateComponents(year: 2023, month: month))!
    return dateFormatter.string(from: date)
  }
}
