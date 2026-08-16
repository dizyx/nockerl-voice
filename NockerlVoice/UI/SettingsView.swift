import NockerlDesign
import SwiftUI

/// Transcription settings pane. Card-based, on the NockerlDesign form grammar:
/// NockerlFormSection eyebrow cards, info tips in the headerAccessory
/// slot, hints in the footer slot.
struct TranscriptionSection: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var tabValue: String = TranscriptionEngine.openrouter.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NockerlSpace.space4) {
                SectionTitle(.transcription)
                // The first-class design-system NockerlTabs (v1.15.0): icon tabs on the
                // contained NockerlSurface panel. Each tab owns its engine's config.
                NockerlTabs(
                    tabs: [
                        NockerlTabItem(
                            value: TranscriptionEngine.openrouter.rawValue, label: "OpenRouter",
                            icon: AnyView(Image("openrouter").renderingMode(.template).resizable().scaledToFit().frame(width: 15, height: 15))
                        ),
                        NockerlTabItem(
                            value: TranscriptionEngine.custom.rawValue, label: "Custom",
                            icon: AnyView(Image(systemName: "server.rack"))
                        ),
                    ],
                    selection: $tabValue,
                    label: "Transcription engine",
                    variant: .underline
                ) { value in
                    if value == TranscriptionEngine.custom.rawValue {
                        CustomTab(settings: settings)
                    } else {
                        OpenRouterTab(settings: settings)
                    }
                }
            }
            .padding(NockerlSpace.space6)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { tabValue = (settings.defaultEngine ?? .openrouter).rawValue }
    }
}

/// The "Default" card. A standard toggle (mirrors Launch at login), mutually exclusive across
/// engines: turning it on for one tab turns the other off. The toggle is inert until this
/// engine is configured.
///
/// It says nothing about WHY it is inert, and that is the point. A red "Add your API key
/// first" used to sit under it, which put an error colour on the completely expected state of
/// a tab nobody has filled in yet. The explanation belongs beside the field that resolves it,
/// as an informational banner, not as a warning attached to the consequence.
private struct SetAsDefaultCard: View {
    @ObservedObject var settings: SettingsStore
    let engine: TranscriptionEngine
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        let configured = settings.isConfigured(engine)
        NockerlFormSection("Default") {
            VStack(alignment: .leading, spacing: NockerlSpace.space2) {
                HStack(spacing: 6) {
                    Text("Set as default").foregroundStyle(palette.onCard)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.defaultEngine == engine },
                        set: { on in
                            if on { settings.setDefaultEngine(engine) }
                            else if settings.isConfigured(engine.other) { settings.setDefaultEngine(engine.other) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.nockerl)
                    .disabled(!configured)
                }
            }
        }
    }
}

