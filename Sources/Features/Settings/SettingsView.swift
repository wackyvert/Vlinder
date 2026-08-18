import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var serverVersion: String?
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Account") {
                LabeledContent("User", value: app.session?.userName ?? "—")
                LabeledContent("Server", value: app.session?.serverName ?? "—")
                LabeledContent("Address", value: app.session?.serverURL.absoluteString ?? "—")
                if let serverVersion {
                    LabeledContent("Jellyfin", value: serverVersion)
                }
                Button("Sign Out", role: .destructive) {
                    confirmSignOut = true
                }
            }

            Section("Playback") {
                Picker("Streaming quality", selection: $app.settings.maxStreamingBitrate) {
                    ForEach(AppSettings.qualityOptions, id: \.bitrate) { option in
                        Text(option.label).tag(option.bitrate)
                    }
                }
            }

            Section("Live TV") {
                Toggle("Show channel numbers", isOn: $app.settings.showChannelNumbers)
            }

            Section("About") {
                LabeledContent("Vlinder", value: appVersion)
                Text("A native Jellyfin viewer for Mac and iOS, built to Fladder's spec with Tuner's live TV engine.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            guard serverVersion == nil, let client = app.client else { return }
            serverVersion = try? await client.publicSystemInfo().version
        }
        .confirmationDialog(
            "Sign out of \(app.session?.serverName ?? "this server")?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                app.signOut()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
