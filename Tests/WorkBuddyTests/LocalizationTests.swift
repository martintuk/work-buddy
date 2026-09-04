import Foundation
import Observation
import Testing
import os

@testable import WorkBuddy

struct LocalizationTests {
    @Test("Every catalog key has matching format arguments in both languages")
    func catalogCoverage() {
        for key in L10n.Key.allCases {
            let spanish = L10n.text(key, language: .spanish)
            let english = L10n.text(key, language: .english)
            #expect(!spanish.isEmpty)
            #expect(!english.isEmpty)
            #expect(spanish.components(separatedBy: "%@").count
                == english.components(separatedBy: "%@").count)
        }
    }

    @Test("Language preferences persist, fall back safely, and notify views only on change")
    @MainActor
    func persistenceAndObservation() throws {
        let suite = "work-buddy.localization-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppLanguage.load(defaults: defaults) == .spanish)
        defaults.set("unknown", forKey: AppLanguage.preferenceKey)
        #expect(AppLanguage.load(defaults: defaults) == .spanish)

        let localization = Localization(language: .spanish)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = localization.language
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        localization.setLanguage(.spanish, defaults: defaults)
        #expect(changes.withLock { $0 } == 0)
        localization.setLanguage(.english, defaults: defaults)
        #expect(changes.withLock { $0 } == 1)
        #expect(AppLanguage.load(defaults: defaults) == .english)
        #expect(Localization(language: AppLanguage.load(defaults: defaults)).language == .english)

        let message = LocalizedMessage(L10n.text(.settingsTitle, language: localization.language))
        #expect(message.text == "Settings")
        localization.setLanguage(.spanish, defaults: defaults)
        #expect(message.text == "Configuración")
    }

    @Test("Interpolated content is preserved, including percent signs and Unicode")
    func interpolation() {
        #expect(L10n.text(.confirmAction, "Merge", "café-100%", "42", language: .english)
            == "Merge café-100% #42?")
        #expect(L10n.text(.prBehindOne, "1", "main", language: .spanish)
            == "1 commit atrás de main")
        #expect(L10n.text(.prBehindMany, "2", "main", language: .english)
            == "2 commits behind main")
    }

    @Test("English relative time handles all unit boundaries", arguments: [
        (-5.0, "Updated 0 seconds ago"),
        (1.0, "Updated 1 second ago"),
        (59.0, "Updated 59 seconds ago"),
        (60.0, "Updated 1 minute ago"),
        (120.0, "Updated 2 minutes ago"),
        (3_600.0, "Updated 1 hour ago"),
        (7_200.0, "Updated 2 hours ago"),
        (86_400.0, "Updated 1 day ago"),
        (172_800.0, "Updated 2 days ago")
    ])
    func relativeTime(seconds: Double, expected: String) {
        let date = Date(timeIntervalSince1970: 1_000)
        #expect(LastUpdatedText.format(date, relativeTo: date.addingTimeInterval(seconds),
                                       language: .english) == expected)
    }
}
