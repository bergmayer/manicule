#if os(iOS) || os(visionOS)
import SwiftUI

/// Compact playback bar for read-aloud mode with full transport controls.
struct ReadAloudBarView: View {
    let controller: ReadAloudController
    var onDismiss: () -> Void

    @State private var showVoicePicker = false

    var body: some View {
        HStack(spacing: 0) {
            // Transport controls — generous tap targets
            HStack(spacing: 0) {
                transportButton(systemName: "backward.fill") {
                    controller.skipBack()
                }

                transportButton(systemName: controller.isPlaying ? "pause.fill" : "play.fill") {
                    if controller.isPlaying { controller.pause() } else { controller.play() }
                }
                .font(.title2)

                transportButton(systemName: "forward.fill") {
                    controller.skipForward()
                }
            }

            Spacer()

            // Speed picker
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                    Button {
                        controller.speed = s
                    } label: {
                        HStack {
                            Text(ReadAloudController.formatSpeed(s))
                            if abs(controller.speed - s) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(controller.displaySpeed)
                    .font(.caption.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.trailing, 12)

            // Voice picker
            Button { showVoicePicker = true } label: {
                Image(systemName: "person.wave.2")
                    .font(.body)
                    .frame(minWidth: 44, minHeight: 44)
            }

            // Dismiss (close widget)
            Button {
                controller.dismiss()
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            if let error = controller.ttsErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .offset(y: -44)
            }
        }
        .background(ReaderChromeBackground())
        .sheet(isPresented: $showVoicePicker) {
            VoicePickerView(controller: controller)
        }
    }

    /// A transport button with a 44pt minimum tap target.
    @ViewBuilder
    private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }

}

// MARK: - Voice Picker

private struct VoicePickerView: View {
    let controller: ReadAloudController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                voiceList
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var voiceList: some View {
        let grouped = Dictionary(grouping: controller.availableVoiceInfos, by: \.quality)
        let premium = grouped[.premium] ?? []
        let enhanced = grouped[.enhanced] ?? []
        let standard = grouped[.standard] ?? []

        if !premium.isEmpty {
            Section("Premium") {
                ForEach(premium) { voice in voiceRow(voice) }
            }
        }
        if !enhanced.isEmpty {
            Section("Enhanced") {
                ForEach(enhanced) { voice in voiceRow(voice) }
            }
        }
        if !standard.isEmpty {
            Section("Standard") {
                ForEach(standard) { voice in voiceRow(voice) }
            }
        }

        Section {
            Text("Download more voices in Settings > Accessibility > Spoken Content > Voices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func voiceRow(_ voice: VoiceInfo) -> some View {
        Button {
            controller.voiceIdentifier = voice.identifier
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(voice.name)
                    Text(Locale.current.localizedString(forIdentifier: voice.locale) ?? voice.locale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if voice.identifier == controller.selectedVoiceIdentifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}
#endif
