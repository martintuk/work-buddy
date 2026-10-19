import Foundation
import Testing

@testable import WorkBuddy

struct LocalizationTests {
    @Test("Every interface key has English text and valid string placeholders")
    func catalogCoverage() {
        for key in L10n.Key.allCases {
            let template = L10n.text(key)
            #expect(!template.isEmpty)
            let withoutPlaceholders = template.replacingOccurrences(of: "%@", with: "")
                .replacingOccurrences(of: "%%", with: "")
            #expect(!withoutPlaceholders.contains("%"))
        }
    }

    @Test("Interpolated content preserves percent signs and Unicode")
    func interpolation() {
        #expect(L10n.text(.confirmAction, "Merge", "rocket-🚀-100%", "42")
            == "Merge rocket-🚀-100% #42?")
        #expect(L10n.text(.prBehindOne, "1", "main") == "1 commit behind main")
        #expect(L10n.text(.prBehindMany, "2", "main") == "2 commits behind main")
    }

    @Test("Saved messages read the English field from older multilingual history")
    func legacyHistory() throws {
        let data = Data(#"{"spanish":"legacy translation","english":"Could not open the link"}"#.utf8)
        let message = try JSONDecoder().decode(LocalizedMessage.self, from: data)
        #expect(message.text == "Could not open the link")
        let saved = try JSONEncoder().encode(message)
        let fields = try #require(JSONSerialization.jsonObject(with: saved) as? [String: String])
        #expect(fields == ["english": "Could not open the link"])
        #expect(try JSONDecoder().decode(LocalizedMessage.self, from: saved).text == message.text)
    }
}
