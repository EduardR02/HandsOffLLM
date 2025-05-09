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

    @State private var groupedConversations: [(String, [ConversationIndexEntry])] = []

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)

            List {
                ForEach(groupedConversations, id: \.0) { section, entries in
                    Section(header: Text(section)
                                .foregroundColor(Theme.secondaryText)) {
                        ForEach(entries) { entry in
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
                            }
                            .listRowBackground(Theme.menuAccent)
                            .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                        }
                        .onDelete { offsets in
                            deleteConversations(in: section, at: offsets)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("History")
        .listStyle(.insetGrouped)
        .onAppear {
            groupedConversations = historyService.groupIndexByDate()
        }
    }

    private func deleteConversations(in section: String, at offsets: IndexSet) {
        guard let entries = groupedConversations.first(where: { $0.0 == section })?.1 else { return }
        let ids = offsets.map { entries[$0].id }
        for id in ids {
            historyService.deleteConversation(id: id)
        }
        // Refresh the grouped list after deletion
        groupedConversations = historyService.groupIndexByDate()
    }
}

#Preview {
    // --- Make Dummy Conversations Multi-Turn ---
    var convo1 = Conversation(
        messages: [
            ChatMessage(id: UUID(), role: "user", content: "Hello there, how are you?"),
            ChatMessage(id: UUID(), role: "assistant", content: "I'm doing well, thank you for asking! How can I help you today?"),
            ChatMessage(id: UUID(), role: "user", content: "Just testing.")
        ],
        createdAt: Date()
    )
    convo1.title = "Hello there, how are you?"
    
    var convo2 = Conversation(
        messages: [
            ChatMessage(id: UUID(), role: "user", content: "Explain quantum physics simply."),
            ChatMessage(id: UUID(), role: "assistant", content: "Okay, imagine tiny balls that can be in multiple places at once until you look! It's weird but describes the very small."),
            ChatMessage(id: UUID(), role: "user", content: "So looking changes things?"),
            ChatMessage(id: UUID(), role: "assistant", content: "Exactly! The act of measurement forces it to 'choose' a state. It's called the observer effect.")
        ],
        createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    )
    convo2.title = "Explain quantum physics simply."
    
    var convo3 = Conversation(
        messages: [
            ChatMessage(id: UUID(), role: "user", content: "What was the weather like last month?"),
            ChatMessage(id: UUID(), role: "assistant_error", content: "Sorry, I don't have access to historical weather data that far back.")
        ],
        createdAt: Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    )
    convo3.title = "What was the weather like last month?"
    // --- End Multi-Turn Data ---
    
    let history = HistoryService.preview(with: [convo1, convo2, convo3].sorted { $0.createdAt > $1.createdAt })
    
    // Mock other services needed by environment
    let settings = SettingsService()
    let audio = AudioService(settingsService: settings, historyService: history)
    // Pass the *populated* history service to ChatService
    let chat = ChatService(settingsService: settings, historyService: history)
    let viewModel = ChatViewModel(audioService: audio, chatService: chat, settingsService: settings, historyService: history)
    
    // Add 'return' here to explicitly mark the View being returned
    return NavigationStack {
        HistoryView(rootIsActive: .constant(false))
    }
    .environmentObject(history)
    .environmentObject(viewModel) // Provide ViewModel
    .environmentObject(settings)
    .environmentObject(audio)
    .preferredColorScheme(.dark)
}
