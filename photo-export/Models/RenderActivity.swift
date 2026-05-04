import Foundation

/// Toolbar-visible state for an in-progress render. `nil` while no render is
/// active. Surfaces as a `(downloading…)` / `(rendering…)` suffix on the
/// current asset filename so a long render is not perceived as a hang.
enum RenderActivity: Sendable, Equatable {
  case downloading
  case rendering
}
