import Testing
import Foundation
@testable import HandsOffLLM

struct HistoryServiceGroupingTests {

    @Test @MainActor func groupIndexByDateCorrectness() async {
        let history = HistoryService()

        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let lastWeek = Calendar.current.date(byAdding: .day, value: -5, to: now)!

        history.indexEntries = [
            ConversationIndexEntry(id: UUID(), title: "Today 1", createdAt: now, updatedAt: now),
            ConversationIndexEntry(id: UUID(), title: "Yesterday 1", createdAt: yesterday, updatedAt: yesterday),
            ConversationIndexEntry(id: UUID(), title: "Last Week 1", createdAt: lastWeek, updatedAt: lastWeek)
        ].sorted { $0.lastActivityDate > $1.lastActivityDate }

        let groups = history.groupIndexByDate()

        #expect(groups.count == 3)
        #expect(groups[0].0 == "Today")
        #expect(groups[1].0 == "Yesterday")
        #expect(groups[2].0 == "Last Week")
    }

    @Test @MainActor func groupIndexByDateFallsBackToMonthYearForOlderEntries() async {
        let history = HistoryService()
        let now = Date()
        let older = Calendar.current.date(byAdding: .day, value: -40, to: now)!

        history.indexEntries = [
            ConversationIndexEntry(id: UUID(), title: "Old", createdAt: older, updatedAt: older)
        ]

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let expected = formatter.string(from: older)

        let groups = history.groupIndexByDate()
        #expect(groups.count == 1)
        #expect(groups[0].0 == expected)
    }
}
