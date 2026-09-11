import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ClaudeUsageDirect")

/// One GET of `/api/oauth/usage` with the Claude Code credential, so the
/// sidebar's usage bars exist before any session does.
///
/// Every other writer of `SharedRateLimitData` is a `ShimProcess`: the request
/// goes out two seconds after `launch_claude` and the raw `get_usage` half
/// needs a `channelId`, i.e. a running CLI. So a launch that opens on the
/// launcher — no pane, no shim — showed the account email and nothing under
/// it until the first session had been up for two seconds. Nothing failed;
/// nobody had asked.
///
/// The endpoint is the one the CLI's own `fetchUtilization` hits (read out of
/// 2.1.258: `St.get("/api/oauth/usage", …)` against `api.anthropic.com`), and
/// the same bearer that `AnthropicDirect` sends. Measured: 200 with or without
/// the `anthropic-beta` header; it is sent anyway to match the sibling call.
///
/// **This does not refresh an expired token.** The CLI does (`refreshOAuth`
/// on a 401), and writes the new blob back to the Keychain. A 401 here logs at
/// `notice` and leaves the bars absent until a shim's request lands — the same
/// outcome as before this call existed, so the failure is strictly the old
/// behaviour rather than a new one.
enum ClaudeUsageDirect {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// How many times a 429 is retried, and how far apart. Bounded because
    /// every attempt spends the very budget that answered 429.
    static let maxAttempts = 3
    static let retryDelay: Duration = .seconds(30)

    /// Fetch and apply to this Mac's account. Silent success; every failure
    /// logs once.
    ///
    /// `shouldRequestUpdate()` is consumed on purpose, and BEFORE the request:
    /// the throttle's job is "one request per account per interval", and this
    /// is one. A shim opened inside that interval then skips its own — which
    /// is fine, the numbers it would fetch are already on screen.
    ///
    /// **A 429 is retried, and only a 429.** The endpoint's budget is per
    /// ACCOUNT, not per process — measured 2026-09-11 with the installed
    /// Canopy polling once a minute through its shims: a direct call one
    /// second after one of those succeeded got 429 (`Retry-After: 0`), and
    /// the same call 41 s later got 200. The CLI's own poller does not retry
    /// (`I_` handles 401 only) because it comes back a minute later anyway;
    /// this call has no next minute, so it takes a few. Another Mac on the
    /// same account is the ordinary way to hit this at a fresh launch.
    @MainActor
    static func refreshLocalAccount() async {
        let account = SharedRateLimitData.shared.local
        guard account.shouldRequestUpdate() else { return }
        for attempt in 1 ... maxAttempts {
            do {
                let rateLimits = try await fetchRateLimits()
                account.updateFromRawUsage(rateLimits)
                logger.notice("[direct] usage: applied (attempt \(attempt, privacy: .public))")
                return
            } catch AnthropicDirect.Failure.http(status: 429, body: _) where attempt < maxAttempts {
                logger.notice("[direct] usage: HTTP 429, retrying in \(retryDelay.components.seconds, privacy: .public) s")
                try? await Task.sleep(for: retryDelay)
            } catch {
                AnthropicDirect.log(error, label: "usage")
                return
            }
        }
    }

    /// The raw response reshaped into what `RateLimitAccount.updateFromRawUsage`
    /// consumes — the same shape the CLI hands back as
    /// `get_usage_response.usage.rate_limits`.
    static func fetchRateLimits(timeout: TimeInterval = 10) async throws -> [String: Any] {
        guard let token = KeychainAuth.readAccessToken() else {
            throw AnthropicDirect.Failure.noCredential
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnthropicDirect.Failure.malformedResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            throw AnthropicDirect.Failure.http(status: http.statusCode, body: body)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicDirect.Failure.malformedResponse
        }
        return rateLimits(fromRawUsage: object)
    }

    /// Mirror the CLI's projection: the raw object as-is, plus `model_scoped`
    /// built from the `limits[]` entries of kind `weekly_scoped` that name a
    /// model.
    ///
    /// The CLI additionally filters those by a remote allowlist
    /// (`tengu_usage_overage_included_models`, a GrowthBook flag) that this
    /// side cannot read, so this may show a per-model row the CLI would drop.
    /// The first shim's `get_usage` then overwrites `model_scoped` with the
    /// filtered list, so the widest such difference lasts until the first
    /// session's request lands. Measured 2026-09-11: the server emitted one
    /// scoped bucket ("Fable"), which the CLI also shows.
    ///
    /// `model_scoped` is only added when non-empty, as the CLI does — an empty
    /// array means "server says none" to `updateFromRawUsage` and would clear
    /// rows, while absence means "keep previous".
    static func rateLimits(fromRawUsage raw: [String: Any]) -> [String: Any] {
        var result = raw
        let scoped: [[String: Any]] = ((raw["limits"] as? [[String: Any]]) ?? []).compactMap { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty
            else { return nil }
            return [
                "display_name": name,
                "utilization": limit["percent"] ?? NSNull(),
                "resets_at": limit["resets_at"] ?? NSNull(),
            ]
        }
        if !scoped.isEmpty {
            result["model_scoped"] = scoped
        }
        return result
    }
}
