//
//  HistoryView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 18.04.25.
//

import SwiftUI

struct HistoryView: View {
    @Binding var rootIsActive: Bool           // NEW: binding back to ContentView
    @EnvironmentObject var historyService: HistoryService
    @EnvironmentObject var viewModel: ChatViewModel // Add ViewModel
    
    var groupedConversations: [(String, [ConversationIndexEntry])] {
        historyService.groupIndexByDate()
    }
    
    var body: some View {
        List {
            ForEach(groupedConversations, id: \.0) { sectionTitle, entries in
                Section(header: Text(sectionTitle).foregroundColor(.gray)) {
                    ForEach(entries) { entry in
                        ConversationRow(entry: entry, rootIsActive: $rootIsActive)
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
        .onAppear {
            viewModel.pauseMainActivities()
        }
        .onDisappear {
            // Only resume listening when actually exiting history view (not when navigating deeper)
            if !rootIsActive {
                viewModel.startListening()
            }
        }
    }
    
    private func deleteConversations(in section: String, at offsets: IndexSet) {
        guard let entriesInSection = groupedConversations.first(where: { $0.0 == section })?.1 else {
            return
        }
        let idsToDelete = offsets.map { entriesInSection[$0].id }
        for id in idsToDelete {
            historyService.deleteConversation(id: id)
        }
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

// MARK: – Tiny helper to speed up compilation
private struct ConversationRow: View {
    let entry: ConversationIndexEntry
    @Binding var rootIsActive: Bool
    
    var body: some View {
        NavigationLink(destination: ChatDetailView(
            rootIsActive: $rootIsActive,
            conversationId: entry.id
        )) {
            VStack(alignment: .leading) {
                Text(entry.title ?? "Untitled Chat")
                    .font(.headline)
                Text(entry.createdAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .isDetailLink(false)
    }
}
