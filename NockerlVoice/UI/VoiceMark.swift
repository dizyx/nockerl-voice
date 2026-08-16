import AppKit

/// The menu bar's Voice mark, and ONLY that.
///
/// Everything else that used to live here is gone. The product mark now comes from
/// NockerlDesign (`NockerlProductMark(.voice)`), whose art ships inside the package and
/// resolves from `Bundle.module`, and the hand-rolled lockup was retired when
/// `NockerlLockup` gained a `mark:` slot. Rendering the mark app-side would now be a
/// second source of truth for the same artwork.
///
/// WHY THIS SURVIVES. A status item needs an `NSImage` with `isTemplate = true`: macOS
/// draws only its alpha and tints it for light and dark menu bars. The package's public
/// surface for product art is a SwiftUI `Image` (`NockerlProduct.image`) and the
/// `NockerlProductMark` view. Neither yields a tintable template `NSImage`, and putting a
/// SwiftUI `Image` in the status item would render the full-colour art and ignore menu bar
/// tinting entirely. Until the framework offers a template image, this stays.
///
/// The vendored asset it reads (`VoiceMarkTemplate.imageset`) is likewise deliberate: its
/// SVG is drawn entirely in `#000000` and the imageset carries
/// `template-rendering-intent: template`, so the colour cannot survive even if the
/// `isTemplate` flag below were ever lost.
enum VoiceMark {
    /// Monochrome silhouette for the menu bar.
    static let templateAssetName = "VoiceMarkTemplate"

    /// A menu-bar-ready TEMPLATE image. Two independent guarantees that no colour reaches
    /// the menu bar: the vendored SVG is already pure black, and `isTemplate` is set here.
    ///
    /// The catalog image is a shared cached instance, so it is COPIED before its `size` and
    /// `isTemplate` are set. Mutating the cached original would leak into every other use.
    static func statusItemImage(size: CGFloat = 16) -> NSImage {
        guard let cached = NSImage(named: Self.templateAssetName) else {
            // Missing asset: an empty image keeps the menu bar alive rather than crashing.
            return NSImage(size: NSSize(width: size, height: size))
        }
        let image = (cached.copy() as? NSImage) ?? cached
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
