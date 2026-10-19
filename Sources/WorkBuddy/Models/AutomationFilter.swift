import Foundation

/// Filter by author independently of the PR's displayed section.
enum AutomationFilter: String, CaseIterable {
    case all
    case excludingAutomation
    case onlyAutomation

    private static let key = "github.automationFilter"

    var isActive: Bool { self != .all }

    var title: String {
        switch self {
        case .all: L10n.text(.automationFilterAll)
        case .excludingAutomation: L10n.text(.automationFilterHide)
        case .onlyAutomation: L10n.text(.automationFilterOnly)
        }
    }

    func includes(_ pullRequest: PullRequest) -> Bool {
        switch self {
        case .all: true
        case .excludingAutomation: !pullRequest.author.isBot
        case .onlyAutomation: pullRequest.author.isBot
        }
    }

    func apply(to pullRequests: [PullRequest]) -> [PullRequest] {
        pullRequests.filter { includes($0) }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .all
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key)
    }
}
