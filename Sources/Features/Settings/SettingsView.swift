import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(GuideModel.self) private var guide
    @State private var serverVersion: String?
    @State private var confirmSignOut = false
    @State private var lineupFeedback: String?
    @State private var isRefreshingLineup = false
    @State private var showAddAccount = false
    @State private var showSetPasscode = false
    @State private var localURLText = ""

    var body: some View {
        @Bindable var app = app
        Form {
            accountSection
            switchAccountSection

            Section("Appearance") {
                Picker("Theme", selection: $app.settings.theme) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Poster size", selection: $app.settings.posterScale) {
                    ForEach(PosterScale.allCases) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                Toggle("Home banner", isOn: $app.settings.showHomeBanner)
            }

            Section("Playback") {
                Picker("Streaming quality", selection: $app.settings.maxStreamingBitrate) {
                    ForEach(AppSettings.qualityOptions, id: \.bitrate) { option in
                        Text(option.label).tag(option.bitrate)
                    }
                }
            }

            liveTVSection
            securitySection

            Section("About") {
                LabeledContent("Vlinder", value: appVersion)
                LabeledContent("Built", value: buildDate)
                Text("A native Jellyfin viewer for Mac and iOS, built to Fladder's spec with Tuner's live TV engine.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            localURLText = app.session?.localURL?.absoluteString ?? ""
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
        .sheet(isPresented: $showAddAccount) {
            NavigationStack {
                ConnectView(showsSavedAccounts: false)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAddAccount = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showSetPasscode) {
            SetPasscodeSheet()
        }
        .onChange(of: app.phase) {
            // Adding an account signs it in; close the sheet when that happens.
            if showAddAccount { showAddAccount = false }
        }
        .onChange(of: app.session?.id) {
            localURLText = app.session?.localURL?.absoluteString ?? ""
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            LabeledContent("User", value: app.session?.userName ?? "—")
            LabeledContent("Server", value: app.session?.serverName ?? "—")
            LabeledContent("Address", value: app.session?.serverURL.absoluteString ?? "—")
            if let serverVersion {
                LabeledContent("Jellyfin", value: serverVersion)
            }
            HStack {
                TextField("Local (LAN) address override", text: $localURLText)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Button("Apply") {
                    applyLocalURL()
                }
                .disabled(localURLText == (app.session?.localURL?.absoluteString ?? ""))
            }
            Button("Sign Out", role: .destructive) {
                confirmSignOut = true
            }
        } header: {
            Text("Account")
        } footer: {
            Text("When the local address responds, Vlinder streams over the LAN instead of the public address.")
        }
    }

    private func applyLocalURL() {
        let trimmed = localURLText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            app.setLocalURL(nil)
        } else if let url = try? JellyfinClient.normalizeServerInput(trimmed) {
            localURLText = url.absoluteString
            app.setLocalURL(url)
        }
    }

    @ViewBuilder
    private var switchAccountSection: some View {
        Section("Accounts") {
            ForEach(app.accounts) { account in
                Button {
                    app.switchTo(accountId: account.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.userName ?? "User")
                                .foregroundStyle(.primary)
                            Text(account.serverName ?? account.serverURL.host() ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if account.id == app.session?.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove account", role: .destructive) {
                        app.removeAccount(accountId: account.id)
                    }
                }
            }
            Button {
                showAddAccount = true
            } label: {
                Label("Add account", systemImage: "plus")
            }
        }
    }

    // MARK: - Live TV

    private var liveTVSection: some View {
        @Bindable var app = app
        return Section {
            Toggle("Show channel numbers", isOn: $app.settings.showChannelNumbers)
            TextField("Lineup URL (M3U or lineup JSON)", text: $app.settings.lineupUrl)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            HStack {
                Button("Refresh lineup") {
                    refreshLineup()
                }
                .disabled(isRefreshingLineup || app.settings.lineupUrl.isEmpty)
                if isRefreshingLineup {
                    ProgressView().controlSize(.small)
                } else if let lineupFeedback {
                    Text(lineupFeedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Live TV")
        } footer: {
            Text("A lineup URL groups the TV guide into categories (e.g. an Xfinity relay or any M3U with group-title tags). Grouping survives the source being unreachable via an on-disk cache.")
        }
    }

    private func refreshLineup() {
        isRefreshingLineup = true
        lineupFeedback = nil
        Task {
            let count = await guide.refreshLineup(urlString: app.settings.lineupUrl, force: true)
            isRefreshingLineup = false
            if let count {
                lineupFeedback = "\(count) group\(count == 1 ? "" : "s")"
            } else {
                lineupFeedback = "No lineup found"
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            if app.settings.appLockEnabled {
                Button("Turn off app lock", role: .destructive) {
                    app.disableAppLock()
                }
            } else {
                Button("Set a passcode…") {
                    showSetPasscode = true
                }
            }
        } header: {
            Text("Security")
        } footer: {
            Text("With app lock on, Vlinder asks for the passcode at launch.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Executable modification date — an unambiguous "which build am I running".
    private var buildDate: String {
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date
        else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
