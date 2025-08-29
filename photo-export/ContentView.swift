//
//  ContentView.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import AppKit
import Foundation
import Photos
import SwiftUI

private struct ExportRecordStoreKey: EnvironmentKey {
    static let defaultValue: ExportRecordStore? = nil
}

extension EnvironmentValues {
    var exportRecordStore: ExportRecordStore? {
        get { self[ExportRecordStoreKey.self] }
        set { self[ExportRecordStoreKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
    @EnvironmentObject private var exportManager: ExportManager
    @State private var isShowingAuthorizationView = false
    @State private var selectedYearMonth: YearMonth? = YearMonth(
        year: Calendar.current.component(.year, from: Date()),
        month: Calendar.current.component(.month, from: Date()))
    @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
    @Environment(\.exportRecordStore) private var exportRecordStore
    @State private var years: [Int] = []
    @State private var expandedYears: Set<Int> = []
    @State private var monthsWithAssetsByYear: [Int: [Int]] = [:]

    // Detail selection
    @State private var selectedAsset: PHAsset?

    var body: some View {
        Group {
            if photoLibraryManager.isAuthorized {
                NavigationSplitView(sidebar: {
                    List(selection: $selectedYearMonth) {
                        // Export destination selector
                        Section("Export Destination") {
                            exportDestinationSection
                        }

                        Section("Photos by Year") {
                            ForEach(years, id: \.self) { year in
                                DisclosureGroup(
                                    isExpanded: Binding(
                                        get: { expandedYears.contains(year) },
                                        set: { newValue in
                                            if newValue { expandedYears.insert(year) } else { expandedYears.remove(year) }
                                        }
                                    )
                                ) {
                                    ForEach(monthsWithAssetsByYear[year] ?? [], id: \.self) { month in
                                        MonthRow(
                                            year: year,
                                            month: month,
                                            totalProvider: { [weak photoLibraryManager] in
                                                guard let mgr = photoLibraryManager else { return 0 }
                                                return (try? mgr.countAssets(year: year, month: month)) ?? 0
                                            },
                                            summaryProvider: { total in
                                                if let store = exportRecordStore {
                                                    return store.monthSummary(year: year, month: month, totalAssets: total)
                                                }
                                                return MonthStatusSummary(year: year, month: month, exportedCount: 0, totalCount: total, status: .notExported)
                                            },
                                            exportAction: {
                                                exportManager.startExportMonth(year: year, month: month)
                                            },
                                            canExportNow: exportDestinationManager.canExportNow
                                        )
                                        .tag(YearMonth(year: year, month: month))
                                    }
                                } label: {
                                    Text(verbatim: String(year))
                                }
                            }
                        }
                    }
                    .navigationTitle("Photo Export")
                }, content: {
                    if let selected = selectedYearMonth {
                        MonthContentView(year: selected.year, month: selected.month, selectedAsset: $selectedAsset, photoLibraryManager: photoLibraryManager)
                            .environmentObject(photoLibraryManager)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack {
                            Spacer()
                            Text("Select a month")
                                .foregroundColor(.gray)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }, detail: {
                    AssetDetailView(asset: selectedAsset)
                        .environmentObject(photoLibraryManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                })
            } else {
                AuthorizationView(photoLibraryManager: photoLibraryManager)
            }
        }
        .onAppear {
            isShowingAuthorizationView = photoLibraryManager.authorizationStatus != .authorized
            if photoLibraryManager.isAuthorized {
                years = (try? photoLibraryManager.availableYears()) ?? []
                if let selected = selectedYearMonth {
                    expandedYears.insert(selected.year)
                    monthsWithAssetsByYear[selected.year] = computeMonthsWithAssets(for: selected.year)
                }
            }
        }
        .onChange(of: photoLibraryManager.isAuthorized) { isAuth in
            if isAuth {
                years = (try? photoLibraryManager.availableYears()) ?? []
                if let selected = selectedYearMonth {
                    expandedYears.insert(selected.year)
                    monthsWithAssetsByYear[selected.year] = computeMonthsWithAssets(for: selected.year)
                }
            } else {
                years = []
                expandedYears.removeAll()
                monthsWithAssetsByYear.removeAll()
            }
        }
        .onChange(of: expandedYears) { _ in
            // Lazy compute months for newly expanded years
            for year in expandedYears where monthsWithAssetsByYear[year] == nil {
                monthsWithAssetsByYear[year] = computeMonthsWithAssets(for: year)
            }
        }
        .onChange(of: selectedYearMonth) { _ in
            // Clear asset selection when month changes
            selectedAsset = nil
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(.windowBackgroundColor))
    }

    private struct YearMonth: Hashable, Identifiable {
        let year: Int
        let month: Int
        var id: String { "\(year)-\(month)" }
    }

    // MARK: - Export Destination UI
    private var exportDestinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = exportDestinationManager.selectedFolderURL {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: exportDestinationManager.isAvailable && exportDestinationManager.isWritable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(exportDestinationManager.isAvailable && exportDestinationManager.isWritable ? .green : .yellow)
                    Text(truncatedPath(for: url.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
                if let message = exportDestinationManager.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                // Export queue status
                HStack(spacing: 6) {
                    Label("Queue: \(exportManager.queueCount)", systemImage: exportManager.isRunning ? "arrow.triangle.2.circlepath" : "tray.and.arrow.down")
                        .foregroundColor(exportManager.isRunning ? .orange : .secondary)
                    Spacer()
                    if exportManager.isRunning { ProgressView().scaleEffect(0.6) }
                }
                .font(.caption)

                HStack(spacing: 8) {
                    Button("Change…") { exportDestinationManager.selectFolder() }
                    Button("Reveal in Finder") { exportDestinationManager.revealInFinder() }
                    Spacer()
                    Button("Clear") { exportDestinationManager.clearSelection() }
                        .foregroundColor(.red)
                }
            } else {
                Text("No export folder selected")
                    .foregroundColor(.secondary)
                Button("Select Folder…") { exportDestinationManager.selectFolder() }
            }
        }
        .padding(.vertical, 4)
    }

    private func truncatedPath(for path: String, maxLength: Int = 40) -> String {
        guard path.count > maxLength else { return path }
        let prefixCount = Int(Double(maxLength) * 0.6)
        let suffixCount = maxLength - prefixCount - 1
        let start = path.prefix(prefixCount)
        let end = path.suffix(suffixCount)
        return String(start) + "…" + String(end)
    }

    private func monthName(_ month: Int) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM"

        var components = DateComponents()
        components.month = month
        components.year = 2023  // Any year will do for getting month name

        if let date = Calendar.current.date(from: components) {
            return dateFormatter.string(from: date)
        }
        return "\(month)"
    }

    private func computeMonthsWithAssets(for year: Int) -> [Int] {
        (1...12).filter { month in
            ((try? photoLibraryManager.countAssets(year: year, month: month)) ?? 0) > 0
        }
    }
}

struct AuthorizationView: View {
    @ObservedObject var photoLibraryManager: PhotoLibraryManager
    @State private var isRequestingAuthorization = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .foregroundColor(.blue)

            Text("Photo Library Access Required")
                .font(.title)
                .bold()

            Text(
                "This app needs access to your Photos library to back up photos and videos to external storage."
            )
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Button(action: {
                requestPermission()
            }) {
                Text("Grant Access")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            .disabled(isRequestingAuthorization)

            if isRequestingAuthorization {
                ProgressView()
                    .padding()
            }

            if photoLibraryManager.authorizationStatus == .denied
                || photoLibraryManager.authorizationStatus == .restricted
            {
                Text("Please enable Photos access in Settings to use this app.")
                    .foregroundColor(.red)
                    .padding()

                Button("Open System Preferences") {
                    NSWorkspace.shared.open(
                        URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
                        )!)
                }
                .padding()
            }
        }
        .padding()
    }

    private func requestPermission() {
        isRequestingAuthorization = true

        Task {
            _ = await photoLibraryManager.requestAuthorization()
            isRequestingAuthorization = false
        }
    }
}

struct MonthRow: View {
    @EnvironmentObject private var exportManager: ExportManager

    let year: Int
    let month: Int
    let totalProvider: () -> Int
    let summaryProvider: (_ total: Int) -> MonthStatusSummary
    let exportAction: () -> Void
    let canExportNow: Bool

    var body: some View {
        let total = totalProvider()
        let summary = summaryProvider(total)
        return HStack(spacing: 8) {
            Text("\(String(year)) \(monthName(month))")
            Spacer()
            if total > 0 {
                switch summary.status {
                case .complete:
                    Label("\(summary.exportedCount)/\(summary.totalCount)", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                case .partial:
                    Label("\(summary.exportedCount)/\(summary.totalCount)", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(.orange)
                        .font(.caption)
                case .notExported:
                    Label("0/\(summary.totalCount)", systemImage: "circle")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                Button("Export") { exportAction() }
                    .buttonStyle(.bordered)
                    .disabled(!canExportNow)
                    .help(canExportNow ? "Export this month to selected folder" : "Select a writable export folder first")
            }
        }
        .contentShape(Rectangle())
    }

    private func monthName(_ month: Int) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM"
        let date = Calendar.current.date(from: DateComponents(year: 2023, month: month))!
        return dateFormatter.string(from: date)
    }
}

struct MainView: View {
    @EnvironmentObject var photoLibraryManager: PhotoLibraryManager
    @Binding var selectedYear: Int
    @Binding var selectedMonth: Int

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left sidebar with navigation/selection options
                VStack(alignment: .leading) {
                    Text("Library")
                        .font(.headline)
                        .padding()

                    List {
                        // Combined year/month selection
                        Section("Photos by Month") {
                            ForEach(2020...2025, id: \.self) { year in
                                ForEach(1...12, id: \.self) { month in
                                    HStack {
                                        Text("\(year) \(monthName(month))")
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .background(
                                        selectedYear == year && selectedMonth == month
                                            ? Color.blue.opacity(0.2) : Color.clear
                                    )
                                    .onTapGesture {
                                        selectedYear = year
                                        selectedMonth = month
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width * 0.25)

                // Right side placeholder (legacy)
                VStack { Text("Deprecated MainView") }
                    .frame(width: geometry.size.width * 0.75)
            }
        }
    }

    private func monthName(_ month: Int) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM"

        var components = DateComponents()
        components.month = month
        components.year = 2023  // Any year will do for getting month name

        if let date = Calendar.current.date(from: components) {
            return dateFormatter.string(from: date)
        }
        return "\(month)"
    }
}

#Preview {
    ContentView()
}

// Removed inline MonthView; logic moved to MonthContentView and AssetDetailView.
