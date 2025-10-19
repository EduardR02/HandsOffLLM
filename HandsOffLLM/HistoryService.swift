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
    @Published var audioRetentionDays: Int
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
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: "HistoryService.audioRetentionDays") as? Int {
            audioRetentionDays = max(0, stored)
        } else {
            audioRetentionDays = 7
        }
        // Ensure directories exist
        if let convURL = convFolderURL {
            try? FileManager.default.createDirectory(at: convURL, withIntermediateDirectories: true)
        }
        if let audioURL = audioFolderURL {
            try? FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        }
        Task {
            await loadIndex()
            await scheduleDailyAudioCleanup()
        }
    }
    
    // MARK: - Index Persistence
    private func loadIndex() async {
        guard let url = indexFileURL else {
            logger.warning("Index file URL is nil, rebuilding.")
            await rebuildIndexFromFiles()
            return
        }

        let fileExists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value

        if !fileExists {
            logger.info("Index file not found, rebuilding.")
            await rebuildIndexFromFiles()
            return
        }
        
        do {
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            indexEntries = try decoder.decode([ConversationIndexEntry].self, from: data)
        } catch {
            logger.error("Failed to load index: \(error.localizedDescription), rebuilding.")
            await rebuildIndexFromFiles()
        }
    }
    
    private func saveIndex() async {
        guard let url = indexFileURL else {
            logger.error("Could not get index file URL for saving.")
            return
        }
        let entriesToSave = self.indexEntries
        let capturedLogger = self.logger
        await Task.detached {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(entriesToSave)
                try data.write(to: url, options: [.atomicWrite])
            } catch {
                capturedLogger.error("Failed to save index in background: \(error.localizedDescription)")
            }
        }.value
    }
    
    // MARK: - Full Conversation Storage
    private func conversationFileURL(for id: UUID) -> URL? {
        convFolderURL?.appendingPathComponent("\(id.uuidString).json")
    }
    
    private func saveConversationFile(_ conversation: Conversation) async {
        guard let url = conversationFileURL(for: conversation.id) else {
            logger.error("Could not get file URL for conversation \(conversation.id)")
            return
        }
        let capturedLogger = self.logger
        await Task.detached {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(conversation)
                try data.write(to: url, options: [.atomicWrite])
            } catch {
                capturedLogger.error("Failed to save conversation \(conversation.id) in background: \(error.localizedDescription)")
            }
        }.value
    }
    
    // MARK: - Conversation Management
    
    func addOrUpdateConversation(_ conversation: Conversation) async {
        await saveConversationFile(conversation)
        let entry = ConversationIndexEntry(id: conversation.id,
                                           title: conversation.title,
                                           createdAt: conversation.createdAt)
        if let idx = indexEntries.firstIndex(where: { $0.id == entry.id }) {
            indexEntries[idx] = entry
        } else {
            indexEntries.insert(entry, at: 0)
            indexEntries.sort { $0.createdAt > $1.createdAt } // Maintain sort order
        }
        await saveIndex()
    }

    func updateConversationTitle(conversationId: UUID, newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var didMutateIndex = false
        if let idx = indexEntries.firstIndex(where: { $0.id == conversationId }) {
            let existing = indexEntries[idx]
            if existing.title != trimmed {
                let updated = ConversationIndexEntry(id: existing.id,
                                                     title: trimmed,
                                                     createdAt: existing.createdAt)
                indexEntries[idx] = updated
                didMutateIndex = true
            }
        }
        if didMutateIndex { await saveIndex() }

        guard let url = conversationFileURL(for: conversationId) else { return }
        let capturedLogger = self.logger
        await Task.detached {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601

            do {
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                let data = try Data(contentsOf: url)
                var conversation = try decoder.decode(Conversation.self, from: data)
                if conversation.title == trimmed { return }
                conversation.title = trimmed
                let updatedData = try encoder.encode(conversation)
                try updatedData.write(to: url, options: [.atomicWrite])
            } catch {
                capturedLogger.error("Failed to update title for conversation \(conversationId): \(error.localizedDescription)")
            }
        }.value
    }
    
    private func removeConversationAssets(id: UUID) async {
        let capturedLogger = self.logger
        if let fileURL = conversationFileURL(for: id) {
            await Task.detached {
                do { try FileManager.default.removeItem(at: fileURL) }
                catch { capturedLogger.warning("Failed to remove conversation file \(id): \(error.localizedDescription)")}
            }.value
        }
        if let audioDir = audioFolderURL?.appendingPathComponent(id.uuidString) {
            await Task.detached {
                do { try FileManager.default.removeItem(at: audioDir) }
                catch { capturedLogger.warning("Failed to remove audio directory for conversation \(id): \(error.localizedDescription)")}
            }.value
        }
        if let idx = indexEntries.firstIndex(where: { $0.id == id }) {
            indexEntries.remove(at: idx)
        }
    }
    
    func deleteConversation(id: UUID) async {
        await removeConversationAssets(id: id)
        await saveIndex()
        logger.info("Deleted conversation with id \(id).")
    }
    
    func loadConversationDetail(id: UUID) async -> Conversation? {
        // If set for preview, return from memory
        if let conv = previewStore[id] { return conv }
        guard let url = conversationFileURL(for: id) else { return nil }

        let capturedLogger = self.logger
        return await Task.detached {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(Conversation.self, from: data)
            } catch {
                capturedLogger.error("Background error loading conversation detail \(id): \(error.localizedDescription)")
                return nil
            }
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
                updatedConversation.title = "\(words.joined(separator: " "))"
            } else {
                updatedConversation.title = "Chat from \(dateString)"
            }
            logger.info("Generated title for conversation \(updatedConversation.id): '\(updatedConversation.title ?? "Error")'")
        }
        return updatedConversation
    }
    
    // MARK: - Utility for Views
    
    private func getSectionKey(for date: Date, calendar: Calendar, now: Date, formatter: DateFormatter) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now), date >= sevenDaysAgo { return "Last Week" }
        if let oneMonthAgo = calendar.date(byAdding: .month, value: -1, to: now), date >= oneMonthAgo { return "Last Month" }
        return formatter.string(from: date)
    }
    
    func groupIndexByDate() -> [(String, [ConversationIndexEntry])] {
        guard !indexEntries.isEmpty else { return [] }

        var result: [(String, [ConversationIndexEntry])] = []
        var currentSectionTitle: String = ""
        var currentSectionEntries: [ConversationIndexEntry] = []

        let calendar = Calendar.current
        let now = Date()
        let monthYearFormatter = DateFormatter()
        monthYearFormatter.dateFormat = "MMMM yyyy"

        // indexEntries are assumed to be sorted by createdAt, newest first.
        for entry in indexEntries {
            let key = getSectionKey(for: entry.createdAt, calendar: calendar, now: now, formatter: monthYearFormatter)

            if key == currentSectionTitle {
                currentSectionEntries.append(entry)
            } else {
                if !currentSectionEntries.isEmpty { // Only append if there are entries for the previous section
                    result.append((currentSectionTitle, currentSectionEntries))
                }
                currentSectionTitle = key
                currentSectionEntries = [entry]
            }
        }

        // Append the very last section being built, if it has entries.
        if !currentSectionEntries.isEmpty {
            result.append((currentSectionTitle, currentSectionEntries))
        }

        return result
    }
    
    func saveAudioData(conversationID: UUID, messageID: UUID, data: Data, ext: String, chunkIndex: Int) async throws -> String {
        guard let docs = documentsURL else {
            throw NSError(domain: "HistoryService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Documents directory not found"]) }
        let audioDir = docs.appendingPathComponent("Audio").appendingPathComponent(conversationID.uuidString)
        let filename = "\(messageID.uuidString)-\(chunkIndex).\(ext)"
        let fileURL = audioDir.appendingPathComponent(filename)
        
        let capturedLogger = self.logger
        try await Task.detached {
            do {
                try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: nil)
                try data.write(to: fileURL, options: .atomicWrite)
            } catch {
                capturedLogger.error("Failed to save audio data for msg \(messageID) chunk \(chunkIndex) in background: \(error.localizedDescription)")
                throw error // Rethrow to be caught by the caller
            }
        }.value
        
        return "Audio/\(conversationID.uuidString)/\(filename)"
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
    private func rebuildIndexFromFiles() async {
        guard let folder = convFolderURL else { indexEntries = []; return }

        let entries: [ConversationIndexEntry] = await Task.detached {
            let fileURLs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?
                              .filter { $0.pathExtension == "json" } ?? []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return fileURLs.compactMap { url in
                (try? Data(contentsOf: url)).flatMap { data in
                    try? decoder.decode(ConversationIndexEntry.self, from: data)
                }
            }
        }.value

        indexEntries = entries.sorted { $0.createdAt > $1.createdAt }
        logger.info("Rebuilt index from \(self.indexEntries.count) conversation files.")
        await saveIndex()
    }

    // → only run deletion once per calendar day
    private func scheduleDailyAudioCleanup(force: Bool = false) async {
        guard audioRetentionDays > 0 else { return }
        let key = "HistoryService.lastAudioCleanupDate"
        let defaults = UserDefaults.standard
        if !force,
           let lastCleanupDate = defaults.object(forKey: key) as? Date,
           Calendar.current.isDateInToday(lastCleanupDate) {
            return 
        }
        await cleanupOldAudioFiles(olderThan: audioRetentionDays)
        defaults.set(Date(), forKey: key)
    }

    // → walk the Audio folder and delete files > days old
    private func cleanupOldAudioFiles(olderThan days: Int) async {
        guard days > 0 else {
            logger.info("Audio retention set to keep forever; skipping cleanup.")
            return
        }
        logger.info("Starting cleanup of audio files older than \(days) days.")
        guard let audioRootURL = audioFolderURL else {
            logger.warning("Audio folder URL is nil. Cannot perform cleanup.")
            return
        }
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        
        let capturedLogger = self.logger
        await Task.detached {
            let fm = FileManager.default
            guard let conversationAudioDirs = try? fm.contentsOfDirectory(
                at: audioRootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], // Include creationDateKey for directories
                options: .skipsHiddenFiles
            ) else {
                capturedLogger.warning("Could not list conversation audio directories for cleanup.")
                return
            }

            for dirURL in conversationAudioDirs {
                guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                
                do {
                    // Check the creation date of the directory itself
                    let directoryAttributes = try dirURL.resourceValues(forKeys: [.creationDateKey])
                    if let creationDate = directoryAttributes.creationDate, creationDate < cutoffDate {
                        try fm.removeItem(at: dirURL)
                        // capturedLogger.info("Cleaned up old audio directory: \(dirURL.lastPathComponent)")
                    }
                } catch {
                    capturedLogger.warning("Error processing or deleting audio directory \(dirURL.lastPathComponent): \(error)")
                }
            }
        }.value
        logger.info("Audio cleanup task completed.")
    }

    func updateAudioRetentionDays(_ days: Int) {
        let normalized = max(0, days)
        guard normalized != audioRetentionDays else { return }
        audioRetentionDays = normalized
        let defaults = UserDefaults.standard
        defaults.set(normalized, forKey: "HistoryService.audioRetentionDays")
        if normalized == 0 {
            defaults.removeObject(forKey: "HistoryService.lastAudioCleanupDate")
        } else {
            Task {
                await scheduleDailyAudioCleanup(force: true)
            }
        }
    }

    func purgeAllAudio() async {
        logger.notice("Purging all saved audio on user request.")
        guard let audioRootURL = audioFolderURL else {
            logger.warning("Audio folder URL is nil. Nothing to purge.")
            return
        }
        let capturedLogger = logger
        await Task.detached {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(at: audioRootURL,
                                                             includingPropertiesForKeys: nil,
                                                             options: .skipsHiddenFiles) else {
                capturedLogger.warning("Failed to enumerate audio folder while purging.")
                return
            }
            for url in contents {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    capturedLogger.warning("Failed to remove audio item \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }.value
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "HistoryService.lastAudioCleanupDate")
        capturedLogger.info("Audio purge completed.")
    }
}
