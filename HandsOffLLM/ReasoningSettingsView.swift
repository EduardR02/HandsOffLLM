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
                        HStack(spacing: 12) {
                            Image(systemName: "brain")
                                .font(.title2)
                                .foregroundColor(Theme.secondaryAccent)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Extended Reasoning")
                                    .foregroundColor(Theme.primaryText)
                                Text("Claude · Grok · Gemini")
                                    .font(.caption2)
                                    .foregroundColor(Theme.secondaryText.opacity(0.7))
                            }
                        }
                    }
                    .tint(Theme.secondaryAccent)
                    .listRowBackground(Theme.menuAccent)
                }

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
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.title2)
                                .foregroundColor(Theme.secondaryAccent)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GPT-5 Reasoning Effort")
                                    .foregroundColor(Theme.primaryText)
                                Text("Low · Medium · High")
                                    .font(.caption2)
                                    .foregroundColor(Theme.secondaryText.opacity(0.7))
                            }
                        }
                    }
                    .tint(Theme.secondaryAccent)
                    .id("reasoningEffortPicker-\(darkerModeObserver)")
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
