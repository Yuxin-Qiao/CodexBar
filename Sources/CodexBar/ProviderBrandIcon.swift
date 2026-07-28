import AppKit
import CodexBarCore

@MainActor
enum ProviderBrandIcon {
    private static let size = NSSize(width: 16, height: 16)
    private static var cache: [UsageProvider: NSImage] = [:]

    /// Lazy-loaded resource bundle for provider icons.
    private static let resourceBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        // SwiftPM creates a CodexBar_CodexBar.bundle for resources in the CodexBar target.
        if let bundleURL = Bundle.main.url(forResource: "CodexBar_CodexBar", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        // Fallback to main bundle for development/testing.
        return Bundle.main
    }()

    static func image(for provider: UsageProvider) -> NSImage? {
        if let cached = self.cache[provider] {
            return cached
        }

        let branding = ProviderDescriptorRegistry.descriptor(for: provider).branding
        let baseName = branding.iconResourceName
        guard let bundle = self.resourceBundle else {
            return nil
        }
        let extensions = ["svg", "png"]
        guard let url = extensions.lazy.compactMap({
            bundle.url(forResource: baseName, withExtension: $0)
        }).first else {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.size = self.size
        image.isTemplate = true
        self.cache[provider] = image
        return image
    }

    static func resetCacheForTesting() {
        self.cache.removeAll()
    }
}
