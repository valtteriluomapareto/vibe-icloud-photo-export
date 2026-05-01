import Photos
import SwiftUI

/// Sidebar for the Collections section: a synthetic Favorites entry followed by the
/// user's albums and folders. Selection is bridged out as a `LibrarySelection` so the
/// content area can observe it.
///
/// The tree is fetched lazily through `PhotoLibraryService.fetchCollectionTree()` and
/// re-fetched whenever `PhotoLibraryManager.libraryRevision` bumps. Per-collection
/// counts come from `cachedCountAssets(in:)` so concurrent sidebar reads share one
/// fetch and the cache is cleared on the same change observer.
struct CollectionsSidebarView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager

  @Binding var selection: LibrarySelection?

  @State private var tree: [PhotoCollectionDescriptor] = []
  @State private var expandedFolders: Set<String> = []
  @State private var countsById: [String: Int] = [:]

  var body: some View {
    List(selection: selectionBinding) {
      Section("Favorites") {
        CollectionRow(
          descriptor: favoritesDescriptor,
          count: countsById[favoritesDescriptor.id]
        )
        .tag(LibrarySelection.favorites)
        .task(id: photoLibraryManager.libraryRevision) {
          await loadCount(for: .favorites, descriptorId: favoritesDescriptor.id)
        }
      }

      if !userCollections.isEmpty {
        Section("Albums") {
          ForEach(userCollections, id: \.id) { node in
            descriptorRows(node, depth: 0)
          }
        }
      }
    }
    .navigationTitle("Photo Export")
    .task(id: photoLibraryManager.libraryRevision) {
      reloadTree()
    }
  }

  // MARK: - Tree rendering

  /// Recursive — must return `AnyView`. Without the type-erasure SwiftUI's opaque
  /// return type ends up referencing itself, which the compiler rejects.
  private func descriptorRows(_ descriptor: PhotoCollectionDescriptor, depth: Int)
    -> AnyView
  {
    switch descriptor.kind {
    case .album:
      let row = CollectionRow(
        descriptor: descriptor, count: countsById[descriptor.id], depth: depth
      )
      .tag(LibrarySelection.album(collectionId: descriptor.localIdentifier ?? ""))
      .task(id: descriptor.id + "|\(photoLibraryManager.libraryRevision)") {
        if let id = descriptor.localIdentifier {
          await loadCount(for: .album(collectionId: id), descriptorId: descriptor.id)
        }
      }
      return AnyView(row)
    case .folder:
      let group = DisclosureGroup(
        isExpanded: Binding(
          get: { expandedFolders.contains(descriptor.id) },
          set: { newValue in
            if newValue {
              expandedFolders.insert(descriptor.id)
            } else {
              expandedFolders.remove(descriptor.id)
            }
          }
        )
      ) {
        ForEach(descriptor.children, id: \.id) { child in
          descriptorRows(child, depth: depth + 1)
        }
      } label: {
        // Folders are not directly exportable, so they have no `LibrarySelection`
        // tag — clicking the disclosure just toggles expansion.
        FolderRow(descriptor: descriptor, depth: depth)
      }
      return AnyView(group)
    case .favorites:
      // Favorites is rendered as its own section above; never appears in the user
      // collection list. This case is unreachable in practice.
      return AnyView(EmptyView())
    }
  }

  // MARK: - Selection plumbing

  /// `List(selection:)` accepts any `Hashable` tag, including `nil`. Folder rows have no
  /// tag, so a click on a folder row preserves the prior selection (which is the desired
  /// behavior). This binding mediates so that ad-hoc nil writes from List don't clear
  /// our selection state.
  private var selectionBinding: Binding<LibrarySelection?> {
    Binding(
      get: { selection },
      set: { newValue in
        if let newValue {
          selection = newValue
        }
      }
    )
  }

  // MARK: - Tree fetch

  private var favoritesDescriptor: PhotoCollectionDescriptor {
    tree.first(where: { $0.kind == .favorites })
      ?? PhotoCollectionDescriptor(
        id: "favorites", localIdentifier: nil, title: "Favorites", kind: .favorites,
        pathComponents: [], estimatedAssetCount: nil, children: [])
  }

  private var userCollections: [PhotoCollectionDescriptor] {
    tree.filter { $0.kind != .favorites }
  }

  private func reloadTree() {
    do {
      tree = try photoLibraryManager.fetchCollectionTree()
    } catch {
      tree = []
    }
  }

  private func loadCount(for scope: PhotoFetchScope, descriptorId: String) async {
    do {
      let n = try await photoLibraryManager.cachedCountAssets(in: scope)
      await MainActor.run { countsById[descriptorId] = n }
    } catch {
      // Leave the count as-is on error; the row will render without a count badge.
    }
  }
}

// MARK: - Rows

private struct CollectionRow: View {
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore
  @EnvironmentObject private var exportManager: ExportManager

  let descriptor: PhotoCollectionDescriptor
  let count: Int?
  var depth: Int = 0

  var body: some View {
    HStack(spacing: 8) {
      if depth > 0 {
        // Indent nested albums under folders so the hierarchy reads at a glance.
        Color.clear.frame(width: CGFloat(depth) * 8, height: 1)
      }
      Image(systemName: descriptor.kind == .favorites ? "heart.fill" : "rectangle.stack")
        .foregroundColor(descriptor.kind == .favorites ? .pink : .secondary)
      Text(descriptor.title.isEmpty ? "Untitled" : descriptor.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer()
      countBadge
    }
    .help(tooltip)
  }

  @ViewBuilder
  private var countBadge: some View {
    if let count, count > 0, let placement = matchingPlacement() {
      let summary = collectionExportRecordStore.summary(for: placement)
      switch summary.status {
      case .complete:
        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
      case .partial:
        Text("\(summary.exportedCount)/\(count)").foregroundColor(.orange).font(.caption)
      case .notExported:
        Text("\(count)").foregroundColor(.secondary).font(.caption)
      }
    } else if let count {
      Text("\(count)").foregroundColor(.secondary).font(.caption)
    }
  }

  /// Looks up the persisted placement for this descriptor (if any) so the sidebar can
  /// show partial-export progress before the user starts a new run. Favorites resolves
  /// to the canonical placement id; albums match on `collectionLocalIdentifier`.
  private func matchingPlacement() -> ExportPlacement? {
    switch descriptor.kind {
    case .favorites:
      return collectionExportRecordStore.placement(id: ExportPlacement.favorites().id)
    case .album:
      guard let id = descriptor.localIdentifier else { return nil }
      return collectionExportRecordStore.placements(matching: .album)
        .first(where: { $0.collectionLocalIdentifier == id })
    case .folder:
      return nil
    }
  }

  private var tooltip: String {
    if let count {
      return "\(descriptor.title): \(count) photos"
    }
    return descriptor.title
  }
}

private struct FolderRow: View {
  let descriptor: PhotoCollectionDescriptor
  let depth: Int

  var body: some View {
    HStack(spacing: 8) {
      if depth > 0 {
        Color.clear.frame(width: CGFloat(depth) * 8, height: 1)
      }
      Image(systemName: "folder").foregroundColor(.secondary)
      Text(descriptor.title.isEmpty ? "Untitled folder" : descriptor.title)
        .lineLimit(1)
      Spacer()
    }
  }
}
