import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "AnthropicDirect")

/// One non-streaming `/v1/messages` call, using the Claude Code credential
/// Canopy already reads from the Keychain.
///
/// **This exists because the CLI costs 7-8x the latency of the API for the
/// same answer.** Measured three times each on the same prompt and model:
/// `claude -p` took 6.93 / 7.15 / 8.50 s, this path took **0.97 s**. None of
/// that gap is process spawn — `claude --version` returns in 0.04 s — so it is
/// the CLI's own initialisation plus its round trip, and nothing on this side
/// can shorten it. For a call the user is watching a spinner through, that is
/// the whole difference between "instant" and "why is this slow".
///
/// **The credential is scoped for exactly this.** The Keychain blob's OAuth
/// scopes include `user:inference`, alongside `user:profile`,
/// `user:sessions:claude_code` and others — so a plain inference request is
/// the sanctioned use of the token, not a way around the CLI. The
/// `anthropic-beta: oauth-2025-04-20` header is what makes the OAuth bearer
/// acceptable where an API key would normally go; measured, and the request is
/// rejected without it.
///
/// Deliberately narrow: no streaming, no tools, no conversation. Anything that
/// needs those belongs in a real session, and anything that merely needs a
/// sentence back should not be paying for a CLI boot.
enum AnthropicDirect {
    /// Cheapest tier that can do the short shaping jobs this is for.
    ///
    /// Pinned to a dated id rather than the `haiku` alias: the alias is a CLI
    /// concept, and the API wants a model id.
    static let haikuModel = "claude-haiku-4-5-20251001"

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    enum Failure: Error {
        /// No Claude Code credential — the user has never logged in, or the
        /// Keychain item is unreadable. Callers fall back to the CLI, which
        /// fails the same way but with its own diagnostics.
        case noCredential
        case http(status: Int, body: String)
        case malformedResponse
    }

    /// Send one system + user pair and return the assistant's text.
    ///
    /// Throws rather than returning nil so a caller can tell "no credential"
    /// (fall back to the CLI, which may have one this cannot see) from "the
    /// API said no" (falling back will fail the same way, slower).
    static func message(
        system: String,
        user: String,
        model: String = haikuModel,
        maxTokens: Int = 64,
        timeout: TimeInterval = 20
    ) async throws -> String {
        // Token only: this request never names an organization, so requiring
        // one would disable the fast path on any blob that lacks the field.
        guard let token = KeychainAuth.readAccessToken() else {
            throw Failure.noCredential
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        // Never logged, never surfaced: the token is written into the request
        // and nowhere else.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            // Bounded, and `.private` at the log site. The first version of
            // this comment claimed the body "carries no user content — the
            // request that produced it is not echoed back", which was asserted
            // rather than measured: a validation error can name the offending
            // field, and the `user` field here IS the user's verbatim prompt.
            // Over-redacting a diagnostic is the safe direction.
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            throw Failure.http(status: http.statusCode, body: body)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = object["content"] as? [[String: Any]]
        else { throw Failure.malformedResponse }
        // Concatenated rather than taking the first block: a response can be
        // split across several text blocks, and taking [0] would silently
        // truncate one.
        let text = blocks
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined()
        guard !text.isEmpty else { throw Failure.malformedResponse }
        return text
    }

    /// Log a failure at the level its cause deserves.
    ///
    /// `noCredential` is `debug`, and the reason is narrower than it looks:
    /// it fires at most once per naming or titling attempt, and the CLI
    /// fallback that follows reports a missing login properly. (An earlier
    /// version of this justified the level by a per-keystroke prefetch — that
    /// mechanism was deleted in the same change, so do not restore the level
    /// on that argument.) Everything else is
    /// `notice`, because it means the fast path is silently off and the only
    /// symptom is that things got slow again.
    static func log(_ error: Error, label: String) {
        switch error {
        case Failure.noCredential:
            logger.debug("[direct] \(label, privacy: .public): no Claude Code credential")
        case let Failure.http(status, body):
            logger.notice("[direct] \(label, privacy: .public): HTTP \(status, privacy: .public): \(body, privacy: .private)")
        default:
            logger.notice("[direct] \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
