import AppKit
import NockerlDesign
import SwiftUI

/// The unified Nockerl Voice window: a Finder-style layout.
///
/// Design (after a long fight with NavigationSplitView's opaque sidebar + title
/// strip): there is NO title bar (`.windowStyle(.hiddenTitleBar)` on the scene).
/// One `NockerlFacetedBackground` fills the entire window, edge to edge, under the
/// traffic lights. A translucent sidebar floats on top of it (the geometric pattern
/// shows through), and the selected page fills the rest, full-bleed, over the same
/// background. We deliberately do NOT use NavigationSplitView here: its sidebar
/// paints an opaque system material you cannot see an in-app background through,
/// and its `.balanced` style ejects the traffic lights into a separate strip.
struct DashboardView: View {
    @ObservedObject private var router = DashboardRouter.shared
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var systemAppearance = NockerlSystemAppearance()
    /// Freezes the faceted background (0 CPU) whenever the app has NO visible window:
    /// occluded behind another app, or minimized. Driven by NSApp.occlusionState (v1.14.0
    /// `paused` param). The 20fps cap covers the visible case; this covers the hidden case.
    @State private var backgroundPaused = false

    /// Ratified sidebar width: `NockerlSize.containerXs` (216pt, the exact value
    /// this sidebar already used).
    private let sidebarWidth: CGFloat = NockerlSize.containerXs

    /// Resolve the setting to a concrete scheme so "System" reliably follows the OS
    /// (passing nil to .preferredColorScheme left the window stuck on its last mode).
    private var effectiveScheme: ColorScheme {
        switch settings.appearance {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemAppearance.colorScheme
        }
    }

    /// The design-system palette resolved for the effective scheme: deterministic
    /// (no environment round-trip), matching what `.preferredColorScheme` shows.
    private var palette: NockerlPalette { NockerlPalette.resolve(effectiveScheme) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // One geometric background behind EVERYTHING, edge to edge.
            NockerlFacetedBackground(paused: backgroundPaused)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Flow up under the (hidden) title bar so the background and sidebar
            // run to the very top, with the traffic lights floating over them.
            .ignoresSafeArea(.container, edges: .top)
        }
        // FIXED, not minimum. The scene pins the window to its content size, so this is
        // what actually sets the window's dimensions. A minimum let the window grow without
        // limit, which is the defect this closes. Matches the scene's `.defaultSize`.
        .frame(width: 880, height: 600)
        .tint(palette.accentPrimary)
        // Concrete scheme (System resolved to the OS) so the content reliably
        // re-renders on switch: .preferredColorScheme(nil) left the window stuck.
        .preferredColorScheme(effectiveScheme)
        // Pause the faceted background (0 CPU) when no Voice window is visible: occluded
        // behind another app or minimized. NSApp.occlusionState flips on this notification;
        // `.visible` present == the app has at least one on-screen window. (v1.14.0.)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeOcclusionStateNotification)) { _ in
            backgroundPaused = !NSApp.occlusionState.contains(.visible)
        }
        .onAppear { backgroundPaused = !NSApp.occlusionState.contains(.visible) }
    }

    /// Translucent sidebar floating over the geometric background (Finder-like).
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Brand, pushed clear of the traffic lights (they float over top-left).
            // The canonical lockup: mark + "Nockerl" thin + "Voice" in the cyan
            // accent, the ONE brand lockup on every surface.
            HStack(spacing: 0) {
                // The framework lockup, leading with the Voice mark instead of the house
                // mark. This replaces a hand-rolled reproduction of the lockup: the
                // typography, the 0.9x wordmark ratio and both gaps are the component's
                // again, so they cannot drift from canon.
                //
                // BOTH sizes are 28 and they must match. A supplied mark owns its own
                // sizing (the component's `size` drives the wordmark and the gaps, not the
                // mark), so passing the mark unsized would render it at the HUD's 16pt
                // default and leave it visibly small beside a 28pt wordmark. Change one and
                // change the other.
                NockerlLockup(
                    product: "Voice",
                    size: 28,
                    mark: NockerlProductMark(.voice, size: 28)
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NockerlSpace.space4)
            .padding(.top, 50)
            .padding(.bottom, NockerlSpace.space4)

            ForEach(AppSection.navItems) { section in
                NockerlNavRow(
                    section.title,
                    selected: router.section == section,
                    action: { router.section = section }
                ) {
                    Image(systemName: section.icon)
                }
                .padding(.horizontal, NockerlSpace.space2)
            }

            // Directly under the nav items, so an update reads as the next thing in the
            // list rather than as chrome. Renders nothing at all unless there is news, so
            // the sidebar is unchanged on almost every launch.
            UpdateNavRow()

            Spacer(minLength: 0)

            // Settings cog, pinned to the bottom of the panel.
            NockerlNavRow(
                AppSection.settings.title,
                selected: router.section == .settings,
                action: { router.section = .settings }
            ) {
                Image(systemName: AppSection.settings.icon)
            }
            .padding(.horizontal, NockerlSpace.space2)
            .padding(.bottom, 14)
        }
        .frame(width: sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        // A light dark tint ONLY (no frosting material): the full-window facet
        // background reads clearly through the panel, so the geometric design runs
        // edge-to-edge behind the nav and the sidebar floats over it. Just opaque
        // enough to keep the nav text legible. Kept at canvas@0.3: the
        // `surfaceTranslucencySidebar` token (chrome@0.55) exists but would visibly
        // thicken the veil over the facet field.
        .background(palette.canvas.opacity(0.3))
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.cardHairline).frame(width: 1)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.section {
        case .dashboard: DashboardSection()
        case .transcription: TranscriptionSection()
        case .vocabulary: VocabularyView()
        case .styles: StylesSection()
        case .history: HistorySection()
        case .settings: AppSettingsSection()
        }
    }
}

// The sidebar nav rows are `NockerlNavRow`, the framework component carrying
// the ratified selected-state recipe: chrome-plane inks (onChromeMuted ->
// onChrome on hover), accentPrimarySoft selected wash, thin accent selected
// border @0.45, control radius, minHeight 40 + 12/8/8 metrics, press-scale
// 0.985, macOS focus-disabled.

