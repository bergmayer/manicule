import SwiftUI
import os

struct MarginSettings: Codable, Sendable, Equatable {
    var topBottom: Double = 8
    var leftRight: Double = 16
    static let `default` = MarginSettings()
}

/// Global and per-book reading preferences for typography and appearance.
@Observable @MainActor
final class ReadingPreferences {
    private static let logger = Logger(subsystem: "com.palefire.raedad", category: "ReadingPreferences")
    static let shared = ReadingPreferences()

    // MARK: - Global Defaults

    var fontFamily: FontFamily = .serif
    var fontSize: Double = 18
    var lineSpacing: Double = 1.4
    var marginsOneUp: MarginSettings = .default
    var marginsTwoUp: MarginSettings = .default
    var theme: ReaderTheme = .system
    var viewMode: ViewMode = .paginated
    var reflowText: Bool = false
    var trimWhitespace: Bool = false
    var textAlign: TextAlignment = .natural

    // MARK: - Per-Book Overrides

    /// Keyed by file hash prefix. If a key exists, its values override the global defaults.
    private(set) var perBookOverrides: [String: BookOverride] = [:]

    // MARK: - Persistence Keys

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private let globalKey = "raedad.readingPrefs.global"
    private let overridesKey = "raedad.readingPrefs.overrides"

    /// Maximum number of per-book overrides to keep.
    static let maxOverrides = 60

    private init() {
        loadFromDefaults()
    }

    // MARK: - Effective Preferences

    /// Returns the effective preferences for a specific file, merging per-book overrides if present.
    func effective(for fileHash: String?) -> EffectivePreferences {
        guard let hash = fileHash, let override = perBookOverrides[hash] else {
            return EffectivePreferences(
                fontFamily: fontFamily,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                marginsOneUp: marginsOneUp,
                marginsTwoUp: marginsTwoUp,
                theme: theme,
                viewMode: viewMode,
                twoUp: nil,
                reflowText: reflowText,
                trimWhitespace: trimWhitespace,
                textAlign: textAlign
            )
        }
        return EffectivePreferences(
            fontFamily: override.fontFamily ?? fontFamily,
            fontSize: override.fontSize ?? fontSize,
            lineSpacing: override.lineSpacing ?? lineSpacing,
            marginsOneUp: override.marginsOneUp ?? marginsOneUp,
            marginsTwoUp: override.marginsTwoUp ?? marginsTwoUp,
            theme: override.theme ?? theme,
            viewMode: override.viewMode ?? viewMode,
            twoUp: override.twoUp,
            reflowText: override.reflowText ?? reflowText,
            trimWhitespace: override.trimWhitespace ?? trimWhitespace,
            textAlign: override.textAlign ?? textAlign
        )
    }

    /// Updates the lastUsed timestamp for a per-book override (for LRU eviction).
    /// Call this when a book is opened, not on every settings read.
    func touchLastUsed(for fileHash: String?) {
        guard let hash = fileHash, perBookOverrides[hash] != nil else { return }
        if let lastUsed = perBookOverrides[hash]?.lastUsed,
           Date().timeIntervalSince(lastUsed) <= 60 { return }
        perBookOverrides[hash]?.lastUsed = Date()
    }

    /// Whether a per-book override exists for the given hash.
    func hasOverride(for fileHash: String?) -> Bool {
        guard let hash = fileHash else { return false }
        return perBookOverrides[hash] != nil
    }

    /// Whether the override limit has been reached for new books.
    var isOverrideLimitReached: Bool {
        perBookOverrides.count >= Self.maxOverrides
    }

    /// Sets a per-book override. Returns an error message if the limit is reached for a new book; nil on success.
    @discardableResult
    func setOverride(for fileHash: String, override: BookOverride) -> String? {
        // Allow updating existing overrides even when at limit
        if perBookOverrides[fileHash] == nil && perBookOverrides.count >= Self.maxOverrides {
            return "You have \(Self.maxOverrides) books with custom settings. Please remove some in Settings > Books before adding more."
        }
        var updated = override
        updated.lastUsed = Date()
        perBookOverrides[fileHash] = updated
        save()
        return nil
    }

    /// Removes the per-book override, reverting to global defaults.
    func removeOverride(for fileHash: String) {
        perBookOverrides.removeValue(forKey: fileHash)
        save()
    }

    /// Updates a preference for a specific book. Always creates a per-book override
    /// when a fileHash is available, so view mode, twoUp, and other settings are
    /// tracked per-book and restored when reopening. Falls back to global default
    /// only when no fileHash is available.
    func updatePreference(for fileHash: String?, apply: (inout BookOverride) -> Void, applyGlobal: () -> Void) {
        if let hash = fileHash {
            var override = perBookOverrides[hash] ?? BookOverride()
            apply(&override)
            setOverride(for: hash, override: override)
        } else {
            applyGlobal()
            save()
        }
    }

