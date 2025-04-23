//
//  ChatDetailView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 18.04.25.
//

import SwiftUI
import OSLog

struct ChatDetailView: View {
    @Binding var rootIsActive: Bool          // NEW: binding to pop all the way home
    @EnvironmentObject var viewModel: ChatViewModel // For loading history
    @EnvironmentObject var audioService: AudioService // For TTS replay (future)
    @EnvironmentObject var historyService: HistoryService         // ← added
    
    let conversationId: UUID                                     // ← changed from `Conversation`
    
    // Always read the latest from HistoryService
    private var conversation: Conversation {
        historyService.conversations.first { $0.id == conversationId }!
    }
    
    @State private var replayingMessageId: UUID? = nil           // ← added
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatDetailView")
    
    var body: some View {
        ScrollViewReader { proxy in // To scroll to bottom
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        MessageView(message: message, index: index, conversationId: conversation.id)
                            .id(message.id) // Add ID for scrolling
                    }
                }
                .padding()
            }
            .navigationTitle(conversation.title ?? "Chat Details")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Scroll to the bottom on appear
                if let lastMessageId = conversation.messages.last?.id {
                    DispatchQueue.main.async { // Ensure UI updates are done
                        proxy.scrollTo(lastMessageId, anchor: .bottom)
                    }
                }
            }
            .onDisappear {
                // Stop any ongoing replay when the view disappears
                if replayingMessageId != nil {
                    logger.info("ChatDetailView disappearing, stopping audio replay.")
                    audioService.stopReplay()
                    replayingMessageId = nil // Also clear the state
                }
            }
        }
    }
    
    // Inner view for displaying a single message with buttons
    @ViewBuilder
    private func MessageView(message: ChatMessage, index: Int, conversationId: UUID) -> some View {
        HStack {
            if message.role == "user" { Spacer() } // Align user messages right
            
            VStack(alignment: message.role == "user" ? .trailing : .leading) {
                Text(message.content)
                    .padding(10)
                    .background(messageBackgroundColor(role: message.role))
                    .foregroundColor(messageForegroundColor(role: message.role))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                
                // Add buttons below assistant messages
                if message.role.starts(with: "assistant") { // Covers assistant, assistant_partial, assistant_error
                    HStack {
                        Button {
                            if replayingMessageId == message.id && audioService.isSpeaking {
                                audioService.stopReplay()             // ← new stop
                                replayingMessageId = nil
                            } else {
                                replayingMessageId = message.id      // ← mark playing
                                replayTTS(message: message)
                            }
                        } label: {
                            if replayingMessageId == message.id && audioService.isSpeaking {
                                Image(systemName: "stop.fill")
                            } else {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                        }
                        .buttonStyle(.borderless)
                        .tint(.white)
                        .font(.caption)
                        .disabled(conversation.ttsAudioPaths?[message.id]?.isEmpty ?? true)
                        
                        Button {
                            continueFromMessage(index: index)
                        } label: {
                            Image(systemName: "arrowshape.turn.up.right.fill")
                        }
                        .buttonStyle(.borderless)
                        .tint(.white)
                        .font(.caption)
                    }
                    .padding(.top, 2)
                    .padding(.leading, 10)
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: message.role == "user" ? .trailing : .leading) // Limit width
            
            
            if message.role != "user" { Spacer() } // Align assistant messages left
        }
    }
    
    // --- Action Handlers ---
    private func replayTTS(message: ChatMessage) {
        if let paths = conversation.ttsAudioPaths?[message.id], !paths.isEmpty {
            logger.info("Replay TTS for message \(message.id), files: \(paths)")
            audioService.replayAudioFiles(paths)
        } else {
            logger.warning("No saved audio for message \(message.id).")
        }
    }
    
    private func continueFromMessage(index: Int) {
        logger.info("Continue tapped at \(index) for \(conversation.id).")
        // Load up to the selected message and reset context; listening will resume when returning to main view
        viewModel.loadConversationHistory(conversation, upTo: index)
        // Pop back to the main view; ContentView.onChange will trigger listening start
        rootIsActive = false
    }
    
    // --- Styling Helpers ---
    private func messageBackgroundColor(role: String) -> Color {
        switch role {
        case "user": return Color(red: 40/255.0, green: 44/255.0, blue: 52/255.0)
        default: return Color.clear
        }
    }
    private func messageForegroundColor(role: String) -> Color {
        switch role {
        case "user": return Color.white
        case "assistant": return Color.white
        case "assistant_partial", "assistant_error": return Color(red: 250/255.0, green: 170/255.0, blue: 170/255.0)
        default: return Color.primary
        }
    }
}

#Preview {
    // Mock data for preview
    let history = HistoryService()
    var convo = Conversation(messages: [
        ChatMessage(id: UUID(), role: "user", content: "Tell me a joke."),
        ChatMessage(id: UUID(), role: "assistant", content: "Why don't scientists trust atoms? Because they make up everything!"),
        ChatMessage(id: UUID(), role: "user", content: "That was funny."),
        ChatMessage(id: UUID(), role: "assistant_partial", content: "I'm glad you think"),
    ], createdAt: Date())
    convo.title = "Joke Chat"
    history.conversations = [convo]
    
    let settings = SettingsService()
    let audio = AudioService(settingsService: settings, historyService: history)
    let chat = ChatService(settingsService: settings, historyService: history)
    let viewModel = ChatViewModel(audioService: audio, chatService: chat, settingsService: settings, historyService: history)
    
    return NavigationStack { // Add NavigationStack for preview context
        ChatDetailView(rootIsActive: .constant(false), conversationId: convo.id)
    }
    .environmentObject(viewModel)
    .environmentObject(audio)
    .environmentObject(settings) // Make sure all required env objects are present
    .environmentObject(history)
    .preferredColorScheme(.dark)
}

