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

struct ContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportManager: ExportManager
  @State private var selectedYearMonth: YearMonth? = YearMonth(
    year: Calendar.current.component(.year, from: Date()),
    month: Calendar.current.component(.month, from: Date()))
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @State private var years: [Int] = []
  @State private var expandedYears: Set<Int> = []
  @State private var monthsWithAssetsByYear: [Int: [Int]] = [:]
  @State private var assetCountsByYearMonth: [String: Int] = [:]
  @State private var assetCountsByYear: [Int: Int] = [:]

  // Onboarding — default to false for new users; existing users are auto-detected in .onAppear
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

  // Detail selection
  @State private var selectedAsset: PHAsset?

  // Import sheet
  @State private var isShowingImportSheet: Bool = false

  private var canImport: Bool {
    hasCompletedOnboarding && photoLibraryManager.isAuthorized
      && exportDestinationManager.canImportNow && !exportManager.hasActiveExportWork
      && !exportManager.isImporting
  }

  var body: some View {
    Group {
      if photoLibraryManager.isAuthorized && !hasCompletedOnboarding {
        OnboardingView {
          hasCompletedOnboarding = true
        }
      } else if photoLibraryManager.isAuthorized {
        NavigationSplitView(
          sidebar: {
            List(selection: $selectedYearMonth) {
              Section("Photos by Year") {
                ForEach(years, id: \.self) { year in
                  DisclosureGroup(
                    isExpanded: Binding(
                      get: { expandedYears.contains(year) },
                      set: { newValue in
                        if newValue {
                          expandedYears.insert(year)
                        } else {
                          expandedYears.remove(year)
                        }
                      }
                    )
                  ) {
                    ForEach(monthsWithAssetsByYear[year] ?? [], id: \.self) { month in
                      MonthRow(
                        year: year,
                        month: month,
                        total: assetCountsByYearMonth["\(year)-\(month)"]
                          ?? 0
                      )
                      .tag(YearMonth(year: year, month: month))
                    }
                  } label: {
                    YearRow(year: year, totalAssets: assetCountsByYear[year] ?? 0)
                  }
                }
              }
            }
            .navigationTitle("Photo Export")
          },
          content: {
            if let selected = selectedYearMonth {
              MonthContentView(
                year: selected.year, month: selected.month,
                selectedAsset: $selectedAsset,
                photoLibraryManager: photoLibraryManager
              )
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
          },
          detail: {
            AssetDetailView(asset: selectedAsset)
              .environmentObject(photoLibraryManager)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          })
        .toolbar {
          ExportToolbarView()
        }
        .sheet(isPresented: $isShowingImportSheet) {
          ImportView()
            .environmentObject(exportManager)
        }
      } else {
        AuthorizationView(photoLibraryManager: photoLibraryManager)
      }
    }
    .onAppear {
      // Auto-skip onboarding for existing users who already have an export destination or records
      if !hasCompletedOnboarding {
        let hasDestination = exportDestinationManager.selectedFolderURL != nil
        let hasRecords = !exportRecordStore.recordsById.isEmpty
        if hasDestination || hasRecords {
          hasCompletedOnboarding = true
        }
      }
      if photoLibraryManager.isAuthorized {
        loadYears()
        if let selected = selectedYearMonth {
          expandedYears.insert(selected.year)
          monthsWithAssetsByYear[selected.year] = computeMonthsWithAssets(
            for: selected.year)
        }
      }
    }
    .onChange(of: photoLibraryManager.isAuthorized) { _, new in
      if new {
        loadYears()
        if let selected = selectedYearMonth {
          expandedYears.insert(selected.year)
          monthsWithAssetsByYear[selected.year] = computeMonthsWithAssets(
            for: selected.year)
        }
      } else {
        years = []
        expandedYears.removeAll()
        monthsWithAssetsByYear.removeAll()
        assetCountsByYear.removeAll()
      }
    }
    .onChange(of: expandedYears) { _, _ in
      // Lazy compute months for newly expanded years
      for year in expandedYears where monthsWithAssetsByYear[year] == nil {
        monthsWithAssetsByYear[year] = computeMonthsWithAssets(for: year)
      }
    }
    .onChange(of: selectedYearMonth) { _, _ in
      // Clear asset selection when month changes
      selectedAsset = nil
    }
    .focusedSceneValue(\.importBackupAction, canImport ? ImportBackupAction {
      isShowingImportSheet = true
      exportManager.startImport()
    } : nil)
    .frame(minWidth: 900, minHeight: 600)
    .background(Color(.windowBackgroundColor))
  }

  private struct YearMonth: Hashable, Identifiable {
    let year: Int
    let month: Int
    var id: String { "\(year)-\(month)" }
  }

  private func loadYears() {
    let yearCounts = (try? photoLibraryManager.availableYearsWithCounts()) ?? []
    years = yearCounts.map(\.year)
    for (year, count) in yearCounts {
      assetCountsByYear[year] = count
    }
  }

  private func computeMonthsWithAssets(for year: Int) -> [Int] {
    var months: [Int] = []
    for month in 1...12 {
      let count = (try? photoLibraryManager.countAssets(year: year, month: month)) ?? 0
      assetCountsByYearMonth["\(year)-\(month)"] = count
      if count > 0 {
        months.append(month)
      }
    }
    return months
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

      Button {
        requestPermission()
      } label: {
        Text("Grant Access")
          .fontWeight(.semibold)
          .foregroundColor(.white)
          .padding(.horizontal, 40)
          .padding(.vertical, 12)
          .background(Color.blue)
          .cornerRadius(10)
      }
      .buttonStyle(.plain)
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

struct YearRow: View {
  @EnvironmentObject private var exportRecordStore: ExportRecordStore

  let year: Int
  let totalAssets: Int

  var body: some View {
    let exported = exportRecordStore.yearExportedCount(year: year)
    let total = totalAssets
    HStack(spacing: 8) {
      Text(verbatim: String(year))
      Spacer()
      if total > 0 && exported > 0 {
        if exported >= total {
          Image(systemName: "checkmark.seal.fill")
            .foregroundColor(.green)
            .font(.caption)
        } else {
          let pct = Int(Double(exported) / Double(total) * 100)
          Text("\(pct)%")
            .foregroundColor(.orange)
            .font(.caption)
        }
      }
    }
  }
}

struct MonthRow: View {
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore

  let year: Int
  let month: Int
  let total: Int

  var body: some View {
    let summary = exportRecordStore.monthSummary(year: year, month: month, totalAssets: total)
    let queued = exportManager.queuedCount(year: year, month: month)
    return HStack(spacing: 8) {
      Text(MonthFormatting.name(for: month))
      Spacer()
      if queued > 0 {
        ProgressView()
          .scaleEffect(0.5)
          .frame(width: 16, height: 16)
        Text("\(queued) left")
          .font(.caption2)
          .foregroundColor(.orange)
      } else if total > 0 {
        switch summary.status {
        case .complete:
          Image(systemName: "checkmark.seal.fill")
            .foregroundColor(.green)
            .font(.caption)
        case .partial:
          Text("\(summary.exportedCount)/\(summary.totalCount)")
            .foregroundColor(.orange)
            .font(.caption)
        case .notExported:
          Text("\(summary.totalCount)")
            .foregroundColor(.secondary)
            .font(.caption)
        }
      }
    }
    .contentShape(Rectangle())
  }

}

#Preview {
  ContentView()
}