/// A write-only Keychain key field, reused for the OpenRouter key and the optional Custom
/// key. Saved state shows a status row with replace/remove; empty state shows a secure input
/// with an inline cyan Save. The key is never shown back.
private struct KeychainKeyField: View {
    let title: String
    let savedTitle: String
    let present: Bool
    let onSave: (String) -> Void
    let onClear: () -> Void
    @State private var keyInput = ""
    @State private var editing = false
    @State private var confirmRemove = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        Group {
            if present && !editing {
                HStack(spacing: NockerlSpace.space3) {
                    NockerlInsetIcon(systemName: "checkmark", accessibilityLabel: "API key saved", tone: .brand, size: .sm)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(savedTitle).nockerlType(.bodyMedium).foregroundStyle(palette.onCard)
                        Text("Stored in your Keychain, on this device.")
                            .font(.system(size: NockerlFontSize.size12, weight: .light))
                            .foregroundStyle(palette.onCanvasMuted)
                    }
                    Spacer(minLength: NockerlSpace.space2)
                    NockerlDesign.NockerlIconButton(systemName: "pencil", label: "Replace key", density: .compact) {
                        keyInput = ""; editing = true
                    }.help("Replace key")
                    NockerlDesign.NockerlIconButton(systemName: "trash", label: "Remove key", density: .compact, tint: .destructive) {
                        confirmRemove = true
                    }
                    .help("Remove key")
                    .confirmationDialog("Remove the saved key?", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Remove key", role: .destructive) { onClear() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            } else {
                HStack(spacing: NockerlSpace.space2) {
                    SecureField(editing ? "New \(title)" : title, text: $keyInput)
                        .textFieldStyle(.plain)
                        .foregroundStyle(palette.onCanvas)
                        .nockerlFieldWell()
                    NockerlDesign.NockerlIconButton(systemName: "checkmark", label: "Save key", density: .compact) {
                        onSave(keyInput); keyInput = ""; editing = false
                    }
                    .help("Save key")
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editing {
                        NockerlDesign.NockerlIconButton(systemName: "xmark", label: "Cancel", density: .compact, tint: .neutral) {
                            keyInput = ""; editing = false
                        }.help("Cancel")
                    }
                }
            }
        }
        .frame(minHeight: NockerlSpace.space10, alignment: .center)
        .animation(.easeInOut(duration: 0.18), value: editing)
    }
}

/// The OpenRouter tab: default marker, the API key, then the live Model + Provider pickers.
private struct OpenRouterTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space4) {
            SetAsDefaultCard(settings: settings, engine: .openrouter)
            ZDRToggleCard(settings: settings)
            // Key + model + provider combined into one card (saves the height that was
            // causing the tab to scroll).
            NockerlFormSection(
                "OpenRouter settings",
                // The field assumed an account the reader may not have. This says what the
                // key is and where it comes from; the link beneath it is the way there.
                // The tip changes with the same state as the link below it. Its last
                // sentence pointed at "the link below", which is not there once a key is
                // saved, so leaving the text fixed would have described a control that no
                // longer exists. What the key IS and where it is stored stays useful
                // forever; only the how-to-get-one half is first-run copy.
                headerAccessory: AnyView(NockerlInfoTip(text: settings.cloudKeyPresent
                    ? "OpenRouter is a paid gateway to many speech models, and this key is how Nockerl Voice pays for your transcriptions. The key is stored in your Keychain on this device and is sent only to OpenRouter."
                    : "OpenRouter is a paid gateway to many speech models, and this key is how Nockerl Voice pays for your transcriptions. The key is stored in your Keychain on this device and is sent only to OpenRouter. If you do not have an account yet, use the link below to create one and generate a key."))
            ) {
                VStack(alignment: .leading, spacing: NockerlSpace.space3) {
                    // Informational, not a warning. Having no key yet is the expected state of
                    // a fresh install, so this states what the key unlocks and stops. `.info`
                    // is the brand cyan; a warning or danger intent here would put an alarm
                    // colour on someone who has done nothing wrong.
                    if !settings.cloudKeyPresent {
                        NockerlBanner(
                            message: "Add your OpenRouter key to choose a model and provider, and to make this your default engine.",
                            intent: .info
                        )
                    }
                    KeychainKeyField(
                        title: "OpenRouter API key", savedTitle: "OpenRouter API key saved",
                        present: settings.cloudKeyPresent,
                        onSave: { settings.setCloudKey($0) }, onClear: { settings.clearCloudKey() }
                    )
                    // A real link, so it announces as a link and opens the default browser,
                    // rather than a bare URL printed as text for the reader to retype.
                    //
                    // Gated on the SAME state the field above reads, so the way in
                    // disappears once the user is in. Unconditionally, it kept telling
                    // someone who had already saved a key to go and create an account.
                    if !settings.cloudKeyPresent {
                        OpenRouterKeyLink()
                    }
                    // Hidden until a key exists, rather than shown as two dropdowns that can
                    // only say "Add your API key first". Both lists are fetched FROM
                    // OpenRouter with that key, so before it is saved there is nothing to
                    // choose from and the controls are pure furniture. The banner above the
                    // field already says the key is what unlocks them.
                    //
                    // The fetch still fires at the right moment: `CloudPickers` carries
                    // `.task(id: settings.cloudKeyPresent)`, so saving a key both reveals the
                    // pickers and loads their contents.
                    if settings.cloudKeyPresent {
                        CloudPickers(settings: settings)
                    }
                }
            }
        }
    }
}

