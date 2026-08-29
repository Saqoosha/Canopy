import Foundation

/// What Canopy writes at quit so the next launch can rebuild the sidebar's
/// open block and the detail column as they were: every open session in row
/// order, which of them were in panes, in what left-to-right order, at what
/// widths, and which pane had focus.
///
/// **Every open session is captured, paned or not** — one per resumeId; see
/// the dedup in `SessionStore.captureRestoreSnapshot`. Unpaned ones used to be
/// dropped, because restoring one puts a row in the open block with no shim
/// behind it — nothing mounts its WKWebView, so the lazy spawn in
/// `SessionContainer` never runs and a `.spawning` status would sit there
/// forever, rendering as the breathing cyan of a session that is working.
/// `OpenSession.Status.dormant` is what makes the row honest instead: idle
/// dot, no shim, and `SessionStore.startIfDormant(_:)` promotes it to
/// `.spawning` the moment a pane takes it. What is still lost across the
/// relaunch is the *process* — a session that was open, unpaned and still
/// RUNNING at quit had a live shim and comes back with none until a pane
/// takes it. (One that was already dormant at quit loses nothing, and "until
/// a pane takes it" is wider than "until the row is clicked" — see
/// `OpenSession.Status.dormant`.) The alternative is one Node subprocess per
/// open session at launch, which is why this is the trade taken.
///
/// **A surviving session pane remains the precondition for restoring at
/// all** — see `isEmpty`. Widening that to "any surviving session" was tried
/// and reverted: it made a restore with no session pane reachable, and such a
/// launch comes up with zero shims, which `ShimProcess.hasActiveSession` —
/// the gate on the quit prompt that is the snapshot's only writer — reads as
/// "nothing to save". The rows came back once and were then discarded
/// silently. Requiring one session pane keeps at least one shim alive at
/// launch, so the next quit still offers to save. The residue is narrow and
/// is NOT "close everything by hand": in the ordinary case `closeSession`
/// promotes the next open session as each pane empties, waking a dormant row
/// and keeping a shim alive. It needs a strip that holds no session pane —
/// a surviving launcher pane, or an already-empty strip — and the exact
/// condition is argued at the gate in `AppDelegate.applicationShouldTerminate`.
/// Even then it is a limitation of the feature rather than a regression, since
/// those rows did not come back at all before it.
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
    ///
    /// `sessions` widened from "the paned sessions" to "every open session"
    /// without a bump, deliberately, because the change is compatible in both
    /// directions: an old blob is a valid subset — every session in it is
    /// paned, so any that keeps its pane restores `.spawning` as before, and
    /// one whose pane sanitize drops comes back as a dormant row instead of
    /// vanishing, which is a difference but a benign one — and an
    /// old build reading a new blob re-applies its own "drop sessions no pane
    /// refers to" filter and degrades to the old behaviour rather than
    /// misreading anything. A bump would have cost one launch of layout for
    /// no behavioural difference.
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
    /// The test is **a surviving session pane**, not `panes.isEmpty` and not
    /// `sessions.isEmpty`, so that "worth saving" and "worth restoring" are
    /// one predicate rather than two. They used to differ, and the gap was
    /// reachable: Cmd+N in each of two panes leaves two launcher panes with
    /// their sessions still running, so the quit prompt appeared, the
    /// snapshot passed the save gate, and `sanitized`'s no-session-pane rule
    /// then rejected it at launch. The user got nothing back — plus the
    /// multi-pane-wide window, because taking the save branch had skipped
    /// `normalizeSavedFrameForSinglePane()`.
    ///
    /// Restoring that arrangement — launcher panes plus dormant rows — is
    /// what the session-based test would have bought, and it is deliberately
    /// not bought: see the type doc for why a launch with zero shims cannot
    /// save itself again. So a launcher-only strip still stores no snapshot,
    /// and the frame still gets normalized, exactly as before.
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
    ///   gone would do something this project has twice guessed wrong about —
    ///   see `ClaudeSessionHistory.sessionFileExists` for what is and is not
    ///   established. An absent pane is the one outcome that needs no guess.
    /// - A resumeId appearing in two panes keeps only the leftmost, because
    ///   the store's one-session-one-pane invariant has no way to express
    ///   the duplicate and `paneIndex(forSession:)` would answer with the
    ///   first one anyway.
    /// - Panes past `paneCap` are dropped rather than the whole snapshot
    ///   rejected: the cap can shrink between versions, and losing the
    ///   rightmost panes beats losing the layout.
    /// - A resumeId appearing twice in `sessions` keeps only the first that
    ///   survives `sessionIsResumable` — the dedup runs over the resumable
    ///   set, so a hand-edited blob whose first twin points at a dead path
    ///   keeps the second.
    ///   Capture cannot emit that, but this blob is plain JSON in
    ///   UserDefaults and sanitize is the one place stored input is
    ///   laundered. Both entries would become `OpenSession`s while only the
    ///   last won the pane — `applyRestoreSnapshot`'s `byResumeId` is
    ///   last-write-wins — leaving the first unpaned. Note `.dormant` does
    ///   NOT rescue that one: the paned/unpaned split is decided by
    ///   `panedResumeIds.contains`, which is keyed on resumeId, so the
    ///   stranded duplicate would be marked `.spawning` and would stay there,
    ///   as the breathing "working" dot with nothing behind it, until a pane
    ///   took it. (Subjunctive throughout: the dedup is in force, so none of
    ///   this is live behaviour — it is the argument FOR the rule.) (Do not reach
    ///   for `paneIndex(forSession:)` to explain this the way the bullet
    ///   above does: that one is keyed on `OpenSession.ID`, a per-process
    ///   UUID, and two duplicates get two distinct ones.)
    /// - **A snapshot with no surviving session PANE collapses to empty.**
    ///   (Listed after the dedup bullet above, but it runs BEFORE it — the
    ///   guard is the earlier return, and the dedup never sees a collapsed
    ///   snapshot.)
    ///   Launcher panes are faithful to what the user arranged, but a
    ///   relaunch into three empty launchers reads as a bug, and — since the
    ///   open block became restorable — a launch with no session pane has no
    ///   shim, which is the state that cannot save itself again. See
    ///   `isEmpty`, which is this same predicate.
    /// - **A session no pane refers to is KEPT.** It was dropped until
    ///   panes stopped being the only thing restored; keeping it is the whole
    ///   point of `.dormant`, and it also means a pane lost to `paneCap`
    ///   demotes its session to a dormant row instead of erasing it.
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

        // De-duplicate by resumeId. Unpaned survivors are kept — that is what
        // restores the sidebar's open block rather than only the pane strip.
        var seenSessions: Set<String> = []
        let keptSessions = resumable.filter { seenSessions.insert($0.resumeId).inserted }

        // `keptPanes` is non-empty past the guard above, so `count - 1` is a
        // valid index and needs no floor.
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
