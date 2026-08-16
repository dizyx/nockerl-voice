import NockerlDesign
import SwiftUI

/// First-run-style permissions checklist. Opened from the menu when any of the
/// three grants is missing.
struct OnboardingView: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var controller: DictationController
    @Environment(\.dismissWindow) private var dismissWindow

    /// This window is DARK-ONLY by design (`.preferredColorScheme(.dark)` below),
    /// so the palette resolves `.dark` deterministically: the same values the old
    /// dynamic NockerlTheme colors produced under the forced appearance.
    private let palette = NockerlPalette.resolve(.dark)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                // The framework product mark at the same size 22. Decorative: the title
                // names the window, so no label. NockerlProductMark's accessibilityLabel
                // already defaults to nil, which hides it, so the posture is unchanged.
                NockerlProductMark(.voice, size: 22)
                VStack(alignment: .leading, spacing: 4) {
                    // macOS .title2 ≈ 17pt → size18 bold, nearest token.
                    // NOT the pre-flight's iOS 22pt reading.
                    Text("Set up Nockerl Voice")
                        // Heading → Outfit titleLarge (18/500: the ramp
                        // cap; bold has no heavier Outfit face, §11).
                        .nockerlType(.titleLarge)
                        .foregroundStyle(palette.onCanvas)
                    Text("Grant these two permissions to dictate into any app.")
                        .nockerlType(.bodyMedium)   // subtitle → Outfit 300/14
                        .foregroundStyle(palette.onCanvasMuted)
                }
            }

            PermissionRow(
                title: "Microphone",
                detail: "Record your voice while dictating.",
                granted: permissions.microphone == .granted,
                denied: permissions.microphone == .denied,
                action: { permissions.requestMicrophone() }
            )
            PermissionRow(
                title: "Accessibility",
                detail: "Paste transcribed text into the focused app.",
                granted: permissions.accessibility,
                action: { permissions.requestAccessibility() }
            )

            // Structural separator on the divider token (no framework divider
            // component; `divider` is the structural line, stronger than hairline).
            Rectangle().fill(palette.divider).frame(height: NockerlSpace.spacePx)

            HStack {
                if permissions.allGranted {
                    // Cyan, matching the row checks above it. It carries the same tick glyph
                    // in the same window, so leaving this one green while they went cyan would
                    // read as two different kinds of success on one screen.
                    Label("All set. You're ready to dictate.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(palette.accentPrimary)
                } else {
                    // Quietest tier: the escape hatch, disappears once granted.
                    NockerlButton("Quit & Reopen", variant: .ghost, size: .sm) {
                        permissions.relaunchApp()
                    }
                    .help("A new grant only takes effect once the app is restarted.")
                }
                Spacer()
                // Same accent tier as the row Grants: both act on permissions.
                NockerlButton("Re-check", variant: .tertiary, size: .sm) {
                    permissions.refresh()
                    controller.startHotkey()   // re-attach the tap if newly granted
                }
                if permissions.allGranted {
                    // A way OUT, which this window did not have. Once everything was granted it
                    // said "All set" and then offered nothing but Re-check, so the only exit was
                    // the titlebar close button and it read as being stuck. Primary tier because
                    // at that point it is the obvious next action.
                    NockerlButton("Done", variant: .primary, size: .sm) {
                        dismissWindow(id: "onboarding")
                    }
                }
            }
        }
        .padding(NockerlSpace.space6)
        // 480 has no size token (containerLg 360 / grid containerMd 768 bracket
        // it) - kept literal.
        .frame(width: 480)
        .background(palette.canvas)
        // Forced dark is sacred here: scene-level appearance modernization is
        // explicitly out of scope for this view.
        .preferredColorScheme(.dark)
        .tint(palette.accentPrimary)
        .onAppear {
            permissions.refresh()
            controller.startHotkey()
            // Open with NOTHING focused, exactly as the welcome window does. AppKit gives a
            // new window an initial first responder, which here is the first Grant button,
            // and that draws a ring on a setup screen that should just be read. Clearing
            // SwiftUI's `@FocusState` alone is not enough: the responder is AppKit's and has
            // to be released on the window itself. Deferred a turn because the window is not
            // key yet during `.onAppear`, so `keyWindow` would be nil and this would silently
            // do nothing.
            //
            // This window was missed when the welcome window was fixed, which is why the ring
            // appeared to come back the moment the two chained.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

}
