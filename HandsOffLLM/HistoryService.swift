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
    @Published var conversations: [Conversation] = []

    private let persistenceFileName = "conversations.json"
    private var persistenceURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(persistenceFileName)
    }

    init() {
        loadConversations()
        logger.info("HistoryService initialized. Loaded \(self.conversations.count) conversations.")
    }

    // MARK: - Persistence
    private func loadConversations() {
        guard let url = persistenceURL else {
            logger.error("Could not get persistence URL.")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("No history file found at \(url.path). Starting fresh.")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            // Handle potential date decoding issues if format changes
            decoder.dateDecodingStrategy = .iso8601 // Or .secondsSince1970 etc. depending on how you save
            conversations = try decoder.decode([Conversation].self, from: data)
            // Sort by date descending after loading
            conversations.sort { $0.createdAt > $1.createdAt }
        } catch {
            logger.error("Failed to load or decode conversations: \(error.localizedDescription)")
            // Handle error, maybe backup old file and start fresh?
            conversations = []
        }
    }

    private func saveConversations() {
        guard let url = persistenceURL else {
            logger.error("Could not get persistence URL for saving.")
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted // For readability
            encoder.dateEncodingStrategy = .iso8601 // Match decoding strategy
            let data = try encoder.encode(conversations)
            try data.write(to: url, options: [.atomicWrite])
            logger.info("Successfully saved \(self.conversations.count) conversations.")
        } catch {
            logger.error("Failed to encode or save conversations: \(error.localizedDescription)")
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
        saveConversations()
    }

    func deleteConversation(at offsets: IndexSet) {
        conversations.remove(atOffsets: offsets)
        saveConversations()
        logger.info("Deleted conversations at offsets \(offsets).")
    }

    func deleteConversation(id: UUID) {
        conversations.removeAll { $0.id == id }
        saveConversations()
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
}

