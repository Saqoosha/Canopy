import Foundation

/// Job ETA gauge assertions, run from `SidebarLogicProbe.runAllTests()`.
/// Kept apart from that file only to stop it growing further; the harness
/// (one `record` per assertion, counted against `EXPECTED_ASSERTIONS`) is the same.
enum JobLogicProbe {
    @MainActor static func run(_ record: (String, Bool, String) -> Void) {
        estimator(record)
        wire(record)
        watcher(record)
        pushes(record)
        display(record)
        reviewFixes(record)
    }

    /// Findings from the final review (2026-11-21), each pinned before its fix.
    @MainActor
    private static func reviewFixes(_ record: (String, Bool, String) -> Void) {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func s(_ min: Double, _ d: Int, _ tot: Int = 10) -> JobSample { JobSample(at: t0.addingTimeInterval(min * 60), done: d, total: tot) }
        func ev(_ ss: [JobSample], _ nowMin: Double, failures: Int = 0) -> JobSnapshot {
            JobEstimator.evaluate(label: "x", samples: ss, failures: failures, now: t0.addingTimeInterval(nowMin * 60), stallMinutes: nil)
        }
        // I1: one unit left at 10 min per unit, read 12 min after the last move.
        let late = ev([s(0, 7), s(10, 8), s(20, 9)], 32)
        record("review: the finish time is never in the past",
               late.state == .running && (late.etaAt.map { $0 >= t0.addingTimeInterval(32 * 60) } ?? false), "\(late)")
        // I2: a first unit that takes 20 min is not a stall.
        record("review: a slow first unit is still measuring at 20 min", ev([s(0, 0, 100)], 20).state == .measuring, "")
        record("review: a job that never moves stalls after the first-unit floor", ev([s(0, 0, 100)], 61).state == .stalled, "")
        // M2: a failed reading never turns a job into a stall.
        record("review: a failing probe does not report a stall",
               ev([s(0, 300, 793), s(5, 340, 793), s(10, 380, 793)], 26, failures: 1).state != .stalled, "")

        // I3: a timed-out ssh probe says so, and an unknown job backs off.
        let remote = JobSpec(resumeId: "r", label: "L", probe: "p", host: "rt4090", total: nil, interval: 150, stallMinutes: nil)
        var track = JobTrack(spec: remote)
        track.record(output: nil, exitStatus: -1, at: t0)
        record("review: a timed-out ssh probe carries a note", track.note?.contains("ssh") == true, "\(String(describing: track.note))")
        track.record(output: nil, exitStatus: -1, at: t0.addingTimeInterval(150))
        track.record(output: nil, exitStatus: -1, at: t0.addingTimeInterval(300))
        record("review: an unknown job waits 15 min between runs",
               !track.shouldRun(now: t0.addingTimeInterval(450))
                   && track.shouldRun(now: t0.addingTimeInterval(300 + JobTrack.unknownRetrySeconds)), "")
        var healthy = JobTrack(spec: remote)
        healthy.record(output: "1/10", exitStatus: 0, at: t0)
        record("review: a healthy job runs every tick", healthy.shouldRun(now: t0.addingTimeInterval(150)), "")

        // M1: a probe whose pipeline hangs is killed at the timeout, children included.
        let started = Date()
        let hung = JobWatcher.runSync(["/bin/sh", "-c", "sleep 30 | cat"], env: ProcessInfo.processInfo.environment, timeout: 1)
        let took = Date().timeIntervalSince(started)
        record("review: a hung pipeline is killed at the timeout", hung.status == JobWatcher.timedOut && took < 5, "status=\(hung.status) took=\(took)")
        let ok = JobWatcher.runSync(["/bin/sh", "-c", "echo 3/10"], env: ProcessInfo.processInfo.environment, timeout: 5)
        record("review: a quick probe returns its output", ok.status == 0 && ok.output?.contains("3/10") == true, "\(ok)")
        shipItFixes(record)
        limits(record)
    }

