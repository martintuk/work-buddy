/// Retains the source expression so an already-visible error or action result
/// follows language changes instead of keeping its original translation.
struct LocalizedMessage: Codable {
    private let render: () -> String

    init(_ text: @autoclosure @escaping () -> String) {
        render = text
    }

    var text: String { render() }

    // English-only history from earlier builds remains readable in either language.
    private struct Translations: Codable {
        let spanish: String?
        let english: String
    }

    func encode(to encoder: any Encoder) throws {
        let translations = Translations(
            spanish: L10n.$renderLanguage.withValue(.spanish) { render() },
            english: L10n.$renderLanguage.withValue(.english) { render() })
        try translations.encode(to: encoder)
    }

    init(from decoder: any Decoder) throws {
        let translations = try Translations(from: decoder)
        render = {
            (L10n.renderLanguage ?? Localization.shared.language) == .spanish
                ? (translations.spanish ?? translations.english) : translations.english
        }
    }
}
