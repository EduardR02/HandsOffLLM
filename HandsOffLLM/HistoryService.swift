//
//  HistoryService.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 18.04.25.
//

import Foundation
import OSLog

@MainActor
class HistoryService: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "HistoryService")
    @Published var conversations: [Conversation] = []   // Full conversation objects
    
    // MARK: - Storage Locations
    private let indexFileName = "conversations_index.json"
    private var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    private var indexFileURL: URL? {
        documentsURL?.appendingPathComponent(indexFileName)
    }
    private var convFolderURL: URL? {
        documentsURL?.appendingPathComponent("Conversations")
    }
    private var audioFolderURL: URL? {
        documentsURL?.appendingPathComponent("Audio")
    }
    // In-memory metadata index
    private var indexEntries: [ConversationIndexEntry] = []
    
    init() {
        // Ensure directories exist
        if let convURL = convFolderURL {
            try? FileManager.default.createDirectory(at: convURL, withIntermediateDirectories: true)
        }
        if let audioURL = audioFolderURL {
            try? FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        }
        // Load index and full conversations
        loadIndex()
        conversations = indexEntries.compactMap { entry in
            if let conv = loadFullConversation(id: entry.id) {
                return conv
            } else {
                var conv = Conversation(id: entry.id, messages: [], createdAt: entry.createdAt, parentConversationId: nil)
                conv.title = entry.title
                return conv
            }
        }
        conversations.sort { $0.createdAt > $1.createdAt }
        logger.info("HistoryService initialized. Loaded \(self.conversations.count) conversations.")
    }
    
    // MARK: - Index Persistence
    private func loadIndex() {
        guard let url = indexFileURL, FileManager.default.fileExists(atPath: url.path) else {
            indexEntries = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            indexEntries = try decoder.decode([ConversationIndexEntry].self, from: data)
        } catch {
            logger.error("Failed to load index: \(error.localizedDescription)")
            indexEntries = []
        }
    }
    
    private func saveIndex() {
        guard let url = indexFileURL else {
            logger.error("Could not get index file URL.")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(indexEntries)
            try data.write(to: url, options: [.atomicWrite])
        } catch {
            logger.error("Failed to save index: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Full Conversation Storage
    private func conversationFileURL(for id: UUID) -> URL? {
        convFolderURL?.appendingPathComponent("\(id.uuidString).json")
    }
    
    private func loadFullConversation(id: UUID) -> Conversation? {
        guard let url = conversationFileURL(for: id),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Conversation.self, from: data)
        } catch {
            logger.error("Failed to load conversation \(id): \(error.localizedDescription)")
            return nil
        }
    }
    
    private func saveConversationFile(_ conversation: Conversation) {
        guard let url = conversationFileURL(for: conversation.id) else {
            logger.error("Could not get file URL for conversation \(conversation.id)")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(conversation)
            try data.write(to: url, options: [.atomicWrite])
            logger.info("Saved conversation file for \(conversation.id)")
        } catch {
            logger.error("Failed to save conversation \(conversation.id): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Conversation Management
    
    func addOrUpdateConversation(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            // Update existing
            conversations[index] = conversation
            logger.info("Updated conversation \(conversation.id)")
        } else {
            // Add new
            conversations.insert(conversation, at: 0) // Insert at beginning for date sorting
            logger.info("Added new conversation \(conversation.id)")
        }
        // Ensure sorting after modification
        conversations.sort { $0.createdAt > $1.createdAt }
        // Persist full conversation to its own file
        saveConversationFile(conversation)
        // Update metadata index
        let entry = ConversationIndexEntry(id: conversation.id,
                                           title: conversation.title,
                                           createdAt: conversation.createdAt)
        if let idx = indexEntries.firstIndex(where: { $0.id == conversation.id }) {
            indexEntries[idx] = entry
        } else {
            indexEntries.insert(entry, at: 0)
        }
        saveIndex()
    }
    
    func deleteConversation(at offsets: IndexSet) {
        let idsToDelete = offsets.compactMap { idx in
            conversations.indices.contains(idx) ? conversations[idx].id : nil
        }
        for id in idsToDelete {
            // remove JSON
            if let fileURL = conversationFileURL(for: id) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            // remove audio folder
            if let audioDir = audioFolderURL?.appendingPathComponent(id.uuidString) {
                try? FileManager.default.removeItem(at: audioDir)
            }
            // update indexEntries…
            if let idx = indexEntries.firstIndex(where: { $0.id == id }) {
                indexEntries.remove(at: idx)
            }
        }
        saveIndex()
        conversations.remove(atOffsets: offsets)
        logger.info("Deleted conversations at offsets \(offsets).")
    }
    
    func deleteConversation(id: UUID) {
        // remove JSON
        if let fileURL = conversationFileURL(for: id) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        // remove audio folder
        if let audioDir = audioFolderURL?.appendingPathComponent(id.uuidString) {
            try? FileManager.default.removeItem(at: audioDir)
        }
        // update indexEntries…
        if let idx = indexEntries.firstIndex(where: { $0.id == id }) {
            indexEntries.remove(at: idx)
            saveIndex()
        }
        conversations.removeAll { $0.id == id }
        logger.info("Deleted conversation with id \(id).")
    }
    
    func generateTitleIfNeeded(for conversation: Conversation) -> Conversation {
        var updatedConversation = conversation
        if updatedConversation.title == nil || updatedConversation.title!.isEmpty {
            // Simple title: Use timestamp or first few words of first user message
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let dateString = formatter.string(from: updatedConversation.createdAt)
            
            if let firstUserMessage = updatedConversation.messages.first(where: { $0.role == "user" }) {
                let words = firstUserMessage.content.split(separator: " ").prefix(5)
                updatedConversation.title = "\(words.joined(separator: " "))..."
            } else {
                updatedConversation.title = "Chat from \(dateString)"
            }
            logger.info("Generated title for conversation \(updatedConversation.id): '\(updatedConversation.title ?? "Error")'")
        }
        return updatedConversation
    }
    
    // MARK: - Utility for Views
    func groupConversationsByDate() -> [(String, [Conversation])] {
        let calendar = Calendar.current
        let now = Date()
        var groupedDict: [String: [Conversation]] = [:]
        
        let dateFormatter = DateFormatter()
        
        for conversation in conversations {
            let date = conversation.createdAt
            var key: String
            
            if calendar.isDateInToday(date) {
                key = "Today"
            } else if calendar.isDateInYesterday(date) {
                key = "Yesterday"
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date >= weekAgo {
                key = "Last Week"
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now), date >= monthAgo {
                key = "Last Month"
            } else {
                // Format by Month and Year for older chats
                dateFormatter.dateFormat = "MMMM yyyy" // e.g., "July 2024"
                key = dateFormatter.string(from: date)
            }
            
            if groupedDict[key] == nil { groupedDict[key] = [] }
            groupedDict[key]?.append(conversation)
        }
        
        // Define the order of sections
        let sectionOrder = ["Today", "Yesterday", "Last Week", "Last Month"]
        
        // Create sorted array, respecting the defined order first, then chronological for months/years
        var sortedGroups: [(String, [Conversation])] = []
        
        // Add the fixed sections in order
        for key in sectionOrder {
            if let conversations = groupedDict[key] {
                // Conversations within these sections are already sorted newest first by the initial load sort
                sortedGroups.append((key, conversations))
                groupedDict.removeValue(forKey: key) // Remove from dict
            }
        }
        
        // Add the remaining month/year sections, sorted chronologically descending by month/year
        let remainingKeys = groupedDict.keys.sorted { (key1, key2) -> Bool in
            dateFormatter.dateFormat = "MMMM yyyy"
            guard let date1 = dateFormatter.date(from: key1), let date2 = dateFormatter.date(from: key2) else {
                return false // Should not happen if keys are correct
            }
            return date1 > date2 // Newest month/year first
        }
        
        for key in remainingKeys {
            if let conversations = groupedDict[key] {
                sortedGroups.append((key, conversations))
            }
        }
        
        return sortedGroups
    }
    
    // MARK: - Audio Saving
    /// Save raw TTS audio data for a specific chunk as a file and update the conversation's audio paths
    /// - Parameters:
    ///   - conversationID: The UUID of the conversation
    ///   - messageID: The UUID of the message
    ///   - data: Audio data to save
    ///   - ext: File extension (e.g., "aac", "mp3")
    ///   - chunkIndex: Index of this audio chunk for naming
    /// - Returns: Relative path under Documents to the saved audio file
    func saveAudioData(conversationID: UUID, messageID: UUID, data: Data, ext: String, chunkIndex: Int) throws -> String {
        guard let docs = documentsURL else {
            throw NSError(domain: "HistoryService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Documents directory not found"]) }
        let audioDir = docs.appendingPathComponent("Audio").appendingPathComponent(conversationID.uuidString)
        try FileManager.default.createDirectory(at: audioDir,
                                                withIntermediateDirectories: true)
        let filename = "\(messageID.uuidString)-\(chunkIndex).\(ext)"
        let fileURL = audioDir.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomicWrite)
        let relPath = "Audio/\(conversationID.uuidString)/\(filename)"
        
        return relPath // Just return the path
    }
}

