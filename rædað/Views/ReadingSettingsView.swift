import SwiftUI

/// Settings sheet shown from within a reader view.
/// On iOS this includes a Books tab so users can manage recent/pinned books
/// regardless of where they opened settings from. On macOS the Books tab
/// lives in the dedicated Settings window, so the sheet only shows reading prefs.
struct ReaderSettingsSheet: View {
    let fileHash: String?
    var showReflowOption: Bool = false

    var body: some View {
        #if os(iOS)
        TabView {
            ReadingSettingsView(fileHash: fileHash, showReflowOption: showReflowOption)
                .tabItem { Label("Reading", systemImage: "textformat.size") }
            NavigationStack {
                PerBookSettingsView()
            }
            .tabItem { Label("Books", systemImage: "books.vertical") }
        }
        .presentationDetents([.medium, .large])
        #else
        ReadingSettingsView(fileHash: fileHash, showReflowOption: showReflowOption)
            .frame(minWidth: 400, idealWidth: 500, minHeight: 600)
        #endif
    }
}

/// Settings panel for reading preferences (font, size, spacing, margins, theme).
/// Can operate in global mode or per-book mode.
struct ReadingSettingsView: View {
    let fileHash: String?
    var showReflowOption: Bool = false
    @Environment(\.dismiss) private var dismiss

    private let prefs = ReadingPreferences.shared

    @State private var fontFamily: FontFamily = .system
    @State private var fontSize: Double = 18
    @State private var lineSpacing: Double = 1.4
    @State private var marginsOneUp: MarginSettings = .default
    @State private var marginsTwoUp: MarginSettings = .default
    @State private var theme: ReaderTheme = .system
    @State private var viewMode: ViewMode = .paginated
    @State private var reflowText: Bool = false
    @State private var textAlign: TextAlignment = .natural
    @State private var usePerBookOverride: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                if fileHash != nil {
                    Section {
                        Toggle("Custom Settings for This Book", isOn: $usePerBookOverride)
                    } footer: {
                        Text("When enabled, these settings apply only to this book. Otherwise global defaults are used.")
                    }
                }

                Section("Typography") {
                    Picker("Font", selection: $fontFamily) {
                        ForEach(FontFamily.allCases, id: \.self) { family in
                            Text(family.rawValue).tag(family)
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(fontSize))pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fontSize, in: 12...36, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Line Spacing")
                            Spacer()
                            Text(String(format: "%.1f\u{00d7}", lineSpacing))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $lineSpacing, in: 1.0...2.5, step: 0.1)
                    }

                    HStack {
                        Text("Justification")
                        Spacer()
                        HStack(spacing: 0) {
                            Button {
                                textAlign = .natural
                            } label: {
                                Image(systemName: "text.alignleft")
                                    .frame(width: 44, height: 32)
                            }
                            .buttonStyle(.bordered)
                            .tint(textAlign == .natural ? .accentColor : .secondary)

                            Button {
                                textAlign = .justified
                            } label: {
                                Image(systemName: "text.justify")
                                    .frame(width: 44, height: 32)
                            }
                            .buttonStyle(.bordered)
                            .tint(textAlign == .justified ? .accentColor : .secondary)
                        }
                    }
                }

                Section("Single Page Margins") {
                    MarginRow(label: "Top / Bottom", value: $marginsOneUp.topBottom)
                    MarginRow(label: "Left / Right", value: $marginsOneUp.leftRight)
                }

                Section("Two-Page Margins") {
                    MarginRow(label: "Top / Bottom", value: $marginsTwoUp.topBottom)
                    MarginRow(label: "Left / Right", value: $marginsTwoUp.leftRight)
                }

                Section("Theme") {
                    Picker("Theme", selection: $theme) {
                        ForEach(ReaderTheme.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if showReflowOption {
                    Section {
                        Toggle("Reflow Text", isOn: $reflowText)
                    } footer: {
                        Text("Merges hard-wrapped lines into flowing paragraphs while preserving structural breaks.")
                    }
                }

                Section {
                    previewText
                } header: {
                    Text("Preview")
                }

            }
            .formStyle(.grouped)
            .navigationTitle("Reading Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS) || os(visionOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        applyAndDismiss()
                    }
                }
                #endif
            }
            .task {
                loadCurrentValues()
            }
            .onChange(of: usePerBookOverride) { _, enabled in
                if !enabled, let hash = fileHash {
                    prefs.removeOverride(for: hash)
                }
            }
            #if os(macOS)
            .onChange(of: fontFamily) { _, _ in applyLive() }
            .onChange(of: fontSize) { _, _ in applyLive() }
            .onChange(of: lineSpacing) { _, _ in applyLive() }
            .onChange(of: marginsOneUp) { _, _ in applyLive() }
            .onChange(of: marginsTwoUp) { _, _ in applyLive() }
            .onChange(of: theme) { _, _ in applyLive() }
            .onChange(of: reflowText) { _, _ in applyLive() }
            .onChange(of: textAlign) { _, _ in applyLive() }
            #endif
        }
        #if os(macOS)
        .frame(minHeight: 600)
        #endif
    }

    @ViewBuilder
    private var previewText: some View {
        let effective = EffectivePreferences(
            fontFamily: fontFamily,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            marginsOneUp: marginsOneUp,
            marginsTwoUp: marginsTwoUp,
            theme: theme,
            viewMode: .paginated,
            twoUp: nil,
            reflowText: false,
            trimWhitespace: false,
            textAlign: textAlign
        )
        Text("The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.")
            .font(effective.swiftUIFont)
            .lineSpacing((lineSpacing - 1.0) * fontSize)
            .padding(.horizontal, marginsOneUp.leftRight)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let bg = effective.backgroundColor {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(bg)
                }
            }
            .foregroundStyle(effective.foregroundColor ?? .primary)
    }

    private func loadCurrentValues() {
        let effective: EffectivePreferences
        if let hash = fileHash {
            effective = prefs.effective(for: hash)
            usePerBookOverride = prefs.hasOverride(for: hash)
        } else {
            effective = prefs.effective(for: nil)
        }
        fontFamily = effective.fontFamily
        fontSize = effective.fontSize
        lineSpacing = effective.lineSpacing
        marginsOneUp = effective.marginsOneUp
        marginsTwoUp = effective.marginsTwoUp
        theme = effective.theme
        viewMode = effective.viewMode
        reflowText = effective.reflowText
        textAlign = effective.textAlign
    }

    private func applyAndDismiss() {
        applyLive()
        dismiss()
    }

    private func applyLive() {
        if let hash = fileHash, usePerBookOverride {
            let existingTrim = prefs.perBookOverrides[hash]?.trimWhitespace
            prefs.setOverride(for: hash, override: BookOverride(
                fontFamily: fontFamily,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                marginsOneUp: marginsOneUp,
                marginsTwoUp: marginsTwoUp,
                theme: theme,
                viewMode: viewMode,
                reflowText: reflowText,
                trimWhitespace: existingTrim,
                textAlign: textAlign
            ))
        } else {
            prefs.fontFamily = fontFamily
            prefs.fontSize = fontSize
            prefs.lineSpacing = lineSpacing
            prefs.marginsOneUp = marginsOneUp
            prefs.marginsTwoUp = marginsTwoUp
            prefs.theme = theme
            prefs.viewMode = viewMode
            prefs.reflowText = reflowText
            prefs.textAlign = textAlign
            prefs.save()
        }
    }
}

private struct MarginRow: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value))pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 2...128, step: 2)
        }
    }
}
