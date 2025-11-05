//
//  HistoryView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 18.04.25.
//

import SwiftUI

// Tiny helper to defer view construction
private struct LazyView<Content: View>: View {
    let build: () -> Content
    init(_ build: @escaping @autoclosure () -> Content) { self.build = build }
    var body: Content { build() }
}

struct HistoryView: View {
    @Binding var rootIsActive: Bool
    @EnvironmentObject var historyService: HistoryService
    @EnvironmentObject var viewModel: ChatViewModel
    @EnvironmentObject var chatService: ChatService

    @State private var conversationToRename: ConversationIndexEntry?

    private var groupedConversations: [(String, [ConversationIndexEntry])] {
        historyService.groupIndexByDate()
    }

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)

            List {
                ForEach(groupedConversations, id: \.0) { sectionName, entriesInSection in
                    Section(header: Text(sectionName)
                                .foregroundColor(Theme.secondaryText)) {
                        ForEach(entriesInSection) { entry in
                            NavigationLink(
                                // important, this is so that the view is not created until the link is tapped, no cpu spike on load!
                                destination: LazyView(
                                    ChatDetailView(
                                        rootIsActive: $rootIsActive,
                                        conversationId: entry.id
                                    )
                                )
                            ) {
                                VStack(alignment: .leading) {
                                    Text(entry.title ?? "Untitled Chat")
                                        .font(.headline)
                                        .foregroundColor(Theme.primaryText)
                                    Text(entry.createdAt, style: .date)
                                        .font(.caption)
                                        .foregroundColor(Theme.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.4)
                                        .onEnded { _ in
                                            conversationToRename = entry
                                        }
                                )
                            }
                            .listRowBackground(Theme.menuAccent)
                            .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                        }
                        .onDelete { offsets in
                            deleteConversations(inSectionNamed: sectionName, at: offsets)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .sheet(item: $conversationToRename) { entry in
                RenameConversationSheet(
                    title: entry.title ?? "",
                    onSave: { newTitle in
                        Task {
                            await historyService.updateConversationTitle(conversationId: entry.id, newTitle: newTitle)
                        }
                        conversationToRename = nil
                    },
                    onCancel: {
                        conversationToRename = nil
                    },
                    onAuto: {
                        await chatService.generateTitleForConversation(conversationId: entry.id)
                    }
                )
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
            }
        }
        .navigationTitle("History")
        .listStyle(.insetGrouped)
    }

    private func deleteConversations(inSectionNamed sectionName: String, at offsets: IndexSet) {
        guard let entriesInSection = groupedConversations.first(where: { $0.0 == sectionName })?.1 else { return }
        let idsToDelete = offsets.map { entriesInSection[$0].id }

        Task {
            for id in idsToDelete {
                await historyService.deleteConversation(id: id)
            }
        }
    }
}

// MARK: - Rename Sheet
private struct RenameConversationSheet: View {
    @State private var text: String
    @State private var isGenerating = false
    @State private var showError = false
    @FocusState private var isFocused: Bool

    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onAuto: () async -> String?

    init(title: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void, onAuto: @escaping () async -> String?) {
        _text = State(initialValue: title)
        self.onSave = onSave
        self.onCancel = onCancel
        self.onAuto = onAuto
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Rename Conversation")
                    .font(.headline)
                    .foregroundColor(Theme.primaryText)
                    .padding(.top)

                TextField("Title", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .padding(.horizontal)
                    .submitLabel(.done)
                    .onSubmit {
                        saveIfValid()
                    }
                    .disabled(isGenerating)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.secondaryText)
                    .disabled(isGenerating)
                    .frame(minWidth: 80)

                    Button {
                        Task {
                            isGenerating = true
                            if let generatedTitle = await onAuto() {
                                text = generatedTitle
                                isFocused = true
                            } else {
                                showError = true
                            }
                            isGenerating = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isGenerating {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.primaryText))
                                    .scaleEffect(0.8)
                            }
                            Text("Auto")
                        }
                        .frame(minWidth: 40)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                    .disabled(isGenerating)
                    .frame(minWidth: 80)
                    .accessibilityLabel(isGenerating ? "Generating title" : "Auto-generate title")

                    Button("Save") {
                        saveIfValid()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                    .frame(minWidth: 80)
                }
                .padding(.bottom)
            }
        }
        .onAppear {
            isFocused = true
        }
        .alert("Generation Failed", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Could not generate title. Please try again or enter one manually.")
        }
    }

    private func saveIfValid() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

#if DEBUG
#Preview {
    // --- Make Dummy Conversations Multi-Turn ---
    let convo1: Conversation = {
        var convo = Conversation(
            messages: [
                ChatMessage(id: UUID(), role: "user", content: "Hello there, how are you?"),
                ChatMessage(id: UUID(), role: "assistant", content: "I'm doing well, thank you for asking! How can I help you today?"),
                ChatMessage(id: UUID(), role: "user", content: "Just testing.")
            ],
            createdAt: Date()
        )
        convo.title = "Hello there, how are you?"
        return convo
    }()
    
    let convo2: Conversation = {
        var convo = Conversation(
            messages: [
                ChatMessage(id: UUID(), role: "user", content: "Explain quantum physics simply."),
                ChatMessage(id: UUID(), role: "assistant", content: "Okay, imagine tiny balls that can be in multiple places at once until you look! It's weird but describes the very small."),
                ChatMessage(id: UUID(), role: "user", content: "So looking changes things?"),
                ChatMessage(id: UUID(), role: "assistant", content: "Exactly! The act of measurement forces it to 'choose' a state. It's called the observer effect.")
            ],
            createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )
        convo.title = "Explain quantum physics simply."
        return convo
    }()
    
    let convo3: Conversation = {
        var convo = Conversation(
            messages: [
                ChatMessage(id: UUID(), role: "user", content: "What was the weather like last month?"),
                ChatMessage(id: UUID(), role: "assistant_error", content: "Sorry, I don't have access to historical weather data that far back.")
            ],
            createdAt: Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        )
        convo.title = "What was the weather like last month?"
        return convo
    }()
    // --- End Multi-Turn Data ---
    
    let history = HistoryService.preview(with: [convo1, convo2, convo3].sorted { $0.createdAt > $1.createdAt })
    let env = PreviewEnvironment.make(history: history)
    
    NavigationStack {
        HistoryView(rootIsActive: .constant(false))
    }
    .environmentObject(env.history)
    .environmentObject(env.viewModel)
    .environmentObject(env.settings)
    .environmentObject(env.audio)
    .environmentObject(env.chat)
    .environmentObject(env.auth)
    .preferredColorScheme(.dark)
}
#endif
