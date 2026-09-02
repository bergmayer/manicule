#if os(iOS) || os(visionOS)
import AVFoundation
import MediaPlayer
import NaturalLanguage

/// Manages text-to-speech playback with word-level highlighting and sentence-level navigation.
/// iOS/visionOS only — AVSpeechSynthesizer's AudioUnit is blocked by the macOS App Sandbox.
///
/// Owns sentence navigation, Now Playing integration, and UI state.
/// Delegates actual speech synthesis to AppleTTSProvider.
@Observable @MainActor
final class ReadAloudController: NSObject {
    static let shared = ReadAloudController()

    // MARK: - UserDefaults Keys

    private enum DefaultsKey {
        static let speed = "raedad.readAloud.speed"
        static let voiceIdentifier = "raedad.readAloud.voiceIdentifier"
    }

    // MARK: - Public State

    private(set) var isActive = false
    private(set) var isPlaying = false
    /// True when TTS finished speaking all loaded text naturally (not paused by user).
    /// Used by EPubReaderView to auto-play the next section.
    private(set) var sectionFinishedNaturally = false

    // MARK: - Settings

    var speed: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(speed, forKey: DefaultsKey.speed)
            if isActive { invalidateUtterance() }
        }
    }

    var voiceIdentifier: String? {
        didSet {
            UserDefaults.standard.set(voiceIdentifier, forKey: DefaultsKey.voiceIdentifier)
            if isActive { invalidateUtterance() }
        }
    }

    // MARK: - Callbacks (set by reader view)

    var onWordRange: ((NSRange) -> Void)?
    var onSectionFinished: (() -> Void)?
    var onHighlightCleared: (() -> Void)?
    var onPageScrollNeeded: ((Int) -> Void)?

    /// User-visible error message from the TTS provider.
    private(set) var ttsErrorMessage: String?

    // MARK: - TTS Provider

    @ObservationIgnored private var _provider: AppleTTSProvider?
    private var provider: AppleTTSProvider {
        if let p = _provider { return p }
        let p = AppleTTSProvider()
        _provider = p
        return p
    }

    // MARK: - Private

    // All offsets below are UTF-16 code-unit offsets into `fullText`. This
    // matches the NSRanges from AVSpeechSynthesizer's word callbacks and the
    // JS bridge's string offsets (JavaScript strings are UTF-16), so positions
    // stay correct for text containing emoji or other non-BMP characters.
    private var fullText: String = ""
    private var textOffset: Int = 0
    private var lastSpokenWordLocation: Int = 0
    private var sentences: [(start: Int, end: Int)] = []
    private var remoteCommandsConfigured = false
    private var silentPlayer: AVAudioPlayer?

    override private init() {
        super.init()
        let stored = UserDefaults.standard.double(forKey: DefaultsKey.speed)
        speed = max(0.5, stored.nonZero(or: 1.0))
        voiceIdentifier = UserDefaults.standard.string(forKey: DefaultsKey.voiceIdentifier)
    }

    // MARK: - Voice

    var availableVoiceInfos: [VoiceInfo] {
        provider.availableVoices
    }

    var selectedVoiceIdentifier: String? {
        provider.resolvedVoiceID(voiceIdentifier)
    }

    nonisolated static func formatSpeed(_ speed: Double) -> String {
        if speed == Double(Int(speed)) { return "\(Int(speed))x" }
        return String(format: "%.2gx", speed)
    }

    var displaySpeed: String { Self.formatSpeed(speed) }

    // MARK: - Lifecycle

    /// Load text and show controls without starting playback.
    func loadText(_ text: String, startOffset: Int = 0) {
        sectionFinishedNaturally = false
        cancelSpeech()
        fullText = text
        lastSpokenWordLocation = startOffset
        isActive = true
        isPlaying = false
        computeSentences()

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            ttsErrorMessage = "Audio session error: \(error.localizedDescription)"
        }
        startSilentPlayer()
        setupRemoteCommands()
        updateNowPlaying()
    }

    /// Start or resume playback.
    func play() {
        guard isActive else { return }
        if provider.isPaused {
            provider.resume()
            isPlaying = true
        } else if !isPlaying {
            speakFrom(offset: lastSpokenWordLocation)
        }
        updateNowPlaying()
    }

    /// Pause playback in place.
    func pause() {
        guard isPlaying else { return }
        provider.pause()
        isPlaying = false
        updateNowPlaying()
    }

    /// Dismiss controls entirely.
    func dismiss() {
        onHighlightCleared?()
        cancelSpeech()
        isActive = false
        isPlaying = false
        sectionFinishedNaturally = false
        fullText = ""
        textOffset = 0
        lastSpokenWordLocation = 0
        sentences = []
        onWordRange = nil
        onSectionFinished = nil
        onHighlightCleared = nil
        onPageScrollNeeded = nil

        stopSilentPlayer()
        tearDownRemoteCommands()
        // Deactivation failure is non-fatal; the session cleans up when the app backgrounds.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio Session & Now Playing

    private func startSilentPlayer() {
        guard silentPlayer == nil else { return }
        guard let player = try? AVAudioPlayer(data: Self.silentWAV) else { return }
        player.numberOfLoops = -1
        player.volume = 0.01
        player.play()
        silentPlayer = player
    }

    private func stopSilentPlayer() {
        silentPlayer?.stop()
        silentPlayer = nil
    }

    /// Minimal 1-second silent 8kHz 16-bit mono WAV.
    private static let silentWAV: Data = {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 8000
        let dataSize = numSamples * 2
        var d = Data(capacity: 44 + Int(dataSize))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]); u32(36 + dataSize) // RIFF header
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45])                     // WAVE
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]); u32(16)            // fmt chunk
        u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]); u32(dataSize)      // data chunk
        d.append(Data(count: Int(dataSize)))                                 // silence
        return d
    }()

    private func setupRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        UIApplication.shared.beginReceivingRemoteControlEvents()

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.stopCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false

        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPlaying { self.pause() } else { self.play() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.skipForward(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.skipBack(); return .success }
    }

    private func tearDownRemoteCommands() {
        guard remoteCommandsConfigured else { return }
        remoteCommandsConfigured = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Read Aloud",
            MPMediaItemPropertyArtist: "Manicule",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPMediaItemPropertyMediaType: MPMediaType.anyAudio.rawValue,
        ]
        if !fullText.isEmpty {
            let progress = Double(lastSpokenWordLocation) / Double((fullText as NSString).length)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress * 100
            info[MPMediaItemPropertyPlaybackDuration] = 100.0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    // MARK: - Sentence Navigation

    /// Skip to the next sentence. Never advances chapters.
    func skipForward() {
        guard isActive, !sentences.isEmpty else { return }
        let pos = lastSpokenWordLocation
        if let idx = sentences.firstIndex(where: { $0.start > pos }) {
            seekToSentence(at: idx)
        }
    }

    /// Skip to the previous sentence (or restart current one).
    func skipBack() {
        guard isActive, !sentences.isEmpty else { return }
        let pos = lastSpokenWordLocation
        let currentIdx = sentences.lastIndex(where: { $0.start <= pos }) ?? 0
        if currentIdx > 0 && pos - sentences[currentIdx].start < 20 {
            seekToSentence(at: currentIdx - 1)
        } else {
            seekToSentence(at: currentIdx)
        }
    }

    /// Seek to offset (e.g. from bridge page navigation).
    func seekTo(offset: Int) {
        guard isActive, offset < (fullText as NSString).length else { return }
        lastSpokenWordLocation = offset
        if isPlaying {
            cancelSpeech()
            speakFrom(offset: offset)
        }
    }

    /// Seek to offset, resuming playback if it was active before the seek.
    /// Used when the user flips a page during read-aloud: seekTo restarts speech
    /// if isPlaying, but if TTS finished during the debounce window, isPlaying
    /// is false and seekTo only updates position — this method resumes in that case.
    func seekAndResume(offset: Int) {
        guard isActive, offset < (fullText as NSString).length else { return }
        let wasPlaying = isPlaying
        seekTo(offset: offset)
        if wasPlaying && !isPlaying {
            play()
        }
    }

    // MARK: - Private

    private func seekToSentence(at index: Int) {
        guard index >= 0 && index < sentences.count else { return }
        let offset = sentences[index].start
        lastSpokenWordLocation = offset
        let wasPlaying = isPlaying
        cancelSpeech()
        onPageScrollNeeded?(offset)
        if wasPlaying {
            speakFrom(offset: offset)
        } else {
            onHighlightCleared?()
        }
    }

    private func invalidateUtterance() {
        let wasPlaying = isPlaying
        let pos = lastSpokenWordLocation
        cancelSpeech()
        if wasPlaying {
            speakFrom(offset: pos)
        }
    }

    private func cancelSpeech() {
        provider.stop()
    }

    private func speakFrom(offset: Int) {
        let ns = fullText as NSString
        var clamped = max(0, min(offset, ns.length))
        // Avoid splitting a surrogate pair when the offset comes from a
        // fraction-based estimate rather than a word boundary.
        if clamped > 0 && clamped < ns.length {
            clamped = ns.rangeOfComposedCharacterSequence(at: clamped).location
        }
        let substring = ns.substring(from: clamped)
        guard !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sectionFinishedNaturally = true
            onSectionFinished?()
            return
        }

        textOffset = clamped
        lastSpokenWordLocation = clamped
        isPlaying = true

        // Wire provider callbacks
        let p = provider
        p.onWordRange = { [weak self] range in
            guard let self else { return }
            let adjusted = NSRange(location: range.location + self.textOffset, length: range.length)
            self.lastSpokenWordLocation = adjusted.location
            self.onWordRange?(adjusted)
        }
        p.onFinished = { [weak self] in
            guard let self, self.isActive else { return }
            self.isPlaying = false
            self.sectionFinishedNaturally = true
            self.onSectionFinished?()
        }
        p.onError = { [weak self] message in
            guard let self, self.isActive else { return }
            self.isPlaying = false
            self.ttsErrorMessage = message
            self.onHighlightCleared?()
        }

        ttsErrorMessage = nil
        p.speak(substring, speed: speed, voiceID: selectedVoiceIdentifier)
    }

    private func computeSentences() {
        sentences = []
        guard !fullText.isEmpty else { return }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = fullText
        tokenizer.enumerateTokens(in: fullText.startIndex..<fullText.endIndex) { range, _ in
            let start = range.lowerBound.utf16Offset(in: fullText)
            let end = range.upperBound.utf16Offset(in: fullText)
            sentences.append((start: start, end: end))
            return true
        }
    }

    // MARK: - Text Preparation

    nonisolated private static let mdLinePatterns: [(NSRegularExpression, String)] = [
        ("^#{1,6}\\s+", ""),
        ("^\\s*[-*+]\\s+", ""),
        ("^\\s*\\d+\\.\\s+", ""),
        ("^\\s*>\\s*", ""),
        ("!\\[([^\\]]*?)\\]\\([^)]+\\)", "$1"),
        ("\\[([^\\]]+?)\\]\\([^)]+\\)", "$1"),
        ("\\*{1,3}(.+?)\\*{1,3}", "$1"),
        ("_{1,2}(.+?)_{1,2}", "$1"),
        ("`([^`]+)`", "$1"),
    ].map { (makeRegex($0.0), $0.1) }

    nonisolated private static let mdHRule = makeRegex("^[-*_]{3,}\\s*$", options: .anchorsMatchLines)
    nonisolated private static let excessiveNewlines = makeRegex("\\n{3,}")
    nonisolated private static let htmlTags = makeRegex("<[^>]+>")

    nonisolated private static func makeRegex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid built-in regular expression '\(pattern)': \(error)")
        }
    }

    nonisolated static func stripMarkdown(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let stripped = lines.map { line -> String in
            var s = String(line)
            for (regex, template) in mdLinePatterns {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
            }
            return s
        }.joined(separator: "\n")

        var result = mdHRule.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "")
        result = excessiveNewlines.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func stripHTML(_ html: String) -> String {
        var result = htmlTags.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "")
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        result = excessiveNewlines.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AppleTTSProvider

