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

    let conversation: Conversation
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
                     .clipShape(RoundedRectangle(cornerRadius: 10))

                 // Add buttons below assistant messages
                 if message.role.starts(with: "assistant") { // Covers assistant, assistant_partial, assistant_error
                     HStack {
                         Button {
                             replayTTS(message: message)
                         } label: {
                             Image(systemName: "speaker.wave.2.fill")
                             Text("Replay")
                         }
                         .buttonStyle(.bordered)
                         .tint(.blue)
                         .font(.caption)
                         // Disable if TTS data isn't available (future)
                         .disabled(true) // Placeholder: Disable replay for now

                         Button {
                             continueFromMessage(index: index)
                         } label: {
                             Image(systemName: "arrowshape.turn.up.right.fill")
                             Text("Continue")
                         }
                         .buttonStyle(.bordered)
                         .tint(.green)
                         .font(.caption)
                     }
                     .padding(.top, 2)
                 }
             }
             .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: message.role == "user" ? .trailing : .leading) // Limit width


             if message.role != "user" { Spacer() } // Align assistant messages left
         }
    }

     // --- Action Handlers ---
     private func replayTTS(message: ChatMessage) {
         logger.info("Replay TTS tapped for message \(message.id). (Functionality not implemented)")
         // TODO: Implement actual TTS replay using AudioService
         // 1. Check if audio file exists (using conversation.ttsAudioPaths?[message.id])
         // 2. If yes, tell AudioService to play the file.
         // 3. If no, potentially re-synthesize and play? (More complex)
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
         case "user": return Color.blue
         case "assistant": return Color.gray.opacity(0.6)
         case "assistant_partial": return Color.purple.opacity(0.4)
         case "assistant_error": return Color.red.opacity(0.5)
         default: return Color.secondary
         }
     }
     private func messageForegroundColor(role: String) -> Color {
         switch role {
         case "user": return Color.white
         case "assistant": return Color.white
         case "assistant_partial", "assistant_error": return Color.white
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
     let audio = AudioService(settingsService: settings)
     let chat = ChatService(settingsService: settings, historyService: history)
     let viewModel = ChatViewModel(audioService: audio, chatService: chat, settingsService: settings, historyService: history)

     return NavigationStack { // Add NavigationStack for preview context
         ChatDetailView(rootIsActive: .constant(false), conversation: convo)
     }
     .environmentObject(viewModel)
     .environmentObject(audio)
     .environmentObject(settings) // Make sure all required env objects are present
     .environmentObject(history)
     .preferredColorScheme(.dark)
}

