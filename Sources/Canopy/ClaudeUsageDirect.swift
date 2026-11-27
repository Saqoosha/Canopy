import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ClaudeUsageDirect")

/// A GET of `/api/oauth/usage` with the Claude Code credential, so the
/// sidebar's usage bars exist before any session does.
///
/// Every other writer of `SharedRateLimitData` is a `ShimProcess`: the request
/// goes out two seconds after `launch_claude` and the raw `get_usage` half
/// needs a `channelId`, i.e. a running CLI. So a launch that opens on the
/// launcher — no pane, no shim — showed the account email with no bars under
/// it until the first session had been up for two seconds.
///
/// The path is the one the CLI's own `fetchUtilization` hits (its log prefix
/// in 2.1.258; the literal `/api/oauth/usage` sits beside it), with the same
/// bearer `AnthropicDirect` sends. Measured: 200 with or without the
/// `anthropic-beta` header; sent anyway to match the sibling call.
///
/// **No token refresh.** The CLI refreshes an expired token on a 401 and
/// writes it back to the Keychain; this call logs the 401 and leaves the bars
/// to the first shim's request, which `refreshLocalAccount` never blocks.
enum ClaudeUsageDirect {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Attempts, not retries: three tries, two gaps. Bounded because every
    /// attempt spends the budget that answered 429.
    static let maxAttempts = 3
    /// Half the ~60 s budget interval, so an attempt can land between another
    /// client's polls. Not tuned beyond that.
    static let retryDelay: Duration = .seconds(30)

    /// Fetch and apply to this Mac's account.
    ///
    /// The account's throttle is started AFTER a successful apply, never
    /// before the request: a shim opened inside the interval then skips its
    /// own request only when the numbers are already on screen. Starting it
    /// first was the first revision, and a failed fetch — expired token,
    /// offline — then cost the first shim its 2 s request as well, leaving no
    /// bars until the first turn.
    ///
    /// Only a 429 is retried. The endpoint's budget is per ACCOUNT, roughly one
    /// request a minute — measured 2026-09-11 beside the installed Canopy's
    /// sessions: a direct call one second after theirs succeeded got 429
    /// (`Retry-After: 0`), whatever the User-Agent, and 200 only in a minute
    /// they skipped. The CLI never retries a 429 (its wrapper retries a 401
    /// once, after a token refresh) because its poller comes back next
    /// minute; this call has no next minute.
    /// Returns a one-line failure reason, or nil when it applied or skipped.
    @MainActor @discardableResult
    static func refreshLocalAccount(skipIfAppliedWithin: TimeInterval? = nil) async -> String? {
        await refresh(SharedRateLimitData.shared.local, keychainService: KeychainAuth.defaultService, label: "usage",
                      skipIfAppliedWithin: skipIfAppliedWithin)
            .map { "default login: \($0)" }
    }

    /// How often the GUI refetches while no session is asking. Five minutes,
    /// not one: the endpoint allows about one request a minute per account,
    /// and the CLI's own pollers spend that same budget, so a one-minute timer
    /// would collide with them and mostly collect 429s.
    static let idleRefreshInterval: TimeInterval = 5 * 60
    /// The timer skips an account whose numbers arrived within this window. Shorter
    /// than the period, because the timer's own fetch stamps the time only when it
    /// finishes: with equal values every other tick was skipped (10 min cadence).
    static let idleSkipWindow: TimeInterval = idleRefreshInterval / 2
    /// The manual button skips an account updated within the endpoint's ~1/min
    /// budget: those numbers are current, and a fetch would 429.
    static let manualSkipWindow: TimeInterval = 60
    static let requestTimeout: TimeInterval = 10

