/// Retains a message expression and persists its English text for activity history.
struct LocalizedMessage: Codable {
    private let render: () -> String

    init(_ text: @autoclosure @escaping () -> String) {
        render = text
    }

    var text: String { render() }

    // Earlier history files contain additional translations. Decoding only the
    // English field keeps those files readable without retaining other catalogs.
    private struct StoredText: Codable {
        let english: String
    }

    func encode(to encoder: any Encoder) throws {
        try StoredText(english: render()).encode(to: encoder)
    }

    init(from decoder: any Decoder) throws {
        let stored = try StoredText(from: decoder)
        render = { stored.english }
    }
}
