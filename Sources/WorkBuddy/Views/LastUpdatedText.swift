import Foundation

enum LastUpdatedText {
    static func format(
        _ lastUpdated: Date, relativeTo now: Date
    ) -> String {
        // A refresh can finish after the current tick; never describe it as future.
        let seconds = max(0, Int(now.timeIntervalSince(lastUpdated)))
        let value: Int
        let singular: L10n.Key
        let plural: L10n.Key
        switch seconds {
        case 0..<60:
            (value, singular, plural) = (seconds, .updatedSecondsOne, .updatedSecondsMany)
        case 60..<3_600:
            (value, singular, plural) = (seconds / 60, .updatedMinutesOne, .updatedMinutesMany)
        case 3_600..<86_400:
            (value, singular, plural) = (seconds / 3_600, .updatedHoursOne, .updatedHoursMany)
        default:
            (value, singular, plural) = (seconds / 86_400, .updatedDaysOne, .updatedDaysMany)
        }
        return L10n.text(value == 1 ? singular : plural, String(value))
    }
}