/// The way in for someone who has no OpenRouter account yet. A `Link` rather than a button
/// with an `openURL` call, so it carries the link role and opens the default browser.
private struct OpenRouterKeyLink: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        return Link(destination: URL(string: "https://openrouter.ai/settings/keys")!) {
            HStack(spacing: NockerlSpace.space1) {
                Text("Create an account and generate a key")
                    .nockerlType(.labelSmall)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: NockerlFontSize.size12))
            }
            .foregroundStyle(palette.accentPrimary)
        }
        .buttonStyle(.plain)
        .help("Opens openrouter.ai in your browser.")
    }
}

/// The zero-data-retention toggle card on the OpenRouter tab. Default on; off lets you use a
/// provider that does not guarantee ZDR (your audio may then be retained).
private struct ZDRToggleCard: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        NockerlFormSection(
            "Privacy",
            headerAccessory: AnyView(NockerlInfoTip(text: "Zero data retention means the provider does not store your audio. Leave it on to only use providers that guarantee it; turn it off to allow any provider, in which case your audio may be retained."))
        ) {
            HStack(spacing: 6) {
                Text("Require zero data retention").foregroundStyle(palette.onCard)
                Spacer()
                Toggle("", isOn: $settings.requireZDR).labelsHidden().toggleStyle(.nockerl)
            }
        }
    }
}

/// The Custom tab: default marker, the Omni endpoint URL (with the model-capability tip),
/// and an optional API key. "Custom" because the endpoint may be local or self-hosted.
private struct CustomTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space4) {
            SetAsDefaultCard(settings: settings, engine: .custom)
            NockerlFormSection(
                "Omni endpoint",
                headerAccessory: AnyView(NockerlInfoTip(text: "An OpenAI-compatible transcription URL. Styles, vocabulary, and speaker labels need a model that can follow instructions about your audio (an omni model like MiMo, Gemini, or Qwen-Omni). Plain transcribers like Whisper or Deepgram still work, but return raw text only."))
            ) {
                VStack(alignment: .leading, spacing: NockerlSpace.space3) {
                    // The same treatment the OpenRouter tab gets, for the same reason: the red
                    // line under its Set as default toggle went too, and a toggle that is
                    // simply inert with no explanation anywhere is worse than the red line
                    // was. Said here, beside the field that resolves it, and in the
                    // informational tone the situation deserves.
                    if !settings.isConfigured(.custom) {
                        NockerlBanner(
                            message: "Set an endpoint URL to make this your default engine.",
                            intent: .info
                        )
                    }
                    EditableEndpointField(
                        endpoint: Binding(get: { settings.localEndpoint }, set: { settings.saveCustomEndpoint($0) }),
                        placeholder: "http://localhost:8000",
                        emptyText: "No endpoint set"
                    )
                }
            }
            NockerlFormSection("API key (optional)") {
                KeychainKeyField(
                    title: "API key", savedTitle: "Custom API key saved",
                    present: settings.customKeyPresent,
                    onSave: { settings.setCustomKey($0) }, onClear: { settings.clearCustomKey() }
                )
            }
        }
    }
}

