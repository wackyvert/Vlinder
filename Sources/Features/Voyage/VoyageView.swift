#if os(tvOS)
import SwiftUI

/// A remote-driven journey through a library, sharing the normal detail route.
struct VoyageView: View {
    @Environment(AppState.self) private var app
    @State private var libraries: [BaseItem] = []
    @State private var selectedID = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.10, blue: 0.17).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    Text("Voyage").font(.system(size: 46, weight: .light, design: .rounded))
                    Text("Find your next escape").font(.system(size: 23)).foregroundStyle(.secondary)
                    Spacer()
                    if !libraries.isEmpty {
                        Picker("Library", selection: $selectedID) {
                            ForEach(libraries) { library in
                                Text(library.displayTitle).tag(library.id)
                            }
                        }.frame(maxWidth: 400)
                    }
                }.padding(.horizontal, 70)
                if let library = libraries.first(where: { $0.id == selectedID }) {
                    VoyageLibraryView(container: library).id(library.id)
                } else {
                    Spacer()
                    if loading { ProgressView("Opening your libraries…") }
                    else if let error {
                        ContentUnavailableView {
                            Label("Couldn’t open Voyage", systemImage: "wifi.exclamationmark")
                        } description: { Text(error) } actions: {
                            Button("Try again") { Task { await load() } }
                        }
                    } else {
                        ContentUnavailableView("No movie or TV libraries", systemImage: "film",
                            description: Text("Add a movie or TV library in Jellyfin to begin your voyage."))
                    }
                    Spacer()
                }
            }.padding(.top, 30)
        }
        .task(id: app.session?.id) { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            libraries = try await client.userViews().filter {
                $0.collectionType == "movies" || $0.collectionType == "tvshows"
            }
            if !libraries.contains(where: { $0.id == selectedID }) {
                selectedID = libraries.first?.id ?? ""
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct VoyageLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.navigationRouter) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: LibraryGridModel
    @State private var index = 0
    @FocusState private var islandFocused: Bool

    init(container: BaseItem) {
        _model = State(initialValue: LibraryGridModel(container: container))
    }

    private var selected: BaseItem? {
        model.items.indices.contains(index) ? model.items[index] : nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VoyageSceneView(items: model.items, index: index, client: app.client,
                            reduceMotion: reduceMotion, focused: islandFocused)
                .allowsHitTesting(false).accessibilityHidden(true).ignoresSafeArea(edges: [.horizontal, .bottom])
            LinearGradient(stops: [.init(color: .clear, location: 0.46),
                                   .init(color: Color(red: 0.035, green: 0.10, blue: 0.17).opacity(0.94), location: 0.77),
                                   .init(color: Color(red: 0.035, green: 0.10, blue: 0.17), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: [.horizontal, .bottom]).allowsHitTesting(false)
            if let item = selected {
                VStack(spacing: 12) {
                    Spacer()
                    Text(item.displayTitle)
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .lineLimit(2).multilineTextAlignment(.center)
                    Text([item.yearLabel, item.runtimeLabel, item.officialRating].compactMap { $0 }.joined(separator: "  •  "))
                        .font(.system(size: 23)).foregroundStyle(.secondary)
                    HStack(spacing: 26) {
                        Image(systemName: "chevron.left")
                            .opacity(index == 0 ? 0.2 : 1).accessibilityHidden(true)
                        Button("Explore title") { router?.open(item) }
                            .focused($islandFocused)
                            .accessibilityLabel("Explore \(item.displayTitle)")
                            .onMoveCommand { direction in
                                if direction == .left || direction == .right {
                                    move(direction == .left ? -1 : 1)
                                    // tvOS also proposes a focus move to the neighboring
                                    // control. Keep directional browsing on this anchor.
                                    Task { @MainActor in
                                        await Task.yield()
                                        islandFocused = true
                                    }
                                }
                            }
                        Image(systemName: "chevron.right")
                            .opacity(index + 1 >= model.items.count ? 0.2 : 1).accessibilityHidden(true)
                    }.padding(.top, 14)
                    HStack(spacing: 18) {
                        Text("\(index + 1) of \(model.total ?? model.items.count)")
                        if model.isLoading { ProgressView().scaleEffect(0.65) }
                        Text("Swipe left or right to travel")
                    }.font(.system(size: 20)).foregroundStyle(.secondary).padding(.top, 6)
                    NavigationLink("Poster grid") { LibraryGridView(container: model.container) }
                        .font(.system(size: 22)).buttonStyle(.borderless)
                }.padding(.horizontal, 100).padding(.bottom, 38)
            } else if model.isLoading {
                ProgressView("Charting your library…").frame(maxHeight: .infinity)
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t load this library", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try again") { Task { await reload() } }
                }
            } else {
                ContentUnavailableView("This library is empty", systemImage: "film",
                                       description: Text("Choose another library above."))
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        guard let client = app.client else { return }
        await model.reload(client: client)
        index = min(index, max(0, model.items.count - 1))
        islandFocused = true
    }

    private func move(_ delta: Int) {
        index = min(max(0, index + delta), max(0, model.items.count - 1))
        if let item = selected, let client = app.client {
            model.loadMoreIfNeeded(current: item, client: client)
        }
    }
}
#endif
