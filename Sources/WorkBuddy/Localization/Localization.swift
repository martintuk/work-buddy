import Foundation

/// Shared English interface strings and formatting.
enum L10n {
    static let locale = Locale(identifier: "en_US")

    static func text(_ key: Key, _ arguments: String...) -> String {
        let template = english(key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: arguments)
    }
}
