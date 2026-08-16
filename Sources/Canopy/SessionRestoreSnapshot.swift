import Foundation

/// What Canopy writes at quit so the next launch can rebuild the detail
/// column as it was: which sessions were in panes, in what left-to-right
/// order, at what widths, and which pane had focus.
///
/// **Only sessions a pane referenced are captured.** An open session with no
/// pane is deliberately dropped. Restoring one would put a row in the
/// sidebar's open block with no shim behind it — nothing mounts its
/// WKWebView, so the lazy spawn in `SessionContainer` never runs and
/// `OpenSession.status` sits at `.spawning` forever, which `SessionActivity`
/// renders as the breathing cyan of a session that is working. A permanently
/// busy dot on a session nothing is running is worse than the row's absence,
/// and the row is not really absent: it comes back as an ordinary closed
/// recent, one click from open, which is what an unpaned open session
/// effectively was.
///
/// The model provider is stored **by id, never inline**: `ModelProvider`
/// carries an `authToken`, and this blob lands in UserDefaults as plain
/// JSON. `applyRestoreSnapshot` resolves the id against `ModelProviderStore`
/// at restore time, so a provider the user has since deleted degrades to
/// "no custom provider" rather than resurrecting a stale secret.
struct SessionRestoreSnapshot: Codable, Equatable {
    /// Bumped when a stored field changes meaning. A snapshot whose version
    /// doesn't match is discarded, not migrated: one launch of lost layout
    /// is cheap, and resuming a session against a misread working directory
    /// is not.
    static let currentVersion = 1

    struct Session: Codable, Equatable {
        enum Origin: Codable, Equatable {
            case local(path: String)
            case remote(host: String, path: String)
            case teleported(cloudSessionId: String, path: String)

            var path: String {
                switch self {
                case .local(let p): p
                case .remote(_, let p): p
                case .teleported(_, let p): p
                }
            }

            /// Non-nil only for SSH sessions. Restore uses this to decide
            /// whether the working directory is even checkable from here.
            var remoteHost: String? {
                if case .remote(let host, _) = self { return host }
                return nil
            }
        }

        var resumeId: String
        var title: String
        var project: String
        var origin: Origin
        var permissionMode: PermissionMode
        var model: String?
        var effortLevel: String?
        var providerId: String?
        var lastActiveAt: Date
    }

    enum PaneContent: Codable, Equatable {
        /// Keyed by resumeId, not by `OpenSession.ID` — the UUID identity is
        /// minted per process and means nothing across a relaunch.
        case session(resumeId: String)
        case launcher
    }

    struct Pane: Codable, Equatable {
        var content: PaneContent
        /// Absolute pt, not a `PaneSlot` weight. `captureRestoreSnapshot`
        /// runs `normalizePaneWeightsToVisualWidths()` first so the two
        /// coincide at capture time; the saved window frame restores the
        /// total these were measured against.
        var width: CGFloat
    }

    var version: Int = currentVersion
    var sessions: [Session]
    var panes: [Pane]
    var focusedPaneIndex: Int

    /// True when there is nothing worth rebuilding. Callers treat this as
    /// "launch normally" rather than as an error.
    ///
    /// The test is **a surviving session pane**, not `panes.isEmpty`, so that
    /// "worth saving" and "worth restoring" are one predicate rather than two.
    /// They used to differ, and the gap was reachable: Cmd+N in each of two
    /// panes leaves two launcher panes with their sessions still running, so
    /// the quit prompt appeared, the snapshot passed the save gate, and
    /// `sanitized`'s no-session-pane rule then rejected it at launch. The user
    /// got nothing back — plus the multi-pane-wide window, because taking the
    /// save branch had skipped `normalizeSavedFrameForSinglePane()`.
    var isEmpty: Bool {
        !panes.contains { pane in
            if case .session = pane.content { return true }
            return false
        }
    }
}

