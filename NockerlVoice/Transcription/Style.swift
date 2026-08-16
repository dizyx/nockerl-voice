import Foundation

/// A named, swappable transcription-prompt template. The `body` is the
/// instruction text (register/tone); the global vocabulary block is always
/// appended separately by `PromptBuilder`. Built-ins are read-only in the UI
/// (customize via Duplicate-to-custom); their ids are stable slugs so
/// `activeStyleID` persists across launches.
struct Style: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var body: String

    var isBuiltIn: Bool { Style.builtInIDs.contains(id) }

    /// Stable slugs for the three built-in styles. Custom styles use UUID strings.
    static let builtInIDs: Set<String> = ["standard", "emotional", "meeting-notes"]

    /// Built-ins that shipped once and have since been withdrawn. They must be listed
    /// here rather than merely deleted from `PromptBuilder.defaultStyles`: the store
    /// REFRESHES known built-ins from the defaults and keeps anything it does not
    /// recognise, so a dropped built-in would otherwise survive forever in existing
    /// installs. No longer being in `builtInIDs`, it would turn into an undeletable
    /// pseudo-custom style. `SettingsStore.loadStyles` strips these on load.
    /// `organized` is here rather than simply absent because it DID ship to a real
    /// install before being withdrawn. Anything that ever reached a user's defaults has
    /// to be retired properly, not just deleted from the catalog.
    static let retiredBuiltInIDs: Set<String> = ["formal", "casual", "academic", "organized"]

    /// The non-deletable default style id.
    static let defaultID = "standard"

    /// `id` defaults to a fresh UUID for custom styles; built-ins pass an
    /// explicit slug (`Style(id: "standard", ...)`).
    init(id: String = UUID().uuidString, name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }
}
