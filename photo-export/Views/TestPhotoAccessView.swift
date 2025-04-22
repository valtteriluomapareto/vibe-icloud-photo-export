import SwiftUI
import Photos
import AppKit

struct TestPhotoAccessView: View {
    @EnvironmentObject var photoLibraryManager: PhotoLibraryManager
    @State private var loadingStatus = "Idle"
    @State private var assetCounts: [Int: [Int: Int]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedAsset: PHAsset?
    @State private var selectedThumbnail: NSImage?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Photos Library Test")
                .font(.largeTitle)
                .bold()
            
            Group {
                Text("Authorization Status: \(statusString(photoLibraryManager.authorizationStatus))")
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
                
                if !assetCounts.isEmpty {
                    Text("Photos Library Summary:")
                        .font(.headline)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(assetCounts.keys.sorted(), id: \.self) { year in
                                DisclosureGroup(
                                    content: {
                                        VStack(alignment: .leading) {
                                            ForEach(assetCounts[year]?.keys.sorted() ?? [], id: \.self) { month in
                                                Button(action: {
                                                    loadRandomAsset(year: year, month: month)
                                                }) {
                                                    Text("\(monthString(month)): \(assetCounts[year]?[month] ?? 0) assets")
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                                .buttonStyle(.plain)
                                                .padding(.vertical, 2)
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
                    .frame(height: 200)
                    .border(Color.gray.opacity(0.3))
                }
                
                if let selectedAsset = selectedAsset {
                    VStack(spacing: 10) {
                        Text("Selected Asset:")
                            .font(.headline)
                        
                        if let thumbnail = selectedThumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 300, height: 300)
                                .border(Color.gray)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 300, height: 300)
                                .overlay(ProgressView())
                        }
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ID: \(selectedAsset.localIdentifier)")
                            if let date = selectedAsset.creationDate {
                                Text("Created: \(dateFormatter.string(from: date))")
                            }
                            Text("Type: \(AssetMetadata.mediaTypeString(from: selectedAsset.mediaType))")
                            Text("Size: \(selectedAsset.pixelWidth) x \(selectedAsset.pixelHeight)")
                            if selectedAsset.mediaType == .video {
                                Text("Duration: \(Int(selectedAsset.duration)) seconds")
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
    
    private func loadRandomAsset(year: Int, month: Int) {
        isLoading = true
        loadingStatus = "Loading asset..."
        errorMessage = nil
        selectedThumbnail = nil
        
        Task {
            do {
                let assets = try await photoLibraryManager.fetchAssets(year: year, month: month)
                
                if let randomAsset = assets.randomElement() {
                    let thumbnail = await photoLibraryManager.loadThumbnail(for: randomAsset)
                    
                    DispatchQueue.main.async {
                        self.selectedAsset = randomAsset
                        self.selectedThumbnail = thumbnail
                        self.isLoading = false
                        self.loadingStatus = "Idle"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = "No assets found for this period"
                        self.isLoading = false
                        self.loadingStatus = "Error"
                    }
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
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
} 