    /// Sets the viewMode and twoUp preference together. Used by all four readers'
    /// `select{Automatic,SinglePage,TwoPage,Scrolling}` methods so the boilerplate
    /// of building per-book overrides vs. updating globals lives in one place.
    func setViewMode(_ mode: ViewMode, twoUp: Bool?, for fileHash: String?) {
        updatePreference(
            for: fileHash,
            apply: { $0.viewMode = mode; $0.twoUp = twoUp },
            applyGlobal: { self.viewMode = mode }
        )
    }

    /// Persists current preferences. Both global defaults and per-book overrides
    /// go to UserDefaults (device-local). Reading settings are intentionally NOT
    /// synced — each device can have its own view mode, font size, etc. Bookmarks
    /// and reading positions sync via iCloud in BookmarkStore.
    func save() {
        let global = GlobalPrefs(
            fontFamily: fontFamily,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            marginsOneUp: marginsOneUp,
            marginsTwoUp: marginsTwoUp,
            theme: theme,
            viewMode: viewMode,
            reflowText: reflowText,
            trimWhitespace: trimWhitespace,
            textAlign: textAlign
        )
        do {
            let data = try JSONEncoder().encode(global)
            defaults.set(data, forKey: globalKey)
        } catch {
            Self.logger.error("Failed to encode global prefs: \(error)")
        }
        do {
            let data = try JSONEncoder().encode(perBookOverrides)
            defaults.set(data, forKey: overridesKey)
        } catch {
            Self.logger.error("Failed to encode per-book overrides: \(error)")
        }
    }

    private func loadFromDefaults() {
        if let data = defaults.data(forKey: globalKey),
           let global = try? JSONDecoder().decode(GlobalPrefs.self, from: data) {
            fontFamily = global.fontFamily
            fontSize = global.fontSize
            lineSpacing = global.lineSpacing
            marginsOneUp = global.marginsOneUp
            marginsTwoUp = global.marginsTwoUp
            theme = global.theme
            viewMode = global.viewMode
            reflowText = global.reflowText
            trimWhitespace = global.trimWhitespace
            textAlign = global.textAlign
        }
        // Load per-book overrides from UserDefaults
        if let data = defaults.data(forKey: overridesKey),
           let overrides = try? JSONDecoder().decode([String: BookOverride].self, from: data) {
            perBookOverrides = overrides
        }
        // Migrate overrides from iCloud to UserDefaults (one-time, reverse of old migration)
        if perBookOverrides.isEmpty,
           let cloudData = cloud.data(forKey: overridesKey),
           let cloudOverrides = try? JSONDecoder().decode([String: BookOverride].self, from: cloudData) {
            perBookOverrides = cloudOverrides
            save()
            cloud.removeObject(forKey: overridesKey)
            cloud.synchronize()
        }
    }

}

// MARK: - Supporting Types

/// The resolved preferences to apply, after merging global + per-book overrides.
struct EffectivePreferences: Sendable {
    let fontFamily: FontFamily
    let fontSize: Double
    let lineSpacing: Double
    let marginsOneUp: MarginSettings
    let marginsTwoUp: MarginSettings
    let theme: ReaderTheme
    let viewMode: ViewMode
    let twoUp: Bool?       // nil = use orientation default, true/false = explicit
    let reflowText: Bool
    let trimWhitespace: Bool
    let textAlign: TextAlignment

    /// Generates CSS for injection into WKWebView text content.
    /// Uses one-up margins (scroll mode is single-column).
    var cssString: String {
        var css = """
        body {
            font-family: \(fontFamily.cssFontStack) !important;
            font-size: \(fontSize)px !important;
            line-height: \(lineSpacing) !important;
            padding: \(marginsOneUp.topBottom)px \(marginsOneUp.leftRight)px !important;
        """
        if textAlign == .justified {
            css += "\n    text-align: justify !important;"
        } else {
            css += "\n    text-align: start !important;"
        }
        if let bgColor = theme.cssBackground {
            css += "\n    background-color: \(bgColor) !important;"
        }
        if let textColor = theme.cssForeground {
            css += "\n    color: \(textColor) !important;"
        }
        css += "\n}"
        return css
    }

