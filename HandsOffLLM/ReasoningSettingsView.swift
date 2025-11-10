import SwiftUI

struct ReasoningSettingsView: View {
    @EnvironmentObject var settingsService: SettingsService
    @AppStorage("darkerMode") private var darkerModeObserver: Bool = true

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            Form {
                // MARK: - Universal Reasoning Toggle
                Section {
                    Toggle(isOn: Binding(
                        get: { settingsService.reasoningEnabled },
                        set: { settingsService.updateReasoningEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extended Reasoning")
                                .foregroundColor(Theme.primaryText)
                            Text("Let the AI think before replying. Applies to Claude, Grok, and Gemini.")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                } footer: {
                    Text("When enabled, models take extra time to reason through complex questions before responding.")
                        .foregroundColor(Theme.secondaryText)
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - OpenAI Reasoning Effort
                Section {
                    Picker(selection: Binding(
                        get: { settingsService.openAIReasoningEffort },
                        set: { settingsService.updateOpenAIReasoningEffort($0) }
                    )) {
                        ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                            Text(effort.displayName).tag(effort)
                                .foregroundColor(Theme.primaryText)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GPT-5 Reasoning Effort")
                                .foregroundColor(Theme.primaryText)
                            Text("Control how deeply GPT-5 thinks before answering.")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                    .id("reasoningEffortPicker-\(darkerModeObserver)")
                } footer: {
                    Text("GPT-5 uses reasoning effort levels instead of a simple toggle. Higher effort means more thorough thinking but slower responses.")
                        .foregroundColor(Theme.secondaryText)
                }
                .listRowBackground(Theme.menuAccent)
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
