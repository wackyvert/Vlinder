import SwiftUI
import Observation

@MainActor
@Observable
final class ConnectModel {
    enum Phase: Equatable {
        case enterServer
        case probing
        case chooseMethod
        case quickConnect(code: String?)
        case password
    }

    var phase: Phase = .enterServer
    var serverInput: String = UserDefaults.standard.string(forKey: "vlinder.lastServer") ?? ""
    var errorMessage: String?
    var hint: String?

    var username = ""
    var password = ""
    var isAuthenticating = false

    private(set) var serverName: String?
    private(set) var quickConnectAvailable = false
    @ObservationIgnored private(set) var client: JellyfinClient?
    @ObservationIgnored private var quickConnectTask: Task<Void, Never>?

    // MARK: - Server probe

    func connectToServer() async {
        errorMessage = nil
        phase = .probing
        do {
            let url = try JellyfinClient.normalizeServerInput(serverInput)
            let client = JellyfinClient(serverURL: url, deviceId: DeviceID.persistent())
            let info = try await client.publicSystemInfo()
            self.client = client
            self.serverName = info.serverName
            UserDefaults.standard.set(serverInput, forKey: "vlinder.lastServer")
            self.quickConnectAvailable = (try? await client.quickConnectEnabled()) ?? false
            if quickConnectAvailable {
                startQuickConnect()
            } else {
                phase = .password
            }
        } catch {
            // If the user typed no scheme we defaulted to https; retry once over http
            // for plain-HTTP LAN servers before giving up.
            if !serverInput.contains("://"),
               let httpURL = try? JellyfinClient.normalizeServerInput("http://" + serverInput) {
                let fallback = JellyfinClient(serverURL: httpURL, deviceId: DeviceID.persistent())
                if let info = try? await fallback.publicSystemInfo() {
                    self.client = fallback
                    self.serverName = info.serverName
                    UserDefaults.standard.set(serverInput, forKey: "vlinder.lastServer")
                    self.quickConnectAvailable = (try? await fallback.quickConnectEnabled()) ?? false
                    if quickConnectAvailable {
                        startQuickConnect()
                    } else {
                        phase = .password
                    }
                    return
                }
            }
            errorMessage = error.localizedDescription
            phase = .enterServer
        }
    }

    // MARK: - Quick Connect (polling flow ported from Tuner's runQuickConnectFlow)

    func startQuickConnect() {
        guard let client else { return }
        hint = nil
        errorMessage = nil
        phase = .quickConnect(code: nil)
        quickConnectTask?.cancel()
        quickConnectTask = Task { [weak self] in
            await self?.runQuickConnectLoop(client: client)
        }
    }

    private func runQuickConnectLoop(client: JellyfinClient) async {
        while !Task.isCancelled {
            do {
                let initiated = try await client.quickConnectInitiate()
                guard let secret = initiated.secret else { throw JellyfinError.quickConnectExpired }
                phase = .quickConnect(code: initiated.code)
                hint = nil

                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let state = try await client.quickConnectState(secret: secret)
                    if state.authenticated == true {
                        let result = try await client.authenticateWithQuickConnect(secret: secret)
                        try complete(with: result, client: client)
                        return
                    }
                }
                return
            } catch is CancellationError {
                return
            } catch JellyfinError.quickConnectDisabled {
                quickConnectAvailable = false
                phase = .password
                return
            } catch {
                guard !Task.isCancelled else { return }
                hint = "Connection hiccup — getting a new code…"
                phase = .quickConnect(code: nil)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
    }

    // MARK: - Password sign-in

    func signInWithPassword() async {
        guard let client else { return }
        errorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let result = try await client.authenticateByName(username: username, password: password)
            try complete(with: result, client: client)
        } catch JellyfinError.http(let status, _) where status == 401 {
            errorMessage = "Wrong username or password."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Completion

    var onSignedIn: ((Session) -> Void)?

    private func complete(with result: AuthenticationResult, client: JellyfinClient) throws {
        guard let token = result.accessToken, let user = result.user else {
            throw JellyfinError.decoding("authentication result missing token or user")
        }
        cancelQuickConnect()
        let session = Session(
            serverURL: client.serverURL,
            serverName: serverName,
            userId: user.id,
            userName: user.name,
            accessToken: token,
            deviceId: client.deviceId)
        onSignedIn?(session)
    }

    func backToServerEntry() {
        cancelQuickConnect()
        client = nil
        phase = .enterServer
        errorMessage = nil
        hint = nil
    }
}

struct ConnectView: View {
    @Environment(AppState.self) private var app
    @State private var model = ConnectModel()
    @FocusState private var serverFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                header
                card
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear {
            model.onSignedIn = { session in
                app.adopt(session: session)
            }
        }
        .onDisappear { model.cancelQuickConnect() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text("Vlinder")
                .font(.largeTitle.weight(.bold))
            Text(subtitleText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitleText: String {
        if let name = model.serverName, model.phase != .enterServer, model.phase != .probing {
            return name
        }
        return "Connect to your Jellyfin server"
    }

    @ViewBuilder
    private var card: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .enterServer:
                serverEntry
            case .probing:
                ProgressView("Contacting server…")
                    .padding(.vertical, 20)
            case .quickConnect(let code):
                quickConnect(code: code)
            case .password, .chooseMethod:
                passwordForm
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var serverEntry: some View {
        VStack(spacing: 14) {
            TextField("jellyfin.example.com or 192.168.1.20:8096", text: $model.serverInput)
                .textFieldStyle(.roundedBorder)
                .focused($serverFieldFocused)
                .onSubmit { Task { await model.connectToServer() } }
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Button {
                Task { await model.connectToServer() }
            } label: {
                Text("Connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.serverInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { serverFieldFocused = true }
    }

    @ViewBuilder
    private func quickConnect(code: String?) -> some View {
        VStack(spacing: 14) {
            Text("Quick Connect")
                .font(.headline)
            if let code {
                Text(code)
                    .font(.system(size: 42, weight: .bold, design: .monospaced))
                    .kerning(6)
                    .textSelection(.enabled)
                Text("Enter this code in Jellyfin on another device:\nSettings → Quick Connect")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView("Getting a code…")
                    .padding(.vertical, 12)
            }
            if let hint = model.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button("Use password instead") {
                    model.cancelQuickConnect()
                    model.phase = .password
                }
                Spacer()
                Button("Back") { model.backToServerEntry() }
            }
            .font(.callout)
        }
    }

    private var passwordForm: some View {
        VStack(spacing: 14) {
            TextField("Username", text: $model.username)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            SecureField("Password", text: $model.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.signInWithPassword() } }
            Button {
                Task { await model.signInWithPassword() }
            } label: {
                Group {
                    if model.isAuthenticating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.username.isEmpty || model.isAuthenticating)
            HStack {
                if model.quickConnectAvailable {
                    Button("Use Quick Connect") { model.startQuickConnect() }
                }
                Spacer()
                Button("Back") { model.backToServerEntry() }
            }
            .font(.callout)
        }
    }
}