/// The Cloud **Model** + **Provider** pickers. Both lists are fetched live from the
/// OpenRouter API (audio-capable models, and ZDR + audio-capable providers with pricing)
/// and bound to `settings.cloudModel` / `settings.cloudProvider`. Everything is explicit:
/// you pick both; there is no automatic routing. When the provider list loads
/// and none is validly selected, the cheapest is selected (visible + changeable). With no
/// key / network, the pickers show a clear placeholder. Uses the framework
/// `NockerlSelect`.
private struct CloudPickers: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var network = NetworkMonitor.shared
    @State private var models: [CloudModelInfo] = []
    @State private var providers: [CloudProviderInfo] = []
    @State private var loadingModels = false
    @State private var loadingProviders = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        VStack(alignment: .leading, spacing: NockerlSpace.space3) {
            VStack(alignment: .leading, spacing: NockerlSpace.space1) {
                Text("Model".uppercased())
                    .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                    .foregroundStyle(palette.onCanvasMuted)
                NockerlSelect(
                    options: modelOptions,
                    selection: $settings.cloudModel,
                    placeholder: "Select a model…",
                    isLoading: loadingModels,
                    emptyText: modelsEmptyText,
                    grouped: true
                )
                // The per-row mark says WHICH models are blocked; this says what to do
                // about it, and only when the blocked model is the one actually selected.
                // A callout is a block element and sits under the picker, so it cannot
                // disturb the dropdown's own layout.
                if selectedModelBlockedByZDR {
                    NockerlCallout(
                        message: "This model has no provider offering zero data retention, so it cannot run while the requirement is on. Pick a different model, or turn the requirement off below.",
                        tone: .warning,
                        title: "Zero data retention"
                    )
                }
            }
            VStack(alignment: .leading, spacing: NockerlSpace.space1) {
                Text("Provider".uppercased())
                    .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                    .foregroundStyle(palette.onCanvasMuted)
                NockerlSelect(
                    options: providerOptions,
                    selection: $settings.cloudProvider,
                    placeholder: "Select a provider…",
                    isLoading: loadingProviders,
                    emptyText: providersEmptyText
                )
            }
        }
        .task(id: settings.cloudKeyPresent) { await loadModels() }
        .task(id: "\(settings.cloudKeyPresent)|\(settings.cloudModel)") { await loadProviders() }
    }

    /// Offline is the FIRST thing to check: a failed fetch returns an empty list, and saying
    /// "No audio models found" when the real cause is a dead connection sends people hunting
    /// for a problem with their key or OpenRouter.
    /// No no-key branch, because this whole view only renders once a key is saved. It used
    /// to fall back to "Add your API key first", which is now said once, as a banner beside
    /// the field that fixes it.
    private var modelsEmptyText: String {
        if !network.isOnline { return "You're offline" }
        return "No audio models found"
    }

    private var providersEmptyText: String {
        if !network.isOnline { return "You're offline" }
        return "No providers available for this model"
    }

    /// True when the model the user has actually selected cannot run under the current
    /// zero-data-retention setting. Drives the callout under the picker.
    private var selectedModelBlockedByZDR: Bool {
        settings.requireZDR && CloudProviderCatalog.isZDRIncompatible(settings.cloudModel)
    }

    private var modelOptions: [NockerlSelectOption] {
        // Grouped into Recommended / Untested sections: the picker renders the uppercase
        // eyebrow headers. Models arrive recommended-first, so the groups are contiguous.
        // The group header carries the TIER, so there is no status dot for that.
        //
        // NO per-row ZDR warning. Rows used to carry an amber dot and "Unavailable while
        // zero data retention is on" for models with no zero-retention provider. It was
        // said too early and in the wrong register: a list of choices is not the place to
        // start warning, and an amber dot inside a dropdown does not belong to any of the
        // shapes the rest of this app uses. The same fact is already delivered better in
        // two places that fire on the actual decision: the callout under the picker once
        // such a model is SELECTED, and the plain-language error if a request is ever made
        // under that combination. Both name the conflict and say what to do about it.
        models.map { model in
            NockerlSelectOption(
                value: model.id,
                label: model.name,
                group: model.recommended ? "Recommended" : "Untested"
            )
        }
    }

    private var providerOptions: [NockerlSelectOption] {
        providers.map { p in
            var secondary = p.priceLabel
            if let tps = p.throughputTps { secondary += "  ·  \(tps) tps" }
            // No status dot: every listed provider is already ZDR-filtered, so a dot on
            // every row carried no signal. Title + pricing on the secondary line is enough.
            return NockerlSelectOption(value: p.slug, label: p.name, secondary: secondary)
        }
    }

    @MainActor
    private func loadModels() async {
        guard settings.cloudKeyPresent, let key = KeychainStore.cloudKey(), !key.isEmpty else {
            models = []
            return
        }
        loadingModels = true
        models = await CloudProviderCatalog.fetchAudioModels(apiKey: key)
        loadingModels = false
    }

    @MainActor
    private func loadProviders() async {
        guard settings.cloudKeyPresent, let key = KeychainStore.cloudKey(), !key.isEmpty else {
            providers = []
            return
        }
        loadingProviders = true
        let model = settings.cloudModel.isEmpty ? TranscriptionConfig.defaultCloudModel : settings.cloudModel
        let result = await CloudProviderCatalog.fetchProviders(model: model, apiKey: key)
        providers = result
        loadingProviders = false
        // Pick a default when the current one is not valid for this model. PREFERRED
        // first, cheapest only as the fallback.
        //
        // Cheapest-first alone landed new users on whichever provider happened to be
        // priciest-cheapest that day, which in practice was one that fails the request on
        // its own side. A first transcription that errors is the worst possible first
        // impression, and the user has no way to know the provider was the problem. The
        // preferred slug is a known-good default; it stays fully changeable in the
        // dropdown, so this is still an explicit choice and not hidden routing.
        if !result.contains(where: { $0.slug == settings.cloudProvider }) {
            let preferred = result.first { $0.slug == CloudProviderCatalog.preferredProviderSlug }
            settings.autoSelectProvider((preferred ?? result.first)?.slug ?? "")
        }
    }
}