    /// Fetch every other login's usage too, so a new session can be started
    /// on one with quota left before any session has run on it
    /// (`ClaudeAccountPicker`). One at a time: each has its own budget, but
    /// there is no hurry. A login whose `.claude.json` names the same account
    /// as the default login is already covered by `refreshLocalAccount`.
    /// Returns one failure reason per login that failed.
    @MainActor @discardableResult
    static func refreshOtherAccounts(skipIfAppliedWithin: TimeInterval? = nil) async -> [String] {
        var failures: [String] = []
        let registry = SharedRateLimitData.shared
        let localEmail = ClaudeAccountInfo.current()?.email
        let accounts = ClaudeAccountStore.load()
        logger.notice("[direct] usage: \(accounts.count, privacy: .public) other login(s) to fetch")
        for account in accounts {
            let dir = account.configURL
            let email = await Task.detached { ClaudeAccountInfo.inConfigDir(dir)?.email }.value
            let key = ShimProcess.rateLimitKey(remoteEmail: email, localEmail: localEmail, host: dir.path)
            guard key != nil else {
                logger.notice("[direct] usage[\(account.name, privacy: .public)]: same account as the default login; skipped")
                continue
            }
            registry.noteResolved(host: dir.path, key: key)
            if let failure = await refresh(registry.account(for: key), keychainService: account.keychainService,
                                           label: "usage[\(account.name)]", skipIfAppliedWithin: skipIfAppliedWithin) {
                failures.append("\(account.name): \(failure)")
            }
        }
        return failures
    }

    @MainActor
    private static func refresh(_ account: RateLimitAccount, keychainService: String, label: String,
                                skipIfAppliedWithin: TimeInterval? = nil) async -> String? {
        // A shim or an earlier fetch already has fresh numbers on screen.
        if shouldSkip(account, window: skipIfAppliedWithin) { return nil }
        // Another caller (launch, timer, button) is already fetching this account; a second request would 429.
        let id = ObjectIdentifier(account)
        guard inFlight.insert(id).inserted else { return nil }
        defer { inFlight.remove(id) }
        for attempt in 1 ... maxAttempts {
            do {
                let rateLimits = try await fetchRateLimits(keychainService: keychainService)
                account.updateFromRawUsage(rateLimits)
                account.noteUsageRequested()
                logger.notice("[direct] \(label, privacy: .public): applied (attempt \(attempt, privacy: .public))")
                return nil
            } catch {
                guard shouldRetry(after: error, attempt: attempt) else {
                    AnthropicDirect.log(error, label: label)
                    return failureSummary(error)
                }
                logger.notice("[direct] \(label, privacy: .public): HTTP 429, retrying in \(retryDelay.components.seconds, privacy: .public) s")
                try? await Task.sleep(for: retryDelay)
            }
        }
        return "HTTP 429"  // unreachable: the last attempt's 429 returns above
    }

    @MainActor private static var inFlight: Set<ObjectIdentifier> = []

    /// The skip decision `refresh` makes: numbers that arrived within the window, not a request sent.
    @MainActor
    static func shouldSkip(_ account: RateLimitAccount, window: TimeInterval?) -> Bool {
        guard let window else { return false }
        return account.appliedWithin(window)
    }

    /// Short reason for the refresh button's tooltip; no response body.
    static func failureSummary(_ error: Error) -> String {
        switch error {
        case AnthropicDirect.Failure.noCredential: return "no credential"
        case let AnthropicDirect.Failure.http(status, _): return "HTTP \(status)"
        case AnthropicDirect.Failure.malformedResponse: return "malformed response"
        default: return error.localizedDescription
        }
    }

    /// The retry decision, kept pure so the probe can pin it: a 429 with an
    /// attempt left, nothing else.
    static func shouldRetry(after error: Error, attempt: Int) -> Bool {
        guard case AnthropicDirect.Failure.http(status: 429, body: _) = error else { return false }
        return attempt < maxAttempts
    }

    /// The raw response reshaped into what `RateLimitAccount.updateFromRawUsage`
    /// consumes — the shape the CLI hands back as
    /// `get_usage_response.usage.rate_limits`.
    static func fetchRateLimits(keychainService: String = KeychainAuth.defaultService,
                                timeout: TimeInterval = requestTimeout) async throws -> [String: Any] {
        guard let token = KeychainAuth.readAccessToken(service: keychainService) else {
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

    /// The CLI's projection: the raw object as-is, plus `model_scoped` from the
    /// `limits[]` entries of kind `weekly_scoped` that name a model.
    ///
    /// Not mirrored: the CLI's allowlist over those names (a GrowthBook flag
    /// this side cannot read; with it empty the CLI shows none of these rows
    /// and this side shows all of them), and its numeric→ISO `resets_at`
    /// conversion (a numeric value lands as no reset date). A shim's later
    /// `get_usage` replaces these rows only when the CLI's filtered list is
    /// non-empty; an absent key keeps them, until their reset date.
    ///
    /// `model_scoped` is added only when non-empty, as the CLI does — an empty
    /// array means "server says none" to `updateFromRawUsage` and clears rows,
    /// while absence keeps previous.
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
