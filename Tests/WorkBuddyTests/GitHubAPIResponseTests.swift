import Foundation
import Testing
@testable import WorkBuddy

@Suite("Headers y rate limits de GitHub")
struct GitHubAPIResponseTests {
    @Test("Lee el formato mixto LF/CRLF de gh y conserva el JSON sin headers")
    func headers() throws {
        let response = try GitHubAPIResponse(Data("HTTP/2.0 201 Created\nContent-Type: application/json\r\nX-RateLimit-Remaining: 42\r\n\r\n{\"id\":1}".utf8))
        #expect(response.status == 201)
        #expect(response.headers["x-ratelimit-remaining"] == "42")
        #expect(response.body == Data(#"{"id":1}"#.utf8))
    }

    @Test("403 de permisos no se confunde con 403 de rate limit")
    func forbidden() throws {
        #expect(try !failure(403, message: "Resource not accessible by integration").isRateLimited)
        #expect(try failure(403, message: "You have exceeded a secondary rate limit").isRateLimited)
        #expect(try failure(403, headers: "Retry-After: 20").isRateLimited)
        #expect(try failure(403, headers: "X-RateLimit-Remaining: 0").isRateLimited)
        #expect(try failure(429).isRateLimited)
        #expect(try !failure(422, message: "rate limit").isRateLimited)
    }

    @Test("Sólo reintenta 422 si el mensaje indica una acción enviada demasiado rápido")
    func submittedTooQuickly() throws {
        let json = #"{"message":"Validation Failed","errors":[{"resource":"PullRequestReview","code":"custom","message":"was submitted too quickly"}]}"#
        let response = try GitHubAPIResponse(Data("HTTP/2.0 422 Unprocessable Entity\n\n\(json)".utf8))
        #expect(GitHubAPIError(response: response, detail: "Validation Failed").isRateLimited)
        #expect(try !failure(422, message: "Validation Failed").isRateLimited)
        #expect(try !failure(422, message: "commit_id is invalid").isRateLimited)
    }

    @Test("Respeta Retry-After y reset; sin headers usa 60, 120 y 240 segundos")
    func delays() throws {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(try failure(429, headers: "Retry-After: 7").retryDelay(attempt: 0, now: now) == 7)
        #expect(try failure(403, headers: "X-RateLimit-Remaining: 0\nX-RateLimit-Reset: 1050").retryDelay(attempt: 0, now: now) == 50)
        #expect(try failure(403, headers: "Retry-After: 7\nX-RateLimit-Remaining: 0\nX-RateLimit-Reset: 1050").retryDelay(attempt: 0, now: now) == 50)
        for attempt in 0..<3 {
            #expect(try failure(429).retryDelay(attempt: attempt, now: now) == Double(60 << attempt))
        }
        for invalid in ["invalid", "-5", "nan", "inf"] {
            #expect(try failure(429, headers: "Retry-After: \(invalid)").retryDelay(attempt: 0, now: now) == 60)
        }
    }

    private func failure(_ status: Int, headers: String = "", message: String = "rejected") throws -> GitHubAPIError {
        let response = try GitHubAPIResponse(Data("HTTP/2.0 \(status) Error\n\(headers)\n\n{\"message\":\"\(message)\"}".utf8))
        return GitHubAPIError(response: response, detail: message)
    }
}
