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
    @StateObject private var photoLibraryManager = PhotoLibraryManager()
    @State private var isShowingAuthorizationView = false
    @State private var selectedYearMonth: YearMonth? = YearMonth(
        year: Calendar.current.component(.year, from: Date()),
        month: Calendar.current.component(.month, from: Date()))
    @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
    @Environment(\.exportRecordStore) private var exportRecordStore
    @State private var years: [Int] = []
    @State private var expandedYears: Set<Int> = []

    var body: some View {
        Group {
            if photoLibraryManager.isAuthorized {
                NavigationSplitView {
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
                                    ForEach(1...12, id: \.self) { month in
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
                                            }
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
                } detail: {
                    if let selected = selectedYearMonth {
                        MonthView(year: selected.year, month: selected.month)
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
                }
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
                }
            }
        }
        .onChange(of: photoLibraryManager.isAuthorized) { isAuth in
            if isAuth {
                years = (try? photoLibraryManager.availableYears()) ?? []
                if let selected = selectedYearMonth {
                    expandedYears.insert(selected.year)
                }
            } else {
                years = []
                expandedYears.removeAll()
            }
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
    let year: Int
    let month: Int
    let totalProvider: () -> Int
    let summaryProvider: (_ total: Int) -> MonthStatusSummary

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

                // Right side with MonthView for displaying photos
                MonthView(year: selectedYear, month: selectedMonth)
                    .environmentObject(photoLibraryManager)
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

// Add MonthView struct inline for convenience
// (The real implementation should be moved to a proper file structure later)
struct MonthView: View {
    @EnvironmentObject var photoLibraryManager: PhotoLibraryManager
    @Environment(\.exportRecordStore) private var exportRecordStore
    @State private var assets: [PHAsset] = []
    @State private var selectedAsset: PHAsset?
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var selectedFullImage: NSImage?
    @State private var isLoading = false
    @State private var errorMessage: String?

    let year: Int
    let month: Int

    var body: some View {
        VStack(spacing: 0) {
            // Main image display area
            ZStack {
                if let selectedAsset = selectedAsset {
                    if let fullImage = selectedFullImage {
                        Image(nsImage: fullImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(ProgressView())
                    }

                    VStack {
                        Spacer()
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                if let date = selectedAsset.creationDate {
                                    Text(dateFormatter.string(from: date))
                                        .font(.caption)
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .background(Color.black.opacity(0.6))
                                        .cornerRadius(4)
                                }

                                Text(mediaTypeString(from: selectedAsset.mediaType))
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(6)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(4)
                            }
                            Spacer()
                        }
                        .padding()
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .overlay(
                            Text("No image selected")
                                .foregroundColor(.gray)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Thumbnail strip at the bottom
            VStack {
                Divider()
                    .background(Color.gray)
                    .padding(.horizontal, 8)

                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 8) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            ThumbnailView(
                                asset: asset,
                                thumbnail: thumbnails[asset.localIdentifier],
                                isSelected: asset.localIdentifier == selectedAsset?.localIdentifier,
                                isExported: exportRecordStore?.isExported(assetId: asset.localIdentifier) ?? true
                            )
                            .frame(width: 100, height: 100)
                            .onTapGesture {
                                selectAsset(asset)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal)
                }
                .frame(height: 120)
                .background(Color(.windowBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadAssetsForMonth()
        }
        .onChange(of: year) {
            loadAssetsForMonth()
        }
        .onChange(of: month) {
            loadAssetsForMonth()
        }
        .overlay(
            Group {
                if isLoading && assets.isEmpty {
                    ProgressView("Loading assets...")
                        .padding()
                        .background(Color(.windowBackgroundColor).opacity(0.8))
                        .cornerRadius(8)
                }

                if let errorMessage = errorMessage {
                    Text("Error: \(errorMessage)")
                        .foregroundColor(.red)
                        .padding()
                        .background(Color(.windowBackgroundColor).opacity(0.8))
                        .cornerRadius(8)
                }
            }
        )
    }

    private func mediaTypeString(from type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Audio"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    private func loadAssetsForMonth() {
        isLoading = true
        errorMessage = nil

        // Reset state for new selection
        assets = []
        thumbnails = [:]
        selectedAsset = nil
        selectedFullImage = nil

        Task {
            do {
                let monthAssets = try await photoLibraryManager.fetchAssets(
                    year: year, month: month)
                let initialBatch = Array(monthAssets.prefix(20))
                var thumbnailDict: [String: NSImage] = [:]

                for asset in initialBatch {
                    if let thumbnail = await photoLibraryManager.loadThumbnail(for: asset) {
                        thumbnailDict[asset.localIdentifier] = thumbnail
                    }
                }

                DispatchQueue.main.async {
                    self.assets = monthAssets
                    self.thumbnails = thumbnailDict
                    self.isLoading = false

                    if let firstAsset = monthAssets.first {
                        self.selectAsset(firstAsset)
                    }
                }

                for asset in monthAssets.dropFirst(20) {
                    if let thumbnail = await photoLibraryManager.loadThumbnail(for: asset) {
                        DispatchQueue.main.async {
                            self.thumbnails[asset.localIdentifier] = thumbnail
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func selectAsset(_ asset: PHAsset) {
        selectedAsset = asset
        selectedFullImage = nil

        Task {
            do {
                let image = try await photoLibraryManager.requestFullImage(for: asset)
                DispatchQueue.main.async {
                    self.selectedFullImage = image
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load full image: \(error.localizedDescription)"
                }
            }
        }
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

struct ThumbnailView: View {
    let asset: PHAsset
    let thumbnail: NSImage?
    let isSelected: Bool
    let isExported: Bool

    var body: some View {
        ZStack {
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 100)
                    .overlay(ProgressView())
            }

            if !isExported {
                VStack {
                    HStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.95))
                            .frame(width: 8, height: 8)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(6)
            }

            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.blue, lineWidth: 3)
                    .frame(width: 100, height: 100)
            }

            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "video.fill")
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                        Spacer()
                    }
                    .padding(4)
                }
            }
        }
        .cornerRadius(4)
    }
}
