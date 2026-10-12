#if DEBUG
import Foundation

/// Launch-argument autopilot for deterministic Atrium screenshots in debug
/// builds — drives the real app (real session, real data) to a known state:
///
///   -AtriumAutoLibrary "Movies"   navigate into the named library ("*" = first movies library)
///   -AtriumAutoMode atrium        force the library view mode without touching settings
///   -AtriumAutoSelect 4           select item index after load
///   -AtriumAutoBay 2              park the camera at a bay after load
///   -AtriumAutoDescend 2          open the selected case, then its first case
///   -AtriumAutoAppearance dark    force appearance regardless of the saved theme
///   -AtriumAutoWindow 1600x1000   resize the main window
///
/// Compiled out of release builds entirely.
enum AtriumAutopilot {
    private static var defaults: UserDefaults { .standard }

    static var isActive: Bool {
        libraryName != nil || forceViewMode != nil || LiveWallAutopilot.isActive
    }

    static var libraryName: String? {
        defaults.string(forKey: "AtriumAutoLibrary")
    }

    static var forceViewMode: LibraryViewMode? {
        defaults.string(forKey: "AtriumAutoMode").flatMap(LibraryViewMode.init(rawValue:))
    }

    static var selectIndex: Int? {
        defaults.object(forKey: "AtriumAutoSelect") == nil
            ? nil : defaults.integer(forKey: "AtriumAutoSelect")
    }

    static var scrollBay: Int? {
        defaults.object(forKey: "AtriumAutoBay") == nil
            ? nil : defaults.integer(forKey: "AtriumAutoBay")
    }

    /// How many shelves down to walk after selecting: 1 lands on a show's
    /// seasons, 2 on the first season's episodes.
    static var descendSteps: Int? {
        defaults.object(forKey: "AtriumAutoDescend") == nil
            ? nil : defaults.integer(forKey: "AtriumAutoDescend")
    }

    static var appearanceOverride: ThemeMode? {
        defaults.string(forKey: "AtriumAutoAppearance").flatMap(ThemeMode.init(rawValue:))
    }

    static var windowSize: CGSize? {
        guard let raw = defaults.string(forKey: "AtriumAutoWindow") else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 200, parts[1] > 200 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// Picks the target library from the loaded user views.
    static func matchLibrary(in views: [BaseItem]) -> BaseItem? {
        guard let name = libraryName else { return nil }
        if name == "*" {
            return views.first { $0.collectionType == "movies" } ?? views.first
        }
        return views.first { $0.displayTitle.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? views.first { $0.displayTitle.localizedCaseInsensitiveContains(name) }
    }
}
#endif
