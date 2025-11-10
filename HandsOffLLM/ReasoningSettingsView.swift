import SwiftUI

struct ReasoningSettingsView: View {
    @EnvironmentObject var settingsService: SettingsService

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            Form {
                // MARK: - Universal Reasoning Toggle
                Section {
                    Toggle("Extended Reasoning", isOn: Binding(
                        get: { settingsService.reasoningEnabled },
                        set: { settingsService.updateReasoningEnabled($0) }
                    ))
                    .tint(Theme.secondaryAccent)
                    .listRowBackground(Theme.menuAccent)
                } footer: {
                    Text("Applies to Claude, Grok, and Gemini")
                        .foregroundColor(Theme.secondaryText.opacity(0.6))
                }

                // MARK: - OpenAI Reasoning Effort
                Section {
                    Picker("GPT-5 Reasoning Effort", selection: Binding(
                        get: { settingsService.openAIReasoningEffort },
                        set: { settingsService.updateOpenAIReasoningEffort($0) }
                    )) {
                        ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                            Text(effort.displayName).tag(effort)
                                .foregroundColor(Theme.primaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                    .listRowBackground(Theme.menuAccent)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Reasoning")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    let env = PreviewEnvironment.make()

    NavigationStack {
        ReasoningSettingsView()
    }
    .environmentObject(env.settings)
    .preferredColorScheme(.dark)
}
#endif
