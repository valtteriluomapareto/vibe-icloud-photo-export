import AppKit
import Photos
import SwiftUI

struct TestPhotoAccessView: View {
    @EnvironmentObject var photoLibraryManager: PhotoLibraryManager
    @State private var loadingStatus = "Idle"
    @State private var assetCounts: [Int: [Int: Int]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedYear: Int?
    @State private var selectedMonth: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Photos Library Test")
                .font(.largeTitle)
                .bold()

            Group {
                Text(
                    "Authorization Status: \(statusString(photoLibraryManager.authorizationStatus))"
                )
                .foregroundColor(photoLibraryManager.isAuthorized ? .green : .red)

                Button("Fetch Photos Library Summary") {
                    loadPhotosSummary()
                }
                .disabled(isLoading || !photoLibraryManager.isAuthorized)

                if isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(loadingStatus)
                            .font(.caption)
                    }
                }

                if let errorMessage = errorMessage {
                    Text("Error: \(errorMessage)")
                        .foregroundColor(.red)
                }
            }

            if !assetCounts.isEmpty {
                HStack(spacing: 0) {
                    // Left sidebar with years/months
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Photos Library Summary:")
                            .font(.headline)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(assetCounts.keys.sorted(), id: \.self) { year in
                                    DisclosureGroup(
                                        isExpanded: Binding<Bool>(
                                            get: { selectedYear == year },
                                            set: { if $0 { selectedYear = year } }
                                        ),
                                        content: {
                                            VStack(alignment: .leading) {
                                                ForEach(
                                                    assetCounts[year]?.keys.sorted() ?? [],
                                                    id: \.self
                                                ) { month in
                                                    Button(action: {
                                                        selectYearAndMonth(year: year, month: month)
                                                    }) {
                                                        Text(
                                                            "\(monthString(month)): \(assetCounts[year]?[month] ?? 0) assets"
                                                        )
                                                        .frame(
                                                            maxWidth: .infinity, alignment: .leading
                                                        )
                                                        .padding(.vertical, 2)
                                                        .background(
                                                            selectedYear == year
                                                                && selectedMonth == month
                                                                ? Color.blue.opacity(0.2)
                                                                : Color.clear
                                                        )
                                                        .cornerRadius(4)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(.leading)
                                        },
                                        label: {
                                            Text("\(year): \(totalForYear(year)) assets")
                                                .font(.headline)
                                        }
                                    )
                                    .padding(.vertical, 5)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 250)
                        .background(Color(.textBackgroundColor).opacity(0.3))
                        .cornerRadius(8)
                    }
                    .frame(width: 250)

                    // Right pane for month view
                    if let selectedYear = selectedYear, let selectedMonth = selectedMonth {
                        MonthView(year: selectedYear, month: selectedMonth)
                            .environmentObject(photoLibraryManager)
                    } else {
                        VStack {
                            Spacer()
                            Text("Select a month to view photos")
                                .foregroundColor(.gray)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func loadPhotosSummary() {
        guard photoLibraryManager.isAuthorized else {
            errorMessage = "Not authorized to access Photos library"
            return
        }

        isLoading = true
        loadingStatus = "Fetching assets..."
        errorMessage = nil

        Task {
            do {
                let assetsDict = try await photoLibraryManager.fetchAssetsByYearAndMonth()

                // Convert to count dictionary
                var counts: [Int: [Int: Int]] = [:]
                for (year, months) in assetsDict {
                    counts[year] = [:]
                    for (month, assets) in months {
                        counts[year]?[month] = assets.count
                    }
                }

                DispatchQueue.main.async {
                    self.assetCounts = counts
                    self.isLoading = false
                    self.loadingStatus = "Idle"
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.loadingStatus = "Error"
                }
            }
        }
    }

    private func selectYearAndMonth(year: Int, month: Int) {
        selectedYear = year
        selectedMonth = month
    }

    private func totalForYear(_ year: Int) -> Int {
        return assetCounts[year]?.values.reduce(0, +) ?? 0
    }

    private func statusString(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        case .limited:
            return "Limited"
        @unknown default:
            return "Unknown"
        }
    }

    private func monthString(_ month: Int) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM"
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2020, month: month))!
        return dateFormatter.string(from: date)
    }
}