    /// Canopy#434's two leftovers: the unbounded wait after the pipe closes, and a reaped session
    /// taking its running job with it.
    @MainActor
    private static func limits(_ record: (String, Bool, String) -> Void) {
        let started = Date()
        let closed = JobWatcher.runSync(["/bin/sh", "-c", "echo 1/10; exec >/dev/null 2>&1; sleep 30"],
                                        env: ProcessInfo.processInfo.environment, timeout: 1)
        let took = Date().timeIntervalSince(started)
        record("limits: a probe that closes stdout and keeps running is cut off at the timeout",
               closed.status == JobWatcher.timedOut && took < 5, "status=\(closed.status) took=\(took)")

        record("limits: an unfinished job keeps an idle session from being reaped",
               ShimProcess.reaperHolds(heldByPhone: false, openedByControl: false, watched: false, activeJob: true), "")
        record("limits: no job leaves the reaper as before",
               !ShimProcess.reaperHolds(heldByPhone: false, openedByControl: false, watched: false, activeJob: false), "")
        let running = JobSnapshot(label: "x", done: 1, total: 10, etaAt: nil, state: .running, stalledSince: nil)
        let finished = JobSnapshot(label: "x", done: 10, total: 10, etaAt: nil, state: .done, stalledSince: nil)
        record("limits: a finished job no longer holds the session",
               JobWatcher.holdsSession(running) && JobWatcher.holdsSession(JobSnapshot(label: "x", done: 0, total: 0, etaAt: nil, state: .measuring, stalledSince: nil))
                   && !JobWatcher.holdsSession(finished) && !JobWatcher.holdsSession(nil), "")
    }

