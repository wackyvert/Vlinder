import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case libraries
    case liveTV
    case search
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .libraries: "Libraries"
        case .liveTV: "Live TV"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .libraries: "square.stack"
        case .liveTV: "tv"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

/// Adaptive main navigation: bottom tabs on iPhone/iPad, sidebar on Mac —
/// mirrors Fladder's phone bottom-bar / desktop rail split.
struct MainView: View {
    @State private var selection: AppSection = .home

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            sectionStack(for: selection)
                .id(selection)
        }
        #else
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                sectionStack(for: section)
                    .tabItem { Label(section.title, systemImage: section.icon) }
                    .tag(section)
            }
        }
        #endif
    }

    @ViewBuilder
    private func sectionStack(for section: AppSection) -> some View {
        NavigationStack {
            sectionRoot(for: section)
                .withItemDestinations()
        }
    }

    @ViewBuilder
    private func sectionRoot(for section: AppSection) -> some View {
        switch section {
        case .home: HomeView()
        case .libraries: LibrariesView()
        case .liveTV: LiveTVView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}

extension View {
    /// Registers the shared BaseItem push destination for a navigation stack.
    func withItemDestinations() -> some View {
        navigationDestination(for: BaseItem.self) { item in
            ItemDetailView(item: item)
        }
    }
}