/// Wraps AVSpeechSynthesizer for use by ReadAloudController.
@MainActor
final class AppleTTSProvider: NSObject {
    var onWordRange: ((NSRange) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var speakStartTime: Date = .distantPast
    private var didReceiveWordCallback = false
    private var cachedVoices: [VoiceInfo]?
    private var recoveryTimer: Timer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isPaused: Bool { synthesizer.isPaused }

    func speak(_ text: String, speed: Double, voiceID: String?) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onFinished?()
            return
        }

        speakStartTime = Date()
        didReceiveWordCallback = false

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        if let id = voiceID, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        utterance.preUtteranceDelay = 0.05
        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    var availableVoices: [VoiceInfo] {
        if let cached = cachedVoices { return cached }
        let result = loadVoices()
        cachedVoices = result
        return result
    }

    func resolvedVoiceID(_ id: String?) -> String? {
        guard let id, AVSpeechSynthesisVoice(identifier: id) != nil else {
            return availableVoices.first?.identifier
        }
        return id
    }

    private func loadVoices() -> [VoiceInfo] {
        let langPrefix = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(langPrefix) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
            .map { voice in
                let quality: VoiceInfo.Quality = switch voice.quality {
                case .premium: .premium
                case .enhanced: .enhanced
                default: .standard
                }
                return VoiceInfo(identifier: voice.identifier, name: voice.name, locale: voice.language, quality: quality)
            }
    }

