import SwiftUI

struct AboutView: View {
  private let repoURL = URL(string: "https://github.com/valtteriluomapareto/vibe-icloud-photo-export")!

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 96, height: 96)

      Text("Photo Export")
        .font(.title)
        .fontWeight(.bold)

      Text("Version \(appVersion)")
        .font(.callout)
        .foregroundStyle(.secondary)

      Text("by Valtteri Luoma")
        .font(.callout)

      Link("GitHub", destination: repoURL)
        .font(.callout)
    }
    .padding(40)
    .frame(width: 300)
    .fixedSize()
  }
}
