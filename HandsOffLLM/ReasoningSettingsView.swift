import SwiftUI

struct ReasoningSettingsView: View {
    @EnvironmentObject var settingsService: SettingsService

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            Form {
                Section {
                    Toggle("Extended Reasoning", isOn: Binding(
                        get: { settingsService.reasoningEnabled },
                        set: { settingsService.updateReasoningEnabled($0) }
                    ))
                    .tint(Theme.secondaryAccent)
                    .listRowBackground(Theme.menuAccent)

                    if settingsService.reasoningEnabled {
                        Picker("Reasoning Effort", selection: Binding(
                            get: { settingsService.reasoningEffort },
                            set: { settingsService.updateReasoningEffort($0) }
                        )) {
                            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(Theme.secondaryAccent)
                        .listRowBackground(Theme.menuAccent)
                    }
                } footer: {
                    Text("Applies to Claude, GPT-5, Grok, and Gemini")
                        .foregroundColor(Theme.secondaryText.opacity(0.6))
                }

                Section {
                    Toggle("Web Search", isOn: Binding(
                        get: { settingsService.webSearchEnabled },
                        set: { settingsService.updateWebSearchEnabled($0) }
                    ))
                    .tint(Theme.secondaryAccent)
                    .listRowBackground(Theme.menuAccent)
                } footer: {
                    Text("Lets Claude, GPT-5, Grok, and Gemini browse the web when needed")
                        .foregroundColor(Theme.secondaryText.opacity(0.6))
                }
            }
            .scrollContentBackground(.hidden)
            .foregroundColor(Theme.primaryText)
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
