import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// App preferences (UserDefaults) + the cloud (OpenRouter) key (Keychain). Produces
/// the `TranscriptionConfig` and vocabulary prompt the controller uses, so changes
/// take effect on the next dictation without a restart.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    @Published var localEndpoint: String { didSet { defaults.set(localEndpoint, forKey: Keys.localEndpoint) } }
    /// The active transcription engine (nil until one is configured). Persisted, and
    /// migrated once from the old three-way providerMode on the first post-redesign launch.
    @Published var defaultEngine: TranscriptionEngine? {
        didSet { defaults.set(defaultEngine?.rawValue ?? "", forKey: Keys.defaultEngine) }
    }
    /// True while `cloudProvider` is being set programmatically (cheapest auto-select), so
    /// that write does not auto-promote OpenRouter to the default.
    private var isAutoSelectingProvider = false
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    /// Microphone device UID to record from. Empty = system default input.
    @Published var selectedMicUID: String { didSet { defaults.set(selectedMicUID, forKey: Keys.selectedMicUID) } }
    @Published var terms: [VocabularyTerm] { didSet { saveTerms() } }
    /// Named transcription-prompt styles; the active one's `body` drives `buildPrompt()`.
    @Published var styles: [Style] { didSet { saveStyles() } }
    /// The active style id (a built-in slug or a custom UUID). Default: "standard".
    @Published var activeStyleID: String { didSet { defaults.set(activeStyleID, forKey: Keys.activeStyleID) } }
    /// OpenRouter model slug for the cloud tier (default `xiaomi/mimo-v2.5`).
    @Published var cloudModel: String { didSet { defaults.set(cloudModel, forKey: Keys.cloudModel); promoteOpenRouterOnUserEdit() } }
    /// The chosen OpenRouter provider slug (empty = none picked yet). Strict routing,
    /// ZDR always enforced.
    @Published var cloudProvider: String { didSet { defaults.set(cloudProvider, forKey: Keys.cloudProvider); if !isAutoSelectingProvider { promoteOpenRouterOnUserEdit() } } }
    /// Require zero data retention on the OpenRouter request (default on). Off lets you use a
    /// non-ZDR provider (your audio may be retained).
    @Published var requireZDR: Bool { didSet { defaults.set(requireZDR, forKey: Keys.requireZDR) } }
    /// Whether the app checks nockerl.ai for updates on a schedule. Persisted here;
    /// the actual Sparkle side effect is applied by the app-layer `Updater` through
    /// `applyAutomaticUpdateChecks`. Sparkle is intentionally NOT imported into this file,
    /// which is compiled into the unit-test bundle. This mirrors how `launchAtLogin`
    /// delegates its effect to a subsystem, minus the third-party import.
    @Published var checkForUpdatesAutomatically: Bool {
        didSet {
            defaults.set(checkForUpdatesAutomatically, forKey: Keys.checkForUpdatesAutomatically)
            applyAutomaticUpdateChecks?(checkForUpdatesAutomatically)
        }
    }
    /// Set by the app-layer `Updater` at launch: forwards the toggle to Sparkle's
    /// `automaticallyChecksForUpdates`. Nil in the unit-test bundle (no Sparkle), where the
    /// preference is still persisted and read back, it just has no live updater to drive.
    var applyAutomaticUpdateChecks: ((Bool) -> Void)?
    @Published private(set) var cloudKeyPresent: Bool
    @Published private(set) var customKeyPresent: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        localEndpoint = defaults.string(forKey: Keys.localEndpoint) ?? ""
        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        selectedMicUID = defaults.string(forKey: Keys.selectedMicUID) ?? ""
        terms = Self.loadTerms(from: defaults) ?? PromptBuilder.defaultTerms
        // Held in a local as well: `activeStyleID` below must be validated against the
        // loaded list, and `self.styles` can't be read until every stored property is set.
        let loadedStyles = Self.loadStyles(from: defaults) ?? PromptBuilder.defaultStyles
        styles = loadedStyles
        // Validate against the styles actually loaded: someone whose active style was
        // Formal/Casual/Academic would otherwise be left pointing at a style that no
        // longer exists (no radio lit, prompt silently falling back to base).
        let savedStyleID = defaults.string(forKey: Keys.activeStyleID) ?? Style.defaultID
        activeStyleID = loadedStyles.contains { $0.id == savedStyleID } ? savedStyleID : Style.defaultID
        cloudModel = defaults.string(forKey: Keys.cloudModel) ?? TranscriptionConfig.defaultCloudModel
        cloudProvider = defaults.string(forKey: Keys.cloudProvider) ?? ""
        requireZDR = defaults.object(forKey: Keys.requireZDR) as? Bool ?? true
        // Default ON: auto-update is the norm for directly-distributed Mac apps. The Updater
        // applies this to Sparkle at launch (assigning it here does not fire the didSet).
        checkForUpdatesAutomatically = defaults.object(forKey: Keys.checkForUpdatesAutomatically) as? Bool ?? true
        // Absent key = fresh install for this bundle id = a genuine first run.
        welcomeShown = defaults.bool(forKey: Keys.welcomeShown)
        cloudKeyPresent = (KeychainStore.cloudKey()?.isEmpty == false)
        customKeyPresent = (KeychainStore.customKey()?.isEmpty == false)
        if let raw = defaults.string(forKey: Keys.defaultEngine), let engine = TranscriptionEngine(rawValue: raw) {
            defaultEngine = engine
        } else {
            // First launch after the redesign: migrate the old three-way mode.
            let oldMode = defaults.string(forKey: Keys.legacyProviderMode) ?? "auto"
            defaultEngine = (oldMode == "cloud") ? .openrouter : .custom
        }
        reconcileDefaultEngine()
    }

    // MARK: - Cloud (OpenRouter) key (Keychain)

    func setCloudKey(_ key: String) {
        KeychainStore.setCloudKey(key)
        cloudKeyPresent = (KeychainStore.cloudKey()?.isEmpty == false)
        if openrouterConfigured { defaultEngine = .openrouter } else { demote(.openrouter) }
    }

    func clearCloudKey() {
        KeychainStore.deleteCloudKey()
        cloudKeyPresent = false
        demote(.openrouter)
    }

    func setCustomKey(_ key: String) {
        KeychainStore.setCustomKey(key)
        customKeyPresent = (KeychainStore.customKey()?.isEmpty == false)
        if customConfigured { defaultEngine = .custom }
    }

    func clearCustomKey() {
        KeychainStore.deleteCustomKey()
        customKeyPresent = false
    }

    // MARK: - Engine selection (single default, no fallback)

    var openrouterConfigured: Bool { cloudKeyPresent }
    var customConfigured: Bool { !localEndpoint.trimmingCharacters(in: .whitespaces).isEmpty }

    func isConfigured(_ engine: TranscriptionEngine) -> Bool {
        engine == .openrouter ? openrouterConfigured : customConfigured
    }

    /// Save the Custom endpoint URL; if it is now configured, auto-promote Custom to the
    /// default. Clearing it hands the default back to OpenRouter when that is configured.
    func saveCustomEndpoint(_ url: String) {
        localEndpoint = url.trimmingCharacters(in: .whitespaces)
        if customConfigured { defaultEngine = .custom } else { demote(.custom) }
    }

    /// A manual "Set as default" tap. Honored only when that engine is configured.
    func setDefaultEngine(_ engine: TranscriptionEngine) {
        defaultEngine = EngineSelection.afterManualSelect(engine, isConfigured: isConfigured(engine), current: defaultEngine)
    }

    /// Programmatic cheapest-provider auto-select; must not auto-promote OpenRouter.
    func autoSelectProvider(_ slug: String) {
        isAutoSelectingProvider = true
        cloudProvider = slug
        isAutoSelectingProvider = false
    }

    private func promoteOpenRouterOnUserEdit() {
        if openrouterConfigured { defaultEngine = .openrouter }
    }

    private func demote(_ engine: TranscriptionEngine) {
        defaultEngine = EngineSelection.afterDeconfigure(engine, current: defaultEngine, otherConfigured: isConfigured(engine.other))
    }

    private func reconcileDefaultEngine() {
        if let engine = defaultEngine, !isConfigured(engine) { defaultEngine = nil }
        if defaultEngine == nil {
            if customConfigured { defaultEngine = .custom }
            else if openrouterConfigured { defaultEngine = .openrouter }
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // No-op: the toggle reflects the real status on next read.
            }
        }
    }

    // MARK: - First-run welcome

    /// Whether the first-run welcome window has been shown. Show-once.
    ///
    /// Stored in UserDefaults on purpose. Unlike the Keychain service and the on-disk
    /// directories (which are NOT partitioned per bundle id for a non-sandboxed app,
    /// which is exactly why `AppPaths` exists to namespace them), `UserDefaults`
    /// is ALREADY scoped to the running build's bundle id: its domain is the
    /// `<bundle-id>.plist` preferences file. So a dev build (`com.dizyx.nockerlvoice.dev`)
    /// reads no value here and gets a GENUINE first run, while production keeps its own
    /// flag. That is the same isProduction / namespace isolation `AppPaths` provides,
    /// obtained for free because UserDefaults is bundle-keyed. No new storage location is
    /// invented; `defaults.bool` returns false when the key is absent (fresh install).
    ///
    /// `@Published` (not a plain computed property) so the flip from false to true is an
    /// OBSERVABLE event: the menu-bar scene watches it to replay a permission-guidance
    /// signal that arrived while the welcome still owned the flow (A-F2).
    @Published var welcomeShown: Bool { didSet { defaults.set(welcomeShown, forKey: Keys.welcomeShown) } }

    // MARK: - Derived config

    func buildConfig() -> TranscriptionConfig {
        // No language is sent: the models auto-detect.
        let endpoint = localEndpoint.trimmingCharacters(in: .whitespaces)
        return TranscriptionConfig(
            customEndpoint: URL(string: endpoint) ?? TranscriptionConfig.default.customEndpoint,
            customAPIKey: KeychainStore.customKey(),
            cloudAPIKey: KeychainStore.cloudKey(),
            cloudModel: cloudModel.isEmpty ? TranscriptionConfig.defaultCloudModel : cloudModel,
            cloudProvider: cloudProvider,
            language: nil,
            engine: defaultEngine ?? .openrouter,
            enforceZDR: requireZDR
        )
    }

    var activeStyle: Style? { styles.first { $0.id == activeStyleID } }

    /// Floor: never nil - a corrupted/empty `styles` blob degrades to today's
    /// exact prompt rather than crashing. (Review BLOCKER fix.)
    var activeStyleBody: String { activeStyle?.body ?? PromptBuilder.baseInstructions }

    func setActiveStyle(_ id: String) {
        guard styles.contains(where: { $0.id == id }) else { return }
        activeStyleID = id
    }

    @discardableResult
    func addStyle() -> Style {
        let n = styles.filter { !$0.isBuiltIn }.count + 1
        let style = Style(name: "Untitled \(n)", body: PromptBuilder.baseInstructions)
        styles.insert(style, at: 0)
        return style
    }

    @discardableResult
    func duplicateStyle(_ id: String) -> Style {
        guard let source = styles.first(where: { $0.id == id }) else {
            return addStyle()
        }
        let copy = Style(name: "\(source.name) copy", body: source.body)
        styles.insert(copy, at: 0)
        return copy
    }

    /// Custom styles only. Built-ins are non-deletable. If the deleted style was
    /// active, fall back to the standard default.
    func deleteStyle(_ id: String) {
        guard let style = styles.first(where: { $0.id == id }), !style.isBuiltIn else { return }
        styles.removeAll { $0.id == id }
        if activeStyleID == id {
            activeStyleID = Style.defaultID
        }
    }

    func buildPrompt() -> String {
        PromptBuilder.build(baseBody: activeStyleBody, terms: terms)
    }

    func resetVocabularyToDefault() {
        terms = PromptBuilder.defaultTerms
    }

    func clearAllTerms() {
        terms = []
    }

    private func saveTerms() {
        if let data = try? JSONEncoder().encode(terms) {
            defaults.set(data, forKey: Keys.terms)
        }
    }

    private static func loadTerms(from defaults: UserDefaults) -> [VocabularyTerm]? {
        guard let data = defaults.data(forKey: Keys.terms) else { return nil }
        return try? JSONDecoder().decode([VocabularyTerm].self, from: data)
    }

    private func saveStyles() {
        if let data = try? JSONEncoder().encode(styles) {
            defaults.set(data, forKey: Keys.styles)
        }
    }

    private static func loadStyles(from defaults: UserDefaults) -> [Style]? {
        guard let data = defaults.data(forKey: Keys.styles) else { return nil }
        guard let decoded = try? JSONDecoder().decode([Style].self, from: data) else { return nil }
        // Dedupe by id, keeping first occurrence - guards against hand-edited
        // UserDefaults JSON or a future import feature colliding ids.
        var seen = Set<String>()
        var styles = decoded.filter { seen.insert($0.id).inserted }
        // Drop built-ins that have since been withdrawn (Formal / Casual / Academic).
        // Without this they would persist forever for existing users AND become
        // undeletable, since the UI only offers Delete for styles in `builtInIDs`.
        styles.removeAll { Style.retiredBuiltInIDs.contains($0.id) }
        // Refresh built-in styles from defaultStyles so name/body updates (e.g. renaming
        // Meeting Notes to Multiple Speakers, or an improved prompt) reach existing users.
        // Custom styles keep their saved content untouched.
        styles = styles.map { style in
            PromptBuilder.defaultStyles.first { $0.id == style.id } ?? style
        }
        // Merge in any built-in shipped SINCE these styles were saved, so a new built-in
        // reaches existing users, not just fresh installs.
        for builtIn in PromptBuilder.defaultStyles where seen.insert(builtIn.id).inserted {
            styles.append(builtIn)
        }
        return styles
    }

    private enum Keys {
        static let localEndpoint = "localEndpoint"
        static let legacyProviderMode = "providerMode"   // read once for migration to defaultEngine
        static let defaultEngine = "defaultEngine"
        static let requireZDR = "requireZDR"
        static let appearance = "appearance"
        static let selectedMicUID = "selectedMicUID"
        static let terms = "vocabularyTerms"
        static let styles = "transcriptionStyles"
        static let activeStyleID = "activeStyleID"
        static let cloudModel = "cloudModel"
        static let cloudProvider = "cloudProvider"
        static let checkForUpdatesAutomatically = "checkForUpdatesAutomatically"
        static let welcomeShown = "welcomeShown"
    }
}

/// App-wide appearance preference, applied via `.preferredColorScheme`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The matching NSAppearance for AppKit surfaces (e.g. the recording HUD panel).
    /// nil = follow the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