    /// Generates CSS for foliate-js setStyles() injection into ePub content iframes.
    var foliateCSS: String {
        var css = """
        @namespace epub "http://www.idpf.org/2007/ops";
        html {
            color-scheme: light dark;
        """
        // Default font: set as fallback on html, don't override document fonts
        if fontFamily.respectsDocumentFont {
            css += "\n    font-family: \(fontFamily.cssFontStack);"
        }
        css += """

        }
        p, li, blockquote, dd, div, span, h1, h2, h3, h4, h5, h6 {
        """
        // Explicit font choice: override with !important
        if !fontFamily.respectsDocumentFont {
            css += "\n    font-family: \(fontFamily.cssFontStack) !important;"
        }
        css += """

            font-size: \(fontSize)px !important;
            line-height: \(lineSpacing) !important;
        """
        if textAlign == .justified {
            css += "\n    text-align: justify !important;"
        } else {
            css += "\n    text-align: start !important;"
        }
        css += """

        }
        sup, sub {
            font-size: 0.75em !important;
            line-height: 0 !important;
        }
        sup *, sub * {
            font-size: inherit !important;
            line-height: inherit !important;
        }
        sup, sup * { vertical-align: super !important; }
        sub, sub * { vertical-align: sub !important; }
        """

        if let bgColor = theme.cssBackground, let textColor = theme.cssForeground {
            // Override colors on html, body, and all common text elements.
            // Many ePubs set explicit colors via CSS or inline styles (e.g.
            // body { color: #000 } or <span style="color:black">) which
            // override an html-only rule. Without this, dark/OLED themes
            // show black text on a black background for those books.
            css += """

            html, body {
                background-color: \(bgColor) !important;
                color: \(textColor) !important;
            }
            body, p, li, blockquote, dd, div, span, td, th,
            h1, h2, h3, h4, h5, h6, a, em, strong, b, i, small,
            dt, figcaption, caption, label, cite, q, pre, code {
                color: \(textColor) !important;
            }
            a { color: \(textColor) !important; text-decoration: underline; }
            img, svg, video, canvas, figure { mix-blend-mode: normal; }
            """
        }

        return css
    }

    /// SwiftUI Font for text views.
    var swiftUIFont: Font {
        switch fontFamily {
        case .system:
            return .system(size: fontSize, design: .serif)
        case .serif:
            return .system(size: fontSize, design: .serif)
        case .sansSerif:
            return .system(size: fontSize, design: .default)
        case .monospaced:
            return .system(size: fontSize, design: .monospaced)
        case .georgia:
            return .custom("Georgia", size: fontSize)
        case .palatino:
            return .custom("Palatino", size: fontSize)
        case .baskerville:
            return .custom("Baskerville", size: fontSize)
        case .charter:
            return .custom("Charter", size: fontSize)
        case .iowan:
            return .custom("Iowan Old Style", size: fontSize)
        case .helvetica:
            return .custom("Helvetica Neue", size: fontSize)
        case .avenir:
            return .custom("Avenir Next", size: fontSize)
        case .literata:
            return .custom("Literata", size: fontSize)
        }
    }

    /// SwiftUI background Color for text views.
    var backgroundColor: Color? { theme.swiftUIBackground }

    /// SwiftUI foreground Color for text views.
    var foregroundColor: Color? { theme.swiftUIForeground }
}

/// Per-book override — nil fields inherit from global defaults.
struct BookOverride: Codable, Sendable {
    var fontFamily: FontFamily?
    var fontSize: Double?
    var lineSpacing: Double?
    var marginsOneUp: MarginSettings?
    var marginsTwoUp: MarginSettings?
    var theme: ReaderTheme?
    var viewMode: ViewMode?
    var twoUp: Bool?
    var reflowText: Bool?
    var trimWhitespace: Bool?
    var textAlign: TextAlignment?
    var lastUsed: Date?

    /// Returns true if all fields are nil (no overrides set).
    var isEmpty: Bool {
        fontFamily == nil && fontSize == nil && lineSpacing == nil
            && marginsOneUp == nil && marginsTwoUp == nil && theme == nil
            && viewMode == nil && twoUp == nil && reflowText == nil
            && trimWhitespace == nil && textAlign == nil
    }

