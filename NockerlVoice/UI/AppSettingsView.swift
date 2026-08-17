import NockerlDesign
import SwiftUI

/// App-wide settings: reached via the cog pinned at the bottom of the sidebar.
/// Holds preferences that affect the whole app (appearance, startup), as opposed
/// to the per-feature Transcription / Vocabulary panes.
struct AppSettingsSection: View {
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var micMonitor = MicMonitor()
    @State private var launchAtLogin = SettingsStore.shared.launchAtLogin
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: NockerlSpace.space4) {
                SectionTitle(.settings)

                // The setting groups live inside the recessed container well: the same
                // `.nockerlWell(.container)` grammar as Styles/Vocabulary.
                //
                // The well HUGS its content (no `maxHeight: .infinity`). Styles and
                // Vocabulary can fill the pane because their content genuinely grows; this
                // screen is three short rows, and an infinite-height VStack hands the slack
                // to its flexible children, which stretched the Appearance segmented
                // control to fill the window. Hugging keeps every control its natural size.
                VStack(alignment: .leading, spacing: NockerlSpace.space3) {
                    NockerlFormSection("Appearance") {
                        // Same options/order/labels; onSelect performs the exact same
                        // settings.appearance write the Binding did: didSet persists
                        // immediately, and propagation stays reactive (DashboardView's
                        // .preferredColorScheme reads this @Published value).
                        NockerlSegmented(
                            options: AppAppearance.allCases,
                            selected: settings.appearance,
                            label: { $0.label },
                            onSelect: { settings.appearance = $0 }
                        )
                    }

                    NockerlFormSection("Microphone") {
                        // The framework NockerlSelect: the same
                        // dropdown the Cloud pickers use; one language across the app.
                        NockerlSelect(
                            options: micOptions,
                            selection: $settings.selectedMicUID,
                            placeholder: "System Default"
                        )
                    }

                    NockerlFormSection("Startup") {
                        HStack(spacing: 6) {
                            Text("Launch at login").foregroundStyle(palette.onCard)
                            NockerlInfoTip(text: "Start Nockerl Voice automatically when you log in, so the dictation hotkey is always ready.")
                            Spacer()
                            // Native Toggle keeps switch role/value/
                            // keyboard; only the STYLE changes. SACRED binding chain
                            // preserved verbatim: local mirror → settings.launchAtLogin
                            // write (SMAppService register/unregister, silent catch) →
                            // read-back, so a failed grant snaps the switch back.
                            Toggle("", isOn: $launchAtLogin)
                                .labelsHidden()
                                .toggleStyle(.nockerl)
                                .onChange(of: launchAtLogin) { _, newValue in
                                    settings.launchAtLogin = newValue
                                    launchAtLogin = settings.launchAtLogin
                                }
                        }
                    }

                    NockerlFormSection("Updates") {
                        HStack(spacing: 6) {
                            Text("Check for updates automatically").foregroundStyle(palette.onCard)
                            NockerlInfoTip(text: "Look for a new version in the background. This contacts the Nockerl update feed and sends nothing about you or your dictation.")
                            Spacer()
                            // Bound straight to the @Published preference, unlike Launch at
                            // login: there the truth lives in SMAppService and needs a local
                            // mirror to snap back on a failed grant. Here SettingsStore IS the
                            // truth, and its didSet both persists and forwards to Sparkle.
                            Toggle("", isOn: $settings.checkForUpdatesAutomatically)
                                .labelsHidden()
                                .toggleStyle(.nockerl)
                        }
                    }
                }
                .padding(NockerlSpace.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nockerlWell(.container)
            }
            .padding(NockerlSpace.space6)
            // 640 has no size token: kept literal (same as views 03/04), listed.
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No elastic bounce when the content already fits, which on this fixed 880x600
        // window is almost always the case. The ScrollView is the ROOT of this section, and
        // a root ScrollView on macOS rubber-bands under a trackpad even with nowhere to
        // scroll to, so the page felt loose. Vocabulary, Styles and History never did that,
        // because their roots are fixed VStacks with ScrollViews only around the one region
        // that genuinely scrolls.
        //
        // `.basedOnSize` rather than deleting the ScrollView. Deleting it would clip
        // anything that ever does overflow, and this page can: more microphones, larger
        // accessibility text. Real scrolling stays, and only the empty bounce goes.
        .scrollBounceBehavior(.basedOnSize)
        // Pinned to the PANE's corner via an overlay rather than appended to the stack, so
        // it stays put instead of riding under the well and scrolling away. Muted and small:
        // it is a reference you go looking for, never something competing with the settings.
        .overlay(alignment: .bottomTrailing) {
            Text(AppVersion.display)
                .nockerlType(.bodySmall)
                .foregroundStyle(palette.onCanvasMuted)
                .textSelection(.enabled)   // so a version can be copied into a bug report
                .padding(NockerlSpace.space6)
                .accessibilityLabel("Version \(AppVersion.display)")
        }
    }

    private var micOptions: [NockerlSelectOption] {
        [NockerlSelectOption(value: "", label: "System Default")]
            + micMonitor.devices.map { NockerlSelectOption(value: $0.uid, label: $0.name) }
    }
}
