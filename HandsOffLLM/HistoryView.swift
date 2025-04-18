//
//  HistoryView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 18.04.25.
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var historyService: HistoryService
    @EnvironmentObject var chatViewModel: ChatViewModel // Inject ViewModel for navigation/loading
    @Environment(\.dismiss) var dismiss // To dismiss the view after loading a chat

    var groupedConversations: [(String, [Conversation])] {
        historyService.groupConversationsByDate()
    }

    var body: some View {
        List {
            ForEach(groupedConversations, id: \.0) { sectionTitle, conversationsInSection in
                Section(header: Text(sectionTitle).foregroundColor(.gray)) {
                    ForEach(conversationsInSection) { conversation in
                        NavigationLink {
                            // Navigate to ChatDetailView
                            ChatDetailView(conversation: conversation)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(conversation.title ?? "Untitled Chat")
                                    .font(.headline)
                                Text("Messages: \(conversation.messages.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                // TODO: Add indicator if it's a continued chat (parentConversationId != nil)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        // Find the actual conversations to delete based on the section and indexSet
                        deleteConversations(in: sectionTitle, at: indexSet)
                    }
                }
            }
        }
        .navigationTitle("History")
        .listStyle(.insetGrouped) // Or plain, grouped, etc.
    }

    private func deleteConversations(in section: String, at offsets: IndexSet) {
         guard let conversationsInSection = groupedConversations.first(where: { $0.0 == section })?.1 else {
             return
         }
         let idsToDelete = offsets.map { conversationsInSection[$0].id }
         for id in idsToDelete {
             historyService.deleteConversation(id: id)
         }
    }
}

#Preview {
    // Mock data for preview
    let history = HistoryService()
    // Add some dummy conversations
    var convo1 = Conversation(messages: [ChatMessage(id: UUID(), role: "user", content: "Hello there")], createdAt: Date())
    convo1.title = history.generateTitleIfNeeded(for: convo1).title
    var convo2 = Conversation(messages: [ChatMessage(id: UUID(), role: "user", content: "Explain quantum physics")], createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
     convo2.title = history.generateTitleIfNeeded(for: convo2).title
     var convo3 = Conversation(messages: [ChatMessage(id: UUID(), role: "user", content: "Old chat from last month")], createdAt: Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
     convo3.title = history.generateTitleIfNeeded(for: convo3).title

    history.conversations = [convo1, convo2, convo3]

    // Mock other services needed by environment
    let settings = SettingsService()
    let audio = AudioService(settingsService: settings)
    let chat = ChatService(settingsService: settings, historyService: history)
    let viewModel = ChatViewModel(audioService: audio, chatService: chat, settingsService: settings, historyService: history)

    // Add 'return' here to explicitly mark the View being returned
    return NavigationStack {
        HistoryView()
    }
    .environmentObject(history)
    .environmentObject(viewModel) // Provide ViewModel
    .environmentObject(settings)  // Provide Settings
    .environmentObject(audio)     // Provide Audio
    .preferredColorScheme(.dark)
}

