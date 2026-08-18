import SwiftUI
import Observation

/// Grid of the user's library views; tapping one opens the paged item grid.
@MainActor
@Observable
final class LibrariesModel {
    private(set) var views: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    func load(client: JellyfinClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            views = try await client.userViews()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LibrariesView: View {
    @Environment(AppState.self) private var app
    @State private var model = LibrariesModel()

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        Group {
            if let error = model.errorMessage, !model.hasLoaded {
                ErrorRetryView(message: error) {
                    Task { await reload() }
                }
            } else if !model.hasLoaded {
                CenteredProgressView()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.views) { view in
                            libraryCard(view)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Libraries")
        .task {
            if !model.hasLoaded {
                await reload()
            }
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard let client = app.client else { return }
        await model.load(client: client)
    }

    private func libraryCard(_ view: BaseItem) -> some View {
        NavigationLink(value: view) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: app.client?.imageURL(
                    itemId: view.id, type: .primary,
                    tag: view.imageTags?["Primary"], maxWidth: 640))
                    .aspectRatio(16 / 9, contentMode: .fill)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center, endPoint: .bottom)
                Text(view.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