    /// Schedule a recovery check so a suppressed spurious `didFinish` doesn't stall playback.
    private func scheduleRecoveryTimer(for utterance: AVSpeechUtterance) {
        recoveryTimer?.invalidate()
        let delay = max(0.1, speakStartTime.addingTimeInterval(2.0).timeIntervalSinceNow)
        nonisolated(unsafe) let utteranceRef = utterance
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, utteranceRef === self.activeUtterance else { return }
                self.onFinished?()
            }
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AppleTTSProvider: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // AVSpeechUtterance is not formally Sendable but identity comparison is safe here
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor [weak self] in
            guard let self, utterance === self.activeUtterance else { return }
            self.recoveryTimer?.invalidate()
            self.recoveryTimer = nil
            self.didReceiveWordCallback = true
            self.onWordRange?(characterRange)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor [weak self] in
            guard let self, utterance === self.activeUtterance else { return }
            let elapsed = Date().timeIntervalSince(self.speakStartTime)
            if !self.didReceiveWordCallback && elapsed < 1.0 {
                // Likely a spurious didFinish — schedule a recovery check in case
                // the synthesizer genuinely finished very fast with no word callbacks.
                self.scheduleRecoveryTimer(for: utterance)
                return
            }
            self.onFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}

// MARK: - VoiceInfo

struct VoiceInfo: Identifiable {
    enum Quality: Int, Comparable, Hashable {
        case standard = 0, enhanced = 1, premium = 2
        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let identifier: String
    let name: String
    let locale: String
    let quality: Quality

    var id: String { identifier }
}

private extension Double {
    func nonZero(or defaultValue: Double) -> Double {
        self == 0 ? defaultValue : self
    }
}
#endif
