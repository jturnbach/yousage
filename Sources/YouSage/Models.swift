import Foundation

struct UsageSnapshot: Sendable, Equatable {
    var fetchedAt: Date
    var sections: [UsageSection]
    var rawJSON: String
}

struct UsageSection: Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let kind: Kind
    let infoNote: String?

    enum Kind: String, Sendable, Equatable {
        case session
        case weekly
    }
}

enum MenuBarMetric: String, CaseIterable, Sendable, Identifiable {
    case highest
    case session
    case weekly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highest: return "Highest of all limits"
        case .session: return "Current session (5 hr)"
        case .weekly:  return "Weekly · All models"
        }
    }
}

enum ClaudeError: Error, Sendable {
    case missingSessionKey
    case http(status: Int, body: String)
    case decoding(String)
    case noOrg
    case network(String)

    var userMessage: String {
        switch self {
        case .missingSessionKey:
            return "Add your sessionKey in Settings."
        case .http(let code, _):
            switch code {
            case 401, 403: return "Session expired — paste a fresh sessionKey."
            case 429: return "Rate limited. Backing off…"
            case 500..<600: return "Claude.ai server error (\(code)). Will retry."
            default: return "HTTP \(code) from claude.ai"
            }
        case .decoding(let s):
            return "Unexpected response shape: \(s)"
        case .noOrg:
            return "No organization found on this account."
        case .network(let s):
            return "Network error: \(s)"
        }
    }
}
