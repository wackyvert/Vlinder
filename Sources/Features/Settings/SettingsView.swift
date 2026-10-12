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

            SettingsSection("Appearance") {
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

            SettingsSection("Playback") {
                Picker("Streaming quality", selection: $app.settings.maxStreamingBitrate) {
                    ForEach(AppSettings.qualityOptions, id: \.bitrate) { option in
                        Text(option.label).tag(option.bitrate)
                    }
                }
            }

            liveTVSection
            securitySection

            SettingsSection("About") {
                LabeledContent("Vlinder", value: appVersion)
                LabeledContent("Built", value: buildDate)
                Text("A native Jellyfin viewer for Mac and iOS, built to Fladder's spec with Tuner's live TV engine.")
                    #if os(tvOS)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.8))
                    #else
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    #endif
            }
        }
        .formStyle(.grouped)
        #if os(tvOS)
        // The Mac's grouped Form stretched to 1757pt puts 1600px of plate
        // between a label and its value. Constrain it to the single-column
        // card width Connect already uses, centred (which also clears the
        // 90/60pt title-safe inset), and drop the centred 110pt title: the
        // tab bar already says "Settings" and the title cost half the rows.
        .frame(maxWidth: TenFoot.cardWidth)
        .frame(maxWidth: .infinity)
        .font(.title3)
        .labeledContentStyle(TVLabeledContentStyle())
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle("Settings")
        #endif
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
            #if os(tvOS)
            // tvOS shows no navigation bar in a sheet, so the toolbar Cancel
            // would be unreachable; put it in the content where focus can go.
            VStack(spacing: 0) {
                ConnectView(showsSavedAccounts: false)
                Button("Cancel") { showAddAccount = false }
                    .padding(.bottom, 40)
            }
            #else
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
        SettingsSection("Account", footer: "When the local address responds, Vlinder streams over the LAN instead of the public address.") {
            LabeledContent("User", value: app.session?.userName ?? "—")
            LabeledContent("Server", value: app.session?.serverName ?? "—")
            LabeledContent("Address", value: app.session?.serverURL.absoluteString ?? "—")
            if let serverVersion {
                LabeledContent("Jellyfin", value: serverVersion)
            }
            #if os(tvOS)
            // Two focusable controls sharing one list row fight over the
            // focus platter on tvOS; give the field and Apply a row each.
            TextField("Local (LAN) address override", text: $localURLText)
            // Not disabled when unchanged: tvOS dims a disabled row to ~2.5:1,
            // and re-applying the same address is a harmless no-op.
            Button("Apply local address") {
                applyLocalURL()
            }
            #else
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
            #endif
            Button("Sign Out", role: .destructive) {
                confirmSignOut = true
            }
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
        SettingsSection("Accounts") {
            ForEach(app.accounts) { account in
                Button {
                    app.switchTo(accountId: account.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.userName ?? "User")
                                .foregroundStyle(.primary)
                            Text(account.serverName ?? account.serverURL.host() ?? "")
                                .font(TenFoot.isTV ? .body : .caption)
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
                .rowButtonStyle()
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
        return SettingsSection("Live TV", footer: "A lineup URL groups the TV guide into categories (e.g. an Xfinity relay or any M3U with group-title tags). Grouping survives the source being unreachable via an on-disk cache.") {
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
                        .font(TenFoot.isTV ? .body : .footnote)
                        .foregroundStyle(.secondary)
                }
            }
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
        SettingsSection("Security", footer: "With app lock on, Vlinder asks for the passcode at launch.") {
            if app.settings.appLockEnabled {
                Button("Turn off app lock", role: .destructive) {
                    app.disableAppLock()
                }
            } else {
                Button("Set a passcode…") {
                    showSetPasscode = true
                }
            }
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

/// A titled settings section. The Mac keeps the Form's own header and footer.
/// On tvOS the Form dims header and footer text to ~2.5:1 whatever style they
/// carry, so they become plain, plate-less rows inside the section: body type
/// at primary for the title, callout at high-contrast grey for the note.
private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        #if os(tvOS)
        Section {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .listRowBackground(Color.clear)
                .padding(.top, 8)
            // tvOS list rhythm is ~100pt a row where the Form gives the Mac's
            // 66; the padding lands on each row of the group. (A Form-wide
            // `defaultMinListRowHeight` would also stretch the title rows.)
            content()
                .padding(.vertical, 17)
            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.8))
                    .listRowBackground(Color.clear)
                    .padding(.bottom, 8)
            }
        }
        #else
        Section {
            content()
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
        #endif
    }
}

#if os(tvOS)
/// Label and value in two left-aligned columns instead of pinned to opposite
/// edges of the plate: the eye reads "User  jake" as one line rather than
/// hunting across the row, and the value is primary so it clears 4.5:1.
private struct TVLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            configuration.label
                .frame(width: 300, alignment: .leading)
            configuration.content
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
#endif
