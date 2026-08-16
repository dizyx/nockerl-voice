import Foundation

/// The sections of the unified dashboard window.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case transcription
    case vocabulary
    case styles
    case history
    case settings

    var id: String { rawValue }

    /// The sections shown in the main sidebar nav list. Settings is reached via the
    /// cog pinned at the bottom of the sidebar, so it is excluded here.
    static let navItems: [AppSection] = [.dashboard, .transcription, .vocabulary, .styles, .history]

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .transcription: return "Transcription"
        case .vocabulary: return "Vocabulary"
        case .styles: return "Styles"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .transcription: return "waveform"
        case .vocabulary: return "text.book.closed"
        case .styles: return "text.bubble"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

/// In-app link targets used by text that needs to point at a pane.
///
/// Deliberately NOT nested inside `DashboardRouter`: the router is `@MainActor`, and this
/// constant is read from non-isolated code that builds error strings. Keeping it on a plain
/// namespace means that read carries no actor requirement.
enum DashboardLink {
    /// A custom scheme, never a web address: it must resolve inside the app and must never
    /// open a browser.
    static let scheme = "nockerl"
    static let transcriptionSettings = "\(scheme)://section/transcription"
}

/// Shared selection so the menu bar can open the dashboard to a specific section.
@MainActor
final class DashboardRouter: ObservableObject {
    static let shared = DashboardRouter()
    @Published var section: AppSection = .dashboard

    /// Resolve an in-app link. Returns true when the URL was ours and was handled, so a
    /// caller can pass anything else on to the system unchanged.
    ///
    /// This only moves the selection inside an ALREADY VISIBLE window. It never opens a
    /// window and never activates the app, because the only place these links are rendered is
    /// a History row the user is already looking at.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == DashboardLink.scheme, url.host == "section" else { return false }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let target = AppSection(rawValue: name) else { return false }
        section = target
        return true
    }
}