/// A single-line value with an inline edit flow: a pencil to edit, then Save to
/// commit (or Cancel to discard). No delete: clearing the field and saving simply
/// turns the value off. Used for both the local endpoint and the cloud model slug.
private struct EditableEndpointField: View {
    @Binding var endpoint: String
    var placeholder: String = "https://your-server:port"
    var emptyText: String = "Not set"
    var editHelp: String = "Edit endpoint"
    @State private var editing = false
    @State private var draft = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        // Match the API key field's height: the recessed well wraps ONLY the input/value; the
        // action icons sit OUTSIDE it, so the row is the same short height (wrapping the whole
        // row in the well, icons and all, is what made this box tall).
        HStack(spacing: NockerlSpace.space2) {
            if editing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.nockerlMono(size: 13))
                    .foregroundStyle(palette.onCanvas)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit(save)
                    .nockerlFieldWell()
                NockerlDesign.NockerlIconButton(systemName: "checkmark", label: "Save", density: .compact, action: save)
                    .help("Save")
                NockerlDesign.NockerlIconButton(systemName: "xmark", label: "Cancel", density: .compact, action: { editing = false })
                    .help("Cancel")
            } else {
                Text(endpoint.isEmpty ? emptyText : endpoint)
                    .font(.nockerlMono(size: 13))
                    .foregroundStyle(endpoint.isEmpty ? palette.onCanvasMuted : palette.onCanvas)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nockerlFieldWell()
                NockerlDesign.NockerlIconButton(
                    systemName: "pencil", label: editHelp, density: .compact,
                    action: {
                        draft = endpoint
                        editing = true
                    }
                )
                .help(editHelp)
            }
        }
        .animation(.nockerlStandard(NockerlMotionDuration.base), value: editing)
    }

    private func save() {
        endpoint = draft.trimmingCharacters(in: .whitespaces)
        editing = false
    }
}
