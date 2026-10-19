import Foundation
import Testing

@testable import WorkBuddy

@Suite("Footer elapsed time")
struct LastUpdatedTextTests {
    @Test("Always show past time with correct units and plurals", arguments: [
        (-5.0, "Updated 0 seconds ago"),
        (0.0, "Updated 0 seconds ago"),
        (1.0, "Updated 1 second ago"),
        (59.9, "Updated 59 seconds ago"),
        (60.0, "Updated 1 minute ago"),
        (120.0, "Updated 2 minutes ago"),
        (3_600.0, "Updated 1 hour ago"),
        (7_200.0, "Updated 2 hours ago"),
        (86_400.0, "Updated 1 day ago"),
        (172_800.0, "Updated 2 days ago")
    ])
    func elapsedTime(seconds: Double, expected: String) {
        let lastUpdated = Date(timeIntervalSince1970: 1_000)
        #expect(LastUpdatedText.format(
            lastUpdated, relativeTo: lastUpdated.addingTimeInterval(seconds)
        ) == expected)
    }
}