    init(fontFamily: FontFamily? = nil, fontSize: Double? = nil, lineSpacing: Double? = nil,
         marginsOneUp: MarginSettings? = nil, marginsTwoUp: MarginSettings? = nil,
         theme: ReaderTheme? = nil, viewMode: ViewMode? = nil, twoUp: Bool? = nil,
         reflowText: Bool? = nil, trimWhitespace: Bool? = nil, textAlign: TextAlignment? = nil,
         lastUsed: Date? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.marginsOneUp = marginsOneUp
        self.marginsTwoUp = marginsTwoUp
        self.theme = theme
        self.viewMode = viewMode
        self.twoUp = twoUp
        self.reflowText = reflowText
        self.trimWhitespace = trimWhitespace
        self.textAlign = textAlign
        self.lastUsed = lastUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try container.decodeIfPresent(FontFamily.self, forKey: .fontFamily)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
        lineSpacing = try container.decodeIfPresent(Double.self, forKey: .lineSpacing)
        theme = try container.decodeIfPresent(ReaderTheme.self, forKey: .theme)
        viewMode = try container.decodeIfPresent(ViewMode.self, forKey: .viewMode)
        twoUp = try container.decodeIfPresent(Bool.self, forKey: .twoUp)
        reflowText = try container.decodeIfPresent(Bool.self, forKey: .reflowText)
        trimWhitespace = try container.decodeIfPresent(Bool.self, forKey: .trimWhitespace)
        textAlign = try container.decodeIfPresent(TextAlignment.self, forKey: .textAlign)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)

        // Backward compat: migrate old horizontalMargin to both margin structs
        if let oldMargin = try? container.decodeIfPresent(Double.self, forKey: .horizontalMargin) {
            let m = MarginSettings(topBottom: oldMargin, leftRight: oldMargin)
            marginsOneUp = m
            marginsTwoUp = m
        } else {
            marginsOneUp = try container.decodeIfPresent(MarginSettings.self, forKey: .marginsOneUp)
            marginsTwoUp = try container.decodeIfPresent(MarginSettings.self, forKey: .marginsTwoUp)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fontFamily, fontSize, lineSpacing, marginsOneUp, marginsTwoUp
        case theme, viewMode, twoUp, reflowText, trimWhitespace, textAlign, lastUsed
        case horizontalMargin // legacy key for backward compat decoding only
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try container.encodeIfPresent(fontSize, forKey: .fontSize)
        try container.encodeIfPresent(lineSpacing, forKey: .lineSpacing)
        try container.encodeIfPresent(marginsOneUp, forKey: .marginsOneUp)
        try container.encodeIfPresent(marginsTwoUp, forKey: .marginsTwoUp)
        try container.encodeIfPresent(theme, forKey: .theme)
        try container.encodeIfPresent(viewMode, forKey: .viewMode)
        try container.encodeIfPresent(twoUp, forKey: .twoUp)
        try container.encodeIfPresent(reflowText, forKey: .reflowText)
        try container.encodeIfPresent(trimWhitespace, forKey: .trimWhitespace)
        try container.encodeIfPresent(textAlign, forKey: .textAlign)
        try container.encodeIfPresent(lastUsed, forKey: .lastUsed)
    }
}

enum FontFamily: String, Codable, Sendable, CaseIterable {
    case system = "Default"
    case serif = "Serif"
    case sansSerif = "Sans Serif"
    case monospaced = "Monospaced"
    case georgia = "Georgia"
    case palatino = "Palatino"
    case baskerville = "Baskerville"
    case charter = "Charter"
    case iowan = "Iowan Old Style"
    case helvetica = "Helvetica Neue"
    case avenir = "Avenir"
    case literata = "Literata"

    /// Whether this font respects the document's own font choice.
    var respectsDocumentFont: Bool { self == .system }

    /// CSS font-family stack for web view injection.
    var cssFontStack: String {
        switch self {
        case .system: "serif"
        case .serif: "Georgia, 'Times New Roman', serif"
        case .sansSerif: "'Helvetica Neue', Helvetica, Arial, sans-serif"
        case .monospaced: "'SF Mono', Menlo, Consolas, monospace"
        case .georgia: "Georgia, serif"
        case .palatino: "Palatino, 'Palatino Linotype', 'Book Antiqua', serif"
        case .baskerville: "Baskerville, 'Baskerville Old Face', serif"
        case .charter: "Charter, 'Bitstream Charter', serif"
        case .iowan: "'Iowan Old Style', 'Palatino Linotype', serif"
        case .helvetica: "'Helvetica Neue', Helvetica, Arial, sans-serif"
        case .avenir: "'Avenir Next', Avenir, 'Helvetica Neue', sans-serif"
        case .literata: "Literata, Charter, Georgia, serif"
        }
    }
}

