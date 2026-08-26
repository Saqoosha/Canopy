import Foundation

/// Where a remote MacroPad bridge lives.
///
/// Parsed once, at the settings boundary, and stored as a value from then on.
/// Nothing downstream re-parses an address string, so no runtime path has to
/// decide what a malformed one means.
struct MacroPadRemoteEndpoint: Equatable, Sendable {
    /// Matches the port `scripts/macropad-bridge.sh` listens on. Changing one
    /// without the other silently produces a pad that never connects.
    static let defaultPort: UInt16 = 8765

    let host: String
    let port: UInt16

    /// What logs show — NOT the menu, which renders `host` alone
    /// (`MacroPadCommands.remoteTitle`). Always carries the port, including
    /// when the user typed a bare host, and brackets the host whenever it
    /// contains a colon (an IPv6 literal) so the result stays parseable by
    /// `parse` itself: unbracketed, `fd7a::1:8765` doesn't say where the
    /// address ends and where the port begins. `parse` never constructs an
    /// endpoint with an unbracketed colon in `host`, but the memberwise
    /// initializer isn't private, so this guards the type's own invariant
    /// rather than trusting every caller to have gone through `parse`.
    var displayLabel: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Accepts `host`, `host:port`, `[v6]`, and `[v6]:port`.
    ///
    /// Returns nil for anything that would otherwise have to be guessed at:
    /// an empty host, a port outside 1...65535, a non-numeric port, or a bare
    /// IPv6 literal — the last because `fd7a::1` is indistinguishable from a
    /// `host:port` with a strange host, and picking either reading silently
    /// dials somewhere the user did not ask for.
    static func parse(_ raw: String) -> MacroPadRemoteEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return MacroPadRemoteEndpoint(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let port = parsePort(String(rest.dropFirst())) else { return nil }
            return MacroPadRemoteEndpoint(host: host, port: port)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return MacroPadRemoteEndpoint(host: String(parts[0]), port: defaultPort)
        case 2:
            let host = String(parts[0])
            guard !host.isEmpty, let port = parsePort(String(parts[1])) else { return nil }
            return MacroPadRemoteEndpoint(host: host, port: port)
        default:
            // Two or more colons: an unbracketed IPv6 literal. See the doc.
            return nil
        }
    }

    /// What `SettingsView`'s live typing should store into
    /// `CanopySettings.macroPadRemoteHost`, or nil to leave the stored value
    /// untouched.
    ///
    /// The "Remote bridge" Picker row is gated on the COMMITTED host parsing
    /// successfully (see `SettingsView`'s row builder), and until this
    /// existed nothing wrote that value before `commitHost()` fired on
    /// Return or focus loss — so a user typing a valid address watched
    /// nothing happen, with the very option they were trying to enable still
    /// missing from the menu. Found during real two-machine testing.
    ///
    /// Mirroring the trimmed draft in as the user types fixes that, but only
    /// while `source` is not already `.remote`: storing on every keystroke
    /// against a LIVE remote selection would let the settings file hold a
    /// half-typed host next to a still-`.remote` selector, and
    /// `MacroPadSource.migrated` re-derives `.remote` from exactly that pair
    /// on the next launch — a crash or quit mid-edit would silently resolve
    /// to the half-typed address rather than the address the pad is actually
    /// using. `commitHost()` keeps deferring for that case, unchanged.
    ///
    /// A non-empty, unparseable draft returns nil rather than storing "" or
    /// the garbage itself: storing on every keystroke of an intermediate
    /// shape (`mbp` -> `mbp:` -> `mbp:8`) would destroy a previously-good
    /// stored address and flicker the Picker row open, closed, open again
    /// while the user is still typing toward a valid one.
    static func liveHostUpdate(source: MacroPadSource, draft: String) -> String? {
        if case .remote = source { return nil }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        return parse(trimmed) != nil ? trimmed : nil
    }

    private static func parsePort(_ raw: String) -> UInt16? {
        // `UInt16(raw)` alone would accept "+1" and Unicode digits; both would
        // then be handed to `getaddrinfo` as a service name.
        guard !raw.isEmpty,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt16(raw),
              value > 0
        else { return nil }
        return value
    }
}

/// Which pad this Canopy is driving.
///
/// Replaces `CanopySettings.macroPadEnabled`. Carrying both a boolean and a
/// selector would give two spellings of "off" that could disagree.
///
/// Only one case is ever live at a time, which is the whole design: the
/// firmware blanks itself when its host disconnects, so switching away leaves
/// the abandoned pad dark for free, and `canopy.macroPadAsleep` can stay a
/// single boolean instead of a per-device map.
enum MacroPadSource: Equatable, Sendable {
    case off
    case local
    case remote(MacroPadRemoteEndpoint)

    var isOff: Bool {
        if case .off = self { return true }
        return false
    }

    /// The persisted spelling of the selector only. The address lives in its
    /// own settings key so the menu can switch without re-typing it.
    var rawValue: String {
        switch self {
        case .off: return "off"
        case .local: return "local"
        case .remote: return "remote"
        }
    }

    /// Resolves a stored selector against a stored address.
    ///
    /// Returns nil when the selector itself is unrecognised, so the caller can
    /// fall through to migration rather than inventing a state.
    ///
    /// A `remote` selector whose ADDRESS is unusable degrades to `.off`, never
    /// to `.local`. The settings file is hand-editable, and quietly driving a
    /// different pad than the one configured is worse than driving none.
    static func resolve(rawValue: String, host: String) -> MacroPadSource? {
        switch rawValue {
        case "off": return .off
        case "local": return .local
        case "remote": return MacroPadRemoteEndpoint.parse(host).map(MacroPadSource.remote) ?? .off
        default: return nil
        }
    }

    /// The load-time ladder: a stored selector wins; failing that the retired
    /// `canopy.macroPadEnabled` boolean is mapped once; failing that, `.local`,
    /// which is what a fresh install used to get from `macroPadEnabled = true`.
    ///
    /// Note the asymmetry with `resolve`: an unrecognised SELECTOR falls
    /// through to the legacy key, because it says nothing about intent. An
    /// unusable ADDRESS under a `remote` selector does not — that one is a
    /// specific request that cannot be honoured, so it lands on `.off`.
    static func migrated(storedRaw: String?, storedHost: String, legacyEnabled: Bool?) -> MacroPadSource {
        if let storedRaw, let resolved = resolve(rawValue: storedRaw, host: storedHost) {
            return resolved
        }
        if let legacyEnabled { return legacyEnabled ? .local : .off }
        return .local
    }
}
