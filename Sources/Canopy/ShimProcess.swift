import Cocoa
import UserNotifications
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ShimProcess")

@MainActor
protocol ShimProcessDelegate: AnyObject {
    func shimProcessDidDisconnect(_ shim: ShimProcess, sessionId: String)
    func shimProcessDidCrash(_ shim: ShimProcess, status: Int32)
}

/// Manages a Node.js subprocess running the vscode-shim that bridges the CC extension
/// to Canopy's WKWebView via stdin/stdout NDJSON.
///
/// Thread safety: `stdoutBuffer` is only accessed from the stdout readabilityHandler
/// (serialized by the system). All other mutable state (`isReady`, `pendingMessages`, etc.)
/// is only accessed from the main thread. Stdin writes are serialized via `writeQueue`.
final class ShimProcess: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    weak var webView: WKWebView?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Set when shim sends {"type":"ready"} — extension is activated and providers are set up.
    private var isReady = false
    /// Messages queued before the shim is ready (flushed on "ready").
    private var pendingMessages: [[String: Any]] = []

    /// Accumulates partial lines from stdout (only accessed from readabilityHandler thread).
    private var stdoutBuffer = Data()
    /// Descendant PIDs collected before termination, used for cleanup on unexpected exit.
    private var descendantPids: [pid_t] = []
    /// Channel ID from launch_claude, needed for generate_session_title requests.
    private var channelId: String?
    /// True after an AI-generated title (or fallback) has been applied.
    /// Blocks raw webview title overwrites; the extension keeps re-sending
    /// stale internal titles unless we explicitly replace them.
    private var hasGeneratedTitle = false
    /// True when the current title should be regenerated on the next prompt.
    /// Set on session resume (stored title may not reflect new conversation)
    /// and when the 30s fallback fires. Cleared once an AI title arrives.
    private var titleIsFallback = false
    /// True while a `generate_session_title` request is awaiting a response.
    private var titleRequestInFlight = false
    /// Title generation may queue behind the main turn and MCP startup.
    private let titleFallbackDelay: TimeInterval = 30.0
    /// Request ID of the current title generation, used to reject stale responses.
    private var currentTitleRequestId: String?
    /// Sliding window of recent user prompts (max 5), used as context for title generation.
    private var promptHistory: [String] = []
    /// Most recent user message text, used as fallback when AI generation doesn't respond.
    private var lastUserMessageText: String?
    /// Session ID from webview's update_session_state, used to persist generated titles.
    private var activeSessionId: String?
    /// Generated title waiting to be saved (when activeSessionId arrives after the title response).
    private var pendingGeneratedTitle: String?
    /// The Canopy-owned title currently applied to the native session row.
    private var generatedSessionTitle: String?

    private let writeQueue = DispatchQueue(label: "sh.saqoo.Canopy.shimWrite")

    /// All living ShimProcess instances (weak references, auto-removed on dealloc).
    @MainActor private static var instances = NSHashTable<ShimProcess>.weakObjects()

    /// Whether any shim process is currently running. Used by AppDelegate's
    /// quit-time confirmation alert. `isIntentionalStop` shims are excluded —
    /// `proc.terminate()` is async, so `process.isRunning` lingers true for a
    /// few ms after `stop()` returns and would otherwise trip the prompt.
    @MainActor static var hasActiveSession: Bool {
        instances.allObjects.contains { $0.process?.isRunning == true && !$0.isIntentionalStop }
    }

    /// Number of currently running shim processes (excluding ones already in
    /// the middle of an intentional `stop()`).
    @MainActor static var activeCount: Int {
        instances.allObjects.filter { $0.process?.isRunning == true && !$0.isIntentionalStop }.count
    }

    /// Synchronously stop any running shim that no `OpenSession` still
    /// owns (e.g. orphaned by an SSH reconnect mid-flight). Called as a
    /// cleanup pass from `applicationShouldTerminate` so leftover Node.js
    /// processes don't trigger a spurious "session still running" prompt
    /// at quit time.
    ///
    /// We can't use "webView detached from a window" as the orphan signal
    /// here: in the sidebar shell, inactive open sessions cache their
    /// WKWebView on `OpenSession.webView` with `.window == nil` — they're
    /// legitimate background sessions, not orphans, and killing them on
    /// quit would skip the terminate-confirmation alert. Ownership is the
    /// honest signal: a shim whose `boundSession` is gone, or whose
    /// `boundSession.shim` is now a *different* instance (SSH reconnect
    /// replaced it), is what we actually want to clean up.
    @MainActor static func stopOrphanedSessions() {
        for shim in instances.allObjects {
            let session = shim.boundSession
            if session == nil || session?.shim !== shim {
                shim.stop()
            }
        }
    }

    let workingDirectory: URL
    var resumeSessionId: String?
    var model: String?
    var effortLevel: String?
    var permissionMode: PermissionMode
    var remoteHost: String?
    var customApi: ModelProvider?

    // MARK: - Activity tracking (drives sidebar spinner via boundSession.isThinking)
    private var sessionTitle: String = ""
    private var isWorking = false {
        didSet {
            // When Claude starts a new round (user submitted), clear any
            // outstanding AskUserQuestion asking state — the user already
            // responded, we're back to thinking.
            if isWorking && !oldValue {
                lastAssistantHadAskUserQuestion = false
                refreshAskingState()
                // Reconcile pending background tasks against the session
                // JSONL: only the ids whose `<task-notification>` has
                // landed in the log get cleared. Multi-bg-task case and
                // user-typed-while-bg case both resolve correctly — see
                // `reconcileCompletedBackgroundTasks(trigger:)`.
                if !pendingBackgroundTaskIds.isEmpty {
                    reconcileCompletedBackgroundTasks(trigger: .wake)
                }
            }
            boundSession?.isThinking = isWorking
            refreshWaitingState()
        }
    }

    /// Tool-use id assigned by Claude (`toolu_...`). Distinct from session id /
    /// request id — typealias kept private to lock that distinction at the
    /// signature level for every site that touches the pending-bg map.
    private typealias BackgroundTaskID = String

    /// JSONL byte position used as a *lower bound* for the completion scan.
    /// Same nominal type as a file size, but the units are bytes-in-JSONL —
    /// naming it apart from a generic `UInt64` prevents accidental mix-ups
    /// with timestamps, counts, or `tail.utf8.count` (which can diverge from
    /// the byte count when lossy UTF-8 inserts replacement characters).
    ///
    /// Internal, not private, only because `scannedByteCount` is internal for
    /// the probe and names it in its signature. The distinction it draws is
    /// for readers inside this file either way.
    typealias JSONLByteOffset = UInt64

    /// Outstanding `tool_use` ids whose call was either a `Bash` with
    /// `run_in_background:true` or an `Agent` with `run_in_background:true`.
    /// The CLI never streams the matching `<task-notification>` back through
    /// the io_message channel (verified empirically with bg-trace logging),
    /// so we can't watch for completion directly. Instead we scan the session
    /// JSONL from each launch's byte offset on the next `isWorking: false→true`
    /// transition, plus on an idle timer while nothing else is going to wake us
    /// — see `reconcileCompletedBackgroundTasks(trigger:)` for the full
    /// rationale. While the map is non-empty and `isWorking` is false, the
    /// sidebar shows the "waiting" hourglass.
    ///
    /// The value for each id is a *lower bound* on where that id's completion
    /// marker can appear in the JSONL — captured at detection time, then
    /// moved to each scan's end (see "advance after scan" below; normally
    /// forward, but it re-homes downward when the log is replaced). Three
    /// invariants make `min(values) → EOF` the tightest correct scan window:
    ///
    /// 1. Every pending id's completion marker (`<tool-use-id>X</tool-use-id>`,
    ///    written by the CLI to `queue-operation` / synthetic-user lines —
    ///    NEVER inside the assistant `tool_use` block, which uses the JSON
    ///    field `"id":"toolu_..."` and no tag wrapper) lies at a byte position
    ///    ≥ that id's recorded offset.
    /// 2. Therefore the marker lies at ≥ `min(values)` across all pending ids.
    /// 3. A re-insert under the same id would *raise* the recorded offset (the
    ///    file only grows), shrinking the scan window — so detection is
    ///    guarded by an `[id] == nil` check that locks the first sighting.
    ///
    /// The detection-time offset captures `current_size − SAFETY_MARGIN` to
    /// absorb a narrow race: a very fast bg task may finish and have its
    /// completion marker flushed BEFORE Swift gets around to processing the
    /// `assistant` io_message that started it. Without the margin, the
    /// captured offset would lie past the marker and the hourglass would
    /// stick. After each scan — a wake's OR an idle backstop tick's — we
    /// advance each remaining id's offset to the last whole line the scan
    /// consumed, since markers can't be in already-scanned bytes, so later
    /// scans only read incremental growth (otherwise a long-running bg task
    /// would re-scan the whole accumulated region every time). "Whole line"
    /// rather than "EOF" is what keeps invariant 1 true while the CLI is
    /// mid-append, which idle ticks made routine — see `readJSONLFromOffset`.
    ///
    /// A fixed-size tail (the original 32 KB) silently fails when Claude
    /// continues streaming heavy tool output between launch and the next
    /// scan: the completion marker scrolls off the tail and the hourglass
    /// sticks forever. The offset-tracked approach above is the fix.
    private var pendingBackgroundTaskIds: [BackgroundTaskID: JSONLByteOffset] = [:]

    /// What caused a `reconcileCompletedBackgroundTasks(trigger:)` pass. The
    /// only thing it decides is whether the JSONL-unreachable and read-failed
    /// branches may bulk-clear, and that difference is the whole reason the
    /// idle backstop is safe to add (issue #132).
    ///
    /// A wake means a new turn started — usually the user typing, though the
    /// CLI also wakes itself on a `<task-notification>`. Either way something
    /// moved, so bulk-clearing there trades an edge case (a bg task genuinely
    /// still running under an SSH remote, whose JSONL lives on the other
    /// machine) for a guarantee that the hourglass can't stick forever on
    /// sessions we can't reconcile. The idle backstop fires on a timer with
    /// nothing behind it at all: the same bulk-clear would fire ~15 s after
    /// the launching turn ends, on exactly those unreconcilable sessions, so
    /// the hourglass would never survive long enough to mean anything there.
    /// Hence idle passes only ever clear ids the scan positively matched, and
    /// no-op when there is nothing to scan.
    ///
    /// Internal rather than private so `_SidebarLogicProbe` can pin these
    /// values. Be clear about what that buys: the probe pins the POLICY, and
    /// the two `guard trigger.allowsBulkClear else … return` statements that
    /// APPLY it are inside private instance methods the probe cannot reach.
    /// Deleting one of those guards leaves every assertion green and breaks
    /// SSH sessions silently, which is exactly the failure the policy exists
    /// to prevent — so treat those two guards as untested, not as covered.
    enum BackgroundReconcileTrigger {
        /// `isWorking: false→true`. Usually a new turn — the user typing,
        /// or the CLI answering its own `<task-notification>`. On `--resume`
        /// the CLI's replay of historical `assistant` messages drives it too,
        /// which is not a turn at all; harmless, because the map is empty
        /// then and the reconcile is guarded on it being non-empty.
        case wake
        /// The idle timer below, with `isWorking` false the whole time.
        case idleBackstop

        var allowsBulkClear: Bool {
            switch self {
            case .wake: true
            case .idleBackstop: false
            }
        }

        /// Names the path in the `[bg]` log lines, so "cleared at the start
        /// of a turn" and "cleared by the timer, because that turn's scan
        /// missed it" stay distinguishable. Issue #132 was diagnosed off a
        /// single `wake jsonl-cleared` line whose `bytes=` was implausibly
        /// small; the label exists so that kind of reading still works now
        /// that two paths can emit the line.
        ///
        /// `switch`, not `self == .wake ? …`, for both properties: a third
        /// trigger added later would inherit the ternary's negative branch
        /// silently, and while that is the SAFE default for `allowsBulkClear`
        /// it is a WRONG log label — mislabelling is worse than no label,
        /// because the log is what this subsystem is diagnosed from. Same
        /// reasoning as `MacroPadStatus.Keys` in CLAUDE.md: make dropping a
        /// case a compile error.
        var logLabel: String {
            switch self {
            case .wake: "wake"
            case .idleBackstop: "idle"
            }
        }
    }

    /// Repeating idle reconcile, live while `!isWorking &&
    /// !pendingBackgroundTaskIds.isEmpty` — the same condition that sets
    /// `isWaiting`, armed and torn down from `refreshWaitingState()` so the
    /// timer's lifetime is tied to the state it exists to correct rather than
    /// to a set of call sites that can drift apart from it. Not quite "while
    /// the hourglass is on screen": `SessionActivity` ranks `.error`,
    /// `.asking` and `.working` (which `.spawning` also produces) above
    /// `.background`, and a session with no `boundSession` has nowhere to
    /// draw at all, so the timer's condition is a superset of what is drawn.
    ///
    /// Why it has to exist: the wake path notices completion only at the START
    /// of the next turn, and the wake triggered by a task's own
    /// `<task-notification>` can race the CLI's flush of the matching
    /// `<tool-use-id>` marker. When it loses that race the reconcile lands one
    /// turn late — and if the session then goes quiet, "one turn late" means
    /// "until a human types in it again" (observed: 32 minutes, issue #132).
    ///
    /// What it covers is precisely "the wake missed a marker that IS in the
    /// log", whatever the reason it missed it. What it cannot cover is a
    /// task whose marker is never written at all (abandoned, or
    /// TaskStop-killed), or drift in the `<tool-use-id>` wrapper itself —
    /// the backstop reads that through the same `jsonlTailHasCompletion` the
    /// wake does, so it fails identically. In particular it does NOT rescue
    /// ack-wording drift, whose victims are exactly the TaskStop-killed
    /// launches that write no marker; only the parser can cover that.
    ///
    /// A self-rescheduling `DispatchWorkItem` on the main queue, not a
    /// `Timer` and not a `DispatchSourceTimer`: it is the shape `recapTimeout`
    /// already uses in this file (the title fallback is the `asyncAfter` half
    /// without the cancellable work item), it needs no new kind of object, and
    /// unlike a runloop timer it still fires during the tracking modes (live
    /// window resize, open menu) — exactly when someone is looking at the
    /// sidebar.
    private var bgIdleBackstop: DispatchWorkItem?

    /// True between an idle backstop dispatching its read and that read's
    /// result being applied, so a tick skips rather than stacking a second
    /// read behind a slow one. Guards idle against idle ONLY: a wake is a
    /// discrete event that happens as often as turns do, so its reads are
    /// left free to overlap (with each other, and with an idle read) the way
    /// they always have — it is the repeating timer that would pile up.
    private var bgIdleBackstopReadInFlight = false

    /// Idle reconcile period. Low frequency on purpose: while the session is
    /// idle the JSONL barely grows, and each pass reads only from the stored
    /// per-id offset forward. The FIRST pass after a launch is the expensive
    /// one — it arms only once the launching turn ends, and reads from
    /// `rawSize − bgScanSafetyMarginBytes`, so it covers that 1 MB margin
    /// PLUS everything the rest of that turn appended — and a pass after it
    /// usually reads only what was appended since, because the scan advances
    /// the offsets. "Usually": the advance stops at the last newline, so a
    /// trailing line still being written holds the offset where it is and
    /// the next pass re-reads it, bounded by that line's length.
    ///
    /// The file read is off-main. What runs ON main per tick is
    /// `sessionJSONLPath()` (one `fileExists`, two if the strict encoded
    /// folder misses and the legacy one is tried) and then, in
    /// `applyBgReconcile`, one `jsonlTailHasCompletion` substring search over
    /// the whole scanned region PER PENDING ID. That search is the dominant
    /// cost, and on the first pass it runs over the megabyte above.
    ///
    /// The user-visible cost of the interval is how long a finished bg task
    /// can keep showing the hourglass — 15 s reads as "it noticed", where a
    /// minute reads as "it's stuck".
    private static let bgIdleBackstopInterval: TimeInterval = 15.0

    /// Maps a pending bg launch's `toolu_…` id to the CLI-side opaque
    /// `task_id` (e.g. `b5nt1jeth`) captured from the launch's initial
    /// `tool_result` ack ("Command running in background with ID: <task_id>.
    /// Output is being written to..."). The CLI's `<task-notification>`
    /// completion path uses `task_id` as the primary key AND emits
    /// `<tool-use-id>toolu_…</tool-use-id>` markers on natural completion.
    /// But `TaskStop`-triggered kills DO NOT emit any `<task-notification>`
    /// (verified against a live trace of three consecutive `wrangler dev`
    /// TaskStops, zero completion markers), and the TaskStop tool_use's
    /// own `toolu_…` id identifies the TaskStop call, not the launch it
    /// targets; the only field on TaskStop that points at the original
    /// launch is `input.task_id` (CLI-side opaque id) — hence the
    /// reverse-lookup map. Without it every `wrangler dev` restart would
    /// leave the hourglass on until Canopy restart. See issue #90.
    ///
    /// Cleared alongside `pendingBackgroundTaskIds` in
    /// `resetActivityState()` so shim crash / SSH reconnect can't leak
    /// stale mappings into the next session.
    private var bgTaskIdMap: [BackgroundTaskID: String] = [:]

    /// Every `toolu_…` id that already existed in the session JSONL when this
    /// shim spawned. On `--resume`, the CLI re-emits historical `assistant`
    /// io_messages through the same io_message stream that carries live
    /// events — `detectBackgroundTaskLaunch` can't tell them apart from the
    /// payload alone. Any bg tool_use whose id is in this set is a replay,
    /// not a fresh launch, and must NOT be added to `pendingBackgroundTaskIds`:
    /// - If it already completed, its `<tool-use-id>` marker lives at a low
    ///   JSONL offset that a reconcile scan (bounded at `rawSize - 1MB` at
    ///   detection time, i.e. ~EOF at replay) will never reach → the entry
    ///   would stick forever.
    /// - If it was abandoned (process died without the CLI writing a
    ///   `task-notification`, or the earlier shim was killed mid-flight),
    ///   the marker never gets written at all → same stuck-forever outcome.
    /// Snapshotting the historic ids at spawn side-steps both cases.
    ///
    /// The extractor read is bounded at `historicJsonlBound` — bytes appended
    /// AFTER spawn are LIVE events (this shim's own turns) and must not be
    /// counted as historic, or a genuinely running bg task would be silently
    /// skipped by `detectBackgroundTaskLaunch` and the hourglass would fail
    /// to appear at all.
    private var historicToolUseIds: Set<BackgroundTaskID> = []

    /// Byte position marking the JSONL EOF at shim spawn. The historic-id
    /// scan reads bytes [0, bound) only — anything at or after this offset
    /// is a live event written by the current shim. Snapshotted synchronously
    /// in init (a cheap `attributesOfItem` call) so the async loader has a
    /// stable boundary even if the CLI starts appending immediately.
    private var historicJsonlBound: JSONLByteOffset = 0

    /// Tracks Agent tool subagent activity for the native CLI-style task
    /// list. Snapshots are pushed to `statusBarData.subagents` on change.
    private var subagentTracker = SubagentTracker()

    /// True when the most recent assistant message contained a
    /// `tool_use` block whose name is `AskUserQuestion`. Drives `isAsking`
    /// once the result event fires and `isWorking` goes false.
    private var lastAssistantHadAskUserQuestion = false

    // MARK: - Recap (Canopy port of the CLI's `away_summary`)

    /// Set between injecting `/recap` and consuming the CLI's reply. While
    /// true, `consumeRecapTraffic` swallows the reply so the recap never
    /// reaches the webview's transcript — it belongs in the native strip.
    private var recapRequestInFlight = false

    /// Watchdog for a `/recap` that never answers (CLI killed mid-request,
    /// statsig gate flipped off, extension drops the turn). Without it the
    /// in-flight flag would latch true and silently swallow the NEXT real
    /// turn's assistant messages — a far worse failure than a missing recap.
    private var recapTimeout: DispatchWorkItem?

    /// Monotonic id for the current flight, captured by value in the watchdog
    /// closure so a dequeued-but-stale watchdog can tell it is not this
    /// flight's and do nothing.
    private var recapGeneration = 0

    /// True once a `<synthetic>` reply has been captured for the current
    /// flight. Gates the `result` swallow: without positive evidence that
    /// the recap turn actually produced something, a `result` on the wire
    /// belongs to somebody else and must not be claimed. See
    /// `consumeRecapTraffic`.
    private var recapCapturedReply = false

    /// Set when the user submits ANYTHING through the webview while a recap
    /// is in flight. That submission is the only way another local command
    /// can be running at the same time as ours, and Canopy is the sole
    /// gateway for webview submissions — so this is an exact test, not a
    /// heuristic: if it is false, a `<synthetic>` reply on the wire can only
    /// be the recap's.
    ///
    /// `<synthetic>` tags local-command output in general, not `/recap`
    /// specifically, so without this a `/cost` the user ran on return had its
    /// output captured as the recap AND deleted from the transcript. An
    /// earlier round tried to close that by scoping on "the user came back",
    /// which was a proxy for the wrong thing and broke the tracker path; this
    /// gates on the actual precondition instead.
    private var recapContended = false


    /// Set to true when the session's JSONL was non-empty at spawn, i.e.
    /// this is a resume with prior conversation. Seeds the eligibility gate
    /// so a resumed-and-parked session earns a recap without the user having
    /// to type first — the exact case the feature exists for.
    private var hasHistoricConversation = false

    /// Recap eligibility accounting.
    ///
    /// The CLI gates its away summary on ≥3 prompts in the session and ≥2
    /// since the previous summary, because a terminal is something you sit
    /// in front of — three exchanges in, a summary is finally telling you
    /// something you didn't just watch scroll past. A Canopy pane is the
    /// opposite: it gets opened, handed one large task, and parked. Gating
    /// on three prompts would reject exactly the session a returning user
    /// most needs summarised, so the total gate is 1 — any session that has
    /// been given work at all qualifies, and the since-last-recap gate is
    /// likewise 1.
    private var recapGate = RecapGate()

    /// True when this shim is idle and has accumulated enough conversation
    /// for a recap to say anything useful. The last-line guard inside
    /// `requestRecap`; callers that want a log line read
    /// `recapIneligibilityReason` instead.
    var canRequestRecap: Bool { recapIneligibilityReason == nil }

    /// Which gate rejected the recap, or nil when eligible. Split out from
    /// `canRequestRecap` because a bare false across five conditions is
    /// undiagnosable from the logs — "recap fired for 0/1 panes" tells you
    /// nothing about whether the session was busy, brand new, or missing a
    /// channel. Ordered cheapest-and-most-common first.
    var recapIneligibilityReason: String? {
        if channelId == nil { return "no channelId (session not launched yet)" }
        if isWorking { return "session busy" }
        if recapRequestInFlight { return "recap already in flight" }
        return recapGate.ineligibilityReason(
            hasHistoricConversation: hasHistoricConversation,
            isRemote: remoteHost != nil
        )
    }

    /// Optional OpenSession that owns this shim. Set by WebViewContainer
    /// after spawn so isWorking transitions reach the sidebar's icon.
    ///
    /// didSet re-syncs the session's asking flag against this shim's current
    /// internal state. On SSH reconnect a fresh shim inherits an existing
    /// OpenSession whose `isAsking` may still be true from the previous (now
    /// dead) shim — without this sync the raised-hand icon would linger
    /// until something else triggered `refreshAskingState`.
    weak var boundSession: OpenSession? {
        didSet {
            refreshAskingState()
            refreshWaitingState()
        }
    }

    /// In-flight `tool_permission_request` ids from extension → webview.
    /// When non-empty the user is being asked to approve something; the
    /// sidebar shows a "raised hand" icon while at least one is outstanding.
    private var pendingPermissionRequestIds = Set<String>()

    /// Subset of `pendingPermissionRequestIds` whose `toolName` is
    /// `AskUserQuestion`. Tracked separately so resolving/cancelling an
    /// AskUserQuestion request can immediately clear
    /// `lastAssistantHadAskUserQuestion` instead of waiting for the next
    /// turn's `message_start` stream event.
    private var pendingAskUserQuestionRequestIds = Set<String>()

    var statusBarData: StatusBarData?
    weak var delegate: ShimProcessDelegate?
    private var isIntentionalStop = false

    /// The model string the CLI resolved for this session, taken from the
    /// `system` / `init` event. This is the key space `result.modelUsage` is
    /// keyed by, which is why the context-meter lookup uses it rather than
    /// `StatusBarData.model`. See `mainModelUsage` for the measurements.
    ///
    /// Empty until the first `init` arrives. The CLI re-emits `init` on a
    /// mid-session `/model` switch (measured), so this tracks the current
    /// model rather than only the launch one.
    private var cliResolvedModel: String = ""

    @MainActor
    init(workingDirectory: URL, resumeSessionId: String? = nil, model: String? = nil, effortLevel: String? = nil, permissionMode: PermissionMode = .acceptEdits, sessionTitle: String? = nil, statusBarData: StatusBarData? = nil, remoteHost: String? = nil, customApi: ModelProvider? = nil) {
        self.workingDirectory = workingDirectory
        self.resumeSessionId = resumeSessionId
        self.model = model
        self.effortLevel = effortLevel
        self.permissionMode = permissionMode
        self.sessionTitle = sessionTitle ?? ""
        self.statusBarData = statusBarData
        self.remoteHost = remoteHost
        self.customApi = customApi
        if let resumeSessionId,
           let savedTitle = SessionTitleStore.title(forSessionId: resumeSessionId),
           !savedTitle.isEmpty
        {
            let truncated = Self.truncatedTitle(savedTitle)
            self.sessionTitle = truncated
            self.generatedSessionTitle = truncated
            self.hasGeneratedTitle = true
            // Allow one regeneration on the first new prompt so the title
            // can incorporate the resumed conversation direction.
            self.titleIsFallback = true
        }
        if let resumeSessionId {
            // Seed title-generation context from the resumed conversation.
            // Without this the first post-resume prompt ("continue", "restart
            // server") is the only input and produces junk titles.
            self.promptHistory = Self.trimmedPromptHistory(
                ClaudeSessionHistory.loadUserPrompts(
                    sessionId: resumeSessionId, directory: workingDirectory
                )
            )
        }
        super.init()
        Self.instances.add(self)
        // Set CLI version, VCS branch, initial message count, and remote host
        statusBarData?.cliVersion = CCExtension.extensionVersion() ?? ""
        statusBarData?.remoteHost = remoteHost
        let dir = workingDirectory
        nonisolated(unsafe) let barData = statusBarData
        DispatchQueue.global(qos: .utility).async {
            guard let vcsInfo = Self.detectVCSInfo(at: dir) else { return }
            DispatchQueue.main.async {
                barData?.vcsType = vcsInfo.type
                barData?.gitBranch = vcsInfo.branch
            }
        }
        // Restore cached context limits for immediate display on session resume
        let cachedMax = UserDefaults.standard.integer(forKey: Self.contextMaxKey(workingDirectory))
        if cachedMax > 0 { statusBarData?.contextMax = cachedMax }
        let cachedMaxOutput = UserDefaults.standard.integer(forKey: Self.maxOutputTokensKey(workingDirectory))
        if cachedMaxOutput > 0 { statusBarData?.maxOutputTokens = cachedMaxOutput }
        // Drop the retired pre-#108 keys for this directory as we pass them.
        // Nothing reads them any more. This only reaches directories that get
        // opened again, so one never revisited keeps its dead pair regardless
        // — the sweep is opportunistic, not a migration.
        UserDefaults.standard.removeObject(forKey: "statusBar.contextMax.\(workingDirectory.path)")
        UserDefaults.standard.removeObject(forKey: "statusBar.maxOutputTokens.\(workingDirectory.path)")
        if let sessionId = resumeSessionId {
            statusBarData?.messageCount = ClaudeSessionHistory.countMessages(
                sessionId: sessionId, directory: workingDirectory
            )
            // Snapshot every historic `toolu_…` id in the existing JSONL so
            // `detectBackgroundTaskLaunch` can skip CLI replays of already-
            // logged assistant messages instead of tracking their bg ids as
            // "live" — see `historicToolUseIds` doc for the full rationale.
            //
            // Remote (SSH) sessions write JSONL on the other machine, so the
            // local path is unreachable — fall back to the empty set. The
            // visible impact is bounded: replayed turns self-clean because
            // the CLI re-emits each historic `result`, which freezes any
            // still-running rows and the following `message_start` clears
            // them. The residual flicker is limited to the *last* incomplete
            // turn's bg Agent rows — they stay "running" until the user's
            // next input triggers a fresh `message_start`. A proper fix
            // would need an SSH round-trip to snapshot the remote JSONL at
            // spawn time; deferred, since the current trade-off is small.
            //
            // The read runs off the main actor so a multi-MB session doesn't
            // stall the sidebar's click-to-open. The CLI needs several hundred
            // ms to boot Node, activate the extension, and start streaming
            // replay events; by the time the first replayed assistant
            // io_message arrives the historic set is normally populated. If a
            // detection genuinely races the loader, the completion continuation
            // purges any id it turns out to have been historic — bounded
            // flicker instead of stuck-forever.
            if remoteHost == nil,
               let path = Self.jsonlPath(
                   sessionId: sessionId, workingDirectory: workingDirectory
               )
            {
                self.historicJsonlBound = Self.jsonlFileSize(path: path) ?? 0
                let bound = self.historicJsonlBound
                // A non-empty JSONL at spawn means this is a resumed session
                // with prior conversation, which is all the recap gate needs
                // to know (it compares against 1). Deliberately NOT read via
                // `ClaudeSessionHistory.loadUserPrompts`: that parses with
                // `replacingOccurrences(options: .regularExpression)`, and
                // CLAUDE.md documents `NSRegularExpression` on a background
                // `DispatchQueue` as a hard crash on macOS 26 — this whole
                // block runs on `bgHistoricLoadQueue`. The size read already
                // happened synchronously on the main thread above, so the
                // seed costs nothing extra and opens no new failure path.
                self.hasHistoricConversation = bound > 0
                if bound == 0 {
                    logger.debug("recap seed: JSONL empty at spawn — treating as a new session")
                }
                Self.bgHistoricLoadQueue.async { [weak self] in
                    let ids = Self.extractToolUseIds(fromPath: path, upToOffset: bound)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.historicToolUseIds = ids
                        // Same historic gate for the subagent activity list —
                        // `loadHistoricIds` atomically installs the set and
                        // returns the number of live rows purged (rows that
                        // raced in as "live" before the loader landed).
                        let subagentPurged = self.subagentTracker.loadHistoricIds(ids)
                        if subagentPurged > 0 {
                            self.statusBarData?.subagents = self.subagentTracker.rows
                        }
                        // Race-window reconcile: if a replayed assistant
                        // io_message arrived before the loader completed,
                        // its id is now in `pendingBackgroundTaskIds` even
                        // though the JSONL knew about it all along. Drop
                        // those entries so the hourglass clears instead of
                        // sticking on a ghost. Live ids launched by the
                        // current shim's own turns are, by construction,
                        // NOT in `ids` (they were written after `bound`).
                        var purged = 0
                        var subagentTransitioned = false
                        for id in Array(self.pendingBackgroundTaskIds.keys)
                        where ids.contains(id)
                        {
                            self.pendingBackgroundTaskIds.removeValue(forKey: id)
                            self.bgTaskIdMap.removeValue(forKey: id)
                            if self.subagentTracker.completeIfPresent(id: id, at: Date()) {
                                subagentTransitioned = true
                            }
                            purged += 1
                        }
                        if purged > 0 {
                            self.refreshWaitingState()
                        }
                        if subagentTransitioned {
                            self.statusBarData?.subagents = self.subagentTracker.rows
                        }
                        // `path` names the user's filesystem, and `notice`
                        // (unlike the `info` this was) persists to disk and
                        // into any sysdiagnose — so it drops to `.private`
                        // while the counts, which are what the line is read
                        // for, stay `.public`. Applied to every `[bg]` line
                        // carrying a path rather than only this one: the
                        // `warning`s persist identically, and a rule visible
                        // on one line and not its neighbour reads as an
                        // oversight rather than a decision.
                        logger.notice("[bg] historic toolu ids loaded count=\(ids.count, privacy: .public) purged=\(purged, privacy: .public) subagentPurged=\(subagentPurged, privacy: .public) subagentTransitioned=\(subagentTransitioned, privacy: .public) bound=\(bound, privacy: .public) path=\(path, privacy: .private)")
                    }
                }
            }
        }
    }

    /// Serial background queue for the init-time historic-id snapshot.
    /// Serial so concurrent session opens don't stack multi-MB disk reads
    /// onto the storage subsystem at once; `.utility` matches the
    /// surrounding non-critical init work (VCS branch detection uses the
    /// global utility queue).
    private static let bgHistoricLoadQueue = DispatchQueue(
        label: "sh.saqoo.Canopy.bgHistoricLoadQueue", qos: .utility
    )

    // MARK: - Lifecycle

    /// Start the Node.js shim subprocess. Returns false if startup fails.
    @discardableResult
    func start() -> Bool {
        guard process == nil else {
            logger.warning("start() called while already running")
            return true
        }

        guard let nodeInfo = NodeDiscovery.find() else {
            logger.error("Cannot start shim: Node.js >= 18 not found")
            showErrorInWebView("Node.js >= 18 not found. Install via Homebrew, mise, or nvm.")
            return false
        }

        guard let shimPath = Self.findShimPath() else {
            logger.error("Cannot find vscode-shim/index.js")
            showErrorInWebView("vscode-shim not found in app bundle.")
            return false
        }

        guard let extensionPath = CCExtension.extensionPath()?.path else {
            logger.error("Cannot start shim: CC extension not found")
            showErrorInWebView("Claude Code extension not found. Install it in VSCode first.")
            return false
        }

        // Verify the working directory exists before starting the shim.
        // Skip for SSH remote sessions — the path is on the remote machine.
        if remoteHost == nil {
            let cwdPath = workingDirectory.path
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: cwdPath, isDirectory: &isDir) || !isDir.boolValue {
                logger.error("Working directory does not exist: \(cwdPath, privacy: .public)")
                showErrorInWebView("Directory not found: \(cwdPath)")
                return false
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeInfo.path)

        var args = [shimPath, "--extension-path", extensionPath, "--cwd", workingDirectory.path]
        if let sessionId = resumeSessionId {
            args.append(contentsOf: ["--resume", sessionId])
        }
        args.append(contentsOf: ["--permission-mode", permissionMode.rawValue])
        args.append(contentsOf: ["--settings-path", CanopySettings.shared.filePath.path])
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path

        // Ensure PATH includes directories where tools like rg (ripgrep) live.
        // macOS GUI apps inherit a minimal PATH (/usr/bin:/bin:...). We prepend the
        // Node.js binary's directory (which may come from mise/nvm) and Homebrew paths.
        // The CC extension uses system rg for @-mention file listing with gitignore support.
        let nodeBinDir = (nodeInfo.path as NSString).deletingLastPathComponent
        var extraPaths = [nodeBinDir]
        // Homebrew (Apple Silicon and Intel)
        for p in ["/opt/homebrew/bin", "/usr/local/bin"] {
            if !extraPaths.contains(p) { extraPaths.append(p) }
        }
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existingPaths = Set(currentPath.split(separator: ":").map(String.init))
        let newPaths = extraPaths.filter { !existingPaths.contains($0) }
        if !newPaths.isEmpty {
            env["PATH"] = (newPaths + [currentPath]).joined(separator: ":")
        }

        // Write model/effort to ~/.claude/settings.json before CLI starts.
        // Remote sessions skip this: the CLI runs on the remote host and reads
        // the remote ~/.claude/settings.json, so a local write only pollutes
        // local defaults. The selection travels via CANOPY_REMOTE_MODEL/EFFORT
        // env vars instead, which ssh-claude-wrapper.sh turns into --model /
        // --effort CLI flags on the remote command line.
        if remoteHost == nil {
            Self.applyClaudeSettings([("model", model), ("effortLevel", effortLevel)])
        } else {
            if let model, !model.isEmpty { env["CANOPY_REMOTE_MODEL"] = model }
            if let effortLevel, !effortLevel.isEmpty { env["CANOPY_REMOTE_EFFORT"] = effortLevel }
        }

        // Pin the standard 200K context tier when the user picked a non-1M Opus model.
        // For 1M-eligible accounts the CLI force-appends "[1m]" to ANY opus model at
        // runtime (observed in the CC CLI ~2.1.x via internal, minified symbols — the
        // 1M-eligibility gate and the opus-id rewriter; names change every bundle, so
        // they're not cited here), so the model string alone — even the explicit
        // "claude-opus-4-8" — still resolves to the 1M variant. CLAUDE_CODE_DISABLE_1M_CONTEXT=1
        // turns that auto-upgrade off for this process. Scoped to opus (the only family
        // with this runtime upgrade) and skipped for "[1m]" selections so 1M still works.
        // For SSH remote sessions, ssh-claude-wrapper.sh forwards this var to the remote.
        if customApi == nil, let model, model.contains("opus"), !model.contains("[1m]") {
            env["CLAUDE_CODE_DISABLE_1M_CONTEXT"] = "1"
        }

        // SSH remote: pass wrapper path via env var (per-shim, not the shared
        // settings file). Writing to the settings file caused cross-window
        // interference and broke /resume when the wrapper was eagerly cleared
        // after the first CLI spawn.
        if let remote = remoteHost {
            guard let wrapperPath = Self.findWrapperPath() else {
                logger.error("SSH remote: wrapper script not found in bundle")
                showErrorInWebView("SSH remote mode failed: wrapper script not found. Try reinstalling Canopy.")
                return false
            }
            env["CANOPY_SSH_HOST"] = remote
            env["CANOPY_SSH_CWD"] = workingDirectory.path
            env["CANOPY_SSH_WRAPPER_PATH"] = wrapperPath
            // Ensure wrapper has execute permission (Xcode may strip +x on copy)
            if !FileManager.default.isExecutableFile(atPath: wrapperPath) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)
            }
            logger.info("SSH remote mode: host=\(remote, privacy: .public) wrapper=\(wrapperPath, privacy: .public)")
        } else {
            // Local session: clear any ssh-claude-wrapper.sh left in the shared
            // settings file by pre-env-var Canopy builds, so the CLI spawns
            // directly. User-configured custom wrappers are preserved.
            CanopySettings.shared.clearStaleSSHWrapper()
        }

        // Custom API Provider: inject env vars before CLI starts.
        // These are read by the Claude CLI directly (ANTHROPIC_BASE_URL,
        // ANTHROPIC_AUTH_TOKEN, etc.) and map Anthropic model aliases to
        // third-party model ids.
        if let api = customApi, api.isEnabled {
            env["ANTHROPIC_BASE_URL"] = api.baseURL
            env["ANTHROPIC_AUTH_TOKEN"] = api.authToken.isEmpty ? "" : api.authToken
            // Remove inherited Anthropic key so it never leaks to a custom API endpoint
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            if !api.opusModel.isEmpty { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = api.opusModel }
            if !api.sonnetModel.isEmpty { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = api.sonnetModel }
            if !api.haikuModel.isEmpty { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = api.haikuModel }
            if !api.subagentModel.isEmpty { env["CLAUDE_CODE_SUBAGENT_MODEL"] = api.subagentModel }
            logger.info("Custom API: baseURL=\(api.baseURL, privacy: .private) opus=\(api.opusModel, privacy: .public) sonnet=\(api.sonnetModel, privacy: .public) haiku=\(api.haikuModel, privacy: .public) subagent=\(api.subagentModel, privacy: .public)")
        }

        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        // Read stdout — NDJSON from shim
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // Only disable on true EOF (process exited). Spurious empty reads
                // from a still-running process would permanently kill the handler.
                if self?.process?.isRunning != true {
                    handle.readabilityHandler = nil
                }
                return
            }
            self?.handleStdoutData(data)
        }

        // Read stderr — shim logs + CLI exit detection
        // Use nonisolated(unsafe) to satisfy Sendable requirements — the closure
        // only dispatches to main thread, never accesses self directly.
        nonisolated(unsafe) let weakSelf = self
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                for line in str.split(separator: "\n") {
                    logger.info("[shim] \(line, privacy: .public)")
                    // Detect CLI subprocess exit from extension error log
                    if line.contains("process exited with code") || line.contains("process terminated by signal") {
                        let lineStr = String(line)
                        DispatchQueue.main.async {
                            weakSelf.handleCLISubprocessExit(lineStr)
                        }
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] process in
            logger.info("Shim exited with status \(process.terminationStatus)")
            let pid = process.processIdentifier
            // Best-effort descendant cleanup — some may already be reparented to launchd.
            // Only needed for unexpected exits (stop() collects them before terminating).
            let orphans = Self.collectDescendants(of: pid)
            if !orphans.isEmpty {
                logger.info("Found \(orphans.count) orphan descendants after shim exit: \(orphans)")
                Self.killProcessTree(orphans)
            }
            DispatchQueue.main.async {
                self?.handleProcessExit(status: process.terminationStatus, pid: pid)
            }
        }

        do {
            try proc.run()
            logger.info("Shim started: PID \(proc.processIdentifier), node=\(nodeInfo.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to start shim: \(error.localizedDescription, privacy: .public)")
            showErrorInWebView("Failed to start Node.js: \(error.localizedDescription)")
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            return false
        }
    }

    func stop() {
        isIntentionalStop = true
        guard let proc = process, proc.isRunning else { return }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()

        // Collect entire process tree BEFORE terminating parent (pgrep -P fails after parent exits)
        descendantPids = Self.collectDescendants(of: proc.processIdentifier)
        proc.terminate()

        // Kill all descendants: SIGTERM first, SIGKILL after brief wait
        Self.killProcessTree(descendantPids)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard var dict = message.body as? [String: Any] else { return }

        // Webview → host responses to permission requests close out the
        // `isAsking` flag on the bound OpenSession.
        trackPermissionResponse(dict)

        // Override permission mode in launch_claude from Canopy app settings
        if dict["type"] as? String == "launch_claude" {
            dict["permissionMode"] = permissionMode.rawValue

            let channelId = dict["channelId"] as? String ?? ""
            self.channelId = channelId.isEmpty ? nil : channelId
            let statusMsg: [String: Any] = [
                "type": "from-extension",
                "message": [
                    "type": "io_message",
                    "channelId": channelId,
                    "message": [
                        "type": "system",
                        "subtype": "status",
                        "permissionMode": permissionMode.rawValue,
                    ] as [String: Any],
                    "done": false,
                ] as [String: Any],
            ]
            sendToWebView(statusMsg)


            // Request initial rate limit data after a short delay (extension needs time to activate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.requestUsageUpdate()
            }
        }

        // Backstop: any webview→host message scoped to a running Claude
        // session (io_message, request, interrupt_claude, etc.) carries
        // channelId on the top-level dict. Channel-agnostic messages (init,
        // get_claude_state, get_asset_uris, list_sessions) don't, and the
        // !cid.isEmpty guard correctly skips them. If `launch_claude` failed
        // to set channelId for any reason, the next channel-scoped message
        // recovers it; without this, `requestSessionTitle`'s nil-guard would
        // silently disable title generation for the session's whole lifetime.
        // First non-empty channelId wins; once set, only the launch_claude
        // handler above is allowed to replace it.
        if self.channelId == nil,
           let cid = dict["channelId"] as? String, !cid.isEmpty
        {
            let msgType = dict["type"] as? String ?? "?"
            logger.info(
                "channelId recovered via backstop from \(msgType, privacy: .public) message"
            )
            self.channelId = cid
        }

        var titleRequestDescriptionAfterForward: String?

        // Start spinner when user sends a message and capture title text.
        if dict["type"] as? String == "io_message",
           let ioMsg = dict["message"] as? [String: Any],
           ioMsg["type"] as? String == "user"
        {
            isWorking = true

            // A real prompt supersedes whatever the recap said — the user is
            // back and driving. Counters gate the next recap (see
            // `canRequestRecap`); they only advance on genuine webview→host
            // prompts, so Canopy's own injected `/recap` (which never passes
            // through this handler) can't unlock itself.
            statusBarData?.recap = nil
            showRecapInWebView(nil)
            recapGate.noteUserTurn()
            if recapRequestInFlight, !recapContended {
                // Their submission can produce its own `<synthetic>` output.
                // From here the recap gives up its claim on that shape.
                recapContended = true
                logger.info("recap: user submitted mid-flight — capture disarmed")
            }

            // Capture this user message's text for title generation.
            var userText: String?
            if let userMsg = ioMsg["message"] as? [String: Any] {
                if let content = userMsg["content"] as? [[String: Any]] {
                    let extracted = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !extracted.isEmpty { userText = extracted }
                } else if let text = userMsg["content"] as? String, !text.isEmpty {
                    userText = text
                }
            }

            // Generate a title for the first user prompt (or first after a
            // fallback). Once an AI title is acquired, further prompts skip
            // generation unless the current title is only a fallback.
            if let userText {
                promptHistory.append(userText)
                promptHistory = Self.trimmedPromptHistory(promptHistory)
                lastUserMessageText = userText
                titleRequestDescriptionAfterForward = userText
            }
        }

        // Intercept requests from webview
        if var request = dict["request"] as? [String: Any],
           let reqType = request["type"] as? String
        {
            // Handle open_file: read file and show in ContentViewer directly.
            // open_content: show provided content in ContentViewer.
            if reqType == "open_file" {
                handleOpenFile(request, requestId: dict["requestId"] as? String)
                return
            }
            if reqType == "open_content" {
                handleOpenContent(request, requestId: dict["requestId"] as? String)
                return
            }

            if reqType == "generate_session_title",
               let requestId = dict["requestId"] as? String,
               !requestId.hasPrefix("canopy-title-"),
               let description = request["description"] as? String,
               !description.isEmpty
            {
                request["description"] = titleGenerationDescription(for: description)
                request["persist"] = false
            }

            if reqType == "rename_tab" || reqType == "update_session_state" {
                // Track session ID for title persistence.
                if let sid = request["sessionId"] as? String, UUID(uuidString: sid) != nil {
                    activeSessionId = sid
                    backfillResumeId(sid)
                    // Save any title that was generated before we had a session ID.
                    if let pending = pendingGeneratedTitle {
                        SessionTitleStore.save(title: pending, forSessionId: sid)
                        generatedSessionTitle = pending
                        pendingGeneratedTitle = nil
                    }
                }
                if let title = request["title"] as? String, !title.isEmpty {
                    let truncated = Self.truncatedTitle(title)
                    // Once an AI title (or fallback) has been applied, block
                    // raw webview titles — the extension keeps re-sending its
                    // stale internal title and would otherwise overwrite. Patch
                    // the request before forwarding so the extension host also
                    // sees Canopy's canonical title.
                    if hasGeneratedTitle, let generatedSessionTitle {
                        if truncated != generatedSessionTitle {
                            logger.debug("Ignoring stale webview title '\(truncated, privacy: .public)'; keeping '\(generatedSessionTitle, privacy: .public)'")
                        }
                        request["title"] = generatedSessionTitle
                        updateWindowTitle(generatedSessionTitle)
                        if let sid = activeSessionId ?? resumeSessionId {
                            SessionTitleStore.save(title: generatedSessionTitle, forSessionId: sid)
                        }
                    } else if !hasGeneratedTitle {
                        updateWindowTitle(truncated)
                    }
                }
            }

            dict["request"] = request
        }

        sendToShim(["type": "webview_message", "message": dict])
        if let titleRequestDescriptionAfterForward {
            requestSessionTitle(description: titleRequestDescriptionAfterForward)
        }
    }

    /// The CLI ignores a `--resume` id that has no JSONL on disk (launcher-born
    /// sessions pass a freshly generated UUID) and picks its own session id.
    /// Called whenever the webview reports a session id (`update_session_state`
    /// or `rename_tab` — both carry `sessionId` through the same handler).
    /// Sync the real id back onto the owning OpenSession so the sidebar's
    /// open-vs-recents dedup and `openLocal`'s already-open check compare
    /// against the JSONL that actually exists — otherwise the same session
    /// shows twice (Open + Recents) and can be opened twice.
    private func backfillResumeId(_ sid: String) {
        guard let session = boundSession, session.resumeId != sid else { return }
        let stale = session.resumeId
        session.resumeId = sid
        logger.info("backfillResumeId \(stale, privacy: .public) -> \(sid, privacy: .public)")
        // A title generated before this first session-id report was saved
        // under the placeholder id (`activeSessionId ?? resumeSessionId`
        // fell through to the placeholder) — carry it over to the real id.
        SessionTitleStore.migrate(fromSessionId: stale, toSessionId: sid)
        if let store = SessionStore.shared, store.lastActiveResumeId == stale {
            store.lastActiveResumeId = sid
            SessionStorePersistence.saveLastActiveResumeId(sid)
        }
    }

    // MARK: - WebView Ready

    func webViewDidFinishLoad() {
        sendToShim(["type": "webview_ready"])

        // Force webview permission mode UI after a short delay
        // (webview needs time to process init_response first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.syncPermissionModeToWebView()
        }
    }

    private func syncPermissionModeToWebView() {
        // NOTE: Do NOT send synthetic update_state here — it would reset authStatus to null
        // because update_state handler does: this.authStatus.value = state.authStatus ?? null.
        // Permission mode sync is handled via synthetic system/status io_message in
        // the launch_claude intercept.
        logger.info("Permission mode will sync via system/status on launch_claude")
    }

    // MARK: - Claude Settings

    /// Write or remove multiple keys in ~/.claude/settings.json atomically (single read-modify-write).
    private static func applyClaudeSettings(_ pairs: [(key: String, value: String?)]) {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let path = claudeDir.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        var dict: [String: Any] = (try? Data(contentsOf: path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for (key, value) in pairs {
            if let value {
                dict[key] = value
            } else {
                dict.removeValue(forKey: key)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path)
        }
        let desc = pairs.map { "\($0.key)=\($0.value ?? "nil")" }.joined(separator: ", ")
        logger.info("Applied ~/.claude/settings.json: \(desc, privacy: .public)")
    }

    // MARK: - Shim Path Discovery

    nonisolated static func findShimPath() -> String? {
        // 1. Bundle resources (production — after Task 13 bundles vscode-shim)
        if let bundled = Bundle.main.path(forResource: "index", ofType: "js", inDirectory: "vscode-shim") {
            return bundled
        }

        // 2. Development fallback: navigate from this source file to Resources/vscode-shim/
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()   // Sources/Canopy/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // project root
        let devPath = projectRoot.appendingPathComponent("Resources/vscode-shim/index.js").path
        if FileManager.default.fileExists(atPath: devPath) {
            logger.info("Using development shim: \(devPath, privacy: .public)")
            return devPath
        }

        return nil
    }

    private static func findWrapperPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "ssh-claude-wrapper", ofType: "sh") {
            return bundled
        }
        // Development fallback
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devPath = projectRoot.appendingPathComponent("Resources/ssh-claude-wrapper.sh").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }

    // MARK: - stdout NDJSON Parsing

    /// Called from the stdout readabilityHandler thread. Accumulates data and
    /// extracts complete NDJSON lines, dispatching parsed messages to the main thread.
    private func handleStdoutData(_ data: Data) {
        stdoutBuffer.append(data)

        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else { continue }

            guard let jsonData = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = msg["type"] as? String
            else {
                let preview = String(data: lineData.prefix(200), encoding: .utf8) ?? "<binary>"
                logger.warning("Failed to parse shim NDJSON: \(preview, privacy: .public)")
                continue
            }

            let preview = String(line.prefix(120))
            logger.debug("[stdout] type=\(type, privacy: .public) preview=\(preview, privacy: .public)")

            DispatchQueue.main.async { [weak self] in
                self?.handleShimMessage(type: type, msg: msg)
            }
        }
    }

    // MARK: - Message Handling

    private func handleShimMessage(type: String, msg: [String: Any]) {
        switch type {
        case "ready":
            isReady = true
            logger.info("Shim ready, flushing \(self.pendingMessages.count) pending messages")
            for pending in pendingMessages {
                writeToStdin(pending)
            }
            pendingMessages.removeAll()

        case "webview_message":
            guard var innerMessage = msg["message"] as? [String: Any] else {
                logger.warning("webview_message with no 'message' field")
                return
            }
            let innerType = (innerMessage["type"] as? String) ?? "?"
            logger.debug("[stdout→webview] type=\(innerType, privacy: .public)")
            // Must run ahead of every tracker below: the recap turn reports
            // zeroed usage and an untagged `result`, which would otherwise
            // blank the context bar and freeze the subagent list.
            if consumeRecapTraffic(innerMessage) {
                return
            }
            innerMessage = Self.strippingRecapFromReplay(innerMessage)
            innerMessage = patchAuthIfNeeded(innerMessage)
            trackWorkingState(innerMessage)
            trackPermissionState(stdoutMessage: msg)
            extractStatusData(innerMessage)
            extractTitle(innerMessage)
            extractRawUsage(innerMessage)
            if Self.isCanopyOwnedResponse(innerMessage) {
                return
            }
            sendToWebView(innerMessage)

        case "show_document":
            if let content = msg["content"] as? String {
                let fileName = msg["fileName"] as? String ?? "output"
                ContentViewer.show(content: content, title: fileName, in: webView)
            }

        case "show_notification":
            handleNotification(msg)

        case "open_url":
            if let urlStr = msg["url"] as? String, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }

        case "open_terminal":
            openTerminal(msg)

        case "log":
            let level = msg["level"] as? String ?? "info"
            let message = msg["msg"] as? String ?? ""
            logger.info("[shim:\(level, privacy: .public)] \(message, privacy: .public)")

        case "error":
            let message = msg["message"] as? String ?? "Unknown error"
            let stack = msg["stack"] as? String
            logger.error("Shim error: \(message, privacy: .public)")
            if let stack { logger.error("Stack: \(stack, privacy: .public)") }

        default:
            logger.info("Unknown shim message: \(type, privacy: .public)")
        }
    }

    // MARK: - Host Events

    private func handleNotification(_ msg: [String: Any]) {
        guard let message = msg["message"] as? String,
              let requestId = msg["requestId"] as? String
        else {
            logger.warning("Malformed notification from shim: missing message or requestId")
            return
        }

        let severity = msg["severity"] as? String ?? "info"
        let buttons = msg["buttons"] as? [String] ?? []

        let alert = NSAlert()
        alert.messageText = message
        switch severity {
        case "error": alert.alertStyle = .critical
        case "warning": alert.alertStyle = .warning
        default: alert.alertStyle = .informational
        }
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        let buttonIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let buttonValue: Any
        if buttonIndex < buttons.count {
            buttonValue = buttons[buttonIndex]
        } else {
            buttonValue = NSNull()
        }

        sendToShim([
            "type": "notification_response",
            "requestId": requestId,
            "buttonValue": buttonValue,
        ])
    }

    /// Handle open_file request from webview. By default shows the file in ContentViewer
    /// instead of forwarding to extension (which triggers file:// navigation → WebContent crash).
    /// When `openExternal` is true (set by Cmd-click), opens in the macOS default app.
    private func handleOpenFile(_ request: [String: Any], requestId: String?) {
        let location = request["location"] as? [String: Any]
        let openExternal = request["openExternal"] as? Bool == true

        // Extract file path: CC extension sends filePath at top level of the request,
        // location sub-dict may contain uri/line/col for positioning.
        var rawPath = request["filePath"] as? String
            ?? request["uri"] as? String
            ?? location?["uri"] as? String
            ?? location?["filePath"] as? String
            ?? location?["path"] as? String
            ?? location?["file"] as? String
        if let s = rawPath, s.hasPrefix("file://") {
            rawPath = URL(string: s)?.path ?? String(s.dropFirst(7))
        }

        if let filePath = rawPath {
            let url: URL
            if filePath.hasPrefix("/") {
                url = URL(fileURLWithPath: filePath)
            } else {
                url = workingDirectory.appendingPathComponent(filePath)
            }
            // Resolve symlinks and ensure the file is under the working directory (prevent path traversal)
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let wdResolved = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(wdResolved.path + "/") || resolved.path == wdResolved.path else {
                logger.warning("handleOpenFile: path traversal blocked: \(resolved.path, privacy: .public)")
                if let requestId {
                    sendToWebView([
                        "type": "response",
                        "requestId": requestId,
                        "response": ["type": "open_file_response"] as [String: Any],
                    ] as [String: Any])
                }
                return
            }
            if FileManager.default.fileExists(atPath: resolved.path) {
                if openExternal {
                    logger.info("handleOpenFile: opening externally (Cmd-click): \(resolved.path, privacy: .public)")
                    if !NSWorkspace.shared.open(resolved) {
                        logger.warning("handleOpenFile: NSWorkspace failed to open: \(resolved.path, privacy: .public)")
                    }
                } else {
                    do {
                        let content = try String(contentsOf: resolved, encoding: .utf8)
                        let startLine = location?["startLine"] as? Int
                        let endLine = location?["endLine"] as? Int
                        logger.info("handleOpenFile: showing in ContentViewer: \(resolved.lastPathComponent, privacy: .public) line:\(startLine ?? 0, privacy: .public)-\(endLine ?? 0, privacy: .public)")
                        ContentViewer.show(content: content, title: resolved.lastPathComponent, in: webView, startLine: startLine, endLine: endLine)
                    } catch {
                        logger.info("handleOpenFile: not UTF-8 text (\(error.localizedDescription, privacy: .public)), opening externally")
                        if !NSWorkspace.shared.open(resolved) {
                            logger.warning("handleOpenFile: NSWorkspace failed to open: \(resolved.path, privacy: .public)")
                        }
                    }
                }
            } else {
                logger.warning("handleOpenFile: file does not exist: \(resolved.path, privacy: .public)")
            }
        } else {
            logger.warning("handleOpenFile: no file path in location keys: \(location?.keys.sorted().description ?? "nil", privacy: .public)")
        }

        // Send response so the webview doesn't hang waiting (fire-and-forget if no requestId)
        if let requestId {
            sendToWebView([
                "type": "response",
                "requestId": requestId,
                "response": ["type": "open_file_response"] as [String: Any],
            ] as [String: Any])
        }
    }

    /// Handle open_content request — show provided content directly in ContentViewer.
    private func handleOpenContent(_ request: [String: Any], requestId: String?) {
        let content = request["content"] as? String ?? ""
        let fileName = request["fileName"] as? String ?? "untitled"
        ContentViewer.show(content: content, title: fileName, in: webView)

        if let requestId {
            sendToWebView([
                "type": "response",
                "requestId": requestId,
                "response": ["type": "open_content_response", "updatedContent": content] as [String: Any],
            ] as [String: Any])
        }
    }

    private func openTerminal(_ msg: [String: Any]) {
        let shellPath = msg["shellPath"] as? String
        let shellArgs = msg["shellArgs"] as? [String] ?? []
        let cwdPath = workingDirectory.path

        var parts = ["cd", shellQuote(cwdPath)]
        if let shellPath {
            parts.append("&&")
            parts.append(shellQuote(shellPath))
            for arg in shellArgs {
                parts.append(shellQuote(arg))
            }
        }
        let command = parts.joined(separator: " ")

        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            logger.error("Failed to open terminal: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Auth State Cache

    /// Intercept messages to inject authStatus from Keychain and override permission/experiment settings.
    private func patchAuthIfNeeded(_ message: [String: Any]) -> [String: Any] {
        guard message["type"] as? String == "from-extension",
              var nested = message["message"] as? [String: Any]
        else { return message }

        // Patch update_state: override permission/experiment settings but do NOT inject authStatus.
        // The extension controls authStatus in update_state — injecting keychain auth here
        // would prevent /login and "Switch Account" from showing the login screen.
        if var request = nested["request"] as? [String: Any],
           request["type"] as? String == "update_state",
           var state = request["state"] as? [String: Any]
        {
            state["initialPermissionMode"] = permissionMode.rawValue
            state["allowDangerouslySkipPermissions"] = CanopySettings.shared.allowDangerouslySkipPermissions
            state["isOnboardingDismissed"] = true
            var gates = (state["experimentGates"] as? [String: Any]) ?? [:]
            gates["tengu_vscode_cc_auth"] = true
            state["experimentGates"] = gates
            request["state"] = state
            nested["request"] = request
            var patchedMessage = message
            patchedMessage["message"] = nested
            return patchedMessage
        }

        // Patch init_response: inject authStatus from Keychain if missing, permission mode, skipPermissions
        if var response = nested["response"] as? [String: Any],
           response["type"] as? String == "init_response",
           var state = response["state"] as? [String: Any]
        {
            logger.info("init_response state from extension: initialPermissionMode=\(state["initialPermissionMode"] as? String ?? "nil", privacy: .public) allowSkip=\(state["allowDangerouslySkipPermissions"] as? Bool ?? false, privacy: .public)")
            if state["authStatus"] == nil || state["authStatus"] is NSNull {
                if let keychainAuth = KeychainAuth.readAuthStatus() {
                    state["authStatus"] = keychainAuth
                    logger.info("Injected Keychain authStatus into init_response")
                }
            }
            state["initialPermissionMode"] = permissionMode.rawValue
            state["allowDangerouslySkipPermissions"] = CanopySettings.shared.allowDangerouslySkipPermissions
            state["isOnboardingDismissed"] = true
            var gates = (state["experimentGates"] as? [String: Any]) ?? [:]
            gates["tengu_vscode_cc_auth"] = true
            state["experimentGates"] = gates
            logger.info("Patched init_response: initialPermissionMode=\(self.permissionMode.rawValue, privacy: .public) allowSkip=true")
            response["state"] = state
            nested["response"] = response
            var patchedMessage = message
            patchedMessage["message"] = nested
            return patchedMessage
        }

        return message
    }

    // MARK: - Shim Communication

    /// Send a message to the shim via stdin. Buffers messages until the shim signals "ready",
    /// except for "webview_ready" which is sent immediately (the shim processes it pre-activation).
    private func sendToShim(_ msg: [String: Any]) {
        if !isReady && msg["type"] as? String != "webview_ready" {
            pendingMessages.append(msg)
            return
        }
        writeToStdin(msg)
    }

    private func writeToStdin(_ msg: [String: Any]) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: msg)
                guard var str = String(data: data, encoding: .utf8) else {
                    logger.warning("writeToStdin: UTF-8 encode failed for message type: \(msg["type"] as? String ?? "?", privacy: .public)")
                    return
                }
                str += "\n"
                guard let writeData = str.data(using: .utf8) else { return }
                try self.stdinPipe?.fileHandleForWriting.write(contentsOf: writeData)
            } catch {
                logger.error("Failed to write to shim stdin: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func sendToWebView(_ message: Any) {
        guard let dict = message as? [String: Any] else {
            logger.warning("sendToWebView: message is not a dictionary: \(String(describing: type(of: message)), privacy: .public)")
            return
        }

        guard webView != nil else {
            logger.error("sendToWebView: webView is nil!")
            return
        }

        // Extension sends two formats:
        //   Unsolicited: {type:"from-extension", message:{...}} — already wrapped
        //   Responses:   {type:"response", requestId:"...", ...} — needs wrapping
        // VSCode internally wraps ALL extension→webview messages in {type:"from-extension"}.
        let jsPayload: String
        let payload: Any = dict["type"] as? String == "from-extension"
            ? dict
            : ["type": "from-extension", "message": dict] as [String: Any]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let jsonStr = String(data: data, encoding: .utf8) else {
                logger.error("sendToWebView: UTF-8 encode failed")
                return
            }
            jsPayload = jsonStr
        } catch {
            logger.error("sendToWebView: JSON serialization failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let js = "window.postMessage(\(jsPayload),'*')"
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                logger.error("sendToWebView JS error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Recap

    /// How long to wait for the CLI's `/recap` reply before giving up and
    /// unlatching `recapRequestInFlight`. Generous: the fork runs a full
    /// model turn against a cache-warm context, and on a slow link (SSH
    /// remote) that can take a while. `RecapCoordinator` has no retry
    /// interval to stay under — a second background cycle inside this window
    /// is possible and is declined by the in-flight gate, not by this
    /// timeout.
    private static let recapTimeoutSeconds: TimeInterval = 90

    /// Ask the CLI for a one-paragraph "what were we doing" recap by
    /// injecting the `/recap` slash command straight into the shim, without
    /// going through the webview.
    ///
    /// `/recap` is a *local* command: the CLI forks the conversation with
    /// `maxTurns: 1`, no tools, `skipCacheWrite` and `skipTranscript`, then
    /// answers with a single synthetic assistant message. Measured against
    /// a live session, the enclosing `result` reports `num_turns: 0` and
    /// all-zero `usage` — the recap costs a cache-read but adds nothing to
    /// the session's context window, which is the whole reason this is
    /// worth doing on a timer.
    ///
    /// Because the request never passes through the webview, the webview
    /// has no matching user bubble for the reply; `consumeRecapTraffic`
    /// therefore swallows both the synthetic assistant and its `result`.
    func requestRecap() {
        guard canRequestRecap, let channelId else {
            logger.debug("requestRecap skipped: not eligible")
            return
        }
        recapRequestInFlight = true

        // Shape copied field-for-field from a real webview→host prompt
        // (captured from the unified log). The extension is stricter than
        // the documented `{type, message}` core suggests: `uuid`,
        // `session_id`, `origin` and `parent_tool_use_id` all ride along on
        // every genuine prompt, so the injection mirrors them rather than
        // betting on which ones are load-bearing. `origin.kind` stays
        // "human" deliberately — this is the only value the path is known
        // to accept, and a speculative "canopy" would fail silently.
        sendToShim([
            "type": "webview_message",
            "message": [
                "type": "io_message",
                "channelId": channelId,
                "done": false,
                "message": [
                    "type": "user",
                    "session_id": "",
                    "origin": ["kind": "human"] as [String: Any],
                    "parent_tool_use_id": NSNull(),
                    "uuid": UUID().uuidString.lowercased(),
                    "message": [
                        "role": "user",
                        "content": [["type": "text", "text": "/recap"]],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ])
        logger.info("requestRecap: /recap injected")

        recapTimeout?.cancel()
        // Generation token: `DispatchWorkItem.cancel()` cannot interrupt an
        // item that has already been dequeued, so without this a stale
        // watchdog could unlatch a NEWER flight and let its reply through as
        // a visible synthetic bubble.
        recapGeneration &+= 1
        let generation = recapGeneration
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.recapRequestInFlight, self.recapGeneration == generation else { return }
            self.endRecapFlight()
            // Error, not warning: reaching the watchdog means `/recap` never
            // answered — an unsupported CLI, a flipped feature gate, or a
            // dropped turn. The feature is silently dead until someone reads
            // this line, so it should stand out in the log.
            logger.error("requestRecap: no reply after \(Self.recapTimeoutSeconds)s — unlatched (is /recap supported by this CLI?)")
        }
        recapTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recapTimeoutSeconds, execute: timeout)
    }

    /// Apply `strippingRecapArtifacts` to a `get_session` response on its way
    /// to the webview, leaving every other message untouched.
    ///
    /// Replay responses arrive both bare and wrapped in `from-extension`
    /// (see `sendToWebView`), so both shapes are handled. Returns the input
    /// unchanged when nothing matches, and skips the rebuild entirely when
    /// no entry was dropped — session replays can be thousands of messages
    /// and this runs on every one of them.
    static func strippingRecapFromReplay(_ message: [String: Any]) -> [String: Any] {
        func strip(_ container: [String: Any]) -> [String: Any]? {
            guard var response = container["response"] as? [String: Any],
                  let messages = response["messages"] as? [[String: Any]]
            else { return nil }
            let filtered = strippingRecapArtifacts(messages)
            guard filtered.count != messages.count else { return nil }
            logger.info("replay: dropped \(messages.count - filtered.count, privacy: .public) recap artifact(s)")
            response["messages"] = filtered
            var updated = container
            updated["response"] = response
            return updated
        }

        if let stripped = strip(message) { return stripped }
        if message["type"] as? String == "from-extension",
           let nested = message["message"] as? [String: Any],
           let stripped = strip(nested)
        {
            var updated = message
            updated["message"] = stripped
            return updated
        }
        return message
    }

    /// Drop Canopy's own `/recap` invocations from a replayed message list.
    ///
    /// Swallowing the live traffic keeps the recap out of the transcript
    /// while a session is open, but the CLI still writes the slash command to
    /// the session JSONL as an ordinary (non-meta) user entry plus a
    /// `system` / `local_command` entry holding the output. Reopening the
    /// session replays those through `get_session`, so the "/recap" bubble
    /// the user never typed reappears — confirmed by restarting a session
    /// after the live fix landed. This is the replay-side half of the same
    /// filter.
    ///
    /// Order-aware rather than type-aware: a bare "drop every
    /// `system`/`local_command`" rule would also erase the output of slash
    /// commands the user genuinely ran. Only the entry directly following a
    /// `/recap` command is removed.
    ///
    /// KNOWN COLLATERAL: a `/recap` the *user* typed themselves is filtered
    /// too. Live, Canopy can tell the two apart exactly (see
    /// `mayCaptureSyntheticReply`) — but replay runs on a fresh shim after
    /// the session is reopened, and the injected `uuid` does not survive:
    /// measured against a real session JSONL, the CLI mints its own `uuid`
    /// and `promptId` for the entry, so nothing Canopy sent is recoverable
    /// from the replayed record. The practical effect is small, because Canopy renders
    /// every recap into the native strip either way; what the user loses is
    /// the transcript copy, not the content. Fixing it properly needs a
    /// marker the CLI would have to round-trip, which does not exist today.
    ///
    /// Consecutive `/recap` entries with no output between them each clear
    /// the pending flag, so a second command cannot orphan the first's
    /// output — the flag tracks "the immediately preceding entry", not "some
    /// earlier entry".
    ///
    /// Pure and static so `_SidebarLogicProbe` can exercise it directly
    /// (see `SidebarLogicProbe.runRecapProbes`).
    static func strippingRecapArtifacts(_ messages: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        result.reserveCapacity(messages.count)
        var previousWasRecapCommand = false

        for message in messages {
            if isRecapCommandEntry(message) {
                previousWasRecapCommand = true
                continue
            }
            if previousWasRecapCommand,
               message["type"] as? String == "system",
               message["subtype"] as? String == "local_command"
            {
                previousWasRecapCommand = false
                continue
            }
            previousWasRecapCommand = false
            result.append(message)
        }
        return result
    }

    /// A replayed transcript entry representing the `/recap` slash command
    /// itself. The CLI stores it as a user message whose text is the
    /// `<command-name>` wrapper rather than the raw "/recap" the webview was
    /// handed; this accepts both forms via `isRecapEcho`, since which one
    /// arrives is an extension implementation detail.
    private static func isRecapCommandEntry(_ message: [String: Any]) -> Bool {
        guard message["type"] as? String == "user" else { return false }
        return isRecapEcho(message)
    }

    /// Whether a `<synthetic>` reply seen during a flight may be claimed as
    /// the recap.
    ///
    /// `<synthetic>` marks local-command output in general, so it identifies
    /// the recap only while nothing else could have produced it. Canopy is
    /// the sole gateway for webview submissions, so "the user has submitted
    /// nothing since we injected" is an exact statement about what else can
    /// be in flight — not a timing guess.
    ///
    /// Trivial by itself; split out so `_SidebarLogicProbe` pins the rule
    /// rather than the shim's private state.
    static func mayCaptureSyntheticReply(contended: Bool) -> Bool {
        !contended
    }

    /// True when a `user` io_message carries a `/recap` invocation.
    ///
    /// Matches ANY `/recap` — Canopy's injection and a user-typed one are
    /// indistinguishable on the wire, so this cannot and does not claim to
    /// identify provenance. Live, that is harmless: the swallow only runs
    /// while Canopy has a flight in progress and the window is open.
    ///
    /// Pure and static so `_SidebarLogicProbe` can exercise the shapes
    /// without a live shim. Accepts both the plain slash command and the
    /// `<command-name>` wrapper the CLI expands it into.
    static func isRecapEcho(_ ioMsg: [String: Any]) -> Bool {
        guard let msg = ioMsg["message"] as? [String: Any] else { return false }
        let text: String
        if let content = msg["content"] as? [[String: Any]] {
            text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        } else if let content = msg["content"] as? String {
            text = content
        } else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whole-text equality on both forms, never `contains`. A substring
        // match destroys any message that merely QUOTES the wrapper — pasting
        // a transcript excerpt, filing a bug about this feature, reviewing
        // this very file — swallowing it live and deleting it from every
        // later replay. The wrapper arrives with the CLI's own indentation
        // between its tags, so compare on the collapsed form rather than
        // trying to reproduce that whitespace exactly.
        if trimmed == Self.recapCommand { return true }
        let collapsed = trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.hasPrefix("<command-name>\(Self.recapCommand)</command-name>")
    }

    /// The slash command Canopy injects, and the text both the live echo
    /// filter and the replay filter match against. Named so the injection
    /// and the two filters cannot drift apart silently — the failure mode
    /// would be a `/recap` bubble the user never typed, with no compile error.
    static let recapCommand = "/recap"

    /// Push the recap into the webview, where `RecapScript` renders it as a
    /// row at the top of the chat composer. Passing nil clears it.
    ///
    /// The webview is the display of record. `statusBarData.recap` is kept in
    /// step purely as observable state for a future native surface or a test;
    /// nothing reads it today, and the eligibility gate does not consult it.
    ///
    /// `RecapScript` owns the retry only once its user script has run — the
    /// `window.__canopyRecap && ...` guard short-circuits to `false` with no
    /// JS error before that, which is why the result is inspected rather than
    /// just the error.
    private func showRecapInWebView(_ text: String?) {
        guard let webView else {
            // Bare returns here cost a paid recap with no trace — the sibling
            // `sendToWebView` logs the identical condition for the same reason.
            if text != nil {
                logger.error("recap dropped: webView is nil")
            }
            return
        }
        // Reports back rather than just running: the call sites are guarded by
        // `window.__canopyRecap && …`, which short-circuits to false with NO JS
        // error when the user script hasn't run yet (mid-navigation, webview
        // recreated). Inspecting only `error` would read that as success and
        // lose the recap silently.
        let call = text.map { RecapScript.setCall(text: $0) } ?? RecapScript.clearCall
        let js = "(window.__canopyRecap ? (\(call), 'ok') : 'no-bridge')"
        webView.evaluateJavaScript(js) { result, error in
            if let error {
                logger.error("recap injection failed: \(error.localizedDescription, privacy: .public)")
            } else if result as? String != "ok" {
                if text != nil {
                    logger.error("recap injection: __canopyRecap bridge missing — recap dropped")
                } else {
                    // `showRecapInWebView(nil)` runs on every user prompt; a
                    // missing bridge there clears nothing and is not an error.
                    logger.debug("recap clear: bridge not present (nothing to clear)")
                }
            }
        }
    }

    /// Tear down the current flight's state in one place, so no path can
    /// clear the latch and leave the watchdog or the capture flag behind.
    private func endRecapFlight() {
        recapRequestInFlight = false
        recapCapturedReply = false
        recapContended = false
        recapTimeout?.cancel()
        recapTimeout = nil
    }


    /// Swallow the CLI traffic generated by our own `/recap` injection.
    /// Returns true when the message was consumed and must NOT reach the
    /// webview (nor any of the status/activity trackers — a `result` with
    /// zeroed usage would blank the context bar, and the same `result`
    /// would trip `SubagentTracker`'s end-of-turn freeze).
    ///
    /// Runs before every other handler in the `webview_message` path, and
    /// is a no-op unless a recap is actually in flight.
    private func consumeRecapTraffic(_ message: [String: Any]) -> Bool {
        guard recapRequestInFlight else { return false }

        // Unsolicited extension→webview messages are wrapped; responses are
        // not (see `sendToWebView`). Recap traffic arrives wrapped, but
        // accept both so a future protocol tweak degrades to "recap missing"
        // rather than "recap latched forever".
        let nested: [String: Any]
        if message["type"] as? String == "from-extension",
           let inner = message["message"] as? [String: Any]
        {
            nested = inner
        } else {
            nested = message
        }
        guard nested["type"] as? String == "io_message",
              let ioMsg = nested["message"] as? [String: Any]
        else { return false }

        // Every message that crosses the wire during a recap turn is worth a
        // log line: the swallow list is derived from what the extension
        // actually emits, and that set is not documented anywhere. When it
        // drifts, this is the only record of what leaked into the webview.
        let ioType = (ioMsg["type"] as? String) ?? "?"
        let subtype = (ioMsg["subtype"] as? String).map { "/\($0)" } ?? ""
        let model = ((ioMsg["message"] as? [String: Any])?["model"] as? String) ?? "-"
        logger.info("[recap-traffic] \(ioType, privacy: .public)\(subtype, privacy: .public) model=\(model, privacy: .public)")

        switch ioMsg["type"] as? String {
        case "command_lifecycle":
            // Emitted twice when a slash command starts. Drives the command
            // chip the webview renders in the transcript — the visible
            // "/recap" bubble a user never typed.
            return true

        case "system" where ioMsg["subtype"] as? String == "init":
            // `/recap` forks the conversation, and the fork announces itself
            // with its own `system/init`. The webview treats ANY init as
            // "a turn just started" (`busy.value = true`) and only a
            // `result` clears it — which we also swallow, so letting this
            // through leaves the session spinning forever with no way out.
            // Observed as the actual cause of the stuck "thinking" state.
            //
            // Safe to drop mid-session: the webview only reads `session_id`
            // off an init when it doesn't already have one, and by the time
            // a recap can fire the session is long since identified.
            return true

        case "user":
            // The extension echoes the submitted prompt back so the webview
            // can render it as a bubble. Ours must not appear: the user never
            // typed it. Matched on content rather than blanket-swallowing
            // `user` messages, so a genuine prompt racing the recap turn
            // still reaches the transcript.
            guard Self.isRecapEcho(ioMsg) else { return false }
            return true

        case "assistant":
            // Local-command output is tagged `<synthetic>` rather than a real
            // model id. Anything else while we're waiting is a genuine
            // assistant turn that must pass through untouched.
            guard let msg = ioMsg["message"] as? [String: Any],
                  msg["model"] as? String == "<synthetic>"
            else { return false }
            // The user submitted since we injected, so this shape is no longer
            // unambiguously ours. Hand it back rather than capturing someone
            // else's command output as the recap and deleting it from their
            // transcript. Our own reply may arrive later and render as an
            // ordinary bubble — a visible miss, not silent data loss. The
            // `result` still passes through correctly because
            // `recapCapturedReply` stays false.
            guard Self.mayCaptureSyntheticReply(contended: recapContended) else {
                logger.info("recap: synthetic reply arrived while contended — passing through")
                return false
            }
            let text = (msg["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            recapCapturedReply = true
            recapGate.recapLanded()
            if text.isEmpty {
                // The turn happened and produced nothing worth showing. The
                // gate still advances: leaving it open re-buys a full
                // conversation cache-read on every later dwell, forever.
                logger.warning("recap reply had no text content — gate advanced anyway")
            } else {
                statusBarData?.recap = text
                showRecapInWebView(text)
                logger.info("recap captured (\(text.count, privacy: .public) chars)")
            }
            return true

        case "result":
            // Closes out the injected turn — but only if this turn actually
            // was ours. Claiming the first `result` unconditionally was wrong:
            // when `/recap` produces no reply (older CLI without the command,
            // feature gate off, the extension dropping the turn), the next
            // REAL turn's result was eaten instead. Nothing else clears the
            // webview's busy flag, so the session span forever with no error
            // and no recovery — the exact failure this feature already caused
            // once via `system/init`.
            //
            // `recapCapturedReply` is the positive evidence. Without it we
            // unlatch and pass the result through, so the real turn completes
            // normally and only the recap is lost.
            guard recapCapturedReply else {
                logger.error("recap: result arrived with no captured reply — passing through, recap lost")
                endRecapFlight()
                return false
            }
            endRecapFlight()
            return true

        default:
            // Everything else passes through, notably `rate_limit_event` —
            // it carries real quota data the status bar wants, and it is not
            // part of the transcript the recap turn would pollute.
            return false
        }
    }

    /// Request rate limit data from extension (triggers /api/oauth/usage fetch).
    /// Throttled globally — only one tab sends the request per interval.
    private func requestUsageUpdate() {
        guard SharedRateLimitData.shared.shouldRequestUpdate() else { return }
        let requestId = "canopy-usage-\(UUID().uuidString.prefix(8))"
        sendToShim([
            "type": "webview_message",
            "message": [
                "type": "request",
                "requestId": requestId,
                "request": [
                    "type": "request_usage_update",
                ] as [String: Any],
            ] as [String: Any],
        ])
        // Also ask the CLI for the RAW usage payload (get_usage). The
        // extension's usage_update transform drops `model_scoped` — the
        // per-model weekly buckets (e.g. "Weekly Fable") that the sidebar
        // Usage section renders. The raw response keeps them. The response
        // is swallowed by isCanopyOwnedResponse so the webview never sees
        // an unmatched requestId. channelId is required (the extension
        // routes get_usage to a per-channel CLI query).
        if let channelId {
            sendToShim([
                "type": "webview_message",
                "message": [
                    "type": "request",
                    "channelId": channelId,
                    "requestId": "canopy-getusage-\(UUID().uuidString.prefix(8))",
                    "request": [
                        "type": "get_usage",
                    ] as [String: Any],
                ] as [String: Any],
            ])
        }
    }

    /// Capture the raw get_usage response requested above and feed the
    /// snake_case rate_limits payload (incl. model_scoped) to
    /// SharedRateLimitData. Responses may arrive unwrapped or wrapped in
    /// from-extension, same as titles (see extractTitle).
    private func extractRawUsage(_ message: [String: Any]) {
        func handle(_ response: [String: Any], requestId: String?) {
            guard let requestId, requestId.hasPrefix("canopy-getusage-") else { return }
            // Past this point the response is OURS, and any shape mismatch
            // means the CLI/extension changed the payload (or answered
            // with an error). These responses are also swallowed before
            // reaching the webview (isCanopyOwnedResponse), so a silent
            // return here would make the per-model usage rows disappear
            // with zero diagnostics anywhere — always log the mismatch.
            guard response["type"] as? String == "get_usage_response",
                  let usage = response["usage"] as? [String: Any],
                  let rateLimits = usage["rate_limits"] as? [String: Any]
            else {
                let respType = (response["type"] as? String) ?? "?"
                let keys = response.keys.sorted().joined(separator: ",")
                logger.warning("get_usage response shape mismatch: type=\(respType, privacy: .public) keys=\(keys, privacy: .public)")
                return
            }
            SharedRateLimitData.shared.updateFromRawUsage(rateLimits)
        }
        if let response = message["response"] as? [String: Any] {
            handle(response, requestId: message["requestId"] as? String)
            return
        }
        if message["type"] as? String == "from-extension",
           let nested = message["message"] as? [String: Any],
           let response = nested["response"] as? [String: Any]
        {
            handle(response, requestId: nested["requestId"] as? String)
        }
    }

    /// Send a synthetic generate_session_title request to the extension via shim.
    /// The extension forwards this to the CLI, which generates a short AI title.
    private func requestSessionTitle(description: String) {
        guard !description.isEmpty else { return }
        guard let channelId else {
            logger.warning("requestSessionTitle skipped: channelId still nil")
            return
        }
        // Don't regenerate if we already have a good AI title (not a fallback).
        if hasGeneratedTitle, !titleIsFallback {
            logger.debug("requestSessionTitle skipped: already have AI-generated title")
            return
        }
        titleRequestInFlight = true

        let requestId = "canopy-title-\(UUID().uuidString.prefix(8))"
        currentTitleRequestId = requestId
        let fallbackText = lastUserMessageText ?? description
        sendToShim([
            "type": "webview_message",
            "message": [
                "type": "request",
                "requestId": requestId,
                "request": [
                    "type": "generate_session_title",
                    "channelId": channelId,
                    "description": titleGenerationDescription(for: description),
                    "persist": false,
                ] as [String: Any],
            ] as [String: Any],
        ])

        // Fallback: if the extension is slow, show this request's user
        // message as a provisional title. Keep the request id alive so a
        // late AI title can still replace it; the next user prompt will
        // install a newer request id and naturally reject this response.
        DispatchQueue.main.asyncAfter(deadline: .now() + titleFallbackDelay) { [weak self] in
            guard let self else {
                logger.debug("Title fallback skipped: ShimProcess deallocated")
                return
            }
            guard self.titleRequestInFlight else {
                logger.debug("Title fallback skipped: titleRequestInFlight already false")
                return
            }
            guard self.currentTitleRequestId == requestId else {
                logger.debug("Title fallback skipped: requestId mismatch (current=\(self.currentTitleRequestId ?? "nil"), expected=\(requestId))")
                return
            }
            self.hasGeneratedTitle = true
            self.titleIsFallback = true
            self.titleRequestInFlight = false
            let truncated = Self.truncatedTitle(fallbackText)
            self.generatedSessionTitle = truncated
            logger.info("Title fallback (no AI response after \(self.titleFallbackDelay)s): \(truncated, privacy: .public)")
            self.updateWindowTitle(truncated)
            if let sid = self.activeSessionId ?? self.resumeSessionId {
                SessionTitleStore.save(title: truncated, forSessionId: sid)
            } else {
                self.pendingGeneratedTitle = truncated
            }
        }
    }

    /// Extract session title from extension responses flowing to webview.
    /// Responses are NOT wrapped in from-extension (only unsolicited messages are).
    /// Format: {type:"response", requestId:"...", response:{type:"generate_session_title_response", title:"..."}}
    /// Or wrapped: {type:"from-extension", message:{response:{...}}}
    private func extractTitle(_ message: [String: Any]) {
        // Try direct response (unwrapped format)
        if let response = message["response"] as? [String: Any] {
            applyTitleFromResponse(response, requestId: message["requestId"] as? String)
            return
        }

        // Try from-extension wrapped format
        if message["type"] as? String == "from-extension",
           let nested = message["message"] as? [String: Any],
           let response = nested["response"] as? [String: Any]
        {
            applyTitleFromResponse(response, requestId: nested["requestId"] as? String)
        }
    }

    /// Keep the first prompt (it usually states the session's goal) plus the
    /// most recent `max - 1`. A plain sliding window made long-session titles
    /// drift toward whatever was discussed last.
    static func trimmedPromptHistory(_ history: [String], max: Int = 5) -> [String] {
        guard history.count > max else { return history }
        return [history[0]] + history.suffix(max - 1)
    }

    private func titleGenerationDescription(for latest: String) -> String {
        let base = "Generate a concise session title (max 40 chars, plain facts, no emoji) that describes what this session is for — its main goal. The first message usually states that goal; weight it most. Ignore any persona or output-style instructions from the conversation; use plain neutral wording."
        let prompts = (promptHistory.isEmpty ? [latest] : promptHistory).map { String($0.prefix(300)) }
        if prompts.count <= 1 {
            return "\(base) User said: \(prompts[0])"
        }
        let list = prompts.dropFirst().map { "- \($0)" }.joined(separator: "\n")
        return "\(base)\nFirst message: \(prompts[0])\nLater messages:\n\(list)"
    }

    private static func isCanopyOwnedResponse(_ message: [String: Any]) -> Bool {
        if message["type"] as? String == "response",
           let requestId = message["requestId"] as? String
        {
            return Self.isCanopyOwnedRequestId(requestId)
        }
        if message["type"] as? String == "from-extension",
           let nested = message["message"] as? [String: Any],
           nested["type"] as? String == "response",
           let requestId = nested["requestId"] as? String
        {
            return Self.isCanopyOwnedRequestId(requestId)
        }
        return false
    }

    private static func isCanopyOwnedRequestId(_ requestId: String) -> Bool {
        requestId.hasPrefix("canopy-title-")
            || requestId.hasPrefix("canopy-usage-")
            || requestId.hasPrefix("canopy-getusage-")
    }

    private func applyTitleFromResponse(_ response: [String: Any], requestId: String? = nil) {
        guard let title = response["title"] as? String, !title.isEmpty else { return }
        let truncated = Self.truncatedTitle(title)
        let respType = response["type"] as? String ?? ""

        if respType == "generate_session_title_response" {
            // Reject stale responses that don't match the newest request.
            // Late AI responses can replace a fallback title as long as no
            // newer prompt has started another title request.
            guard let requestId,
                  requestId == currentTitleRequestId
            else {
                return
            }
            logger.info("Title generated: \(title, privacy: .public)")
            titleRequestInFlight = false
            currentTitleRequestId = nil
            hasGeneratedTitle = true
            titleIsFallback = false
            generatedSessionTitle = truncated
            updateWindowTitle(truncated)
            // Persist to our own store (like Sessylph's SessionTitleStore).
            if let sid = activeSessionId ?? resumeSessionId {
                SessionTitleStore.save(title: truncated, forSessionId: sid)
            } else {
                pendingGeneratedTitle = truncated
            }
        } else if respType == "rename_tab_response"
            || respType == "update_session_state_response"
        {
            if hasGeneratedTitle {
                if let generatedSessionTitle {
                    updateWindowTitle(generatedSessionTitle)
                }
                logger.debug("Ignored extension title response after Canopy title ownership: \(truncated, privacy: .public)")
                return
            }
            // Always accept native title updates from the extension; they
            // reflect evolving conversation context. Periodic AI title
            // generation runs on its own cadence and overwrites when ready.
            logger.info("Title updated: \(title, privacy: .public)")
            updateWindowTitle(truncated)
        }
    }

    // MARK: - Window Title & Working State

    private static func truncatedTitle(_ title: String, maxLength: Int = 60) -> String {
        title.count > maxLength
            ? String(title.prefix(maxLength - 3)) + "..."
            : title
    }

    private func updateWindowTitle(_ title: String) {
        sessionTitle = title
        // Sidebar shell: SwiftUI's `.navigationTitle` on Detail and the
        // sidebar row both read `OpenSession.title`. Without this assignment
        // generated / renamed titles would only live in our private
        // `sessionTitle` and never reach the UI.
        boundSession?.title = title
    }

    /// Watch host→webview messages for `tool_permission_request` (start) and
    /// `cancel_request` (extension-initiated abort) so the sidebar's
    /// raised-hand icon mirrors the user's actual asking state. Pair-only
    /// matching against `response` lives in `trackPermissionResponse`.
    private func trackPermissionState(stdoutMessage message: [String: Any]) {
        guard message["type"] as? String == "webview_message",
              let outer = message["message"] as? [String: Any]
        else { return }
        // Extension may wrap host→webview requests in `from-extension`.
        // Peel one layer if present.
        let inner: [String: Any]
        if outer["type"] as? String == "from-extension",
           let unwrapped = outer["message"] as? [String: Any] {
            inner = unwrapped
        } else {
            inner = outer
        }

        let innerType = inner["type"] as? String

        if innerType == "request",
           let requestId = inner["requestId"] as? String,
           let request = inner["request"] as? [String: Any],
           request["type"] as? String == "tool_permission_request"
        {
            pendingPermissionRequestIds.insert(requestId)
            if request["toolName"] as? String == "AskUserQuestion" {
                pendingAskUserQuestionRequestIds.insert(requestId)
            }
            refreshAskingState()
            return
        }

        // The extension cancels an in-flight tool_permission_request when
        // the user presses Stop or the channel aborts. The webview hides
        // its prompt UI on `cancel_request`, but no `response` follows, so
        // without this handler the requestId leaks and the raised-hand
        // icon stays lit forever.
        if innerType == "cancel_request",
           let targetRequestId = inner["targetRequestId"] as? String,
           pendingPermissionRequestIds.remove(targetRequestId) != nil
        {
            clearAskUserQuestionFlagIfMatching(targetRequestId)
            refreshAskingState()
        }
    }

    /// When an AskUserQuestion permission request resolves (response or
    /// cancel), also clear `lastAssistantHadAskUserQuestion` so the hand
    /// icon disappears immediately. Otherwise it would linger until the
    /// next assistant turn's `message_start` stream event.
    private func clearAskUserQuestionFlagIfMatching(_ requestId: String) {
        guard pendingAskUserQuestionRequestIds.remove(requestId) != nil,
              pendingAskUserQuestionRequestIds.isEmpty
        else { return }
        lastAssistantHadAskUserQuestion = false
    }

    /// Webview→host responses arrive via `userContentController`. When one
    /// matches a tracked permission request id, clear it.
    private func trackPermissionResponse(_ webviewMessage: [String: Any]) {
        guard webviewMessage["type"] as? String == "response",
              let requestId = webviewMessage["requestId"] as? String
        else { return }
        guard pendingPermissionRequestIds.remove(requestId) != nil else { return }
        clearAskUserQuestionFlagIfMatching(requestId)
        refreshAskingState()
    }

    /// Drop every transient activity signal (asking, waiting, subagent
    /// activity) and resync the bound session. Called when the shim/CLI
    /// exits so a crashed or disconnected session row doesn't keep a stale
    /// raised-hand, hourglass, or spinning subagent row — once the process
    /// is gone no protocol message will ever clear those sets organically.
    private func resetActivityState() {
        pendingPermissionRequestIds.removeAll()
        pendingAskUserQuestionRequestIds.removeAll()
        lastAssistantHadAskUserQuestion = false
        pendingBackgroundTaskIds.removeAll()
        bgTaskIdMap.removeAll()
        // Benign today — the flag's only setter is always followed by an
        // apply that clears it first thing — but it is the one piece of this
        // subsystem's state the reset would otherwise skip, and "benign"
        // there is a conclusion someone has to re-derive by tracing. Clearing
        // it costs a line and removes the trace.
        bgIdleBackstopReadInFlight = false
        subagentTracker = SubagentTracker()
        statusBarData?.subagents = []
        // A recap in flight when the process died will never be answered,
        // and its reply-swallowing latch would eat the first assistant
        // message of the reconnected session. The strip's text is left
        // alone: it describes work that still stands after a reconnect.
        endRecapFlight()
        refreshAskingState()
        refreshWaitingState()
    }

    /// Recompute the asking flag from outstanding permission requests AND
    /// any pending AskUserQuestion tool call. Either condition flips the
    /// sidebar icon to "raised hand".
    ///
    /// AskUserQuestion is reflected as soon as we see the `tool_use` block,
    /// even while `isWorking` is still true — the CLI keeps streaming until
    /// the user picks an answer (no `result` fires meanwhile), so we'd
    /// otherwise stay stuck on the thinking flower forever.
    private func refreshAskingState() {
        let asking = !pendingPermissionRequestIds.isEmpty
            || lastAssistantHadAskUserQuestion
        boundSession?.isAsking = asking
    }

    /// Recompute the waiting flag. We only flip the sidebar to "waiting" when
    /// Claude itself is idle — if `isWorking` is true the thinking flower
    /// takes precedence (and the user already knows the session is alive).
    ///
    /// Also owns the idle backstop's lifetime, which is not obvious from the
    /// name and matters at every call site: calling this starts or stops a
    /// repeating timer. See `syncBackgroundIdleBackstop`. (No count here —
    /// a comment that says how many callers there are goes stale on the next
    /// one added, and this one already had.)
    private func refreshWaitingState() {
        let waiting = !isWorking && !pendingBackgroundTaskIds.isEmpty
        boundSession?.isWaiting = waiting
        syncBackgroundIdleBackstop(waiting: waiting)
    }

    /// Arm the idle backstop while a bg task is pending and Claude is idle,
    /// tear it down the moment either stops holding. Driven off the same
    /// `waiting` value `isWaiting` gets, so "the timer is running" and "this
    /// session has an unreconciled bg task" are one condition by construction
    /// — including the teardown paths (`resetActivityState` on shim
    /// exit/crash empties the map and lands here) which would otherwise each
    /// need to remember to cancel.
    private func syncBackgroundIdleBackstop(waiting: Bool) {
        guard waiting else {
            bgIdleBackstop?.cancel()
            bgIdleBackstop = nil
            return
        }
        guard bgIdleBackstop == nil else { return }
        scheduleBackgroundIdleBackstop()
    }

    /// One tick, which re-arms itself. Everything here runs on the main
    /// queue, so the whole mechanism is single-threaded: `refreshWaitingState`
    /// (main) arms it, `asyncAfter` delivers it back to main, and the tick
    /// re-checks its own precondition rather than trusting the arm — a
    /// `cancel()` that lands after the item is already dequeued does not
    /// stop the block, and by then the state may have moved on.
    private func scheduleBackgroundIdleBackstop() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Clear FIRST: this item is spent either way, and leaving it
            // in place would make `syncBackgroundIdleBackstop` believe a
            // tick is still armed and skip re-arming forever.
            self.bgIdleBackstop = nil
            guard !self.isWorking, !self.pendingBackgroundTaskIds.isEmpty else { return }
            if !self.bgIdleBackstopReadInFlight {
                self.reconcileCompletedBackgroundTasks(trigger: .idleBackstop)
            }
            self.scheduleBackgroundIdleBackstop()
        }
        bgIdleBackstop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bgIdleBackstopInterval, execute: work)
    }

    /// Reconcile `pendingBackgroundTaskIds` against the session JSONL, either
    /// on the `isWorking: false→true` transition or from the idle backstop
    /// timer (see `bgIdleBackstop` for why the transition alone isn't
    /// enough). Only ids whose `<task-notification>` has already been written
    /// to the log get cleared; everything else stays pending so the hourglass
    /// keeps showing for bg tasks that are actually still running.
    ///
    /// Rationale: the CLI does NOT route `<task-notification>` user messages
    /// through the io_message stream (verified empirically), so we can't
    /// watch for completion directly. But the CLI does persist every
    /// task-notification to `~/.claude/projects/<encoded>/<sid>.jsonl` —
    /// both as a `queue-operation` enqueue and as the synthetic `user`
    /// message that wakes Claude. By the time we observe `isWorking` going
    /// true (first `stream_event` of the new turn), those JSONL entries are
    /// usually flushed — but NOT reliably, which is the whole of issue #132:
    /// a task's own `<task-notification>` can trigger the wake before its
    /// marker has landed, and that scan then reports the task still running.
    /// Treat a scan as authoritative about what it FOUND, never about what
    /// it didn't; `bgIdleBackstop` is what covers the difference.
    ///
    /// Scans from `min(pendingBackgroundTaskIds.values)` — the earliest launch
    /// offset captured at detection time. This bounds the read to bytes
    /// written since the bg launch and guarantees the completion marker (if
    /// any) is in the scanned window, regardless of how much intervening
    /// tool output Claude streamed. A fixed-size tail silently dropped the
    /// marker once the file grew past it (see the launch-offset comment on
    /// `pendingBackgroundTaskIds`).
    ///
    /// After the scan, every still-pending id's offset is advanced to the
    /// end of the scanned region. The marker for any of those ids is, by the
    /// scan's outcome, NOT in the bytes we just read; if it ever lands, it
    /// must lie at an offset ≥ the read's end, so the next scan only has to
    /// look at incremental file growth. Without this advance, a long-running
    /// bg task would force every subsequent scan to re-scan the whole growing
    /// region from the original launch offset — main-thread cost grows with
    /// the bg task's lifetime, not with what's actually new.
    ///
    /// Falls back to bulk-clear when the JSONL is unreachable (SSH remote
    /// runs the CLI on the other machine; a brand-new session may not have
    /// flushed yet; a folder-encoding mismatch). The "user-typed-while-bg"
    /// and "multi-bg first completion" edge cases reappear in that fallback
    /// path only — and only on a `.wake`, see `BackgroundReconcileTrigger`.
    private func reconcileCompletedBackgroundTasks(trigger: BackgroundReconcileTrigger) {
        let minOffset = pendingBackgroundTaskIds.values.min() ?? 0
        guard let path = sessionJSONLPath() else {
            guard trigger.allowsBulkClear else {
                // Nothing to scan and nothing this pass is allowed to assume.
                // Deliberately not disarming the timer: the path can start
                // resolving later in a session's life (it needs the session
                // id, which arrives after launch). What a tick that keeps
                // landing here costs depends on WHY the path is nil: on an
                // SSH remote, nothing at all — `sessionJSONLPath()` returns
                // at its `remoteHost` guard before touching the filesystem —
                // though the tick then never stops, because that guard can
                // never start passing. Locally it is the `fileExists` probe
                // described on `bgIdleBackstopInterval`, and that case ends
                // once the session id resolves.
                logger.debug("[bg] idle backstop skipped (no JSONL access)")
                return
            }
            // Bulk-clear branch — pendingBackgroundTaskIds gets nuked because
            // we can't reconcile against a JSONL scan (no path). Sweep the
            // tracker too so running bg rows finish here rather than
            // persisting past the F1 exemption into a stuck spinner.
            let ids = Array(pendingBackgroundTaskIds.keys)
            let count = ids.count
            pendingBackgroundTaskIds.removeAll()
            bgTaskIdMap.removeAll()
            var subagentTransitioned = false
            let now = Date()
            for id in ids where subagentTracker.completeIfPresent(id: id, at: now) {
                subagentTransitioned = true
            }
            if subagentTransitioned {
                statusBarData?.subagents = subagentTracker.rows
            }
            logger.notice("[bg] \(trigger.logLabel, privacy: .public) bulk-cleared (no JSONL access) count=\(count, privacy: .public) subagentTransitioned=\(subagentTransitioned, privacy: .public)")
            refreshWaitingState()
            return
        }
        // Run the read on a background queue so a multi-MB JSONL doesn't
        // stall the main thread mid-scan. Ordering and QoS are argued on
        // `bgReadQueue` and not restated here; what matters at this call
        // site is that per-id offsets tolerate a stale read, because the
        // apply step only ever clears ids the read positively matched.
        if trigger == .idleBackstop { bgIdleBackstopReadInFlight = true }
        Self.bgReadQueue.async { [weak self] in
            let read = Self.readJSONLFromOffset(path: path, offset: minOffset)
            DispatchQueue.main.async { [weak self] in
                self?.applyBgReconcile(read: read, scannedFrom: minOffset, trigger: trigger)
            }
        }
    }

    /// Apply the result of an async scan back on the main actor. Split out
    /// from `reconcileCompletedBackgroundTasks(trigger:)` so the I/O can live
    /// off the main thread without leaking the state mutations off it.
    private func applyBgReconcile(read: (text: String, endOffset: JSONLByteOffset)?, scannedFrom minOffset: JSONLByteOffset, trigger: BackgroundReconcileTrigger) {
        if trigger == .idleBackstop { bgIdleBackstopReadInFlight = false }
        guard let read else {
            guard trigger.allowsBulkClear else {
                // A transient read failure says nothing about whether the bg
                // task finished, and unlike a wake there's no user action to
                // resolve against. Leave the map alone; the next tick reads
                // again from the same offset.
                logger.debug("[bg] idle backstop skipped (read failed)")
                return
            }
            // Read failed (I/O error during seek/readToEnd, file vanished
            // between our path probe and the open). Bulk-clear preserves
            // the documented contract of the offline path. Sweep the
            // tracker too so running bg rows finish here rather than
            // persisting past the F1 exemption into a stuck spinner.
            let ids = Array(pendingBackgroundTaskIds.keys)
            let count = ids.count
            pendingBackgroundTaskIds.removeAll()
            bgTaskIdMap.removeAll()
            var subagentTransitioned = false
            let now = Date()
            for id in ids where subagentTracker.completeIfPresent(id: id, at: now) {
                subagentTransitioned = true
            }
            if subagentTransitioned {
                statusBarData?.subagents = subagentTracker.rows
            }
            logger.notice("[bg] \(trigger.logLabel, privacy: .public) bulk-cleared (read failed) count=\(count, privacy: .public) subagentTransitioned=\(subagentTransitioned, privacy: .public)")
            refreshWaitingState()
            return
        }
        // Snapshot keys before mutating — iterating `.keys` while removing
        // from the dictionary is unsupported and can trap or silently
        // skip elements. The `Array(...)` copy is cheap (id strings only).
        var removed: [String] = []
        var subagentTransitioned = false
        for id in Array(pendingBackgroundTaskIds.keys)
        where Self.jsonlTailHasCompletion(tail: read.text, taskId: id)
        {
            pendingBackgroundTaskIds.removeValue(forKey: id)
            bgTaskIdMap.removeValue(forKey: id)
            if subagentTracker.completeIfPresent(id: id, at: Date()) {
                subagentTransitioned = true
            }
            removed.append(id)
        }
        if !removed.isEmpty {
            let scannedBytes = Self.scannedByteCount(end: read.endOffset, from: minOffset)
            logger.notice("[bg] \(trigger.logLabel, privacy: .public) jsonl-cleared ids=\(removed.joined(separator: ","), privacy: .public) bytes=\(scannedBytes, privacy: .public) remaining=\(self.pendingBackgroundTaskIds.count, privacy: .public) subagentTransitioned=\(subagentTransitioned, privacy: .public)")
            refreshWaitingState()
        }
        if subagentTransitioned {
            statusBarData?.subagents = subagentTracker.rows
        }
        // Advance every still-pending id to the read's end: their marker
        // wasn't in the bytes we just scanned (we just verified), so any
        // future marker must land at offset ≥ endOffset. Bounds the next
        // scan's read to file growth, not cumulative-since-launch.
        //
        // **Plain assignment, NOT `max(existing, read.endOffset)`.** The
        // offsets are therefore not monotonic, and that is deliberate: they
        // track a position in whatever file `readJSONLFromOffset` just read,
        // and that file can be replaced. When the recorded offset is past
        // EOF — a truncated or re-forked session log — the read restarts at
        // 0, so its `endOffset` legitimately lands *below* where the id was.
        // Assigning it re-homes the id into the new file. Keeping the larger
        // value instead strands it: the marker gets written near the start of
        // the new file, the file eventually grows past the stale offset, and
        // every later scan begins after the marker and never sees it — the
        // permanent stuck hourglass, which is worse in kind than the
        // re-scanning of a few hundred bytes that a backwards move costs.
        //
        // Recorded because `max` looks like the obvious tightening and was
        // tried: it went in during review, and review caught it.
        if !pendingBackgroundTaskIds.isEmpty {
            for id in Array(pendingBackgroundTaskIds.keys) {
                pendingBackgroundTaskIds[id] = read.endOffset
            }
        }
    }

    /// Serial background queue for the JSONL reconcile scan — both triggers,
    /// and shared process-wide by every `ShimProcess`. Serial guarantees
    /// overlapping scans apply in dispatch order, so the last write to a
    /// per-id offset is the one from the newest read rather than whichever
    /// read happened to finish last. (Ordered, not monotonic — see the
    /// advance in `applyBgReconcile` for why an offset may move backwards.)
    ///
    /// `userInitiated` was chosen for the wake path's "they just sent a
    /// message, the row's about to update" expectation, and the idle
    /// backstop's 15 s poll now rides the same queue at that QoS with no
    /// user action behind it. Left as one queue on purpose: the reads are
    /// small and serializing them is what the ordering guarantee rests on.
    private static let bgReadQueue = DispatchQueue(label: "sh.saqoo.Canopy.bgReadQueue", qos: .userInitiated)

    /// True when the JSONL tail contains a `<task-notification>` completion
    /// marker for `taskId`. The CLI emits the id verbatim inside both
    /// `queue-operation` enqueue lines and the synthetic `user` message,
    /// surrounded by literal `<tool-use-id>...</tool-use-id>` tags — see
    /// recent session JSONLs for fixtures. Extracted as a `static` so the
    /// probe can lock the contract without standing up a live shim — if the
    /// CLI ever changes the wrapper format, the probe goes red instead of
    /// the hourglass silently sticking on every session forever.
    static func jsonlTailHasCompletion(tail: String, taskId: String) -> Bool {
        tail.contains("<tool-use-id>\(taskId)</tool-use-id>")
    }

    /// Resolve the local path to the session's JSONL log, or nil if it is not
    /// reachable from this process (SSH remote sessions write on the other
    /// machine; a brand-new session may not yet have a session id).
    private func sessionJSONLPath() -> String? {
        guard remoteHost == nil else { return nil }
        guard let sid = activeSessionId ?? resumeSessionId, !sid.isEmpty else { return nil }
        return Self.jsonlPath(sessionId: sid, workingDirectory: workingDirectory)
    }

    /// Static form of `sessionJSONLPath()` for callers that don't have an
    /// instance handy yet (init-time historic-id snapshot). Returns the first
    /// existing `~/.claude/projects/<encoded>/<sid>.jsonl` path across the
    /// encoded-folder candidates, or nil when the session log isn't on disk
    /// (brand-new session, or a folder-encoding drift the CLI doesn't cover).
    static func jsonlPath(sessionId: String, workingDirectory: URL) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let home = NSHomeDirectory()
        let fm = FileManager.default
        for encoded in ClaudeSessionHistory.encodedFolderCandidates(for: workingDirectory.path) {
            let path = "\(home)/.claude/projects/\(encoded)/\(sessionId).jsonl"
            if fm.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Read the given JSONL from byte 0 up to `upToOffset` (or EOF, whichever
    /// comes first) and collect every `toolu_…` id that appears. Used at
    /// spawn to snapshot the set of ids the CLI knows about from prior
    /// turns — see `historicToolUseIds`. Callers pass `historicJsonlBound`
    /// to keep the read strictly on pre-spawn bytes; anything appended by
    /// the current shim's own turns is skipped so a live bg tool_use id
    /// can't leak into the historic set.
    ///
    /// The pattern is deliberately loose (any `toolu_[A-Za-z0-9]{16,40}`
    /// substring): CC uses that id shape for both `assistant` `tool_use.id`
    /// and `user` `tool_result.tool_use_id` blocks, plus the
    /// `<tool-use-id>` completion wrapper — matching any occurrence catches
    /// them all without JSON parsing the session log (which can be tens of
    /// MB for long sessions). The price is over-inclusion of ids that only
    /// ever appeared in a `tool_result` and never as a launch, but that's
    /// harmless: those ids were never valid bg-launch candidates anyway,
    /// and Anthropic's id space is wide enough that a new `toolu_…`
    /// colliding with a historic one is astronomically unlikely.
    ///
    /// See `extractToolUseIds(fromText:)` for the scan implementation and the
    /// macOS 26 Tahoe libdispatch rationale for avoiding `NSRegularExpression`.
    /// `toolu_…` is pure ASCII, so both the lossy `String(decoding:)`
    /// conversion here and the subsequent UTF-8 byte scan in the text variant
    /// are robust to any invalid bytes in surrounding Japanese/emoji content.
    private static func extractToolUseIds(fromPath path: String, upToOffset bound: JSONLByteOffset) -> Set<String> {
        guard bound > 0 else { return [] }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            // File vanished between the `fileExists` probe in
            // `sessionJSONLPath`/`jsonlPath` and here. Expected/recoverable —
            // debug level so the log stays quiet in normal operation.
            logger.debug("[bg] extractToolUseIds: file vanished path=\(path, privacy: .private)")
            return []
        }
        defer { try? handle.close() }
        let data: Data
        do {
            // `FileHandle(forReadingAtPath:)` opens at offset 0; no seek needed
            // and adding one would only obscure which call raised on failure.
            // `read(upToCount:)` returns fewer bytes if EOF hits first — no
            // clamp needed vs. the actual file size.
            data = try handle.read(upToCount: Int(clamping: bound)) ?? Data()
        } catch {
            // Genuine I/O failure (EPERM/EACCES/EIO) — surface at warning
            // level so a sandbox regression that silently disables historic
            // filtering shows up in the unified log. Matches `jsonlFileSize`
            // and `readJSONLFromOffset` in this same file.
            logger.warning("[bg] extractToolUseIds I/O error: \(error.localizedDescription, privacy: .public) path=\(path, privacy: .private)")
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        return extractToolUseIds(fromText: text)
    }

    /// Text-only variant of `extractToolUseIds(fromPath:upToOffset:)` so the
    /// probe can lock the scanner without touching the filesystem.
    ///
    /// Pure-Swift UTF-8 scan — deliberately does NOT use `NSRegularExpression`.
    /// Under macOS 26 Tahoe, `NSRegularExpression.enumerateMatches` invoked on
    /// a background dispatch queue trips a spurious main-thread precondition
    /// inside Foundation and crashes the process with
    /// `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue
    /// [com.apple.main-thread]` — even when the closure never touches main.
    /// The historic-id loader has to run off-main (session JSONLs can be
    /// tens of MB), so we scan bytes directly:
    ///   - Match the literal `toolu_` prefix
    ///   - Collect 16..40 following `[A-Za-z0-9]` bytes
    ///   - Reject if the next byte is `[A-Za-z0-9_]` (mirrors the regex's
    ///     `(?![A-Za-z0-9_])` — an overlong id must be captured whole or
    ///     dropped entirely, never truncated to a 40-char prefix)
    /// All target bytes are ASCII, so the UTF-8 view is safe against any
    /// multi-byte characters in surrounding Japanese / emoji content.
    static func extractToolUseIds(fromText text: String) -> Set<String> {
        var out = Set<String>()
        let bytes = Array(text.utf8)
        let n = bytes.count
        // "toolu_"
        let prefix: [UInt8] = [0x74, 0x6f, 0x6f, 0x6c, 0x75, 0x5f]
        let prefixLen = prefix.count
        guard n >= prefixLen + 16 else { return out }
        var i = 0
        while i <= n - prefixLen {
            // Fast reject on first byte mismatch.
            if bytes[i] != prefix[0] {
                i += 1
                continue
            }
            var matched = true
            for k in 1..<prefixLen where bytes[i + k] != prefix[k] {
                matched = false
                break
            }
            if !matched {
                i += 1
                continue
            }
            let idStart = i
            let bodyStart = i + prefixLen
            var end = bodyStart
            while end < n && Self.isAsciiAlnum(bytes[end]) {
                end += 1
            }
            let bodyLen = end - bodyStart
            if bodyLen >= 16, bodyLen <= 40,
               end == n || !Self.isAsciiAlnumOrUnderscore(bytes[end])
            {
                // Slice is guaranteed ASCII (prefix + [A-Za-z0-9]*), so
                // String(decoding:as:) never inserts replacement characters.
                out.insert(String(decoding: bytes[idStart..<end], as: UTF8.self))
            }
            // Advance past the scanned run so a valid match's trailing byte
            // can't seed a phantom re-match. When bodyLen == 0 (bare
            // "toolu_" with no alnum) we still advance by prefixLen.
            i = max(end, i + prefixLen)
        }
        return out
    }

    @inline(__always)
    private static func isAsciiAlnum(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) // 0-9
            || (c >= 0x41 && c <= 0x5A) // A-Z
            || (c >= 0x61 && c <= 0x7A) // a-z
    }

    @inline(__always)
    private static func isAsciiAlnumOrUnderscore(_ c: UInt8) -> Bool {
        isAsciiAlnum(c) || c == 0x5F // _
    }

    /// Pull the `[A-Za-z0-9]+` run that immediately follows `prefix` in
    /// `text`. Returns nil when the prefix is absent or the run is empty.
    /// Shared by `extractLaunchAckTaskId` / `extractStoppedTaskId` so a
    /// CLI wording change only needs one scanner to update. Kept as a
    /// byte-scan for consistency with `extractToolUseIds(fromText:)`; the
    /// isolation hazard that makes closure-free code load-bearing off the
    /// main thread is explained once, on `wholeLinePrefixLength`, and not
    /// restated here — three copies of one mechanism is how the framings
    /// drift apart.
    private static func extractAlnumAfterPrefix(_ text: String, prefix: String) -> String? {
        guard let prefixRange = text.range(of: prefix) else { return nil }
        let rest = text[prefixRange.upperBound...]
        var end = rest.startIndex
        while end < rest.endIndex {
            guard let ascii = rest[end].asciiValue, isAsciiAlnum(ascii) else { break }
            end = rest.index(after: end)
        }
        let id = String(rest[rest.startIndex..<end])
        return id.isEmpty ? nil : id
    }

    /// Captures the opaque CLI-side id a later `TaskStop` will name in
    /// `input.task_id`, so `bgTaskIdMap` can reverse-lookup back to the
    /// Swift-side `toolu_…` we track in `pendingBackgroundTaskIds`. Returns
    /// nil on no match, empty match, or a non-alphanumeric-only run.
    /// Probe-callable (`static`) so a CLI wording change goes red here
    /// instead of leaving the hourglass stuck.
    ///
    /// **Two ack wordings, because the CLI has two background mechanisms.**
    /// A `run_in_background` Bash acks with
    /// `"Command running in background with ID: <task_id>. Output is being
    /// written to: …"` (`b5nt1jeth`-shaped id). An async `Agent` acks with
    /// `"Async agent launched successfully.…\nagentId: <id> (internal ID …)"`
    /// (`a43f5f7881f8bf5de`-shaped) and never uses the Bash phrase — so the
    /// single-prefix version of this function returned nil for every
    /// background Agent it was asked about, and the TaskStop purge path was
    /// dead for those (issue #132). Both agent wordings currently on disk —
    /// with and without the "(This tool result is internal metadata …)"
    /// clause — carry the same `agentId: ` lead-in, so one prefix covers
    /// both. It is the only shared token sitting immediately before the id;
    /// they have other text in common, just not adjacent to what we want.
    ///
    /// The clause first appears in **CLI 2.1.199**, not 2.1.226 as issue
    /// #132 says — measured twice, independently, across the top-level
    /// session JSONLs in `~/.claude/projects` (~2,330 files; the ~6,000
    /// more under `<session-id>/subagents/` were checked separately and
    /// fall inside the legacy range). The last clause-free ack is 2.1.197
    /// and there is no 2.1.198 in the corpus, so the introduction sits
    /// somewhere in that gap — the single 2.1.199 sighting is the earliest
    /// evidence, not a proven boundary. 2.1.226 was just the version in use
    /// when the issue was filed, and the correction matters at a scale no
    /// off-by-one would: the Agent ack has been unparsed for roughly 27
    /// releases, not since last week.
    ///
    /// A third shape exists in older logs — `"Spawned successfully.\n
    /// agent_id: <name>@<team>…"`, from the retired teams / mailbox
    /// mechanism: 72 acks over 54 distinct launches in 14 files. Note
    /// `agent_id` with an underscore and a non-alphanumeric id, so it
    /// returns nil here — and 44 of those 72 came from a `tool_use` that
    /// `isBackgroundLaunchBlock` WOULD have accepted, so they were pending
    /// and did trip the drift warning at the call site. Deliberately
    /// unhandled; recorded so the survey above is not read as "these are
    /// the only two shapes that ever existed".
    ///
    /// "It was asked about" is doing real work in that sentence, and the
    /// gap is measured: across local session JSONLs touched in the 21 days
    /// to 2026-08-10, 33 of 355 async-agent acks belong to an `Agent`
    /// `tool_use` carrying NO `run_in_background` key at all (one session:
    /// 16 of 16). `isBackgroundLaunchBlock` requires that key, so those
    /// launches never enter `pendingBackgroundTaskIds`, this function is
    /// never called for them, and they get no hourglass and no purge. They
    /// do all receive completion markers, so they would reconcile correctly
    /// if they were tracked. Fixing that is a change to DETECTION, not to
    /// this parser, and it is deliberately not made here: widening what
    /// counts as a background launch risks a permanent hourglass on
    /// anything misclassified, which is a worse failure than the one it
    /// would fix.
    ///
    /// That the agent id is the SAME id space TaskStop uses is measured, not
    /// assumed: live JSONLs hold `"name":"TaskStop","input":{"task_id":
    /// "a9109847eff04238e"}` alongside `Successfully stopped task:
    /// a9109847eff04238e`, i.e. `a`-shaped ids flow through the stop path
    /// exactly like `b`-shaped ones.
    ///
    /// A prefix this generic is safe only because of where it's read: the
    /// caller matches `tool_result`s whose `tool_use_id` is already a pending
    /// bg launch, so no unrelated tool output reaches it.
    static func extractLaunchAckTaskId(_ text: String) -> String? {
        extractAlnumAfterPrefix(text, prefix: "Command running in background with ID: ")
            ?? extractAlnumAfterPrefix(text, prefix: "agentId: ")
    }

    /// CLI TaskStop result pattern (verbatim): content is a JSON-object
    /// *string* whose `message` field starts with
    /// `"Successfully stopped task: <task_id> …"`. Captures `<task_id>` so
    /// `processUserToolResults` can purge even if the corresponding
    /// `TaskStop` tool_use was missed (shim replay race). Same nil-on-
    /// empty / non-alnum rules as `extractLaunchAckTaskId`.
    static func extractStoppedTaskId(_ text: String) -> String? {
        extractAlnumAfterPrefix(text, prefix: "Successfully stopped task: ")
    }

    /// Flatten a `tool_result` block's `content` into plain text. The CLI
    /// emits two shapes: (1) a plain `String` (bg-launch ack, TaskStop
    /// result JSON string); (2) an array of `{type:"text", text:"…"}`
    /// sub-blocks (joined with `\n`). Anything else returns `""` so
    /// callers can treat "no usable text" and "empty content" the same.
    static func extractToolResultText(_ block: [String: Any]) -> String {
        if let s = block["content"] as? String {
            return s
        }
        guard let parts = block["content"] as? [[String: Any]] else { return "" }
        var texts: [String] = []
        for part in parts {
            guard part["type"] as? String == "text",
                  let t = part["text"] as? String
            else { continue }
            texts.append(t)
        }
        return texts.joined(separator: "\n")
    }

    /// Read a JSONL file from `offset` to EOF. Returns the lossy-decoded
    /// text of EVERYTHING read, alongside an end offset covering only the
    /// WHOLE LINES within it (`start` + `wholeLinePrefixLength`) — the two
    /// deliberately disagree whenever the read lands mid-append, and the
    /// body says why. The end offset is a *byte* count, so it can be stored
    /// back into `pendingBackgroundTaskIds` for the scan advance without
    /// going through `String.utf8.count` — which inserts replacement
    /// characters for invalid sequences and therefore diverges from the
    /// actual file byte position.
    ///
    /// Returns nil only on real I/O failure (handle open, seek, read). A
    /// `.wake` caller then falls back to bulk-clear; an idle pass leaves the
    /// map untouched — see `BackgroundReconcileTrigger`. Lossy UTF-8 decoding
    /// is intentional: an offset that lands mid-line possibly straddles a
    /// multibyte boundary, and a strict decoder would nil out on every
    /// reconcile pass for Japanese-heavy sessions, degrading the wake path to
    /// bulk-clear and the idle path to doing nothing at all (same pattern as
    /// `ClaudeSessionHistory.extractMetadata`). The substring match further
    /// down looks for ASCII-only `<tool-use-id>…</tool-use-id>` markers,
    /// which live on later, fully-formed lines.
    private static func readJSONLFromOffset(path: String, offset: JSONLByteOffset) -> (text: String, endOffset: JSONLByteOffset)? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            // Race window: file existed at the `fileExists` probe in
            // `sessionJSONLPath` but is gone now. Expected/recoverable.
            logger.debug("[bg] readJSONLFromOffset open failed path=\(path, privacy: .private)")
            return nil
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            // Only clamp when offset is strictly past EOF (file was truncated
            // or rotated). The `==` case is the steady state — nothing new
            // appended since the last advance — and reading 0 bytes from
            // there is the correct (and cheap) answer. The earlier `<`
            // boundary re-scanned the whole file on every scan when nothing
            // new had been written.
            let start = offset <= size ? offset : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            // **Match on everything read; advance only past whole lines.**
            // The two are separate requirements and conflating them costs a
            // marker either way round:
            //
            // - The ADVANCE needs a whole-line boundary. The caller moves
            //   every still-pending id up to `endOffset` on the promise that
            //   the marker cannot be in already-scanned bytes, and a scan
            //   landing mid-append would otherwise consume the front half of
            //   a `<tool-use-id>…</tool-use-id>` tag, advance past it, and
            //   leave no later scan able to see the tag whole. Rare when
            //   scans only happened at turn boundaries; routine now that the
            //   idle backstop reads while the CLI is writing (issue #132).
            // - The MATCH needs no such thing, because the marker is
            //   self-delimiting: seeing the closing tag proves it whole. So
            //   `text` is every byte read. Truncating it to the last newline
            //   too — which this function did on its first revision — throws
            //   away markers that are fully present in an unterminated tail,
            //   and if the CLI died mid-write and the session forked into a
            //   new JSONL, that file never grows again and the hourglass
            //   sticks for good. Matching on the unterminated tail is safe: a
            //   positive match removes the id, so its offset is never read.
            //
            // No newline at all → nothing is advanced (`endOffset == start`)
            // and the next pass re-reads the same bytes, which is the honest
            // answer for a scan that saw no complete line.
            let endOffset = start + JSONLByteOffset(Self.wholeLinePrefixLength(data))
            return (text: String(decoding: data, as: UTF8.self), endOffset: endOffset)
        } catch {
            // Genuine I/O failure (EPERM/EACCES/EIO/EBADF). Shouldn't happen
            // in normal operation; surface it so a sandbox/disk regression
            // isn't masked as the documented "JSONL unreachable" fallback.
            // `offset=` in the message pinpoints whether `seek` or `seekToEnd`
            // tripped — `localizedDescription` alone elides the call site.
            logger.warning("[bg] readJSONLFromOffset I/O error at offset=\(offset, privacy: .public): \(error.localizedDescription, privacy: .public) path=\(path, privacy: .private)")
            return nil
        }
    }

    /// How many bytes a scan covered, for the `[bg]` log line only.
    ///
    /// Guarded subtraction, because the operands can invert:
    /// `readJSONLFromOffset` clamps its start to 0 when the recorded offset
    /// is past EOF (a truncated or re-forked session file), so `end` can
    /// legitimately land BELOW the offset we asked for. In that case the
    /// scan started at 0 and `end` IS the count. `JSONLByteOffset` is
    /// `UInt64`, so the unguarded subtraction does not merely print a silly
    /// number — it traps, which would mean **a crash raised by a log line**.
    /// That is the unusual risk profile worth the extra function: `internal`
    /// so the probe pins it, since inlining the subtraction back is an easy
    /// and invisible way to reintroduce the abort.
    static func scannedByteCount(end: JSONLByteOffset, from start: JSONLByteOffset) -> JSONLByteOffset {
        end >= start ? end - start : end
    }

    /// Bytes of `data` that form whole lines: everything up to and including
    /// the last newline, or 0 when there is none. This is how far a scan is
    /// allowed to advance its per-id offsets — see `readJSONLFromOffset`, and
    /// invariant 1 on `pendingBackgroundTaskIds` for what the whole-line rule
    /// protects.
    ///
    /// Split out and `internal` for the reason `jsonlTailHasCompletion` and
    /// `extractLaunchAckTaskId` are: the probe can then pin the rule, and the
    /// failure it guards against — an offset advanced past a marker nothing
    /// will ever re-read — is silent, permanent, and indistinguishable from
    /// the bug this whole subsystem exists to prevent. The byte arithmetic is
    /// also the one part of the read that a later "simplify" would plausibly
    /// touch without a file to test against.
    ///
    /// **No closure literal here, and that is not style.** `ShimProcess`
    /// conforms to `WKScriptMessageHandler`, which the SDK marks
    /// `WK_SWIFT_UI_ACTOR`, so global-actor inference makes the WHOLE CLASS
    /// `@MainActor` — this `static` included. A closure literal written here
    /// inherits that isolation, and handing it to a stdlib callback taking a
    /// plain (non-`Sendable`) function makes the compiler emit a main-queue
    /// check at the closure's entry; this runs on `bgReadQueue`, so an
    /// innocuous `.map { … }` aborts the process on the first read with
    /// `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue
    /// [com.apple.main-thread]`. Measured, not theorised — that crash is what
    /// sent this function's first version back, and the check is visible in
    /// the binary as a `swift_task_isCurrentExecutor` call inside the
    /// closure's own symbol.
    ///
    /// State the rule narrowly, because the broad version is wrong twice
    /// over: it is about NON-`@Sendable` closure LITERALS WRITTEN IN THIS
    /// CLASS, on a path reachable from a background queue. A `@Sendable`
    /// parameter cannot inherit isolation, which is why the
    /// `bgReadQueue.async { … }` closure a few hundred lines up is fine; and
    /// a stdlib higher-order call is fine too (`lastIndex(of:)` below reaches
    /// `lastIndex(where:)`, whose closure is written inside the stdlib and
    /// inherits nothing from here). There is also a one-keyword escape:
    /// marking a member `nonisolated` drops both the inference and the
    /// emitted check. Not used here — the surrounding invariants are
    /// documented against this shape — but it is the fix, not closure
    /// avoidance. See the NSRegularExpression note in CLAUDE.md: same
    /// mechanism from the outside, `enumerateMatches` takes a closure written
    /// at the call site and `numberOfMatches` does not.
    static func wholeLinePrefixLength(_ data: Data) -> Int {
        guard let newline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        // `distance(from: data.startIndex, …)` rather than the index itself:
        // `readToEnd()` hands back a zero-based `Data`, but a slice (what a
        // caller gets from `prefix`/`dropFirst`) carries the parent's indices,
        // and subtracting from 0 there would over-count by the slice's origin.
        return data.distance(from: data.startIndex, to: newline) + 1
    }

    /// Current byte size of the session JSONL, or nil when the file is not
    /// reachable (SSH remote / not yet flushed). Used to snapshot the launch
    /// offset at bg-task detection time so `reconcileCompletedBackgroundTasks`
    /// can scan from a tight lower bound instead of a fixed-size tail.
    ///
    /// Distinguishes three failure modes so a regression doesn't hide as the
    /// documented "not flushed yet" path:
    /// 1. `path == nil` — caller short-circuited (SSH remote / no session id).
    ///    Quiet, expected.
    /// 2. `fileReadNoSuchFile` — race between `sessionJSONLPath`'s
    ///    `fileExists` probe and us. Expected/recoverable, debug log.
    /// 3. Any other `attributesOfItem` failure (EPERM/EACCES/EIO) OR a
    ///    `.size` attribute that can't be bridged to `UInt64` — both
    ///    are unexpected; warn so they surface in the unified log.
    ///
    /// In all failure modes the call site falls through to `?? 0`, meaning
    /// "scan from the file start on the next pass" — over-scanning is
    /// preferred over silently freezing the wrong hourglass.
    private static func jsonlFileSize(path: String?) -> JSONLByteOffset? {
        guard let path else { return nil }
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path)
        } catch CocoaError.fileReadNoSuchFile {
            logger.debug("[bg] jsonlFileSize: file vanished path=\(path, privacy: .private)")
            return nil
        } catch {
            logger.warning("[bg] jsonlFileSize I/O error: \(error.localizedDescription, privacy: .public) path=\(path, privacy: .private)")
            return nil
        }
        guard let size = attrs[.size] as? JSONLByteOffset else {
            // Bridge to UInt64 fails only on a Foundation API regression —
            // log so it doesn't masquerade as "file not flushed yet".
            logger.warning("[bg] jsonlFileSize: .size attribute missing or unbridgeable path=\(path, privacy: .private)")
            return nil
        }
        return size
    }

    /// Safety margin subtracted from the captured launch offset to absorb the
    /// fast-completion race: a very short bg task can be launched, completed,
    /// and have its `<task-notification>` flushed BEFORE Swift gets around to
    /// processing the `assistant` io_message that started it. Without the
    /// margin the captured offset would lie past the marker and a reconcile
    /// scan would miss it, leaving the hourglass stuck. 1 MB covers many
    /// hundreds of typical assistant + tool_result + queue-operation lines,
    /// so the scan window always reaches back past the launch even under
    /// heavy CLI write activity.
    private static let bgScanSafetyMarginBytes: JSONLByteOffset = 1 * 1024 * 1024

    /// Detect `tool_use` blocks whose call kicked off a background task
    /// (Bash with `run_in_background:true`, or Agent with same flag).
    /// We only inspect the final `assistant` io_message — for stream_event
    /// content_block_start the `input` field is typically empty (input arrives
    /// over later content_block_delta `input_json_delta` events), so the
    /// `run_in_background` flag isn't observable there. The assistant message
    /// fires within a few hundred ms of the tool call, which is plenty fast
    /// for a between-turns indicator.
    private func detectBackgroundTaskLaunch(in ioMsg: [String: Any]) {
        guard ioMsg["type"] as? String == "assistant",
              let assistantMsg = ioMsg["message"] as? [String: Any],
              let content = assistantMsg["content"] as? [[String: Any]]
        else { return }

        // Snapshot JSONL size once per assistant message — a single message can
        // launch several bg tools (rare but possible) and they share this
        // lower bound. Subtract `bgScanSafetyMarginBytes` to absorb the
        // fast-completion race documented on that constant: without the margin
        // a reconcile scan starts AFTER the completion marker and never sees
        // it. Including a few extra MB of JSONL in the scan is harmless —
        // `jsonlTailHasCompletion` looks for `<tool-use-id>X</tool-use-id>`,
        // an angle-bracket tag wrapper that the CLI only emits in
        // `queue-operation`/synthetic-user lines (completion). The assistant
        // launch line itself writes the id as the JSON field `"id":"toolu_…"`
        // (no tag wrapper), so including it in the scan window cannot
        // false-match. Verified against live session JSONLs.
        let rawSize = Self.jsonlFileSize(path: sessionJSONLPath()) ?? 0
        let launchOffset: JSONLByteOffset = rawSize > Self.bgScanSafetyMarginBytes
            ? rawSize - Self.bgScanSafetyMarginBytes
            : 0
        var added: [String] = []
        var skippedHistoric = 0
        for block in content {
            guard let id = block["id"] as? String,
                  Self.isBackgroundLaunchBlock(block)
            else { continue }
            // Historic replay guard — see `historicToolUseIds` for why.
            if historicToolUseIds.contains(id) {
                skippedHistoric += 1
                continue
            }
            // Only insert on first sight: re-inserting would replace a
            // smaller (safer) launch offset with a larger one — possibly one
            // that's past this id's completion marker — and the reconcile scan
            // would miss it. The `== nil` guard is therefore an invariant,
            // not an optimization.
            if pendingBackgroundTaskIds[id] == nil {
                pendingBackgroundTaskIds[id] = launchOffset
                added.append(id)
            }
        }
        if skippedHistoric > 0 {
            logger.debug("[bg] skipped historic replays count=\(skippedHistoric, privacy: .public)")
        }
        if !added.isEmpty {
            // `notice`, like every other [bg] line that RECORDS A DECISION
            // (launch, cleared, purged, ack-mapped): `info` lives only in an
            // in-memory ring buffer, so those records survive exactly as long
            // as nobody needs them — which is the wrong property for a
            // subsystem whose failure mode is silent staleness. Issue #132
            // was investigated soon enough to still quote its `info` lines;
            // the next one will not necessarily be, and that is the case
            // this level change is for. Volume is a handful of lines per bg
            // task. The skip/no-op lines stay `debug`; they say nothing
            // happened.
            logger.notice("[bg] launch +\(added.count, privacy: .public) ids=\(added.joined(separator: ","), privacy: .public) offset=\(launchOffset, privacy: .public) rawSize=\(rawSize, privacy: .public) pending=\(self.pendingBackgroundTaskIds.count, privacy: .public)")
            refreshWaitingState()
        }
    }

    /// Detect `TaskStop` tool_use blocks and purge the matching pending bg
    /// launch. The CLI's kill path does NOT emit a `<task-notification>` /
    /// `<tool-use-id>` completion marker (natural completion does), so the
    /// JSONL reconcile in `reconcileCompletedBackgroundTasks` never sees
    /// these — without this live-stream path the hourglass sticks until
    /// Canopy restart. Mirrors `detectBackgroundTaskLaunch`: only the final
    /// `assistant` io_message is inspected (`stream_event` content_block_start
    /// typically has empty `input`, so `task_id` isn't observable there).
    /// Like `detectBackgroundTaskLaunch`, does not gate on
    /// `parent_tool_use_id` — TaskStops from any turn (including a
    /// subagent) must clear the matching pending launch.
    private func detectTaskStopLaunch(in ioMsg: [String: Any]) {
        guard ioMsg["type"] as? String == "assistant",
              let assistantMsg = ioMsg["message"] as? [String: Any],
              let content = assistantMsg["content"] as? [[String: Any]]
        else { return }

        for block in content {
            guard block["type"] as? String == "tool_use",
                  block["name"] as? String == "TaskStop"
            else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            guard let taskId = input["task_id"] as? String, !taskId.isEmpty else {
                logger.warning("[bg] TaskStop tool_use missing/empty task_id — CLI shape drift? keys=\(Array(input.keys).joined(separator: ","), privacy: .public)")
                continue
            }
            purgePendingByTaskId(taskId, reason: "TaskStop tool_use")
        }
    }

    /// Reverse-lookup `bgTaskIdMap` for `taskId` and drop the matching
    /// entry from both the map and `pendingBackgroundTaskIds`. Also finishes
    /// a matching bg-Agent subagent row via `completeIfPresent` so the
    /// activity list checkmark lands on the kill, not the parent turn's
    /// `result` (see issue #91). No-op (debug log) when no mapping exists —
    /// expected for TaskStops of tasks this shim never launched, or launches
    /// whose ack arrived before we started tracking. Always refreshes waiting
    /// state on a successful purge so the hourglass drops in the same turn
    /// as the kill.
    private func purgePendingByTaskId(_ taskId: String, reason: String) {
        guard let entry = bgTaskIdMap.first(where: { $0.value == taskId }) else {
            logger.debug("[bg] TaskStop no-mapping taskId=\(taskId, privacy: .public) reason=\(reason, privacy: .public)")
            return
        }
        let toolUseId = entry.key
        bgTaskIdMap.removeValue(forKey: toolUseId)
        pendingBackgroundTaskIds.removeValue(forKey: toolUseId)
        let subagentTransitioned = subagentTracker.completeIfPresent(id: toolUseId, at: Date())
        if subagentTransitioned {
            statusBarData?.subagents = subagentTracker.rows
        }
        logger.notice("[bg] TaskStop purged taskId=\(taskId, privacy: .public) toolUseId=\(toolUseId, privacy: .public) reason=\(reason, privacy: .public) remaining=\(self.pendingBackgroundTaskIds.count, privacy: .public) subagentTransitioned=\(subagentTransitioned, privacy: .public)")
        refreshWaitingState()
    }

    /// Process top-level `user` io_messages that carry `tool_result` blocks.
    /// Two jobs: (1) capture the CLI `task_id` from a bg-launch ack so
    /// `bgTaskIdMap` can reverse-lookup later TaskStops; (2) safety-net
    /// purge on TaskStop tool_result text in case the tool_use observation
    /// was lost (shim replay race). Subagent-scope tool_results are
    /// ignored: the reverse-lookup map is load-bearing only for
    /// `TaskStop` kills (whose completion markers never appear in the
    /// JSONL, unlike natural completion), and TaskStops from subagents
    /// are rare enough that adding subagent-side ack seeding here would
    /// just churn state for no observed use case. If a subagent-issued
    /// TaskStop ever reproduces the sticky-hourglass symptom, drop this
    /// gate then. Plain-string `message.content` (a normal user prompt)
    /// is also a no-op: only the array-of-blocks shape carries
    /// tool_results.
    private func processUserToolResults(_ ioMsg: [String: Any]) {
        // JSON `null` deserializes as NSNull — use `is String` so a top-level
        // message carrying `"parent_tool_use_id": null` is not skipped.
        if ioMsg["parent_tool_use_id"] is String { return }
        guard let userMsg = ioMsg["message"] as? [String: Any],
              let content = userMsg["content"] as? [[String: Any]]
        else { return }

        for block in content {
            guard block["type"] as? String == "tool_result" else { continue }
            let text = Self.extractToolResultText(block)

            // Launch-ack path: only map ids we already tracked as pending
            // bg launches. A tool_result for an unrelated tool_use that
            // happens to contain similar wording must not seed the map.
            if let toolUseId = block["tool_use_id"] as? String,
               pendingBackgroundTaskIds[toolUseId] != nil {
                if let taskId = Self.extractLaunchAckTaskId(text) {
                    let previous = bgTaskIdMap[toolUseId]
                    if previous != taskId {
                        bgTaskIdMap[toolUseId] = taskId
                        logger.notice("[bg] ack-mapped toolUseId=\(toolUseId, privacy: .public) taskId=\(taskId, privacy: .public)")
                    }
                } else {
                    logger.warning("[bg] pending launch tool_result missing ack task_id — CLI wording drift? toolUseId=\(toolUseId, privacy: .public) textPrefix=\(text.prefix(80), privacy: .public)")
                }
            }

            // TaskStop-result safety net — redundant with
            // `detectTaskStopLaunch` in the common case, but survives a
            // lost tool_use observation.
            if let stoppedId = Self.extractStoppedTaskId(text) {
                purgePendingByTaskId(stoppedId, reason: "TaskStop tool_result")
            }
        }
    }

    /// True if `block` is a `tool_use` for `Bash` or `Agent` whose input
    /// has `run_in_background:true`. Static so `_SidebarLogicProbe` can test
    /// the predicate without spawning a shim.
    static func isBackgroundLaunchBlock(_ block: [String: Any]) -> Bool {
        guard block["type"] as? String == "tool_use" else { return false }
        let name = block["name"] as? String ?? ""
        guard name == "Bash" || name == "Agent" else { return false }
        let input = block["input"] as? [String: Any] ?? [:]
        return input["run_in_background"] as? Bool == true
    }

    /// Scan an io_message for `tool_use` blocks named `AskUserQuestion`,
    /// and also clear the AskUserQuestion flag when a new assistant turn
    /// begins (message_start stream_event). The latter handles the case
    /// where the user dismissed the answer panel via Escape and Claude
    /// started a new response without a fresh AskUserQuestion.
    private func detectAskUserQuestion(in ioMsg: [String: Any]) {
        let ioType = ioMsg["type"] as? String
        var found = false
        var newTurnStart = false
        if ioType == "assistant",
           let assistantMsg = ioMsg["message"] as? [String: Any],
           let content = assistantMsg["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "tool_use",
                   block["name"] as? String == "AskUserQuestion" {
                    found = true
                    break
                }
            }
        } else if ioType == "stream_event",
                  let event = ioMsg["event"] as? [String: Any] {
            let evType = event["type"] as? String
            if evType == "content_block_start",
               let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               block["name"] as? String == "AskUserQuestion" {
                found = true
            } else if evType == "message_start" {
                newTurnStart = true
            }
        }
        if newTurnStart && lastAssistantHadAskUserQuestion {
            // Stale flag from the previous turn — clear so the icon
            // returns to the thinking flower for THIS turn (and we'll
            // re-set it if the new turn also calls AskUserQuestion).
            lastAssistantHadAskUserQuestion = false
            refreshAskingState()
        }
        if found && !lastAssistantHadAskUserQuestion {
            lastAssistantHadAskUserQuestion = true
            // Immediately reflect — CLI won't emit `result` until the user
            // picks an answer, so waiting for that would never trigger the
            // raised-hand icon.
            refreshAskingState()
        }
    }

    /// Track CLI working state from io_message events flowing to webview.
    /// Message structure: {type:"from-extension", message:{type:"io_message", message:{type:"assistant"|"result"|...}}}
    private func trackWorkingState(_ message: [String: Any]) {
        guard message["type"] as? String == "from-extension",
              let nested = message["message"] as? [String: Any],
              nested["type"] as? String == "io_message",
              let ioMsg = nested["message"] as? [String: Any],
              let ioType = ioMsg["type"] as? String
        else { return }

        switch ioType {
        case "assistant", "stream_event":
            detectAskUserQuestion(in: ioMsg)
            detectBackgroundTaskLaunch(in: ioMsg)
            detectTaskStopLaunch(in: ioMsg)
            isWorking = true
        case "user":
            processUserToolResults(ioMsg)
        case "result":
            if isWorking {
                isWorking = false
                postTaskCompletedNotification()
            }
            // If the turn ended without any AskUserQuestion permission
            // request being tracked, the `tool_use`-stream-derived
            // `lastAssistantHadAskUserQuestion` flag is orphaned — e.g. user
            // pressed Stop and the extension sent `cancel_request` before
            // the corresponding `tool_permission_request` ever reached us,
            // so neither lifecycle path could clear it. Drop it now so the
            // hand icon doesn't linger until the next user message. When a
            // permission request IS tracked, leave the flag alone — the
            // user is genuinely being asked.
            if pendingAskUserQuestionRequestIds.isEmpty {
                lastAssistantHadAskUserQuestion = false
            }
            refreshAskingState()
        default:
            break
        }
    }

    // MARK: - Status Bar Data Extraction

    /// Extract usage/cost/model data from CLI events for the native status bar.
    private func extractStatusData(_ message: [String: Any]) {
        guard let data = statusBarData else { return }
        guard message["type"] as? String == "from-extension",
              let nested = message["message"] as? [String: Any]
        else { return }

        // Intercept usage_update requests from extension → webview
        if let request = nested["request"] as? [String: Any],
           request["type"] as? String == "usage_update",
           let utilization = request["utilization"] as? [String: Any]
        {
            SharedRateLimitData.shared.update(from: utilization)
            return
        }

        // io_message events from CLI
        guard nested["type"] as? String == "io_message",
              let ioMsg = nested["message"] as? [String: Any],
              let ioType = ioMsg["type"] as? String
        else { return }

        if subagentTracker.observe(ioMsg, now: Date()) {
            data.subagents = subagentTracker.rows
        }

        switch ioType {
        case "system":
            // `subtype` and a non-empty `model` are both required because the
            // CLI emits `system` frames under several subtypes (status,
            // hook_started, task_notification, …) and only `init` carries the
            // resolved model. Canopy also synthesises a `subtype: "status"`
            // frame of its own when it patches `launch_claude` — that one
            // travels outbound via `sendToWebView` and cannot reach this
            // branch, so it is precedent for the shape rather than a hazard
            // this guard defends against.
            //
            // NOTE: nothing probe-tests that the CLI's `init` frame actually
            // arrives here — the probe only reaches the pure
            // `mainModelUsage`. The dependency is real: if it never arrives,
            // `cliResolvedModel` stays empty and every lookup misses. The
            // evidence it does is the CLI's documented event list (`system`
            // is one of the types the extension forwards verbatim as
            // io_message, see the Protocol notes in CLAUDE.md) plus the
            // captures on `mainModelUsage`.
            if ioMsg["subtype"] as? String == "init",
               let model = ioMsg["model"] as? String, !model.isEmpty
            {
                cliResolvedModel = model
            }

        case "stream_event":
            guard let event = ioMsg["event"] as? [String: Any],
                  let eventType = event["type"] as? String
            else { return }

            if eventType == "message_start" {
                // Clear compact indicator on next API call (fresh context reported)
                data.clearCompactIndicator()
                requestUsageUpdate()
            }

            // Neither `message_start` block in this branch is gated on
            // `isMainConversationMessage`, unlike the `assistant` branch
            // below. The CLI's stream-json writer hardcodes
            // `parent_tool_use_id: null` on every `stream_event` frame, and
            // subagent traffic is routed out as `assistant` / `user` frames
            // instead — a subagent-tagged `stream_event` does not exist
            // (verified in CLI 2.1.217). A guard here would be inert.
            //
            // Do not add one "for safety". The failure it would create is
            // worse than the one it prevents: if a future CLI stamped a
            // non-null `parent_tool_use_id` on MAIN-loop `stream_event` frames
            // too, the guard would reject every `message_start` and
            // `contextUsed` would stop updating — while the `result` branch
            // keeps writing `contextMax`, so `StatusBarView`'s `hasContext`
            // stays true and the bar renders a frozen, plausible-looking
            // number instead of failing visibly. See issue #106.
            //
            // The `data.model` write below feeds the status bar's model label
            // only. #108 deliberately does NOT read it for the context-meter
            // lookup — see `mainModelUsage` — so this branch and the `result`
            // branch stay independent, and the frozen-number reasoning above
            // still describes what a guard here would actually cause.
            if eventType == "message_start",
               let msg = event["message"] as? [String: Any]
            {
                // Model name (raw ID; StatusBarView formats it for display)
                if let model = msg["model"] as? String {
                    data.model = model
                }
                // Context usage from message_start (current context at API call time)
                if let usage = msg["usage"] as? [String: Any] {
                    let input = usage["input_tokens"] as? Int ?? 0
                    let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    data.contextUsed = input + cacheCreate + cacheRead
                }
            }

        case "result":
            if let modelUsage = ioMsg["modelUsage"] as? [String: Any] {
                if let usage = Self.mainModelUsage(modelUsage: modelUsage, mainModel: cliResolvedModel) {
                    data.contextMax = usage.contextWindow
                    data.maxOutputTokens = usage.maxOutputTokens
                    UserDefaults.standard.set(usage.contextWindow, forKey: Self.contextMaxKey(workingDirectory))
                    UserDefaults.standard.set(usage.maxOutputTokens, forKey: Self.maxOutputTokensKey(workingDirectory))
                } else {
                    // Leaving the previous values in place is the deliberate
                    // choice — see `mainModelUsage`, which also records what
                    // it costs. Warn so a silent CLI rename is discoverable in
                    // the unified log rather than only as a percentage
                    // climbing against a stale denominator (or, on a directory
                    // with no cache, a meter that never appears).
                    //
                    // "no usable entry" covers every way the lookup returns
                    // nil — model not yet known, key absent, value not a
                    // dictionary, no positive `contextWindow`. Naming only
                    // the key-absent case would contradict the key list
                    // printed beside it in the others.
                    //
                    // Scope of the claim above: this catches a renamed model
                    // id or a renamed `contextWindow`. Two renames stay
                    // silent — `modelUsage` ITSELF (falls out of the
                    // enclosing `if let`) and `maxOutputTokens` (the `?? 0`
                    // returns a hit, and the only symptom is every threshold
                    // degrading to `.unknown`). Both gaps are unaddressed.
                    logger.warning(
                        "no usable modelUsage entry for main model \"\(self.cliResolvedModel, privacy: .public)\"; context limits left unchanged (keys: \(modelUsage.keys.sorted().joined(separator: ", "), privacy: .public))"
                    )
                }
            }
            // Refresh VCS branch (user may have switched branches during session)
            // Dispatch to background to avoid blocking main thread with subprocess calls
            let dir = workingDirectory
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let vcsInfo = Self.detectVCSInfo(at: dir) else { return }
                DispatchQueue.main.async {
                    self?.statusBarData?.vcsType = vcsInfo.type
                    self?.statusBarData?.gitBranch = vcsInfo.branch
                }
            }
            // Refresh rate limits after each turn
            requestUsageUpdate()

        case "user":
            data.messageCount += 1
            requestUsageUpdate()

        case "assistant":
            data.messageCount += 1
            requestUsageUpdate()
            // Update contextUsed to include output_tokens (matches CC popup: input + cache_creation + cache_read + output)
            if Self.isMainConversationMessage(ioMsg),
               let msg = ioMsg["message"] as? [String: Any],
               let usage = msg["usage"] as? [String: Any]
            {
                let input = usage["input_tokens"] as? Int ?? 0
                let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                data.contextUsed = input + cacheCreate + cacheRead + output
            }

        case "compact_boundary":
            data.resetContext()

        default:
            break
        }
    }

    /// True when an io_message belongs to the main conversation rather than a
    /// subagent's or skill's nested turn. These reach us as the CLI's
    /// `agent_progress` / `skill_progress` events, which its stream-json writer
    /// re-emits as `assistant` / `user` frames with `parent_tool_use_id` set —
    /// NOT via the `--forward-subagent-text` flag, which Canopy does not pass
    /// (don't conclude the guard is dead from that flag's absence). Such a
    /// frame's `usage` describes the SUBAGENT's context, so letting it reach
    /// the status bar would make the meter dive mid-turn and snap back at turn
    /// end.
    ///
    /// Not `stream_event` (hardcoded `null` there — see the comment in that
    /// branch) and not `result` (the emitted frame has no such field at all,
    /// so a subagent-tagged `result` cannot exist).
    ///
    /// The key is absent on some frames and present-but-JSON-`null` on others,
    /// and `null` bridges to `NSNull` rather than `nil` — hence two checks.
    ///
    /// `messageCount` and `requestUsageUpdate()` are left outside the guard:
    /// they count all traffic, subagent included.
    ///
    /// Static so `_SidebarLogicProbe` can test the predicate without spawning
    /// a shim.
    static func isMainConversationMessage(_ ioMsg: [String: Any]) -> Bool {
        let parentToolUseId = ioMsg["parent_tool_use_id"]
        return parentToolUseId == nil || parentToolUseId is NSNull
    }

    /// The `result` event's `modelUsage` entry for the main conversation's
    /// model, or `nil` when the map has no usable entry under that name.
    ///
    /// `modelUsage` is a process-global accumulator in the CLI: it carries an
    /// entry for every model the session touched, subagents included. The
    /// previous implementation took the widest `contextWindow` in the map,
    /// which is only correct while the main model is the widest thing in the
    /// session. Measured against CLI 2.1.217 — a Haiku main session
    /// (`--model haiku`) with one Opus subagent produces:
    ///
    ///     claude-haiku-4-5-20251001   contextWindow 200_000    maxOutputTokens 32_000
    ///     claude-opus-4-8[1m]         contextWindow 1_000_000  maxOutputTokens 64_000
    ///
    /// Both models cap to the same 20,000 output reserve, so the error is
    /// carried entirely by the window: `compactionWindow` became 967,000
    /// against a true 167,000. The meter read 5.8× optimistic — ~17% at a true
    /// 100% of the CLI's compact level. (100% of that level is not a promise
    /// that compaction is imminent; `StatusBarData.compactionWindow` lists the
    /// cases where the two diverge.) Issue #108.
    ///
    /// **`mainModel` must be the CLI's own resolved model string — the
    /// `system` / `init` event's `model`, tracked in `cliResolvedModel` — and
    /// NOT `StatusBarData.model`.** The two are different strings in the
    /// configuration Canopy ships by default, and only the first one keys
    /// `modelUsage`. Measured across nine captures against CLI 2.1.217 (the
    /// two rows below are the disagreements; the other seven agreed). These
    /// are capture-harness invocations — a local Canopy session writes the
    /// model into `~/.claude/settings.json` rather than passing `--model`, so
    /// read the first row as "no model selected":
    ///
    ///                             init.model            message_start.model  modelUsage key
    ///     no --model (default)    claude-opus-4-8[1m]   claude-opus-4-8      claude-opus-4-8[1m]
    ///     --model 'opus[1m]'      claude-opus-4-8[1m]   claude-opus-4-8      claude-opus-4-8[1m]
    ///
    /// `init.model` matched the key in 9 of 9; `message_start.model` in 7 of
    /// 9. Neither miss is exotic: `LauncherView` offers an empty model
    /// selection AND an explicit `opus[1m]`, and the spawn code only sets
    /// `CLAUDE_CODE_DISABLE_1M_CONTEXT` when `customApi == nil` AND a model
    /// was explicitly chosen AND it contains "opus" AND it lacks `[1m]` — so
    /// both of those selections go down the `[1m]` path, and the lookup would
    /// miss on every turn. On a directory with no cached pair that hides the
    /// meter completely; on one with a cache, see the degradation note below.
    ///
    /// What the suffix means is settled only in the negative: it does NOT
    /// mark "this entry is a subagent's". An earlier revision claimed exactly
    /// that, inferred from captures that all happened to pass `--model`, and
    /// it was wrong. Do not replace it with the equally tempting "it marks a
    /// resolved 1M tier" — the `opusMain` fixture in the probe is a bare key
    /// at a 1,000,000 window, which refutes that too. The captures establish
    /// which string to use; they do not explain the CLI's naming rule.
    ///
    /// `init` is also not a launch-only snapshot: the CLI re-emits it on a
    /// mid-session `/model` switch (measured — a `/model sonnet` turn emitted
    /// a second `init` carrying `claude-sonnet-5`, and `modelUsage` keyed the
    /// same), so this tracks the current model, which was the one property
    /// `message_start` was originally picked for. It tracks with a one-turn
    /// lag, though: `cliResolvedModel` moves at the new `init` while
    /// `contextMax` only moves at the following `result`, so the intervening
    /// turn is measured against the previous model's window.
    ///
    /// **Exact string match, deliberately — do not add suffix normalisation.**
    /// Stripping a trailing `[…]` tag would collapse `claude-opus-4-8` and
    /// `claude-opus-4-8[1m]` onto one bucket, and both can be present at once
    /// with different windows, so something would have to pick between them —
    /// exactly the widest-wins guess this function exists to remove. The bare
    /// id is not even a stable width on its own: it measured 1,000,000 with
    /// `CLAUDE_CODE_DISABLE_1M_CONTEXT` unset and 200,000 with it set, which
    /// is a second reason no rule over the string's shape can be trusted.
    /// With `init.model` as the source the normalisation is not needed in the
    /// first place: the string already carries whatever the CLI resolved.
    ///
    /// Returning `nil` writes nothing. On a directory opened for the first
    /// time that means `contextMax` stays `0` and `StatusBarView` hides the
    /// meter — the intended degradation, per #110: an absent meter is merely
    /// missing, while a wrong absolute token count presented as the line where
    /// requests fail is a lie.
    ///
    /// **That is not the whole picture, and the gap is known rather than
    /// overlooked.** On any directory that already has a cached pair, the
    /// restore in `init` has populated both values before the first `result`
    /// arrives, so a *persistent* miss leaves the previous model's numbers
    /// standing — and because the miss path also skips the cache write, they
    /// survive relaunches. Worse, the stale pair can be NARROWER than the
    /// truth (a directory last used on Haiku, reopened on 1M Opus), and that
    /// direction is not covered by the tooltip's level gate — see
    /// `StatusBarView.contextTooltip()`.
    ///
    /// Scoping the cache by model would close it, but `init` restores before
    /// any `system` / `init` frame has been seen, so no *resolved* name exists
    /// at that point — the launcher's requested model does exist, and is not
    /// the same thing (it is nil for the default selection, and `opus[1m]`
    /// where the resolved name is `claude-opus-4-8[1m]`). Validating rather than
    /// keying — cache the name alongside the pair and drop the restore once
    /// the first `init` disagrees — would preserve the eager restore and is
    /// the better shape; it is left out of #108 only because it is new
    /// behaviour rather than a fix to the reported bug. Hence a warning here.
    ///
    /// With `init.model` as the key source, none of the nine captures taken
    /// for #108 (2026-08-01, CLI 2.1.217) produced a miss. That is a stated
    /// sample, not a proof: nothing in the repo re-runs it, and exactly the
    /// same was believed of `message_start.model` until the default
    /// configuration was actually tried. Custom `ModelProvider` sessions were
    /// not among the nine and are the likeliest place for the two strings to
    /// disagree, since a third-party gateway canonicalises ids its own way.
    ///
    /// Static so `_SidebarLogicProbe` can test it without spawning a shim.
    static func mainModelUsage(
        modelUsage: [String: Any],
        mainModel: String
    ) -> (contextWindow: Int, maxOutputTokens: Int)? {
        guard !mainModel.isEmpty,
              let info = modelUsage[mainModel] as? [String: Any],
              let contextWindow = info["contextWindow"] as? Int,
              contextWindow > 0
        else { return nil }
        // `?? 0` matches the pre-#108 behaviour. Zero is handled downstream:
        // `StatusBarData.hasTrustedThresholds` refuses to derive levels from
        // it rather than treating it as "this model reserves no output".
        return (contextWindow, info["maxOutputTokens"] as? Int ?? 0)
    }

    /// Per-working-directory cache of the last known context limits, restored
    /// on launch so the meter has something to show before the session's first
    /// `result` arrives.
    ///
    /// The `.v2` infix retires the pre-#108 keys, which were written by the
    /// widest-wins picker and so may hold a subagent's window. Without the
    /// bump every existing install would restore its poisoned number on launch
    /// and keep showing it until the first turn completed.
    ///
    /// The infix only guarantees nothing reads the old pair again; the actual
    /// deletion is the opportunistic sweep in `init`. Neither changes the
    /// key's *scope*.
    ///
    /// These are still keyed by directory rather than by model, so a value
    /// cached by a different model in the same directory is still restored as
    /// if it applied. Unchanged by #108 — see `mainModelUsage` for why a
    /// model-scoped key is not a drop-in replacement.
    static func contextMaxKey(_ directory: URL) -> String {
        "statusBar.contextMax.v2.\(directory.path)"
    }

    /// See `contextMaxKey` — the two are written and read as a pair.
    static func maxOutputTokensKey(_ directory: URL) -> String {
        "statusBar.maxOutputTokens.v2.\(directory.path)"
    }

    private func postTaskCompletedNotification() {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Canopy"
        content.body = sessionTitle.isEmpty ? "Task completed" : "\(sessionTitle) — completed"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("Notification error: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - CLI Subprocess Exit Detection

    /// Called when stderr contains evidence that the CLI subprocess died
    /// while the shim (Node.js) is still running.
    private func handleCLISubprocessExit(_ line: String) {
        guard !isIntentionalStop else { return }
        // Extract exit code from "process exited with code NNN"
        let exitCode: Int32
        if let range = line.range(of: "exited with code "),
           let code = Int32(line[range.upperBound...].prefix(while: \.isNumber)) {
            exitCode = code
        } else {
            exitCode = -1
        }
        logger.error("CLI subprocess died (code \(exitCode)), stopping shim")
        resetActivityState()
        stop()
        delegate?.shimProcessDidCrash(self, status: exitCode)
    }

    // MARK: - Process Exit

    private func handleProcessExit(status: Int32, pid: pid_t) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if !descendantPids.isEmpty {
            Self.killProcessTree(descendantPids)
            descendantPids = []
        }

        // Even for intentional stops the bound session is about to be
        // dropped or replaced — clearing here keeps the sidebar consistent
        // through the crash/disconnect/close paths uniformly.
        resetActivityState()

        guard !isIntentionalStop else { return }

        if remoteHost != nil, let sessionId = activeSessionId {
            logger.error("SSH disconnection detected (status \(status)), requesting reconnect for session \(sessionId, privacy: .public)")
            delegate?.shimProcessDidDisconnect(self, sessionId: sessionId)
        } else {
            logger.error("Shim exited unexpectedly (status \(status))")
            delegate?.shimProcessDidCrash(self, status: status)
        }
    }

    private func showErrorInWebView(_ message: String) {
        // Escape backslash FIRST, then single quotes
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
            var el = document.getElementById('claude-error');
            if (!el) { el = document.createElement('pre'); el.id = 'claude-error'; document.body.prepend(el); }
            el.style.cssText = 'display:block;position:fixed;top:0;left:0;right:0;z-index:9999;margin:0;padding:12px 16px;background:#fee2e2;color:#991b1b;font-size:13px;white-space:pre-wrap;font-family:-apple-system,sans-serif;';
            el.textContent = '\(escaped)';
        })()
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - VCS Branch Detection

    /// Detect VCS type and current branch/bookmark for status bar display.
    /// Checks for jj first (`.jj/` directory), falls back to git.
    private static func detectVCSInfo(at directory: URL) -> (type: StatusBarData.VCSType, branch: String)? {
        let fm = FileManager.default

        // Check for jj repo
        let jjDir = directory.appendingPathComponent(".jj")
        if fm.fileExists(atPath: jjDir.path), let jjPath = findExecutable("jj") {
            let status = runCommand(jjPath, args: ["log", "-r", "@", "--no-graph", "-T",
                "if(empty, \"(empty)\", \"(modified)\")"], at: directory)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // 1. If @ has its own bookmarks, show them
            if let bookmarks = runCommand(jjPath, args: ["log", "-r", "@", "--no-graph", "-T", "bookmarks"], at: directory) {
                let trimmed = bookmarks.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "*", with: "")
                if !trimmed.isEmpty {
                    let first = trimmed.components(separatedBy: " ").first ?? trimmed
                    return (.jj, "\(first) \(status)".trimmingCharacters(in: .whitespaces))
                }
            }

            // 2. No bookmarks on @ — check parent for context ("working on top of main")
            if let parentBookmarks = runCommand(jjPath, args: ["log", "-r", "@-", "--no-graph", "-T", "bookmarks"], at: directory) {
                let trimmed = parentBookmarks.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "*", with: "")
                if !trimmed.isEmpty {
                    let first = trimmed.components(separatedBy: " ").first ?? trimmed
                    return (.jj, "\(first) \(status)".trimmingCharacters(in: .whitespaces))
                }
            }

            // 3. Fallback: short change ID + status
            if let changeId = runCommand(jjPath, args: ["log", "-r", "@", "--no-graph", "-T", "change_id.shortest(8)"], at: directory) {
                let trimmed = changeId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return (.jj, "\(trimmed) \(status)".trimmingCharacters(in: .whitespaces)) }
            }
            return (.jj, "")
        }

        // Fall back to git
        if let branch = runCommand("/usr/bin/git", args: ["rev-parse", "--abbrev-ref", "HEAD"], at: directory) {
            let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return (.git, trimmed) }
        }

        return nil
    }

    /// Find an executable by name, checking common locations that GUI apps miss from PATH.
    private static func findExecutable(_ name: String) -> String? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.cargo/bin",
            NSHomeDirectory() + "/.local/share/mise/shims",
        ]
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Run a command and return stdout as String, or nil on failure.
    private static func runCommand(_ executable: String, args: [String], at directory: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = directory
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            logger.debug("runCommand failed: \(executable) \(args.joined(separator: " ")): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }

    // MARK: - Process Tree Cleanup

    /// Recursively collect all descendant PIDs of a given process.
    /// Must be called BEFORE terminating the parent — once the parent exits,
    /// children are reparented to PID 1 and pgrep -P no longer finds them.
    private static func collectDescendants(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let directChildren = pgrepChildren(of: pid)
        var all = directChildren
        for child in directChildren {
            all.append(contentsOf: collectDescendants(of: child))
        }
        return all
    }

    /// Run `pgrep -P <pid>` and return the list of child PIDs.
    private static func pgrepChildren(of pid: pid_t) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            logger.warning("pgrep -P \(pid) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Send SIGTERM to all PIDs, wait briefly, then SIGKILL any survivors.
    private static func killProcessTree(_ pids: [pid_t]) {
        guard !pids.isEmpty else { return }

        for pid in pids {
            kill(pid, SIGTERM)
            logger.info("SIGTERM → PID \(pid)")
        }

        // Brief grace period for clean shutdown
        usleep(200_000) // 200ms

        for pid in pids {
            // Check if still alive (kill with signal 0 tests existence)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
                logger.info("SIGKILL → PID \(pid) (survived SIGTERM)")
            }
        }
    }
}
