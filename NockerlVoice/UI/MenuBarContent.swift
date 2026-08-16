import AppKit
import SwiftData
import SwiftUI

/// The menu shown from the menu-bar icon: status, manual start/stop, recent
/// transcriptions (quick copy), and entry points into the dashboard.
struct MenuBarContent: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var permissions: PermissionsManager
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var updateModel = UpdateModel.shared
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \TranscriptionRecord.createdAt, order: .reverse) private var records: [TranscriptionRecord]

    var body: some View {
        Text("Nockerl Voice - \(controller.status.label)")

        if !permissions.allGranted {
            Button("⚠ Set up permissions…") {
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button(controller.status == .recording ? "Stop dictation" : "Start dictation") {
            controller.toggleManually()
        }
        .disabled(controller.status == .transcribing)

        Text(controller.hotkeyActive
             ? "Double-tap Right ⌘ to dictate"
             : "Enable Input Monitoring for the Right ⌘ hotkey")
            .font(.caption)

        if let error = controller.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        // Quick-switch the active transcription Style. Applies to the NEXT dictation
        // (the prompt is read at transcribe-time), so this never swaps an in-flight run.
        // Picker-in-Menu renders a native submenu with a checkmark on the active style.
        Picker("Style", selection: Binding(
            get: { settings.activeStyleID },
            set: { settings.setActiveStyle($0) }
        )) {
            ForEach(settings.styles) { style in
                Text(style.name).tag(style.id)
            }
        }

        if !records.isEmpty {
            Divider()
            Text("Recent")
                .font(.caption)
            ForEach(records.prefix(5)) { record in
                Button(menuLabel(for: record)) { copy(record.text) }
            }
        }

        Divider()

        Button("Dashboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d", modifiers: .command)

        // Sparkle, in the conventional Mac spot: the app-level group just above
        // Quit. Disabled until a real EdDSA key ships, so it is never a dead action.
        // QUIET DISCOVERY. This line is the ENTIRE unprompted surface of a found update.
        // A menu the user chose to open cannot steal focus and cannot appear over anything,
        // so discovery is visible without ever interrupting. Acting on it is a second,
        // separate click, which is the opt-in the real update flow waits for.
        // ONE item, never both. Offering "Check for Updates" beside "Update Available"
        // asked the user to check for something the same menu had just told them was
        // found.
        if updateModel.hasQuietUpdate {
            Button("Update Available…") {
                // Open the dashboard FIRST. The update flow lives in the sidebar now,
                // so re-presenting it while no window is on screen is what made this
                // item look inert: the result had nowhere to appear.
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
                updater.openDiscoveredUpdate()
            }
        } else {
            Button("Check for Updates…") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        Button("Quit Nockerl Voice") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func menuLabel(for record: TranscriptionRecord) -> String {
        let single = record.text.replacingOccurrences(of: "\n", with: " ")
        return single.count > 60 ? String(single.prefix(60)) + "…" : single
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
