import Foundation

enum LastUpdatedText {
    static func format(_ lastUpdated: Date, relativeTo now: Date) -> String {
        // Un refresh puede terminar después de la fecha del tick actual.
        // Nunca describir una actualización ya realizada como futura.
        let seconds = max(0, Int(now.timeIntervalSince(lastUpdated)))
        let value: Int
        let unit: String
        switch seconds {
        case 0..<60:
            (value, unit) = (seconds, "segundo")
        case 60..<3_600:
            (value, unit) = (seconds / 60, "minuto")
        case 3_600..<86_400:
            (value, unit) = (seconds / 3_600, "hora")
        default:
            (value, unit) = (seconds / 86_400, "día")
        }
        return "Actualizado hace \(value) \(unit)\(value == 1 ? "" : "s")"
    }
}
