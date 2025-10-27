//
//  ChatDetailView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 18.04.25.
//

import SwiftUI
import OSLog

struct ChatDetailView: View {
    @Binding var rootIsActive: Bool          // binding to pop all the way home
    @EnvironmentObject var viewModel: ChatViewModel
    @EnvironmentObject var audioService: AudioService
    @EnvironmentObject var historyService: HistoryService
    
    let conversationId: UUID
    
    @State private var conversationDetail: Conversation?    // loaded on demand
    @State private var replayingMessageId: UUID? = nil
    @State private var missingAudioMessageId: UUID? = nil
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatDetailView")
    
    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            Group {
                if let conversation = conversationDetail {
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
                } else {
                    ProgressView("Loading conversation…")
                        .foregroundColor(Theme.primaryText)
                        .progressViewStyle(CircularProgressViewStyle(tint: Theme.accent))
                }
            }
        }
        .onAppear {
            // Only load when the detail actually appears
            if conversationDetail == nil {
                Task {
                    conversationDetail = await historyService.loadConversationDetail(id: conversationId)
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
                if message.content.isEmpty && message.role.starts(with: "assistant") {
                    Text("No response received")
                        .italic()
                        .foregroundColor(Theme.secondaryText)
                        .padding(10)
                        .background(messageBackgroundColor(role: message.role))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    Text(message.content)
                        .padding(10)
                        .background(messageBackgroundColor(role: message.role))
                        .foregroundColor(messageForegroundColor(role: message.role))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            message.role == "assistant_partial" ? 
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(Theme.secondaryText.opacity(0.4), lineWidth: 1)
                                    
                                    Text("interrupted")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.secondaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule().fill(Theme.background.opacity(0.8))
                                        )
                                        .offset(y: 10)
                                } : nil
                        )
                }
                
                // Add buttons below assistant messages     
                if message.role.starts(with: "assistant") { // Covers assistant, assistant_partial, assistant_error
                    HStack {
                        Button {
                            toggleReplay(for: message)
                        } label: {
                            let isPlaying = replayingMessageId == message.id && audioService.isSpeaking
                            let isMissing = missingAudioMessageId == message.id
                            Image(systemName: "waveform")
                                .foregroundColor(isMissing ? Theme.errorText : Theme.primaryText)
                                .symbolEffect(.wiggle.left.byLayer, options: isMissing ? .repeat(.periodic(delay: 10)): .repeat(.continuous), isActive: isMissing || isPlaying)
                                .animation(.easeInOut(duration: 0.2), value: isMissing)
                        }
                        .buttonStyle(.borderless)
                        .font(.body)
                        
                        Button {
                            continueFromMessage(index: index)
                        } label: {
                            Image(systemName: "arrowshape.turn.up.right.fill")
                        }
                        .buttonStyle(.borderless)
                        .tint(Theme.primaryText)
                        .font(.body)
                    }
                    .padding(.top, 2)
                    .padding(.leading, 10)
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: message.role == "user" ? .trailing : .leading)
            .textSelection(.enabled)
            
            if message.role != "user" { Spacer() } // Align assistant messages left
        }
    }
    
    // --- Action Handlers ---
    
    private func continueFromMessage(index: Int) {
        logger.info("Continue tapped at \(index) for \(conversationId).")
        // Load up to the selected message and reset context; listening will resume when returning to main view
        if let conversation = conversationDetail {
            viewModel.loadConversationHistory(conversation, upTo: index)
        }
        // Pop back to the main view; ContentView.onChange will trigger listening start
        rootIsActive = false
    }
    
    // --- Styling Helpers ---
    private func messageBackgroundColor(role: String) -> Color {
        switch role {
        case "user": return Theme.menuAccent
        case "assistant_partial": return Theme.background.opacity(0.6)
        default: return Color.clear // Assistant messages will have no distinct background
        }
    }
    private func messageForegroundColor(role: String) -> Color {
        switch role {
        case "user": return Theme.primaryText
        case "assistant": return Theme.primaryText
        case "assistant_partial": return Theme.secondaryText
        case "assistant_error": return Theme.errorText
        default: return Theme.primaryText
        }
    }
    
    // Helper to only return file paths that still exist on disk
    private func existingAudioPaths(for message: ChatMessage) -> [String] {
        guard let relPaths = conversationDetail?.ttsAudioPaths?[message.id],
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return [] }
        return relPaths.filter {
            FileManager.default.fileExists(atPath: docs.appendingPathComponent($0).path)
        }
    }
    
    // Encapsulated toggle logic for replay/missing
    private func toggleReplay(for message: ChatMessage) {
        if replayingMessageId == message.id && audioService.isSpeaking {
            audioService.stopReplay()
            replayingMessageId = nil
        } else {
            let validPaths = existingAudioPaths(for: message)
            if validPaths.isEmpty {
                missingAudioMessageId = message.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { missingAudioMessageId = nil }  // hacky but timing is configured so that color transition ends when one wiggle animation ends
            } else {
                replayingMessageId = message.id
                audioService.replayAudioFiles(validPaths)
            }
        }
    }
}

#if DEBUG
#Preview {
    let conversation: Conversation = {
        var convo = Conversation(messages: [
            ChatMessage(id: UUID(), role: "user", content: "Tell me a joke."),
            ChatMessage(id: UUID(), role: "assistant", content: "Why don't scientists trust atoms? Because they make up everything!"),
            ChatMessage(id: UUID(), role: "user", content: "That was funny."),
            ChatMessage(id: UUID(), role: "assistant_partial", content: "I'm glad you think")
        ], createdAt: Date())
        convo.title = "Joke Chat"
        return convo
    }()
    let history = HistoryService.preview(with: [conversation])
    let env = PreviewEnvironment.make(history: history)

    NavigationStack { // Add NavigationStack for preview context
        ChatDetailView(rootIsActive: .constant(false), conversationId: conversation.id)
    }
    .environmentObject(env.viewModel)
    .environmentObject(env.audio)
    .environmentObject(env.settings)
    .environmentObject(env.history)
    .environmentObject(env.chat)
    .preferredColorScheme(.dark)
}
#endif
