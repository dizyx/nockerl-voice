import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// Tracks and requests the three TCC permissions Nockerl Voice needs.
@MainActor
final class PermissionsManager: ObservableObject {
    enum Status: Equatable { case granted, denied, notDetermined }

    @Published var microphone: Status = .notDetermined
    @Published var accessibility = false   // synthesized ⌘V paste
    @Published var inputMonitoring = false // global Right ⌘ event tap

    /// Microphone and Accessibility only. Input Monitoring is NOT required: the hotkey tap
    /// is built preferring `.defaultTap`, which Accessibility authorises, and `.listenOnly`
    /// (the option Input Monitoring covers) is only a degraded fallback. Requiring it meant
    /// this never returned true no matter what the user granted, because
    /// `CGPreflightListenEventAccess` reports a different TCC service and the app never
    /// appears in that pane. `inputMonitoring` is still published for diagnostics.
    var allGranted: Bool { microphone == .granted && accessibility }

    init() { refresh() }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied, .restricted: microphone = .denied
        default: microphone = .notDetermined
        }
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestAccessibility() {
        // Registers the app in the Accessibility list and shows the system prompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        openPrivacyPane("Privacy_ListenEvent")
    }

    func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quit and reopen the app. Input Monitoring (and sometimes Accessibility)
    /// grants only take effect after a relaunch.
    func relaunchApp() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }
}