    /// Findings from /ship-it on #434 and Canopy-Mobile#108.
    @MainActor
    private static func shipItFixes(_ record: (String, Bool, String) -> Void) {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func s(_ min: Double, _ d: Int, _ tot: Int = 100) -> JobSample { JobSample(at: t0.addingTimeInterval(min * 60), done: d, total: tot) }
        func ev(_ ss: [JobSample], _ nowMin: Double, failures: Int = 0, previous: JobState? = nil) -> JobSnapshot {
            JobEstimator.evaluate(label: "x", samples: ss, failures: failures, now: t0.addingTimeInterval(nowMin * 60),
                                  stallMinutes: nil, previous: previous)
        }
        // Registered 19 min into a 20 min unit: the first move says nothing about the rate.
        let oneMove = ev([s(0, 3), s(1, 4)], 2)
        record("ship: one move after registering is still measuring", oneMove.state == .measuring && oneMove.etaAt == nil, "\(oneMove)")
        record("ship: one move does not set a 15 min stall threshold", ev([s(0, 3), s(1, 4)], 17).state == .measuring, "")
        // 15 min window: fast long ago, slow lately.
        let mixed = ev([s(0, 0), s(1, 30), s(2, 60), s(30, 61), s(40, 62), s(50, 63)], 50)
        let expected = t0.addingTimeInterval(50 * 60 + Double(100 - 63) * 10 * 60)
        record("ship: the rate comes from the last 15 min", mixed.etaAt.map { abs($0.timeIntervalSince(expected)) < 120 } == true, "\(mixed)")
        // 15 min floor over a fast median.
        let fast = ev([s(0, 0), s(2.5, 1), s(5, 2), s(7.5, 3)], 17.5)
        record("ship: the stall floor holds over fast units", fast.state == .running, "\(fast)")
        // A stalled job stays stalled through one failed reading.
        let still = ev([s(0, 300, 793), s(5, 340, 793), s(10, 380, 793)], 30, failures: 1, previous: .stalled)
        record("ship: one failed reading keeps a stall", still.state == .stalled && still.etaAt == nil, "\(still)")
        // Counts that would overflow a date are not readings.
        record("ship: an implausible count is not a reading",
               JobEstimator.parse("9223372036854775000/9223372036854775807", total: nil) == nil
                   && JobEstimator.parse("5/0", total: nil) == nil, "")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 21))!
        let later = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 13, minute: 5))!
        record("ship: two days out shows the date", JobDisplay.timeLabel(later, now: now, calendar: cal) == "11/23 13:05",
               JobDisplay.timeLabel(later, now: now, calendar: cal))

        let stalled = JobSnapshot(label: "h7", done: 680, total: 1077, etaAt: nil, state: .stalled, stalledSince: t0)
        record("ship: an asking row keeps its question over a stall",
               JobDisplay.secondLine(.asking, job: stalled, attentionLine: "Bash: make") == "Bash: make", "")
        record("ship: an idle row with a stall shows the count",
               JobDisplay.secondLine(.idle, job: stalled, attentionLine: nil) == "680/1077 で止まっている", "")
        record("ship: an unread row shows its line", JobDisplay.secondLine(.unread, job: nil, attentionLine: "done") == "done", "")
        record("ship: an idle row shows nothing", JobDisplay.secondLine(.idle, job: nil, attentionLine: "x") == nil, "")
        let empty = JobSnapshot(label: "IG", done: 0, total: 0, etaAt: nil, state: .measuring, stalledSince: nil)
        record("ship: hover without a reading has no 0/0", JobDisplay.help(empty, now: t0) == "IG · 計測中", JobDisplay.help(empty, now: t0))

        let localSpec = JobSpec(resumeId: "r", label: "L", probe: "p", host: nil, total: nil, interval: 150, stallMinutes: nil)
        var local = JobTrack(spec: localSpec)
        local.record(output: "partial\n", exitStatus: 2, at: t0)
        record("ship: a failed local probe names why", local.note == "exit 2: partial", "\(String(describing: local.note))")
        local.record(output: "starting\n", exitStatus: 0, at: t0)
        record("ship: output without a count says so", local.note == "出力に数が無い", "\(String(describing: local.note))")
        let orphan = JobWatcher.runSync(["/bin/sh", "-c", "sleep 30 & echo 1/10"], env: ProcessInfo.processInfo.environment, timeout: 1)
        record("ship: a background child holding the pipe does not outlast the timeout",
               orphan.status == JobWatcher.timedOut && orphan.output?.contains("1/10") == true, "\(orphan)")
        let big = JobWatcher.runSync(["/bin/sh", "-c", "yes"], env: ProcessInfo.processInfo.environment, timeout: 5)
        record("ship: endless output is cut off", big.status == JobWatcher.tooMuchOutput, "status=\(big.status)")

        for (host, ok) in [("rt4090", true), ("me@studio.local", true), ("-oProxyCommand=x", false), ("a b", false)] {
            record("ship: host \(host) is \(ok ? "accepted" : "refused")", JobSpec.isValidHost(host) == ok, "")
        }
        var sent: [[String: Any]] = []
        let control = ControlSession(store: SessionStore(), isLocal: true, allowBypass: { false }) { sent.append($0) }
        for (id, extra) in [("V1", ["stallMinutes": 0] as [String: Any]), ("V2", ["host": "-oProxyCommand=x"])] {
            control.handle(["type": "request", "id": id, "verb": "job_watch",
                            "params": ["sessionId": "x", "label": "L", "probe": "p"].merging(extra) { $1 }])
        }
        func err(_ id: String) -> String? { sent.first { $0["id"] as? String == id }?["error"] as? String }
        record("ship: job_watch refuses a non-positive stallMinutes", err("V1") == "stallMinutes must be positive", "\(sent)")
        record("ship: job_watch refuses a host that is an ssh option", err("V2") == "host is not a host name", "\(sent)")
    }

    @MainActor
    private static func display(_ record: (String, Bool, String) -> Void) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
        }
        let now = at(21, 9, 45)
        record("job display: same-day time", JobDisplay.timeLabel(at(21, 10, 40), now: now, calendar: cal) == "10:40", "")
        record("job display: next-day time says 明日",
               JobDisplay.timeLabel(at(22, 1, 20), now: now, calendar: cal) == "明日 1:20",
               JobDisplay.timeLabel(at(22, 1, 20), now: now, calendar: cal))

        let running = JobSnapshot(label: "IG LOD", done: 328, total: 793, etaAt: at(21, 10, 40), state: .running, stalledSince: nil)
        let r = JobDisplay.trailing(running, now: now, calendar: cal)
        record("job display: running shows time and percent", r.top == "10:40" && r.bottom == "41%" && !r.isAlert, "\(r)")
        let stalled = JobSnapshot(label: "h7", done: 680, total: 1077, etaAt: nil, state: .stalled, stalledSince: at(21, 9, 30))
        let s = JobDisplay.trailing(stalled, now: now, calendar: cal)
        record("job display: stalled shows 停止 and minutes", s.top == "停止" && s.bottom == "15m" && s.isAlert, "\(s)")
        let measuring = JobSnapshot(label: "IG LOD", done: 328, total: 793, etaAt: nil, state: .measuring, stalledSince: nil)
        let m = JobDisplay.trailing(measuring, now: now, calendar: cal)
        record("job display: measuring shows 計測中 and percent", m.top == "計測中" && m.bottom == "41%" && !m.isAlert, "\(m)")
        let unknown = JobSnapshot(label: "IG LOD", done: 328, total: 793, etaAt: nil, state: .unknown, stalledSince: nil,
                                  note: "ssh の認証に失敗")
        let u = JobDisplay.trailing(unknown, now: now, calendar: cal)
        record("job display: unknown shows a dash", u.top == "—" && u.bottom == nil && !u.isAlert, "\(u)")

        record("job display: running help", JobDisplay.help(running, now: now) == "IG LOD 328/793 · あと 55 分",
               JobDisplay.help(running, now: now))
        record("job display: unknown help names the note", JobDisplay.help(unknown, now: now) == "IG LOD · ssh の認証に失敗",
               JobDisplay.help(unknown, now: now))
        record("job display: stalled line", JobDisplay.stalledLine(stalled) == "680/1077 で止まっている", "")
        record("job display: progress fraction", abs(JobDisplay.fraction(running) - 328.0 / 793) < 0.0001
                   && JobDisplay.fraction(JobSnapshot(label: "x", done: 0, total: 0, etaAt: nil, state: .measuring, stalledSince: nil)) == 0, "")

        record("job display: an idle session with a running job draws as background",
               JobDisplay.ringActivity(.idle, job: running) == .background, "")
        record("job display: an unread session with a job draws as background",
               JobDisplay.ringActivity(.unread, job: measuring) == .background, "")
        record("job display: asking stays asking over a stall", JobDisplay.ringActivity(.asking, job: stalled) == .asking, "")
        record("job display: a stall draws as error over working", JobDisplay.ringActivity(.working, job: stalled) == .error, "")
        record("job display: no job keeps the activity", JobDisplay.ringActivity(.idle, job: nil) == .idle, "")
        let doneJob = JobSnapshot(label: "x", done: 10, total: 10, etaAt: nil, state: .done, stalledSince: nil)
        record("job display: a done job draws no ring", !JobDisplay.drawsRing(doneJob) && JobDisplay.drawsRing(running), "")

        record("job display: a stalled job puts an idle row in Needs you",
               JobDisplay.statusGroup(.idle, job: stalled) == .needsYou, "")
        record("job display: a running job leaves the group alone",
               JobDisplay.statusGroup(.idle, job: running) == .idle && JobDisplay.statusGroup(.working, job: running) == .working, "")

        var tracker = MacroPadUnreadTracker()
        let id = UUID()
        func step(_ jobDone: Bool) -> Bool {
            tracker.update([.init(id: id, isThinking: false, jobDone: jobDone)], lastInteractedSessionId: nil,
                           interactionSeq: 0, secondsSincePresence: 1000, isAppActive: false)
            return tracker.unread.contains(id)
        }
        let first = step(false)
        let finished = step(true)
        record("job display: a job finishing marks the session unread", !first && finished, "first=\(first) finished=\(finished)")
        var fresh = MacroPadUnreadTracker()
        fresh.update([.init(id: id, isThinking: false, jobDone: true)], lastInteractedSessionId: nil,
                     interactionSeq: 0, secondsSincePresence: 1000, isAppActive: false)
        let seenDone = fresh.unread.contains(id)
        record("job display: a job already done when first seen does not mark unread", !seenDone, "")
    }

    @MainActor
    private static func pushes(_ record: (String, Bool, String) -> Void) {
        func job(_ state: JobState) -> JobSnapshot {
            JobSnapshot(label: "h7", done: 680, total: 1077, etaAt: nil, state: state, stalledSince: nil)
        }
        let stalled = JobWatcher.pushText(job(.stalled))
        record("job push: stalled text", stalled?.title == "h7" && stalled?.body == "680/1077 で止まっている", "\(String(describing: stalled))")
        let done = JobWatcher.pushText(job(.done))
        record("job push: done text", done?.title == "h7" && done?.body == "完了", "\(String(describing: done))")
        record("job push: other states send nothing",
               [JobState.running, .measuring, .unknown].allSatisfy { JobWatcher.pushText(job($0)) == nil }, "")
        var previous: JobState? = nil
        var posts = 0
        for state in [JobState.measuring, .running, .stalled, .stalled, .running, .stalled, .done, .done] {
            if JobWatcher.shouldPush(from: previous, to: state) { posts += 1 }
            previous = state
        }
        record("job push: one push per transition into stalled or done", posts == 3, "posts=\(posts)")
        record("job push: the first reading never pushes", !JobWatcher.shouldPush(from: nil, to: .done), "")
        record("job push: kinds match the relay's names",
               RosterNotifier.Kind.jobStalled.rawValue == "job_stalled" && RosterNotifier.Kind.jobDone.rawValue == "job_done", "")
    }

    @MainActor
    private static func watcher(_ record: (String, Bool, String) -> Void) {
        let local = JobSpec(resumeId: "r", label: "L", probe: "echo 3/10", host: nil, total: nil, interval: 150, stallMinutes: nil)
        record("job: a local probe runs under sh -c with pipefail",
               JobWatcher.command(for: local) == ["/bin/sh", "-c", "set -o pipefail; echo 3/10"],
               "\(JobWatcher.command(for: local))")
        let remote = JobSpec(resumeId: "r", label: "L", probe: "tail -1 log", host: "rt4090", total: nil, interval: 150, stallMinutes: nil)
        let argv = JobWatcher.command(for: remote)
        record("job: a remote probe is ssh with BatchMode, ConnectTimeout=10 and ControlPersist",
               argv.first == "/usr/bin/ssh" && argv.suffix(3) == ["--", "rt4090", "tail -1 log"]
                   && ["BatchMode=yes", "ConnectTimeout=10", "ControlMaster=auto", "ControlPersist=10m"].allSatisfy(argv.contains)
                   && argv.contains { $0.hasPrefix("ControlPath=") },
               "\(argv)")
        let settings = Data(#"{"env":{"SSH_AUTH_SOCK":"/x/agent.sock"}}"#.utf8)
        record("job: SSH_AUTH_SOCK comes from settings.json env",
               JobWatcher.sshAuthSock(settingsJSON: settings, fallback: "/y") == "/x/agent.sock", "")
        record("job: SSH_AUTH_SOCK falls back without settings",
               JobWatcher.sshAuthSock(settingsJSON: nil, fallback: "/y") == "/y"
                   && JobWatcher.sshAuthSock(settingsJSON: Data("{}".utf8), fallback: "/y") == "/y", "")

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var track = JobTrack(spec: remote)
        track.record(output: "[3/10]\n", exitStatus: 0, at: t0)
        track.record(output: "", exitStatus: 255, at: t0.addingTimeInterval(150))
        record("job: a failed run counts a failure and keeps the samples",
               track.failures == 1 && track.samples.count == 1 && track.note == "ssh の接続か認証に失敗", "\(track)")
        track.record(output: "[4/10]", exitStatus: 0, at: t0.addingTimeInterval(300))
        record("job: a parsed run resets failures and the note",
               track.failures == 0 && track.note == nil && track.samples.last?.done == 4, "\(track)")
        track.record(output: "No such file", exitStatus: 0, at: t0.addingTimeInterval(450))
        record("job: output without a count is a failure, not done = 0",
               track.failures == 1 && track.samples.last?.done == 4, "\(track)")
        let restored = (try? JSONEncoder().encode([track])).flatMap { try? JSONDecoder().decode([JobTrack].self, from: $0) }
        record("job: tracks persist and restore", restored == [track], "")
        var old = JobTrack(spec: local)
        let hour: TimeInterval = 3600
        // Hourly readings 0 h…7 h, all 1/10: the window (keepSeconds) keeps 3 h…7 h, plus the 0 h reading,
        // which is where the count last changed.
        for h in 0...7 { old.record(output: "1/10", exitStatus: 0, at: t0.addingTimeInterval(Double(h) * hour)) }
        let windowReadings = Int(JobTrack.keepSeconds / hour) + 1
        record("job: unchanged readings older than the window are dropped, the last move is kept",
               old.samples.first?.at == t0 && old.samples.count == 1 + windowReadings
                   && old.snapshot(now: t0.addingTimeInterval(8 * hour)).stalledSince == t0, "\(old.samples.map(\.at))")

        var sent: [[String: Any]] = []
        let tcp = ControlSession(store: SessionStore(), isLocal: false, allowBypass: { false }) { sent.append($0) }
        for (id, verb) in [("J1", "job_watch"), ("J2", "job_clear")] {
            tcp.handle(["type": "request", "id": id, "verb": verb, "params": ["sessionId": "x", "label": "L", "probe": "id"]])
        }
        record("job: job_watch and job_clear refuse a TCP client",
               ["J1", "J2"].allSatisfy { id in sent.first { $0["id"] as? String == id }?["error"] as? String == "local clients only" },
               "\(sent)")
        var localSent: [[String: Any]] = []
        let localControl = ControlSession(store: SessionStore(), isLocal: true, allowBypass: { false }) { localSent.append($0) }
        localControl.handle(["type": "request", "id": "J3", "verb": "job_watch", "params": ["sessionId": "x", "label": "L"]])
        record("job: job_watch needs a probe", localSent.first?["error"] as? String == "probe is required", "\(localSent)")
    }

    private static func wire(_ record: (String, Bool, String) -> Void) {
        let job = JobSnapshot(label: "IG LOD", done: 328, total: 793, etaAt: Date(timeIntervalSince1970: 1_003_300),
                              state: .running, stalledSince: nil, note: "ssh の認証に失敗")
        func row(_ job: JobSnapshot?) -> ControlProtocol.SessionRow {
            ControlProtocol.SessionRow(key: "k", resumeId: "r", title: "t", project: "p", cwd: "/", state: "background",
                                       running: true, clients: 0, lastActiveAt: 0, model: "", messageCount: 0,
                                       permissionMode: "default", accountId: nil, job: job)
        }
        let back = ControlProtocol.SessionRow(wire: row(job).wire)
        record("job wire: SessionRow round-trips job", back?.job == job, "\(String(describing: back?.job))")
        let jobWire = row(job).wire["job"] as? [String: Any]
        record("job wire: etaAt is unix seconds", jobWire?["etaAt"] as? Int == 1_003_300, "\(String(describing: jobWire))")
        record("job wire: an absent job leaves no key", row(nil).wire["job"] == nil, "")
        let stalled = JobSnapshot(label: "h7", done: 680, total: 1077, etaAt: nil, state: .stalled,
                                  stalledSince: Date(timeIntervalSince1970: 1_000_600))
        record("job wire: a stalled job round-trips", ControlProtocol.SessionRow(wire: row(stalled).wire)?.job == stalled, "")

        let pane = RosterSnapshot.Pane(sessionId: "s", resumeId: "r", paneIndex: 0, title: "t", project: "p",
                                       state: "background", stateSince: 1, contextPct: 0, model: "", messageCount: 0,
                                       live: true, attentionLine: "Bash: make", job: job)
        let encoded = (try? JSONEncoder().encode(pane)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let paneJob = encoded?["job"] as? [String: Any]
        record("roster: pane encodes job and attentionLine with etaAt as Int seconds",
               paneJob?["etaAt"] as? Int == 1_003_300 && paneJob?["state"] as? String == "running"
                   && encoded?["attentionLine"] as? String == "Bash: make", "\(String(describing: encoded))")
        let decoded = (try? JSONEncoder().encode(pane)).flatMap { try? JSONDecoder().decode(RosterSnapshot.Pane.self, from: $0) }
        record("roster: pane round-trips job", decoded?.job == job && decoded?.attentionLine == "Bash: make", "")
        let old = #"{"sessionId":"s","paneIndex":0,"title":"t","project":"p","state":"idle","stateSince":1,"contextPct":0,"model":"","messageCount":0}"#
        let oldPane = try? JSONDecoder().decode(RosterSnapshot.Pane.self, from: Data(old.utf8))
        record("roster: old pane JSON without the keys decodes", oldPane != nil && oldPane?.job == nil && oldPane?.attentionLine == nil, "")
    }

    private static func estimator(_ record: (String, Bool, String) -> Void) {
        let p = JobEstimator.parse
        let last = p("[12/793] ...\n[328/793] chunk", nil)
        record("job: parse takes the last N/M", last?.done == 328 && last?.total == 793, "\(String(describing: last))")
        let counted = p("1037\n", 1077)
        record("job: parse with --total takes the last integer", counted?.done == 1037 && counted?.total == 1077, "\(String(describing: counted))")
        record("job: parse with no number is nil", p("No such file\n", nil) == nil && p("", 10) == nil, "")

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func s(_ min: Double, _ d: Int, _ tot: Int = 793) -> JobSample {
            JobSample(at: t0.addingTimeInterval(min * 60), done: d, total: tot)
        }
        func ev(_ ss: [JobSample], _ nowMin: Double, failures: Int = 0, stall: Double? = nil) -> JobSnapshot {
            JobEstimator.evaluate(label: "IG LOD", samples: ss, failures: failures,
                                  now: t0.addingTimeInterval(nowMin * 60), stallMinutes: stall)
        }

        let one = ev([s(0, 100)], 0)
        record("job: one sample is measuring", one.state == .measuring && one.etaAt == nil, "\(one)")

        // 8.5 per minute: 465 left → about 54.7 min after the last sample.
        let r = ev([s(0, 243), s(5, 285), s(10, 328)], 10)
        let expected = t0.addingTimeInterval(10 * 60 + 465 / 8.5 * 60)
        record("job: steady rate gives eta from the recent window",
               r.state == .running && r.etaAt.map { abs($0.timeIntervalSince(expected)) < 60 } == true, "\(r)")

        let back = ev([s(0, 300), s(5, 310), s(10, 20)], 10)
        record("job: done going backwards resets to measuring", back.state == .measuring && back.done == 20, "\(back)")
        let retotal = ev([s(0, 300), s(5, 310), s(10, 320, 900)], 10)
        record("job: a total change resets to measuring", retotal.state == .measuring && retotal.total == 900, "\(retotal)")

        // One unit per 20 min: the window widens, and 16 min without progress is not a stall.
        let slow = ev([s(0, 1, 30), s(20, 2, 30), s(40, 3, 30)], 56)
        record("job: slow units widen the window and do not stall early", slow.state == .running && slow.etaAt != nil, "\(slow)")

        let stalled = ev([s(0, 300), s(5, 340), s(10, 380)], 26)
        record("job: no progress past the 15 min floor is stalled",
               stalled.state == .stalled && stalled.etaAt == nil && stalled.stalledSince == t0.addingTimeInterval(600), "\(stalled)")
        let notYet = ev([s(0, 300), s(5, 340), s(10, 380)], 24)
        record("job: no progress under the floor is still running", notYet.state == .running, "\(notYet)")
        let overridden = ev([s(0, 300), s(5, 340), s(10, 380)], 16, stall: 5)
        record("job: stallMinutes overrides the floor", overridden.state == .stalled, "\(overridden)")

        let unknown = ev([s(0, 1), s(5, 2)], 6, failures: 3)
        record("job: 3 failures is unknown and keeps the last count",
               unknown.state == .unknown && unknown.done == 2 && unknown.etaAt == nil, "\(unknown)")
        let twoFailures = ev([s(0, 1), s(5, 2)], 6, failures: 2)
        record("job: 2 failures is not unknown yet", twoFailures.state != .unknown, "\(twoFailures)")

        let finished = ev([s(0, 790), s(5, 793)], 5)
        record("job: done when done reaches total", finished.state == .done, "\(finished)")
        let none = ev([], 0)
        record("job: no samples is measuring at 0/0", none.state == .measuring && none.total == 0, "\(none)")
    }
}
