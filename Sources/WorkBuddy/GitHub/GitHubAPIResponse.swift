import Foundation

/// gh api --include retains response headers even when the command fails.
struct GitHubAPIResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(_ data: Data) throws {
        // gh mixes LF on the status line with CRLF at the end of headers.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        guard let separator = text.range(of: "\n\n") else { throw GH.Failure.badJSON("Missing HTTP headers") }
        let lines = text[..<separator.lowerBound].split(separator: "\n")
        guard let first = lines.first, first.hasPrefix("HTTP/"),
              let status = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            throw GH.Failure.badJSON("Missing HTTP status")
        }
        self.status = status
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        body = Data(text[separator.upperBound...].utf8)
    }
}

struct GitHubAPIError: LocalizedError {
    let response: GitHubAPIResponse
    let detail: String

    var errorDescription: String? { L10n.text(.errorGHCommand, String(response.status), detail) }

    var isRateLimited: Bool {
        let message = String(decoding: response.body, as: UTF8.self).lowercased()
        // 422 may indicate spam protection. Distinguish ordinary validation errors
        // from an explicit rejection for submitting too quickly.
        if response.status == 422 { return message.contains("was submitted too quickly") }
        guard response.status == 403 || response.status == 429 else { return false }
        return response.status == 429 || response.headers["retry-after"] != nil
            || response.headers["x-ratelimit-remaining"] == "0"
            || message.contains("rate limit") || message.contains("abuse detection")
    }

    func retryDelay(attempt: Int, now: Date) -> TimeInterval {
        // When both headers are present, honor the more restrictive wait.
        var delays: [TimeInterval] = []
        if let raw = response.headers["retry-after"], let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
            delays.append(seconds)
        }
        if response.headers["x-ratelimit-remaining"] == "0",
           let raw = response.headers["x-ratelimit-reset"], let reset = Double(raw), reset.isFinite {
            delays.append(max(0, reset - now.timeIntervalSince1970))
        }
        return max(1, delays.max() ?? (60 * pow(2, Double(attempt))))
    }
}
