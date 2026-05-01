import AppKit
import SwiftUI

/// View modifier that surfaces the corruption-recovery alert for both record stores.
///
/// Either store can independently transition to `.failed` when its snapshot fails to
/// decode (see `JSONLRecordFile.load()`). The store keeps the corrupt snapshot on disk
/// untouched and only renames it (`<name>.broken-<ISO8601>`) when the user explicitly
/// chooses Reset, so the user never silently loses their record history. This host
/// presents a single alert at a time; if both stores are failed, the timeline store's
/// alert shows first and the collection store's alert follows after the user acks it.
///
/// Buttons match the plan's recovery contract: **Reset** runs the deferred rename and
/// reinitializes the failed store, **Quit** terminates the app (the user can investigate
/// the broken file by hand before relaunching), and **Cancel** dismisses the alert
/// without touching disk so the user can choose later.
struct RecordStoreAlertHost: ViewModifier {
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore

  func body(content: Content) -> some View {
    content
      .alert(
        "Timeline Records Could Not Be Read",
        isPresented: timelineAlertBinding,
        actions: {
          Button("Reset") { exportRecordStore.resetToEmpty() }
          Button("Quit") { NSApplication.shared.terminate(nil) }
          Button("Cancel", role: .cancel) {}
        },
        message: {
          Text(
            "The timeline export records file is corrupt or unreadable. Reset will move "
              + "the broken file aside and start fresh — your exported files on disk are "
              + "untouched. The next export run will rebuild the records.")
        }
      )
      .alert(
        "Collection Records Could Not Be Read",
        isPresented: collectionAlertBinding,
        actions: {
          Button("Reset") { collectionExportRecordStore.resetToEmpty() }
          Button("Quit") { NSApplication.shared.terminate(nil) }
          Button("Cancel", role: .cancel) {}
        },
        message: {
          Text(
            "The collection export records file is corrupt or unreadable. Reset will move "
              + "the broken file aside and start fresh — your exported files on disk are "
              + "untouched. The next collection export will rebuild the records.")
        }
      )
  }

  private var timelineAlertBinding: Binding<Bool> {
    Binding(
      get: { exportRecordStore.state == .failed },
      set: { _ in }  // dismissal handled by the actions above
    )
  }

  private var collectionAlertBinding: Binding<Bool> {
    Binding(
      get: {
        // Only show the collection alert when the timeline alert isn't already active so
        // SwiftUI doesn't try to present two alerts on the same view at once.
        exportRecordStore.state != .failed
          && collectionExportRecordStore.state == .failed
      },
      set: { _ in }
    )
  }
}

extension View {
  /// Attaches the record-store corruption-recovery alert host. See
  /// `RecordStoreAlertHost` for behavior.
  func recordStoreAlertHost() -> some View {
    modifier(RecordStoreAlertHost())
  }
}
