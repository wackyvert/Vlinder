import Observation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case libraries
    #if os(tvOS)
    case voyage
    #endif
    case liveTV
    case search
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        #if os(tvOS)
        case .voyage: "Voyage"
        #endif
        case .libraries: "Libraries"
        case .liveTV: "Live TV"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        #if os(tvOS)
        case .voyage: "safari"
        #endif
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

    init() {
        #if DEBUG
        // -OpenSection libraries: land on a section directly, so a screenshot
        // harness can photograph every tab on every platform without driving
        // the navigation itself. Same idea on the Mac and the TV.
        if let raw = UserDefaults.standard.string(forKey: "OpenSection"),
           let section = AppSection(rawValue: raw) {
            _selection = State(initialValue: section)
        }
        #if os(tvOS)
        if GuideAutopilot.isActive {
            _selection = State(initialValue: .liveTV)
        }
        #else
        if LiveWallAutopilot.isActive {
            _selection = State(initialValue: .liveTV)
        } else if AtriumAutopilot.isActive {
            _selection = State(initialValue: .libraries)
        }
        #endif
        #endif
    }

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
        SectionStack {
            sectionRoot(for: section)
        }
    }

    @ViewBuilder
    private func sectionRoot(for section: AppSection) -> some View {
        switch section {
        case .home: HomeView()
        #if os(tvOS)
        case .voyage: VoyageView()
        #endif
        case .libraries: LibrariesView()
        case .liveTV: LiveTVView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}

/// Programmatic access to a section's navigation stack, so surfaces that can't
/// use a `NavigationLink` (the Atrium's 3D scene, keyboard activation) still
/// push through the one shared `BaseItem` destination.
@MainActor
@Observable
final class NavigationRouter {
    var path = NavigationPath()

    func open(_ item: BaseItem) {
        path.append(item)
    }
}

private struct NavigationRouterKey: EnvironmentKey {
    static let defaultValue: NavigationRouter? = nil
}

extension EnvironmentValues {
    /// Optional by design: a screen outside a `SectionStack` still renders, it
    /// just has nothing to push onto.
    var navigationRouter: NavigationRouter? {
        get { self[NavigationRouterKey.self] }
        set { self[NavigationRouterKey.self] = newValue }
    }
}

extension View {
    /// Registers the shared BaseItem push destination for a navigation stack.
    /// The router is threaded into each destination explicitly, because a
    /// pushed screen does not inherit environment set outside the stack.
    func withItemDestinations(router: NavigationRouter? = nil) -> some View {
        navigationDestination(for: BaseItem.self) { item in
            ItemDetailView(item: item)
                .environment(\.navigationRouter, router)
        }
    }
}

/// One navigation stack per section, owning its path and exposing it as a router.
private struct SectionStack<Content: View>: View {
    @State private var router = NavigationRouter()
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack(path: $router.path) {
            content()
                .withItemDestinations(router: router)
                .environment(\.navigationRouter, router)
        }
    }
}
