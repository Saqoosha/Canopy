import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RemoteSessionsAPI")

/// Three buckets we care about when surfacing /v1/sessions to the user:
/// - `web`: ran on Anthropic's Cloud Compute Resource (env_id set, cwd empty).
///   These are the actual "remote sessions" the user wants to teleport down.
/// - `local`: ran here (Canopy/CLI), metadata uploaded to the cloud
///   (env_id empty, cwd populated). Already present locally — teleport rarely useful.
/// - `bridge`: neither env_id nor cwd populated. Likely remote-control bridges
///   (CLI bridged to claude.ai/code/<id>) or never-started sessions.
enum RemoteSessionKind: String, CaseIterable, Sendable, Hashable {
    case web
    case local
    case bridge

    var displayName: String {
        switch self {
        case .web: "Web"
        case .local: "Local synced"
        case .bridge: "Bridged"
        }
    }
}

enum RemoteSessionsAPIError: Error, LocalizedError {
    case noOAuthToken
    case requestFailed(String)
    case httpStatus(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .noOAuthToken: "Not signed in. Log in via Claude.ai (OAuth) first."
        case .requestFailed(let m): "Request failed: \(m)"
        case .httpStatus(let s, let m): "HTTP \(s): \(m)"
        case .decode(let m): "Failed to decode response: \(m)"
        }
    }
}

/// Calls the Anthropic /v1/sessions API directly using the OAuth token from
/// macOS Keychain. Returns the full session list with classification — the
/// extension's own `list_remote_sessions` strips most fields, so we go around it.
enum RemoteSessionsAPI {
    private static let baseURL = "https://api.anthropic.com"
    private static let anthropicVersion = "2023-06-01"
    private static let anthropicBeta = "ccr-byoc-2025-07-29"

