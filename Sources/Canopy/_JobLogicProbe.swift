import Foundation

/// Job ETA gauge assertions, run from `SidebarLogicProbe.runAllTests()`.
/// Kept apart from that file only to stop it growing further; the harness
/// (one `record` per assertion, counted against `EXPECTED_ASSERTIONS`) is the same.
enum JobLogicProbe {
    static func run(_ record: (String, Bool, String) -> Void) {
        estimator(record)
        wire(record)
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
