import SwiftUI

/// A login running out of quota, as the CLI reports it on `rate_limit_event`.
///
/// Measured on CLI 2.1.258: every turn carries `rate_limit_info` with a
/// `status` of `allowed`; the extension's own "You've hit your … limit" row
/// fires on `status == "rejected"` with a `rateLimitType`, and this mirrors
/// that exact condition so the banner and the webview agree.
struct RateLimitHit: Equatable {
    let limitType: String
    let resetsAt: Date?

    enum Signal: Equatable {
        case hit(RateLimitHit)
        case cleared
        case unknown
    }

    static func signal(from ioMessage: [String: Any]) -> Signal {
        guard ioMessage["type"] as? String == "rate_limit_event",
              let info = ioMessage["rate_limit_info"] as? [String: Any],
              let status = info["status"] as? String
        else { return .unknown }
        switch status {
        case "rejected":
            guard let type = info["rateLimitType"] as? String, !type.isEmpty else { return .unknown }
            let resets = (info["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return .hit(RateLimitHit(limitType: type, resetsAt: resets))
        case "allowed", "allowed_warning":
            return .cleared
        default:
            return .unknown
        }
    }

    /// What a session's hit becomes after one signal: a hit replaces it,
    /// an allowed status clears it, anything else leaves it alone.
    static func next(current: RateLimitHit?, signal: Signal) -> RateLimitHit? {
        switch signal {
        case .hit(let hit): hit
        case .cleared: nil
        case .unknown: current
        }
    }

    /// "5-hour", "weekly", or the CLI's own name with underscores spaced.
    var limitLabel: String {
        switch limitType {
        case "five_hour": "5-hour"
        case "seven_day": "weekly"
        default: limitType.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Offers the other logins when this session's login is out of quota. One
/// click switches the session and resumes the same conversation there.
struct AccountLimitBanner: View {
    @Bindable var session: OpenSession
    /// The hit the user closed; a new hit (another window or reset time)
    /// shows the banner again.
    @State private var dismissed: RateLimitHit?

    var body: some View {
        // Group so the cleared-hit reset below has a view to hang on even
        // when the banner itself is hidden.
        Group { banner }
            .onChange(of: session.statusBar.limitHit) { _, hit in
                if hit == nil { dismissed = nil }
            }
    }

    @ViewBuilder
    private var banner: some View {
        let data = session.statusBar
        if let hit = data.limitHit, hit != dismissed,
           session.origin.remoteHost == nil, session.origin.mirrorTarget == nil {
            let targets = Self.targets(current: session.claudeAccount, accounts: ClaudeAccountStore.load())
            if !targets.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    let text = Text(Self.message(account: session.claudeAccount, hit: hit))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // A pane can be as narrow as 100 pt; the buttons fold into
                    // one menu when they would not fit beside the message.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            text.fixedSize()
                            Spacer(minLength: 4)
                            ForEach(targets, id: \.id) { target in
                                Button("Continue on \(target.name)") { switchTo(target) }
                                    .controlSize(.small)
                            }
                        }
                        HStack(spacing: 8) {
                            text
                            Spacer(minLength: 4)
                            Menu("Switch") {
                                ForEach(targets, id: \.id) { target in
                                    Button("Continue on \(target.name)") { switchTo(target) }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                    Button {
                        dismissed = hit
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Dismiss")
                }
                .frame(maxWidth: data.chatInputWidth ?? 640)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.white)
            }
        } else if let note = session.accountAutoSwitch {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundStyle(.secondary)
                Text(Self.autoSwitchMessage(note, to: session.claudeAccount))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button {
                    session.accountAutoSwitch = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Dismiss")
            }
            .frame(maxWidth: data.chatInputWidth ?? 640)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.white)
        }
    }

    static func autoSwitchMessage(_ note: AccountAutoSwitch, to account: ClaudeAccount?) -> String {
        var text = "Started on \(ClaudeAccountPicker.displayName(account)) · \(note.fromName) is at its \(note.limitLabel) limit"
        if let resets = note.resetsAt { text += " until \(resetText(resets))" }
        return text
    }

    /// A weekly window can reset days away, so name the day then.
    static func resetText(_ date: Date) -> String {
        let format: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return date.formatted(format)
    }

    private func switchTo(_ target: Target) {
        SessionStore.shared?.switchAccount(session.id, to: target.account)
    }

    struct Target: Equatable {
        let name: String
        let account: ClaudeAccount?
        var id: String { account?.id ?? "" }
    }

    /// Every login except the one the session is on, the default first.
    static func targets(current: ClaudeAccount?, accounts: [ClaudeAccount]) -> [Target] {
        var result: [Target] = []
        if current != nil { result.append(Target(name: "Default", account: nil)) }
        for account in accounts where account.id != current?.id {
            result.append(Target(name: account.name, account: account))
        }
        return result
    }

    static func message(account: ClaudeAccount?, hit: RateLimitHit) -> String {
        var text = "\(account?.name ?? "Default") hit its \(hit.limitLabel) limit"
        if let resets = hit.resetsAt { text += " · resets \(resetText(resets))" }
        return text
    }
}