    /// Fetch all sessions on the current OAuth account (no repo filter).
    static func listAll() async throws -> [RemoteSession] {
        guard let creds = KeychainAuth.readAccessTokenAndOrg() else {
            throw RemoteSessionsAPIError.noOAuthToken
        }
        let url = URL(string: "\(baseURL)/v1/sessions")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.orgUUID, forHTTPHeaderField: "x-organization-uuid")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RemoteSessionsAPIError.requestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RemoteSessionsAPIError.requestFailed("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface only the API's own error.message when present; raw bodies
            // can include request-id / org headers we don't want in the UI.
            var detail = "HTTP \(http.statusCode)"
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = parsed["error"] as? [String: Any],
               let msg = err["message"] as? String {
                detail = msg
            }
            throw RemoteSessionsAPIError.httpStatus(http.statusCode, detail)
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RemoteSessionsAPIError.decode("response is not a dictionary")
            }
            json = parsed
        } catch {
            throw RemoteSessionsAPIError.decode(error.localizedDescription)
        }

        let raw = (json["data"] as? [[String: Any]]) ?? []
        let parsed = raw.compactMap(parseSession(_:))
        logger.info("Fetched \(parsed.count) session(s) (raw=\(raw.count))")
        return parsed
    }

    private static func parseSession(_ raw: [String: Any]) -> RemoteSession? {
        guard let id = raw["id"] as? String else { return nil }

        let title = (raw["title"] as? String) ?? "Untitled"
        let updatedAt = (raw["updated_at"] as? String) ?? ""
        let lastModified = parseISO8601(updatedAt) ?? Date(timeIntervalSince1970: 0)
        let status = (raw["session_status"] as? String) ?? "idle"

        let context = (raw["session_context"] as? [String: Any]) ?? [:]
        let cwd = (context["cwd"] as? String) ?? ""
        let environmentId = (raw["environment_id"] as? String) ?? ""
        let origin = raw["origin"] as? String

        // Classify by mutual exclusion of (environment_id, cwd). The doc-comment
        // on RemoteSessionKind enumerates the exact buckets — keep this in sync.
        let kind: RemoteSessionKind
        switch (!environmentId.isEmpty, !cwd.isEmpty) {
        case (true, false):  kind = .web      // CCR-running, cloud-only state
        case (false, true):  kind = .local    // ran here, metadata uploaded
        case (false, false): kind = .bridge   // remote-control mirror or never-started
        case (true, true):
            // Both populated — currently unobserved; treat as bridge so we
            // don't surface it as a clean teleport target by default.
            logger.warning("Session \(id) has both environment_id and cwd; classifying as .bridge")
            kind = .bridge
        }

        // Repo info: prefer outcomes[].git_info, fall back to sources[].git_repository
        var repoOwner: String?
        var repoName: String?
        var branch: String?

        if let outcomes = context["outcomes"] as? [[String: Any]] {
            for outcome in outcomes {
                if let gitInfo = outcome["git_info"] as? [String: Any] {
                    if let repoStr = gitInfo["repo"] as? String {
                        let parts = repoStr.split(separator: "/", maxSplits: 1)
                        if parts.count == 2 {
                            repoOwner = String(parts[0])
                            repoName = String(parts[1])
                        }
                    }
                    if let branches = gitInfo["branches"] as? [String], let first = branches.first {
                        branch = first
                    }
                    break
                }
            }
        }
        if repoName == nil, let sources = context["sources"] as? [[String: Any]] {
            for source in sources {
                if (source["type"] as? String) == "git_repository",
                   let url = source["url"] as? String {
                    if let parsed = parseGitHubRepo(url) {
                        repoOwner = parsed.owner
                        repoName = parsed.name
                    }
                    if branch == nil {
                        if let revision = source["revision"] as? String {
                            // refs/heads/main → main
                            if revision.hasPrefix("refs/heads/") {
                                branch = String(revision.dropFirst("refs/heads/".count))
                            } else {
                                branch = revision
                            }
                        }
                    }
                    break
                }
            }
        }

        return RemoteSession(
            id: id,
            summary: title,
            lastModified: lastModified,
            status: status,
            repoOwner: repoOwner,
            repoName: repoName,
            branch: branch,
            kind: kind,
            origin: origin,
            cwd: cwd.isEmpty ? nil : cwd
        )
    }

    /// Strict github.com / *.github.com check. Avoids false positives on
    /// hosts like `notgithub.io` or `github.example.com` that contain
    /// "github" as a substring but aren't the real GitHub.
    private static func isGitHubHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "github.com" || h.hasSuffix(".github.com")
    }

    private static func parseGitHubRepo(_ url: String) -> (owner: String, name: String)? {
        // Handles three forms:
        //   https://github.com/owner/name(.git)
        //   ssh://git@github.com/owner/name(.git)
        //   git@github.com:owner/name(.git)            (scp shorthand — URLComponents fails)
        let path: String
        if let scpRange = url.range(of: ":"),
           url.hasPrefix("git@") || url.hasPrefix("ssh://git@"),
           !url.hasPrefix("ssh://") {
            // scp form: host is "git@github.com" — pull off the user@.
            let leftSide = String(url[..<scpRange.lowerBound])
            let host = leftSide.split(separator: "@").last.map(String.init) ?? leftSide
            guard isGitHubHost(host) else { return nil }
            path = String(url[scpRange.upperBound...])
        } else if let components = URLComponents(string: url),
                  let host = components.host,
                  isGitHubHost(host) {
            path = components.path
        } else {
            return nil
        }
        let parts = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")
            .split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Cached formatters; ISO8601DateFormatter is documented thread-safe for
    /// `date(from:)` once configured. Wrapped in nonisolated(unsafe) so the
    /// concurrency checker doesn't flag the static state.
    private nonisolated(unsafe) static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO8601(_ s: String) -> Date? {
        if let d = iso8601WithFraction.date(from: s) { return d }
        return iso8601.date(from: s)
    }
}
