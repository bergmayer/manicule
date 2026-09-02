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
    private static let logger = Logger(subsystem: "com.palefire.manicule", category: "ReadingPreferences")
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
    private(set) var lastError: String?

    // MARK: - Persistence Keys

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private let globalKey = "manicule.readingPrefs.global"
    private let overridesKey = "manicule.readingPrefs.overrides"
    private let tombstonesKey = "manicule.readingPrefs.overrideTombstones"
    private var overrideTombstones: [String: Date] = [:]
    private var cloudObserver: NSObjectProtocol?

    /// Maximum number of per-book overrides to keep.
    static let maxOverrides = 60

    private init() {
        loadFromDefaults()
        mergeFromCloudIfAvailable()
        save()
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mergeFromCloudIfAvailable(refreshPinnedState: true)
            }
        }
        cloud.synchronize()
    }

    // MARK: - Effective Preferences

    func migrateIdentity(from legacyHash: String, to fileHash: String) {
        guard legacyHash != fileHash,
              let legacy = perBookOverrides.removeValue(forKey: legacyHash) else { return }
        if perBookOverrides[fileHash] == nil {
            perBookOverrides[fileHash] = legacy
        }
        overrideTombstones[legacyHash] = Date()
        save()
        BookmarkStore.shared.refreshPinnedStatus(for: fileHash)
    }

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
        save()
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
            let message = "You have \(Self.maxOverrides) books with custom settings. Please remove some in Settings > Books before adding more."
            lastError = message
            return message
        }
        var updated = override
        updated.lastUsed = Date()
        updated.modifiedAt = Date()
        perBookOverrides[fileHash] = updated
        overrideTombstones.removeValue(forKey: fileHash)
        lastError = nil
        save()
        BookmarkStore.shared.refreshPinnedStatus(for: fileHash)
        return nil
    }

    /// Removes the per-book override, reverting to global defaults.
    func removeOverride(for fileHash: String) {
        guard perBookOverrides.removeValue(forKey: fileHash) != nil else { return }
        overrideTombstones[fileHash] = Date()
        save()
        BookmarkStore.shared.refreshPinnedStatus(for: fileHash)
    }

    func clearAllOverrides() {
        let hashes = Array(perBookOverrides.keys)
        let now = Date()
        for hash in hashes { overrideTombstones[hash] = now }
        perBookOverrides.removeAll()
        save()
        for hash in hashes { BookmarkStore.shared.refreshPinnedStatus(for: hash) }
    }

    func clearLastError() {
        lastError = nil
    }

    /// Updates a preference for a specific book. Always creates a per-book override
    /// when a fileHash is available, so view mode, twoUp, and other settings are
    /// tracked per-book and restored when reopening. Falls back to global default
    /// only when no fileHash is available.
    @discardableResult
    func updatePreference(for fileHash: String?, apply: (inout BookOverride) -> Void, applyGlobal: () -> Void) -> String? {
        if let hash = fileHash {
            var override = perBookOverrides[hash] ?? BookOverride()
            apply(&override)
            return setOverride(for: hash, override: override)
        } else {
            applyGlobal()
            save()
            return nil
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

    /// Global defaults remain device-local. Per-book overrides are also written
    /// to iCloud KVS so a book keeps its chosen layout and typography on every
    /// device, matching bookmark/position behavior.
    func save(syncOverrides: Bool = true) {
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
            defaults.set(try JSONEncoder().encode(overrideTombstones), forKey: tombstonesKey)
            if syncOverrides {
                let payload = SyncedOverrides(
                    overrides: perBookOverrides,
                    tombstones: overrideTombstones
                )
                cloud.set(try JSONEncoder().encode(payload), forKey: overridesKey)
                cloud.synchronize()
            }
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
        if let data = defaults.data(forKey: tombstonesKey),
           let tombstones = try? JSONDecoder().decode([String: Date].self, from: data) {
            overrideTombstones = tombstones
        }
    }

    private func mergeFromCloudIfAvailable(refreshPinnedState: Bool = false) {
        guard let data = cloud.data(forKey: overridesKey) else { return }
        let previousHashes = Set(perBookOverrides.keys)
        let payload: SyncedOverrides
        if let decoded = try? JSONDecoder().decode(SyncedOverrides.self, from: data) {
            payload = decoded
        } else if let legacy = try? JSONDecoder().decode([String: BookOverride].self, from: data) {
            payload = SyncedOverrides(overrides: legacy, tombstones: [:])
        } else {
            return
        }

        for (hash, date) in payload.tombstones {
            if date > (overrideTombstones[hash] ?? .distantPast) {
                overrideTombstones[hash] = date
            }
        }

        for (hash, remote) in payload.overrides {
            let local = perBookOverrides[hash]
            let localDate = local?.modifiedAt ?? local?.lastUsed ?? .distantPast
            let remoteDate = remote.modifiedAt ?? remote.lastUsed ?? .distantPast
            var selected = remoteDate >= localDate ? remote : (local ?? remote)
            if let remoteLastUsed = remote.lastUsed,
               remoteLastUsed > (selected.lastUsed ?? .distantPast) {
                selected.lastUsed = remoteLastUsed
            }
            perBookOverrides[hash] = selected
        }

        for (hash, deletedAt) in overrideTombstones {
            if let value = perBookOverrides[hash],
               deletedAt >= (value.modifiedAt ?? value.lastUsed ?? .distantPast) {
                perBookOverrides.removeValue(forKey: hash)
            }
        }
        // External merges are written back as a union so concurrent edits to
        // different books on two devices are not lost to whole-dictionary
        // last-writer-wins behavior. During init the caller performs one save.
        save(syncOverrides: refreshPinnedState)
        if refreshPinnedState {
            for hash in previousHashes.union(perBookOverrides.keys) {
                BookmarkStore.shared.refreshPinnedStatus(for: hash)
            }
        }
    }

    private struct SyncedOverrides: Codable {
        var overrides: [String: BookOverride]
        var tombstones: [String: Date]
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
        if let accentColor = theme.cssAccent {
            css += "\na { color: \(accentColor) !important; }"
        }
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
            a { color: \(theme.cssAccent ?? textColor) !important; text-decoration: underline; }
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
    var modifiedAt: Date?

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
         lastUsed: Date? = nil, modifiedAt: Date? = nil) {
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
        self.modifiedAt = modifiedAt
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
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)

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
        case theme, viewMode, twoUp, reflowText, trimWhitespace, textAlign, lastUsed, modifiedAt
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
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
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
    case solarizedLight = "Solarized Light"
    case solarizedDark = "Solarized Dark"
    case dracula = "Dracula"
    case nord = "Nord"
    case platinum = "Platinum"
    case norton = "Norton"
    case amber = "Amber CRT"
    case phosphorGreen = "Phosphor Green"
    case blackAndWhite = "Black and White"

    nonisolated private var palette: ReaderThemePalette? {
        switch self {
        case .system: nil
        case .light: .init(background: 0xFFFFFF, foreground: 0x000000, accent: 0x0066CC, isDark: false)
        case .dark: .init(background: 0x1C1C1E, foreground: 0xE5E5E7, accent: 0x64B5F6, isDark: true)
        case .oled: .init(background: 0x000000, foreground: 0xE5E5E7, accent: 0x64B5F6, isDark: true)
        case .sepia: .init(background: 0xF5E6C8, foreground: 0x3B2E1A, accent: 0x8B5A2B, isDark: false)
        case .solarizedLight: .init(background: 0xFDF6E3, foreground: 0x657B83, accent: 0x268BD2, isDark: false)
        case .solarizedDark: .init(background: 0x002B36, foreground: 0x839496, accent: 0x268BD2, isDark: true)
        case .dracula: .init(background: 0x282A36, foreground: 0xF8F8F2, accent: 0xBD93F9, isDark: true)
        case .nord: .init(background: 0x2E3440, foreground: 0xD8DEE9, accent: 0x88C0D0, isDark: true)
        case .platinum: .init(background: 0xDDDDDD, foreground: 0x000000, accent: 0x3B78FF, isDark: false)
        case .norton: .init(background: 0x0000AA, foreground: 0xFFFFFF, accent: 0x55FFFF, isDark: true)
        case .amber: .init(background: 0x0F0800, foreground: 0xFFB000, accent: 0xFFB000, isDark: true)
        case .phosphorGreen: .init(background: 0x000C00, foreground: 0x50FF64, accent: 0x50FF64, isDark: true)
        case .blackAndWhite: .init(background: 0xFFFFFF, foreground: 0x000000, accent: 0x000000, isDark: false)
        }
    }

    /// CSS background color string, or nil for system theme.
    nonisolated var cssBackground: String? { palette?.backgroundCSS }

    /// CSS foreground (text) color string, or nil for system theme.
    nonisolated var cssForeground: String? { palette?.foregroundCSS }

    /// CSS accent color used for links and other interactive text.
    nonisolated var cssAccent: String? { palette?.accentCSS }

    /// SwiftUI background Color, or nil for system theme.
    nonisolated var swiftUIBackground: Color? { palette?.backgroundColor }

    /// SwiftUI ColorScheme override, or nil for system theme.
    nonisolated var preferredColorScheme: ColorScheme? { palette.map { $0.isDark ? .dark : .light } }

    /// SwiftUI foreground Color, or nil for system theme.
    nonisolated var swiftUIForeground: Color? { palette?.foregroundColor }
}

private struct ReaderThemePalette {
    let background: UInt32
    let foreground: UInt32
    let accent: UInt32
    let isDark: Bool

    nonisolated init(background: UInt32, foreground: UInt32, accent: UInt32, isDark: Bool) {
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.isDark = isDark
    }

    nonisolated var backgroundCSS: String { Self.css(background) }
    nonisolated var foregroundCSS: String { Self.css(foreground) }
    nonisolated var accentCSS: String { Self.css(accent) }
    nonisolated var backgroundColor: Color { Self.color(background) }
    nonisolated var foregroundColor: Color { Self.color(foreground) }

    nonisolated private static func css(_ value: UInt32) -> String {
        String(format: "#%06x", value)
    }

    nonisolated private static func color(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
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
