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
                    }
                )
                .presentationDetents([.height(200)])
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
    @FocusState private var isFocused: Bool

    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(title: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: title)
        self.onSave = onSave
        self.onCancel = onCancel
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

                HStack(spacing: 16) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.secondaryText)

                    Button("Save") {
                        saveIfValid()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom)
            }
        }
        .onAppear {
            isFocused = true
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
    .preferredColorScheme(.dark)
}
#endif