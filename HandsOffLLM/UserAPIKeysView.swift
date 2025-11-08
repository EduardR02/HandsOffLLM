import SwiftUI
import UIKit

struct UserAPIKeysView: View {
    @EnvironmentObject var settingsService: SettingsService

    @State private var openAIKeyDraft: String = ""
    @State private var anthropicKeyDraft: String = ""
    @State private var geminiKeyDraft: String = ""
    @State private var xaiKeyDraft: String = ""
    @State private var moonshotKeyDraft: String = ""
    @State private var mistralKeyDraft: String = ""
    @State private var replicateKeyDraft: String = ""

    @State private var revealOpenAI = false
    @State private var revealAnthropic = false
    @State private var revealGemini = false
    @State private var revealXAI = false
    @State private var revealMoonshot = false
    @State private var revealMistral = false
    @State private var revealReplicate = false

    var body: some View {
        List {
            Section {
                Text("Use your own API keys to get billed directly by each provider. Keys are encrypted in the system keychain and stay on this device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .listRowBackground(Color.clear)

            keySection(
                title: "OpenAI (GPT-4, GPT-5, TTS)",
                toggle: $settingsService.useOwnOpenAIKey,
                fieldPlaceholder: "sk-...",
                text: $openAIKeyDraft,
                reveal: $revealOpenAI,
                statusIcon: "waveform",
                storedKey: settingsService.openaiAPIKey,
                onSave: settingsService.setOpenAIAPIKey
            )

            keySection(
                title: "Anthropic (Claude)",
                toggle: $settingsService.useOwnAnthropicKey,
                fieldPlaceholder: "sk-ant-...",
                text: $anthropicKeyDraft,
                reveal: $revealAnthropic,
                statusIcon: "sun.max.fill",
                storedKey: settingsService.anthropicAPIKey,
                onSave: settingsService.setAnthropicAPIKey
            )

            keySection(
                title: "Google Gemini",
                toggle: $settingsService.useOwnGeminiKey,
                fieldPlaceholder: "AI...",
                text: $geminiKeyDraft,
                reveal: $revealGemini,
                statusIcon: "sparkles",
                storedKey: settingsService.geminiAPIKey,
                onSave: settingsService.setGeminiAPIKey
            )

            keySection(
                title: "xAI (Grok)",
                toggle: $settingsService.useOwnXAIKey,
                fieldPlaceholder: "xai-...",
                text: $xaiKeyDraft,
                reveal: $revealXAI,
                statusIcon: "bolt.fill",
                storedKey: settingsService.xaiAPIKey,
                onSave: settingsService.setXAIAPIKey
            )

            keySection(
                title: "Moonshot AI (Kimi)",
                toggle: $settingsService.useOwnMoonshotKey,
                fieldPlaceholder: "sk-...",
                text: $moonshotKeyDraft,
                reveal: $revealMoonshot,
                statusIcon: "moon.stars.fill",
                storedKey: settingsService.moonshotAPIKey,
                onSave: settingsService.setMoonshotAPIKey
            )

            keySection(
                title: "Mistral (Transcription)",
                toggle: $settingsService.useOwnMistralKey,
                fieldPlaceholder: "mst-...",
                text: $mistralKeyDraft,
                reveal: $revealMistral,
                statusIcon: "waveform.circle.fill",
                storedKey: settingsService.mistralAPIKey,
                onSave: settingsService.setMistralAPIKey
            )

            keySection(
                title: "Replicate (Kokoro TTS)",
                toggle: $settingsService.useOwnReplicateKey,
                fieldPlaceholder: "r8_...",
                text: $replicateKeyDraft,
                reveal: $revealReplicate,
                statusIcon: "speaker.wave.2.fill",
                storedKey: settingsService.replicateAPIKey,
                onSave: settingsService.setReplicateAPIKey
            )
        }
        .navigationTitle("Your API Keys")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background.edgesIgnoringSafeArea(.all))
        .onAppear {
            syncDrafts()
        }
        .onChange(of: settingsService.openaiAPIKey) { _, newValue in openAIKeyDraft = newValue ?? "" }
        .onChange(of: settingsService.anthropicAPIKey) { _, newValue in anthropicKeyDraft = newValue ?? "" }
        .onChange(of: settingsService.geminiAPIKey) { _, newValue in geminiKeyDraft = newValue ?? "" }
        .onChange(of: settingsService.xaiAPIKey) { _, newValue in xaiKeyDraft = newValue ?? "" }
        .onChange(of: settingsService.moonshotAPIKey) { _, newValue in moonshotKeyDraft = newValue ?? "" }
        .onChange(of: settingsService.mistralAPIKey) { _, newValue in mistralKeyDraft = newValue ?? "" }
        .onChange(of: settingsService.replicateAPIKey) { _, newValue in replicateKeyDraft = newValue ?? "" }
    }

    private func syncDrafts() {
        openAIKeyDraft = settingsService.openaiAPIKey ?? ""
        anthropicKeyDraft = settingsService.anthropicAPIKey ?? ""
        geminiKeyDraft = settingsService.geminiAPIKey ?? ""
        xaiKeyDraft = settingsService.xaiAPIKey ?? ""
        moonshotKeyDraft = settingsService.moonshotAPIKey ?? ""
        mistralKeyDraft = settingsService.mistralAPIKey ?? ""
        replicateKeyDraft = settingsService.replicateAPIKey ?? ""
    }

    @ViewBuilder
    private func keySection(
        title: String,
        toggle: Binding<Bool>,
        fieldPlaceholder: String,
        text: Binding<String>,
        reveal: Binding<Bool>,
        statusIcon: String,
        storedKey: String?,
        onSave: @escaping (String?) -> Void
    ) -> some View {
        Section {
            Toggle("Use My Key", isOn: toggle)
                .tint(Theme.secondaryAccent)

            if toggle.wrappedValue {
                VStack(alignment: .leading, spacing: 12) {
                    let trimmedDraft = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    Group {
                        if reveal.wrappedValue {
                            TextField(fieldPlaceholder, text: text, onCommit: {
                                commit(trimmedDraft, storedKey: storedKey, onSave: onSave)
                            })
                        } else {
                            SecureField(fieldPlaceholder, text: text, onCommit: {
                                commit(trimmedDraft, storedKey: storedKey, onSave: onSave)
                            })
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                    HStack(spacing: 12) {
                        Button(reveal.wrappedValue ? "Hide" : "Show") {
                            reveal.wrappedValue.toggle()
                        }
                        .buttonStyle(.bordered)

                        Button("Paste") {
                            if let pasted = UIPasteboard.general.string {
                                text.wrappedValue = pasted
                            }
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Save") {
                            commit(trimmedDraft, storedKey: storedKey, onSave: onSave)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(trimmedDraft == storedKey)

                        Button("Clear") {
                            text.wrappedValue = ""
                            commit("", storedKey: storedKey, onSave: onSave)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                    statusRow(icon: statusIcon, storedKey: storedKey)
                }
                .padding(.top, 8)
            }
        } header: {
            Text(title)
        }
        .listRowBackground(Theme.menuAccent)
    }

    @ViewBuilder
    private func statusRow(icon: String, storedKey: String?) -> some View {
        let hasKey = !(storedKey?.isEmpty ?? true)
        HStack(spacing: 8) {
            Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(hasKey ? .green : .orange)
            Text(hasKey ? "Key saved in keychain" : "No key saved yet")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commit(
        _ trimmedDraft: String,
        storedKey: String?,
        onSave: @escaping (String?) -> Void
    ) {
        let newValue = trimmedDraft.isEmpty ? nil : trimmedDraft
        guard newValue != storedKey else { return }
        onSave(newValue)
    }
}

#Preview {
    NavigationStack {
        UserAPIKeysView()
    }
    .environmentObject(SettingsService())
    .preferredColorScheme(.dark)
}
