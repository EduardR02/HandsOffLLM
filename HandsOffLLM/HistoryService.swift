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
    // Published metadata index (for list views)
    @Published var indexEntries: [ConversationIndexEntry] = []
    // In-memory store for SwiftUI previews
    private var previewStore: [UUID: Conversation] = [:]
    
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
    
    init() {
        // Ensure directories exist
        if let convURL = convFolderURL {
            try? FileManager.default.createDirectory(at: convURL, withIntermediateDirectories: true)
        }
        if let audioURL = audioFolderURL {
            try? FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        }
        loadIndex()
    }
    
    // MARK: - Index Persistence
    private func loadIndex() {
        guard let url = indexFileURL, FileManager.default.fileExists(atPath: url.path) else {
            // No index file: rebuild from conversation JSON files
            rebuildIndexFromFiles()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            indexEntries = try decoder.decode([ConversationIndexEntry].self, from: data)
        } catch {
            logger.error("Failed to load index: \(error.localizedDescription)")
            // On error, also attempt rebuild
            rebuildIndexFromFiles()
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
        // Persist full conversation to file and update indexEntries
        saveConversationFile(conversation)
        let entry = ConversationIndexEntry(id: conversation.id,
                                           title: conversation.title,
                                           createdAt: conversation.createdAt)
        if let idx = indexEntries.firstIndex(where: { $0.id == entry.id }) {
            indexEntries[idx] = entry
        } else {
            indexEntries.insert(entry, at: 0)
        }
        saveIndex()
    }
    
    private func removeConversationAssets(id: UUID) {
        if let fileURL = conversationFileURL(for: id) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let audioDir = audioFolderURL?.appendingPathComponent(id.uuidString) {
            try? FileManager.default.removeItem(at: audioDir)
        }
        if let idx = indexEntries.firstIndex(where: { $0.id == id }) {
            indexEntries.remove(at: idx)
        }
    }
    
    func deleteConversation(id: UUID) {
        removeConversationAssets(id: id)
        saveIndex()
        logger.info("Deleted conversation with id \(id).")
    }
    
    func loadConversationDetail(id: UUID) async -> Conversation? {
        // If set for preview, return from memory
        if let conv = previewStore[id] { return conv }
        guard let url = conversationFileURL(for: id) else { return nil }
        return await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Conversation.self, from: data)
        }.value
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
    
    func groupIndexByDate() -> [(String, [ConversationIndexEntry])] {
        let calendar = Calendar.current
        let now = Date()
        var grouped: [String: [ConversationIndexEntry]] = [:]
        let df = DateFormatter()
        for entry in indexEntries {
            let date = entry.createdAt
            let key: String
            if calendar.isDateInToday(date) { key = "Today" }
            else if calendar.isDateInYesterday(date) { key = "Yesterday" }
            else if let wk = calendar.date(byAdding: .day, value: -7, to: now), date >= wk { key = "Last Week" }
            else if let mo = calendar.date(byAdding: .month, value: -1, to: now), date >= mo { key = "Last Month" }
            else { df.dateFormat = "MMMM yyyy"; key = df.string(from: date) }
            grouped[key, default: []].append(entry)
        }
        let order = ["Today","Yesterday","Last Week","Last Month"]
        var result: [(String, [ConversationIndexEntry])] = []
        for k in order { if let arr = grouped.removeValue(forKey: k) { result.append((k, arr)) }}
        let rest = grouped.keys.sorted { df.dateFormat = "MMMM yyyy"; return df.date(from: $0)! > df.date(from: $1)! }
        for k in rest { result.append((k, grouped[k]!)) }
        return result
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
    
    /// SwiftUI preview factory: sets indexEntries and in-memory conversations
    static func preview(with conversations: [Conversation]) -> HistoryService {
        let service = HistoryService()
        let entries = conversations.map { ConversationIndexEntry(id: $0.id,
                                                                 title: $0.title,
                                                                 createdAt: $0.createdAt) }
        service.indexEntries = entries.sorted { $0.createdAt > $1.createdAt }
        service.previewStore = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        return service
    }
    
    /// Rebuilds the index by scanning stored conversation files.
    private func rebuildIndexFromFiles() {
        guard let folder = convFolderURL else {
            indexEntries = []
            return
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: .skipsHiddenFiles)
                .filter { $0.pathExtension == "json" }
            var entries: [ConversationIndexEntry] = []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for fileURL in files {
                if let data = try? Data(contentsOf: fileURL),
                   let conv = try? decoder.decode(Conversation.self, from: data) {
                    entries.append(ConversationIndexEntry(id: conv.id,
                                                         title: conv.title,
                                                         createdAt: conv.createdAt))
                    // Optionally keep in previewStore
                    previewStore[conv.id] = conv
                }
            }
            // Sort and persist
            indexEntries = entries.sorted { $0.createdAt > $1.createdAt }
            saveIndex()
            logger.info("Rebuilt index from \(entries.count) files.")
        } catch {
            logger.error("Failed to rebuild index: \(error.localizedDescription)")
            indexEntries = []
        }
    }
}