extension SessionRestoreSnapshot {
    /// Everything that can make a stored snapshot unusable, resolved in one
    /// pass. Pure: the "does this session still exist" question comes in as
    /// a closure so the probe can drive every branch without touching disk.
    ///
    /// The rules, and why each one is here:
    /// - **Version mismatch → empty**, before anything else is examined.
    /// - Sessions failing `sessionIsResumable` are dropped, and every pane
    ///   pointing at one goes with them. Restoring a session whose JSONL is
    ///   gone fails loudly at the CLI (measurement on
    ///   `ClaudeSessionHistory.sessionFileExists`), so the pane would come
    ///   back as a crash rather than as a session; an absent pane is quieter
    ///   and does not claim to have restored anything.
    /// - A resumeId appearing in two panes keeps only the leftmost, because
    ///   the store's one-session-one-pane invariant has no way to express
    ///   the duplicate and `paneIndex(forSession:)` would answer with the
    ///   first one anyway.
    /// - Panes past `paneCap` are dropped rather than the whole snapshot
    ///   rejected: the cap can shrink between versions, and losing the
    ///   rightmost panes beats losing the layout.
    /// - **A snapshot with no surviving session pane collapses to empty.**
    ///   Launcher panes are faithful to what the user arranged, but a
    ///   relaunch into three empty launchers reads as a bug, and a
    ///   launcher-only arrangement has nothing to restore in the first place.
    /// - Sessions no surviving pane refers to are dropped, so a pane lost to
    ///   the cap cannot strand one.
    /// - `focusedPaneIndex` is clamped last, after the pane list is final.
    ///   Note the bookkeeping only repairs panes dropped BEFORE the focused
    ///   one; when the focused pane is itself dropped, focus lands on
    ///   whatever slid into its index. That is deliberate — there is no
    ///   better answer — but it is not what "keeps pointing at the same
    ///   content" would suggest on its own.
    func sanitized(
        paneCap: Int,
        sessionIsResumable: (Session) -> Bool
    ) -> SessionRestoreSnapshot {
        guard version == Self.currentVersion else {
            return SessionRestoreSnapshot(sessions: [], panes: [], focusedPaneIndex: 0)
        }

        let resumable = sessions.filter(sessionIsResumable)
        let resumableIds = Set(resumable.map(\.resumeId))

        var keptPanes: [Pane] = []
        var claimed: Set<String> = []
        // Track how many panes disappear ahead of the stored focus so the
        // focused pane keeps pointing at the same content, not at whatever
        // slid left into its index.
        var droppedBeforeFocus = 0
        for (index, pane) in panes.enumerated() {
            let keep: Bool
            switch pane.content {
            case .launcher:
                keep = true
            case .session(let resumeId):
                keep = resumableIds.contains(resumeId) && claimed.insert(resumeId).inserted
            }
            if keep, keptPanes.count < max(0, paneCap) {
                keptPanes.append(pane)
            } else if index < focusedPaneIndex {
                droppedBeforeFocus += 1
            }
        }

        let hasSessionPane = keptPanes.contains { pane in
            if case .session = pane.content { return true }
            return false
        }
        guard hasSessionPane else {
            return SessionRestoreSnapshot(sessions: [], panes: [], focusedPaneIndex: 0)
        }

        // Drop sessions no surviving pane refers to — capture only stores
        // paned sessions, but a pane lost to the cap can strand one.
        let referenced: Set<String> = Set(keptPanes.compactMap {
            if case .session(let id) = $0.content { return id } else { return nil }
        })
        // De-duplicate by resumeId as well as filtering. Capture cannot emit a
        // duplicate, but this blob is plain JSON in UserDefaults and sanitize
        // is the one place untrusted stored input gets laundered. Two entries
        // sharing a resumeId would both become `OpenSession`s while only the
        // last won the pane, leaving the first as an unpaned row stuck at
        // `.spawning` — the permanently breathing "working" dot this type's
        // own doc says the paned-only rule exists to prevent.
        var seenSessions: Set<String> = []
        let keptSessions = resumable.filter {
            referenced.contains($0.resumeId) && seenSessions.insert($0.resumeId).inserted
        }

        let focus = min(max(0, focusedPaneIndex - droppedBeforeFocus), keptPanes.count - 1)
        return SessionRestoreSnapshot(sessions: keptSessions, panes: keptPanes, focusedPaneIndex: focus)
    }

    /// The real-disk predicate `sanitized` takes in production.
    ///
    /// An SSH session is accepted unchecked: both its working directory and
    /// its JSONL live on the other machine, so there is nothing here to
    /// look at, and "can't verify" must not be reported as "gone" — the same
    /// asymmetry the background-task reconcile draws for remote sessions.
    static func resumableOnDisk(_ session: Session) -> Bool {
        if session.origin.remoteHost != nil { return true }
        let directory = URL(fileURLWithPath: session.origin.path)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        return ClaudeSessionHistory.sessionFileExists(id: session.resumeId, directory: directory)
    }
}