enum ReaderTheme: String, Codable, Sendable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case oled = "OLED Black"
    case sepia = "Sepia"

    /// CSS background color string, or nil for system theme.
    var cssBackground: String? {
        switch self {
        case .system: nil
        case .light: "#ffffff"
        case .dark: "#1c1c1e"
        case .oled: "#000000"
        case .sepia: "#f5e6c8"
        }
    }

    /// CSS foreground (text) color string, or nil for system theme.
    var cssForeground: String? {
        switch self {
        case .system: nil
        case .light: "#000000"
        case .dark: "#e5e5e7"
        case .oled: "#e5e5e7"
        case .sepia: "#3b2e1a"
        }
    }

    /// SwiftUI background Color, or nil for system theme.
    var swiftUIBackground: Color? {
        switch self {
        case .system: nil
        case .light: Color.white
        case .dark: Color(red: 0.11, green: 0.11, blue: 0.12)
        case .oled: Color.black
        case .sepia: Color(red: 0.96, green: 0.90, blue: 0.78)
        }
    }

    /// SwiftUI ColorScheme override, or nil for system theme.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .oled: .dark
        case .sepia: .light
        }
    }

    /// SwiftUI foreground Color, or nil for system theme.
    var swiftUIForeground: Color? {
        switch self {
        case .system: nil
        case .light: Color.black
        case .dark: Color(red: 0.90, green: 0.90, blue: 0.91)
        case .oled: Color(red: 0.90, green: 0.90, blue: 0.91)
        case .sepia: Color(red: 0.23, green: 0.18, blue: 0.10)
        }
    }
}

enum ViewMode: String, Codable, Sendable, CaseIterable {
    case paginated = "Paginated"
    case scrolling = "Scrolling"
}

enum TextAlignment: String, Codable, Sendable, CaseIterable {
    case natural = "Ragged Right"
    case justified = "Justified"
}

// MARK: - Codable wrapper for global prefs

private struct GlobalPrefs: Codable {
    let fontFamily: FontFamily
    let fontSize: Double
    let lineSpacing: Double
    let marginsOneUp: MarginSettings
    let marginsTwoUp: MarginSettings
    let theme: ReaderTheme
    var viewMode: ViewMode = .paginated
    var reflowText: Bool = false
    var trimWhitespace: Bool = false
    var textAlign: TextAlignment = .natural

    init(fontFamily: FontFamily, fontSize: Double, lineSpacing: Double, marginsOneUp: MarginSettings, marginsTwoUp: MarginSettings, theme: ReaderTheme, viewMode: ViewMode, reflowText: Bool, trimWhitespace: Bool, textAlign: TextAlignment) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.marginsOneUp = marginsOneUp
        self.marginsTwoUp = marginsTwoUp
        self.theme = theme
        self.viewMode = viewMode
        self.reflowText = reflowText
        self.trimWhitespace = trimWhitespace
        self.textAlign = textAlign
    }

    private enum CodingKeys: String, CodingKey {
        case fontFamily, fontSize, lineSpacing, marginsOneUp, marginsTwoUp
        case theme, viewMode, reflowText, trimWhitespace, textAlign
        case horizontalMargin // legacy key for backward compat decoding only
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try container.decode(FontFamily.self, forKey: .fontFamily)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        lineSpacing = try container.decode(Double.self, forKey: .lineSpacing)
        theme = try container.decode(ReaderTheme.self, forKey: .theme)
        viewMode = try container.decodeIfPresent(ViewMode.self, forKey: .viewMode) ?? .paginated
        reflowText = try container.decodeIfPresent(Bool.self, forKey: .reflowText) ?? false
        trimWhitespace = try container.decodeIfPresent(Bool.self, forKey: .trimWhitespace) ?? false
        textAlign = try container.decodeIfPresent(TextAlignment.self, forKey: .textAlign) ?? .natural

        // Backward compat: migrate old horizontalMargin to both margin structs
        if let oldMargin = try? container.decode(Double.self, forKey: .horizontalMargin) {
            let m = MarginSettings(topBottom: oldMargin, leftRight: oldMargin)
            marginsOneUp = m
            marginsTwoUp = m
        } else {
            marginsOneUp = try container.decodeIfPresent(MarginSettings.self, forKey: .marginsOneUp) ?? .default
            marginsTwoUp = try container.decodeIfPresent(MarginSettings.self, forKey: .marginsTwoUp) ?? .default
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontFamily, forKey: .fontFamily)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(lineSpacing, forKey: .lineSpacing)
        try container.encode(marginsOneUp, forKey: .marginsOneUp)
        try container.encode(marginsTwoUp, forKey: .marginsTwoUp)
        try container.encode(theme, forKey: .theme)
        try container.encode(viewMode, forKey: .viewMode)
        try container.encode(reflowText, forKey: .reflowText)
        try container.encode(trimWhitespace, forKey: .trimWhitespace)
        try container.encode(textAlign, forKey: .textAlign)
    }
}
