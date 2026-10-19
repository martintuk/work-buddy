import Testing

@testable import WorkBuddy

struct QueueSectionItemTests {
    private struct PR: Identifiable {
        let id: String
        let ready: Bool
    }

    @Test("Promoting a PR changes row identity without changing resource identity")
    func promotion() {
        let review = QueueSectionItem(section: "needsReview", item: PR(id: "PR_239", ready: false))
        let merge = QueueSectionItem(section: "readyToMerge", item: PR(id: "PR_239", ready: true))
        #expect(review.item.id == merge.item.id)
        #expect(review.id != merge.id)
    }

    @Test("Updating data within a category preserves row identity")
    func refresh() {
        let before = QueueSectionItem(section: "automation", item: PR(id: "PR_239", ready: false))
        let after = QueueSectionItem(section: "automation", item: PR(id: "PR_239", ready: true))
        #expect(before.id == after.id)
    }

    @Test("A PR can coexist in merge, fix, and replies without collisions")
    func simultaneousCategories() {
        let items = ["readyToMerge", "needingCIFix", "needingReply"].flatMap { section in
            ["PR_239", "PR_240"].map { id in
                QueueSectionItem(section: section, item: PR(id: id, ready: true))
            }
        }
        #expect(Set(items.map(\.id)).count == 6)
    }
}
