import NockerlDesign
import SwiftUI

/// First-launch welcome window. A REAL native `Window` scene (declared in
/// NockerlVoiceApp alongside "dashboard" and "onboarding"), not a sheet and not an
/// in-app modal. A modal reads as a web app rather than a native Mac utility, which is
/// the opposite of what a first launch should communicate.
///
/// Sequencing with the permission window: on a fresh install the welcome is
/// shown FIRST and the permission window ("onboarding") is deliberately NOT opened at
/// launch. Get Started marks the welcome seen and only THEN chains to the permission
/// window, and only if a required grant is still missing. The launch-hook gating that
/// enforces this order lives in NockerlVoiceApp.
struct WelcomeView: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// Local mirror of the SMAppService-backed toggle so a failed register / unregister
    /// snaps the switch back to the real status (the same pattern AppSettingsView uses).
    @State private var launchAtLogin = SettingsStore.shared.launchAtLogin

    /// Keyboard focus for the window. Deliberately left EMPTY on appearance so nothing
    /// opens with a focus ring; the `.focused` bindings on the rows exist so Tab still
    /// walks the window normally once a user chooses to use the keyboard.
    @FocusState private var focus: FirstRunFocus?

    /// Set only when a Get Started press found a required grant still missing. Drives the
    /// explanation beside the button, so nothing is said until there is something to say.

    /// Dark-only, matching the sibling first-run window (OnboardingView). On a genuine
    /// first run the appearance preference is still its default (dark), so this is also
    /// what the user would see anyway; forcing it keeps the two first-run windows visually
    /// identical when the welcome chains straight into the permission window.
    private let palette = NockerlPalette.resolve(.dark)

    var body: some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space4) {
            header
            // A SEQUENCE, not a list of features. Permissions first because it is the only
            // step that blocks: nothing else matters if the app cannot type. Settings
            // second because it is quick and optional. The engine last because it is the
            // one thing that sends the user somewhere else, so it reads best immediately
            // above the button that takes them there.
            //
            // The hotkey is deliberately NOT numbered and NOT here. It is not a step, it is
            // how the app is used once these are done, so it now sits in the header as part
            // of what the app IS. Leaving it mid-sequence interrupted the count, and putting
            // it after Get Started would have followed the ending with an afterthought.
            permissionsBlock
            settingsBlock
            // Ends the sequence AND carries Get Started, so there is no divider and no
            // separate footer line below it. The button belongs to the step that describes
            // where it goes, and putting it there closes the window on the last thing the
            // reader looks at instead of restating it under a rule.
            transcriptionBlock
        }
        .padding(NockerlSpace.space6)
        .frame(width: 520)
        .background(palette.canvas)
        // Forced dark, consistent with the sibling permission window.
        .preferredColorScheme(.dark)
        .tint(palette.accentPrimary)
        // Re-read the grants every time the app returns to the front. That is precisely
        // when someone comes back from System Settings, so the rows tick over and Get
        // Started enables itself without the user pressing anything. This is what makes a
        // disabled primary safe here rather than a dead end.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .onAppear {
            permissions.refresh()
            // Open with NOTHING focused, so no control wears a ring on a first run.
            //
            // THE POINT THAT COST FOUR ATTEMPTS: SwiftUI's `@FocusState` and AppKit's first
            // responder are NOT the same thing. Setting `focus = nil` clears only SwiftUI's
            // notion. The ring here comes from AppKit giving the window an initial first
            // responder, which is the first focusable control in the layout (the info tip
            // beside "Launch at login"). Clearing the SwiftUI side left that untouched, which
            // is why the ring kept coming back no matter how the SwiftUI side was pointed.
            //
            // `makeFirstResponder(nil)` on the WINDOW is what actually releases it. Both are
            // cleared: the SwiftUI state so nothing re-derives focus from it, and the
            // responder so the ring goes.
            //
            // Deferred a turn because the window is not key yet during `.onAppear`, so
            // `keyWindow` would be nil and the call would silently do nothing.
            //
            // The cost is deliberate: Return activates nothing until the user Tabs or clicks.
            // Correct for a window whose job is to be read before it is acted on.
            DispatchQueue.main.async {
                focus = nil
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        // No `.defaultFocus` here on purpose. It would re-claim focus straight after the
        // clear above and put the ring back, which is the behaviour being removed. The
        // `@FocusState` and the `.focused` bindings on the rows stay: they are what lets a
        // keyboard user Tab through the window normally, and they cost nothing while
        // focus is nil.
        // THE single exit path (A-F1). Both dismissal routes tear this view down, so both
        // land here: "Get Started" (which dismisses the window) and the titlebar close
        // button. The show-once flag and the chain to the permission window therefore
        // happen exactly once, in one place, no matter how the window was closed.
        .onDisappear { finishWelcome() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: NockerlSpace.space3) {
            // The framework product mark at the same size 28. Decorative: the title line
            // beside it names the product, so no label. NockerlProductMark's
            // accessibilityLabel already defaults to nil, so the posture is unchanged.
            NockerlProductMark(.voice, size: 28)
            // A greeting and nothing else. The tagline and the hotkey instruction that used
            // to sit under here are both gone: the hotkey is the wrong thing to teach on a
            // screen where the app cannot yet transcribe, and reading it before there is any
            // way to use it just costs attention that step 1 needs.
            //
            // Nothing is stranded by dropping it. The empty dashboard, which is where Get
            // Started lands, teaches the hotkey in full, and the menu bar carries
            // "Double-tap Right Command to dictate" as its idle status from first launch.
            titleLine
        }
    }

    /// "Welcome to Nockerl Voice", where only the product name carries the house
    /// wordmark treatment: thin "Nockerl" in the surface ink, regular "Voice" in the
    /// cyan accent, both on the brand tracking. `NockerlLockup` is the canonical
    /// implementation of that treatment and this mirrors it; keep the two in sync.
    ///
    /// Composed by concatenating `Text` values rather than laying out an HStack.
    /// Concatenation preserves per-run styling while keeping the whole thing ONE text
    /// run, so it wraps naturally and every word shares a baseline. An HStack of
    /// separate `Text` views would break both, most visibly at large accessibility
    /// sizes.
    ///
    /// Metrics are derived from the `.titleLarge` role rather than hardcoded, so all
    /// four runs share one optical size and the line follows the type ramp if the
    /// token ever moves.
    private var titleLine: Text {
        let size = NockerlTypeRole.titleLarge.size
        // Brand tracking, the same -0.03em NockerlLockup applies to both wordmark runs.
        let brandTracking = size * -0.03

        // "Welcome to" stays in the normal title style: the titleLarge weight (500),
        // no brand tracking. Only the product name gets the lockup treatment.
        return Text("Welcome to ")
            .font(.nockerl(size: size, weight: .medium))
            .foregroundStyle(palette.onCanvas)
        + Text("Nockerl")
            .font(.nockerl(size: size, weight: .thin))          // 200
            .tracking(brandTracking)
            .foregroundStyle(palette.onCanvas)
        // The word gap. NockerlLockup sets an explicit 0.14em because it lays the two
        // words out geometrically with no space character between them. Inside a
        // sentence the space glyph is what carries the gap, so it is used here and
        // takes the same brand tracking. If this ever needs to match the lockup
        // exactly, tighten THIS run with `.kerning`, and measure it against the
        // sidebar lockup rather than picking a number.
        + Text(" ")
            .font(.nockerl(size: size, weight: .thin))
            .tracking(brandTracking)
        + Text("Voice")
            .font(.nockerl(size: size, weight: .regular))       // 400
            .tracking(brandTracking)
            .foregroundStyle(palette.accentPrimary)
    }

    // MARK: - Blocks

    private var settingsBlock: some View {
        step(2, "Recommended settings") {
            toggleRow(
                label: "Launch at login",
                tip: "Start Nockerl Voice automatically when you log in, so the dictation hotkey is always ready.",
                isOn: $launchAtLogin
            )
            // SMAppService register / unregister with a silent catch, then read back so a
            // failed grant snaps the switch to the real status (mirrors AppSettingsView).
            .onChange(of: launchAtLogin) { _, newValue in
                settings.launchAtLogin = newValue
                launchAtLogin = settings.launchAtLogin
            }
            toggleRow(
                label: "Check for updates automatically",
                // A-F3: states a PREFERENCE, never a capability. The real signing key and
                // the appcast pipeline have both landed, so updating works once a release
                // is tagged, but this copy still promises nothing about whether the app is
                // currently checking. It stayed true while the updater was inert and stays
                // true now, which is exactly why it was worded this way.
                tip: "Your preference for automatic update checks. It applies whenever in-app updating is available, and you can change it any time in Settings.",
                isOn: $settings.checkForUpdatesAutomatically
            )
        }
    }

    /// The last step, built inline rather than through `step()`, because it is ONE ROW:
    /// number, title, and the button that acts on it, all on the same line.
    ///
    /// That shape is why it does not use the shared helper. `step()` stacks its content
    /// under the title, and a tall button in that stack would have dragged the row's height
    /// past the badge, leaving the number floating above a vertically centred title. With
    /// everything on one line there is nothing to misalign.
    ///
    /// The line that used to sit here, "Get Started takes you there.", is gone with the
    /// move. It existed to point at a button somewhere below; the button is now the right
    /// half of this row and points at itself.
    private var transcriptionBlock: some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space2) {
            HStack(alignment: .center, spacing: NockerlSpace.space3) {
                NockerlBadge("3", tone: .accent, variant: .outline)
                Text("Connect a transcription engine")
                    .nockerlType(.titleSmall)
                    .foregroundStyle(palette.onCanvas)
                Spacer(minLength: NockerlSpace.space4)
                // The one filled cyan call to action on the surface (design-laws: one
                // primary per surface). `.lg` = the hero / block action height.
                //
                // Inert until the required grant is in, so the button's colour IS the
                // readiness signal: grey means the app cannot type yet, cyan means it can.
                //
                // This was deliberately NOT disabled before, and the reason was sound: the
                // usual cause of a grant looking missing is that the user just granted it in
                // System Settings and the app has not looked since, so a disabled button
                // would refuse to work for a reason that was no longer true. Two things now
                // close that hole. The window re-checks whenever the app comes back to the
                // front, which is exactly the moment someone returns from System Settings,
                // so the button lights up on its own. And Re-check is on step 1's title
                // line, in view, as the manual fallback.
                NockerlButton("Get Started", variant: .primary, size: .lg) {
                    attemptFinish()
                }
                .disabled(!missingRequiredGrants.isEmpty)
                .focused($focus, equals: .primaryAction)
            }
        }
    }

    /// The permissions the app cannot work without, with live status and a way back in.
    ///
    /// This exists because denying a prompt was a DEAD END: nothing was said, nothing
    /// recovered, and this window offered no route to the setting. macOS will not re-present
    /// a denied prompt, so without a button that opens System Settings the only way forward
    /// was to know to go there unaided.
    ///
    /// `PermissionRow` is the same component the permission window uses, not a second copy.
    private var permissionsBlock: some View {
        // The explanatory paragraph that stood here is DELETED. It said that macOS gates
        // dictation behind Accessibility and that without it the app can do nothing, which
        // the row subtext below already says in fewer words and closer to the control it
        // describes. Two statements of the same fact read as padding.
        // Re-check sits on the TITLE line, not under the rows. Below them it was a third
        // button in a column of Grants, reading as a fourth permission rather than as the
        // action for the step. On the title line it is clearly about the whole step, and
        // the rows below are left as a clean list.
        step(1, "Set your permissions", trailing: permissions.allGranted ? nil : AnyView(
            NockerlButton("Re-check", variant: .tertiary, size: .sm) {
                permissions.refresh()
            }
        )) {
            // These two take the focus binding because they are the two the gate can be
            // waiting on. Nothing claims focus on appearance any more, so the binding exists
            // purely so a keyboard user can Tab to them. Their titles are the keys, and they
            // must stay identical to the strings in `missingRequiredGrants`.
            PermissionRow(
                title: "Accessibility",
                detail: "Paste transcribed text into the focused app.",
                granted: permissions.accessibility,
                action: { permissions.requestAccessibility() },
                focus: $focus
            )
            // Shown for completeness but NOT gated on: unlike the two above, macOS still
            // prompts for the microphone at the first recording, so it can be granted later
            // without a trip to System Settings and does not strand a new user. It takes no
            // focus binding for the same reason: it is never what the gate is waiting for,
            // so a focus target here could never be selected.
            PermissionRow(
                title: "Microphone",
                detail: "Record your voice while dictating.",
                granted: permissions.microphone == .granted,
                denied: permissions.microphone == .denied,
                action: { permissions.requestMicrophone() }
            )
        }
    }

    /// The grants without which the app is completely inert: no hotkey, no paste. The
    /// microphone is deliberately not here, see the note in `permissionsBlock`.
    /// ACCESSIBILITY ONLY. Input Monitoring is deliberately not gated on, and that is a
    /// correctness point rather than a relaxation.
    ///
    /// `RightCommandTapMonitor` builds its tap as `make(.defaultTap) ?? make(.listenOnly)`.
    /// On macOS `.defaultTap` is authorised by ACCESSIBILITY, and `.listenOnly` by Input
    /// Monitoring. An app holding Accessibility can already create the tap, so the preferred
    /// path never needs Input Monitoring at all; `.listenOnly` is only the degraded fallback,
    /// and in that mode the swallow return is ignored anyway.
    ///
    /// Gating on it was actively harmful. `CGPreflightListenEventAccess()` reports a
    /// different TCC service, so it stays false however much Accessibility is granted, and
    /// the app never appears in the Input Monitoring pane because it never asks for that
    /// service. A first-run user was therefore held behind a requirement that could not be
    /// satisfied and did not need to be. The shipping build proves the point: it works with
    /// no entry in that pane at all.
    private var missingRequiredGrants: [String] {
        var missing: [String] = []
        if !permissions.accessibility { missing.append("Accessibility") }
        return missing
    }

    /// Get Started, which now does work rather than sitting inert.
    ///
    /// 1. RE-CHECK FIRST. This is the whole point: the usual reason a grant looks missing is
    ///    that the user just granted it in System Settings and the app has not looked since.
    ///    Checking on the press means the happy path needs no Re-check button at all, which
    ///    was previously an unmarked step in the middle of it.
    /// 2. Present now, so proceed exactly as before.
    /// 3. Still missing, so STAY. Do not dismiss, say what is missing, and point at step 1.
    ///
    /// This does NOT introduce a second exit. The only dismissal is still `completeWelcome`,
    /// and the only place `welcomeShown` is set or the permission window is chained is still
    /// `finishWelcome`, which `.onDisappear` runs.
    private func attemptFinish() {
        permissions.refresh()
        guard missingRequiredGrants.isEmpty else {
            // Unreachable in practice: the button is disabled while anything is missing.
            // Kept as the belt to that braces, because the alternative is dismissing the
            // window on a stale read.
            return
        }
        completeWelcome()
    }

    // MARK: - Helpers

    /// One icon + title + free content block, matching the OnboardingView row anatomy.
    @ViewBuilder
    private func step<Content: View>(
        _ number: Int,
        _ title: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // firstTextBaseline, not top. A trailing control on the title line makes the row
        // as tall as that control, and under `.top` the badge would pin to the top of that
        // taller row and float above the title it numbers. Baseline alignment puts the
        // badge's digit on the title's baseline whatever else shares the line, so the three
        // numbers stay level down the left edge.
        HStack(alignment: .firstTextBaseline, spacing: NockerlSpace.space3) {
            // The number in the framework badge rather than a hand-rolled numbered circle.
            // It is already the small accent-outlined token used elsewhere in the app, so
            // three of them down the left edge read as a sequence at a glance without
            // inventing a component for it. The step glyphs it replaces were decorative and
            // said nothing the title did not.
            NockerlBadge("\(number)", tone: .accent, variant: .outline)
            // space3, not space2. At space2 the first permission row sat right under
            // "Set your permissions" with no visible break, so the title read as part of
            // the row rather than as the heading above it. The rows carry a status disc,
            // which is taller than plain text, so the gap that looked fine in step 2 was
            // too tight in step 1.
            VStack(alignment: .leading, spacing: NockerlSpace.space3) {
                HStack(alignment: .center, spacing: NockerlSpace.space3) {
                    Text(title)
                        .nockerlType(.titleSmall)
                        .foregroundStyle(palette.onCanvas)
                    if trailing != nil {
                        Spacer(minLength: NockerlSpace.space4)
                        trailing
                    }
                }
                content()
            }
        }
    }

    /// A labelled setting row with an info tip and the framework toggle. Native `Toggle`
    /// keeps the switch role / value / keyboard; only the STYLE changes.
    private func toggleRow(label: String, tip: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: NockerlSpace.space2) {
            Text(label)
                .nockerlType(.bodyMedium)
                .foregroundStyle(palette.onCanvas)
            NockerlInfoTip(text: tip)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.nockerl)
        }
    }

    // MARK: - Actions

    /// Get Started: just close the window. Everything that must happen on the way out
    /// (marking the welcome seen, then chaining to the permission window) lives in
    /// `finishWelcome()`, which `.onDisappear` runs for EVERY dismissal route. Keeping the
    /// button dumb is what stops the two routes from drifting apart (A-F1).
    private func completeWelcome() {
        // Land on the Transcription pane, which is the next thing to do and the one thing
        // this window says is still required. Only the shared router selection is set here:
        // the dashboard is already open behind this window (the launch hook opens it), so
        // there is no openWindow and no NSApp.activate, and therefore nothing that can come
        // forward and bury a window the user is still reading. The pane is simply already
        // correct when this window goes away.
        DashboardRouter.shared.section = .transcription
        dismissWindow(id: "welcome")
    }

    /// The one exit path, run from `.onDisappear` whether the user pressed Get Started or
    /// the titlebar close button.
    ///
    /// Order is deliberate (welcome before permissions): mark the welcome seen
    /// FIRST, then open the permission window only when a required grant is still missing.
    /// Before A-F1 the chain lived in the Get Started handler alone, so closing with the
    /// red X flipped `welcomeShown` and skipped the guidance entirely, leaving that whole
    /// session with a dead hotkey and nothing on screen explaining why.
    private func finishWelcome() {
        settings.welcomeShown = true
        // `allGranted` is the ONLY thing that decides this, deliberately, because the
        // condition used to be spelled out here as `!inputMonitoring || !accessibility`
        // and that was permanently true. Input Monitoring stopped being required once the
        // hotkey tap was built preferring `.defaultTap` (Accessibility authorises it), and
        // `CGPreflightListenEventAccess` reports a service this app never appears under, so
        // `!inputMonitoring` never evaluated false. The permission window therefore opened
        // on top of the finished welcome EVERY time, granted or not, and it read as the
        // three steps being replaced by a screen with no way forward.
        guard !permissions.allGranted else { return }
        // Defer one runloop turn: the scene system is mid-teardown of this window, and the
        // same deferral is what makes `openWindow` reliable in the launch hook.
        DispatchQueue.main.async {
            openWindow(id: "onboarding")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

}
