import Foundation
import Observation
import os

enum AppLanguage: String, CaseIterable, Sendable {
    case spanish = "es"
    case english = "en"

    static let preferenceKey = "appearance.language"

    // Keep the existing language for installations with no explicit preference.
    static func load(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .spanish
    }

    var nativeName: String {
        switch self {
        case .spanish: "Español"
        case .english: "English"
        }
    }
}

/// SwiftUI observes reads made by L10n.text, including reads in child views.
/// Only language changes invalidate those views. Background errors and notifications
/// share the same cached selection; no defaults reads or file I/O during rendering.
@Observable
final class Localization: Sendable {
    static let shared = Localization()
    private let selection: OSAllocatedUnfairLock<AppLanguage>

    init(language: AppLanguage = AppLanguage.load()) {
        selection = OSAllocatedUnfairLock(initialState: language)
    }

    var language: AppLanguage {
        access(keyPath: \.language)
        return selection.withLock { $0 }
    }

    @MainActor
    func setLanguage(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        guard self.language != language else { return }
        withMutation(keyPath: \.language) {
            selection.withLock { $0 = language }
            defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        }
    }
}

enum L10n {
    static func text(_ key: Key, _ arguments: String..., language: AppLanguage? = nil) -> String {
        let selected = language ?? Localization.shared.language
        let template = selected == .spanish ? spanish(key) : english(key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: Locale(identifier: selected.rawValue), arguments: arguments)
    }
}
