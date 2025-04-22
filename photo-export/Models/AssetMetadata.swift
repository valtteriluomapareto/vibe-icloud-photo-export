import Photos
import Foundation

/// Represents the metadata of a photo or video asset
struct AssetMetadata: Identifiable, Hashable {
    /// The unique identifier of the asset in the Photos library
    let localIdentifier: String
    
    /// The creation date of the asset
    let creationDate: Date?
    
    /// The media type of the asset (photo, video, etc.)
    let mediaType: PHAssetMediaType
    
    /// The pixel width of the asset
    let pixelWidth: Int
    
    /// The pixel height of the asset
    let pixelHeight: Int
    
    /// The duration of the asset (for videos)
    let duration: TimeInterval
    
    /// Whether the asset is marked as a favorite
    let isFavorite: Bool
    
    /// The unique identifier for Identifiable conformance
    var id: String { localIdentifier }
    
    /// Computed property to check if the asset is a photo
    var isPhoto: Bool {
        return mediaType == .image
    }
    
    /// Computed property to check if the asset is a video
    var isVideo: Bool {
        return mediaType == .video
    }
    
    /// Static method to get a formatted string from a media type
    static func mediaTypeString(from type: PHAssetMediaType) -> String {
        switch type {
        case .image:
            return "Photo"
        case .video:
            return "Video"
        case .audio:
            return "Audio"
        case .unknown:
            return "Unknown"
        @unknown default:
            return "Unknown"
        }
    }
    
    /// Hashing implementation for Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(localIdentifier)
    }
    
    /// Equality implementation for Hashable conformance
    static func == (lhs: AssetMetadata, rhs: AssetMetadata) -> Bool {
        return lhs.localIdentifier == rhs.localIdentifier
    }
} 