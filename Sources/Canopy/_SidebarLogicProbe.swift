#if DEBUG
import Foundation
import os.log

/// Smoke tests for `SidebarRow.sorted`, `SidebarRow.deduped`, and
/// `SidebarFilter.apply`. Project has no XCTest target, so we run these
/// at app launch when `CANOPY_RUN_LOGIC_PROBE=1` is set and exit.
///
/// PASS/FAIL is printed to stderr and to the unified log under
/// `subsystem=sh.saqoo.Canopy category=LogicProbe`.
@MainActor
enum SidebarLogicProbe {
    private static let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "LogicProbe")

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["CANOPY_RUN_LOGIC_PROBE"] == "1" else { return }
        let summary = runAllTests()
        logger.info("\(summary, privacy: .public)")
        FileHandle.standardError.write(Data((summary + "\n").utf8))
        exit(summary.contains("FAIL") ? 1 : 0)
    }

    static func runAllTests() -> String {
        var pass = 0
        var fail = 0
        var lines: [String] = ["=== Sidebar logic probe ==="]

        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1; lines.append("  PASS \(name)") }
            else  { fail += 1; lines.append("  FAIL \(name) — \(detail)") }
        }

        // Synthetic data
        let now = Date()
        let oneHour: TimeInterval = 3600
        let cwd = URL(fileURLWithPath: "/tmp/probe")

        let openA = OpenSession(
            origin: .local(cwd),
            resumeId: "open-A",
            title: "Open A (newest)",
            project: "ProjectA",
            status: .live,
            lastActiveAt: now
        )
        let openB = OpenSession(
            origin: .local(cwd),
            resumeId: "open-B",
            title: "Open B (older)",
            project: "ProjectB",
            status: .live,
            lastActiveAt: now.addingTimeInterval(-oneHour)
        )
        let recentNew = SessionEntry(
            id: "00000000-0000-0000-0000-000000000001",
            title: "Recent new",
            timestamp: now.addingTimeInterval(-oneHour * 2),
            projectDirectory: cwd
        )
        let recentOld = SessionEntry(
            id: "00000000-0000-0000-0000-000000000002",
            title: "Recent old",
            timestamp: now.addingTimeInterval(-oneHour * 24),
            projectDirectory: cwd
        )
        let cloudFresh = RemoteSession(
            id: "session_cloudFresh",
            summary: "Cloud fresh",
            lastModified: now.addingTimeInterval(-oneHour * 3),
            status: "idle",
            repoOwner: "owner",
            repoName: "ProjectA",
            branch: nil,
            kind: .web,
            origin: nil,
            cwd: nil
        )
        let cloudStale = RemoteSession(
            id: "session_cloudStale",
            summary: "Cloud stale",
            lastModified: now.addingTimeInterval(-oneHour * 48),
            status: "idle",
            repoOwner: "owner",
            repoName: "ProjectC",
            branch: nil,
            kind: .web,
            origin: nil,
            cwd: nil
        )
        let cloudTeleported = RemoteSession(
            id: "session_cloudTeleported",
            summary: "Already teleported",
            lastModified: now.addingTimeInterval(-oneHour * 4),
            status: "idle",
            repoOwner: "owner",
            repoName: "ProjectA",
            branch: nil,
            kind: .web,
            origin: nil,
            cwd: nil
        )

        let allRows: [SidebarRow] = [
            .closedLocal(recentOld),         // out of order on purpose
            .open(openB),
            .closedCloud(cloudStale),
            .open(openA),
            .closedLocal(recentNew),
            .closedCloud(cloudFresh),
            .closedCloud(cloudTeleported),
        ]

        // Test 1: sort puts open block first (preserving insertion order),
        // then closed rows mixed by lastModified desc.
        let sorted = SidebarRow.sorted(allRows)
        let sortedIds = sorted.map(\.id)
        // Expected open order = order they appeared in `allRows`
        // (allRows had: openB inserted before openA in the array).
        let expectedSortedIds = [
            "open:\(openB.id.uuidString)",
            "open:\(openA.id.uuidString)",
            "local:\(recentNew.id)",
            "cloud:session_cloudFresh",
            "cloud:session_cloudTeleported",
            "local:\(recentOld.id)",
            "cloud:session_cloudStale",
        ]
        record("sort: open in insertion order, closed mixed by date desc",
               sortedIds == expectedSortedIds,
               "got \(sortedIds)")

        // Test 2: dedup removes a cloud row when a local row was teleported from it
        let teleportedFromMap = ["00000000-0000-0000-0000-000000000003": "session_cloudTeleported"]
        let dedupedRows = SidebarRow.deduped(allRows, teleportedFromMap: teleportedFromMap)
        let cloudIds: Set<String> = Set(dedupedRows.compactMap { row -> String? in
            if case .closedCloud(let r) = row { return r.id } else { return nil }
        })
        record("dedup: teleported cloud row removed",
               !cloudIds.contains("session_cloudTeleported"),
               "still saw cloudTeleported in \(cloudIds)")
        record("dedup: untouched cloud rows kept",
               cloudIds.contains("session_cloudFresh") && cloudIds.contains("session_cloudStale"),
               "missing fresh/stale in \(cloudIds)")

        // Test 3: dedup also removes cloud row when an OpenSession was teleported from it
        let openTeleported = OpenSession(
            origin: .teleportedFrom(cloudSessionId: "session_cloudTeleported", localPath: cwd),
            resumeId: "telep-local",
            title: "Locally resumed teleport",
            project: "ProjectA"
        )
        let withOpenTeleport: [SidebarRow] = [
            .open(openTeleported),
            .closedCloud(cloudTeleported),
            .closedCloud(cloudFresh),
        ]
        let openTeleDeduped = SidebarRow.deduped(withOpenTeleport, teleportedFromMap: [:])
        let openTeleCloudIds = openTeleDeduped.compactMap { row -> String? in
            if case .closedCloud(let r) = row { return r.id } else { return nil }
        }
        record("dedup: open teleport drops matching cloud row",
               !openTeleCloudIds.contains("session_cloudTeleported"),
               "still present in \(openTeleCloudIds)")

        // Test 4: filter status=openOnly returns only open rows
        var f = SidebarFilter()
        f.status = .openOnly
        let onlyOpen = f.apply(to: sorted)
        record("filter status=openOnly", onlyOpen.allSatisfy(\.isOpen) && onlyOpen.count == 2,
               "got \(onlyOpen.map(\.id))")

        // Test 5: filter status=closedOnly excludes open rows
        f = SidebarFilter()
        f.status = .closedOnly
        let onlyClosed = f.apply(to: sorted)
        record("filter status=closedOnly", onlyClosed.allSatisfy { !$0.isOpen },
               "got \(onlyClosed.map(\.id))")

        // Test 6: filter origin=cloud returns only closedCloud rows
        f = SidebarFilter()
        f.origin = .cloud
        let onlyCloud = f.apply(to: sorted)
        record("filter origin=cloud", onlyCloud.allSatisfy { $0.origin == .cloud },
               "got origins=\(onlyCloud.map(\.origin))")

        // Test 7: filter project narrows to one project label
        f = SidebarFilter()
        f.project = "ProjectA"
        let onlyA = f.apply(to: sorted)
        record("filter project=ProjectA", onlyA.allSatisfy { $0.project == "ProjectA" } && !onlyA.isEmpty,
               "got projects=\(onlyA.map(\.project))")

        // Test 8: filter lastActivity=today excludes 24h+ old rows
        f = SidebarFilter()
        f.lastActivity = .today
        let today = f.apply(to: sorted, now: now)
        record("filter lastActivity=today excludes 24h+",
               today.allSatisfy { $0.lastModified >= Calendar.current.startOfDay(for: now) },
               "got lastMods=\(today.map(\.lastModified))")

        // Test 9: filter isActive flag
        f = SidebarFilter()
        record("filter isActive=false default", !f.isActive)
        f.status = .openOnly
        record("filter isActive=true after change", f.isActive)

        // Test 10–12: background scheduled-task JSONL detection
        let scheduledJSONL = """
        {"type":"queue-operation","operation":"enqueue","content":"<scheduled-task name=\\"probe-task\\">run</scheduled-task>"}
        {"type":"user","message":{"role":"user","content":"hello"}}
        """
        let normalJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"}}
        """
        let enqueueOtherJSONL = """
        {"type":"queue-operation","operation":"enqueue","content":"/ship-it"}
        """
        let scheduledAfterUserJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe"}
        {"type":"queue-operation","operation":"enqueue","content":"<scheduled-task name=\\"late\\">run</scheduled-task>"}
        """
        let scheduledPath = writeProbeJSONL(scheduledJSONL)
        let normalPath = writeProbeJSONL(normalJSONL)
        let enqueueOtherPath = writeProbeJSONL(enqueueOtherJSONL)
        let scheduledLatePath = writeProbeJSONL(scheduledAfterUserJSONL)

        // Test 13–19: non-interactive `claude -p` / SDK session detection
        let sdkCliJSONL = """
        {"type":"user","message":{"role":"user","content":"You are a memory observer"},"entrypoint":"sdk-cli"}
        """
        let vscodeJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"entrypoint":"claude-vscode"}
        """
        let cliJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"entrypoint":"cli"}
        """
        // Older sessions predate the `entrypoint` key — must stay visible.
        let noEntrypointJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"}}
        """
        // sdk-cli marker on a later line (first line is a header without entrypoint).
        let lateSdkCliJSONL = """
        {"type":"summary","summary":"prior session"}
        {"type":"user","message":{"role":"user","content":"observe"},"entrypoint":"sdk-cli"}
        """
        // Present-but-empty entrypoint is skipped by the !isEmpty guard → not flagged.
        let emptyEntrypointJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"entrypoint":""}
        """
        // Prefix match: interactive entrypoints must not be flagged.
        let desktopJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"entrypoint":"claude-desktop"}
        """
        // Python Agent SDK runs (e.g. security-guidance plugin background reviews)
        // write sdk-py — must be flagged like sdk-cli.
        let sdkPyJSONL = """
        {"type":"queue-operation","operation":"enqueue","content":"Review this change for security vulnerabilities."}
        {"type":"user","message":{"role":"user","content":"Review this change"},"entrypoint":"sdk-py"}
        """
        let sdkCliPath = writeProbeJSONL(sdkCliJSONL)
        let vscodePath = writeProbeJSONL(vscodeJSONL)
        let cliPath = writeProbeJSONL(cliJSONL)
        let noEntrypointPath = writeProbeJSONL(noEntrypointJSONL)
        let lateSdkCliPath = writeProbeJSONL(lateSdkCliJSONL)
        let emptyEntrypointPath = writeProbeJSONL(emptyEntrypointJSONL)
        let desktopPath = writeProbeJSONL(desktopJSONL)
        let sdkPyPath = writeProbeJSONL(sdkPyJSONL)
        defer {
            for path in [scheduledPath, normalPath, enqueueOtherPath, scheduledLatePath,
                         sdkCliPath, vscodePath, cliPath,
                         noEntrypointPath, lateSdkCliPath, emptyEntrypointPath, desktopPath,
                         sdkPyPath] {
                if let path { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        record("scheduled: enqueue with <scheduled-task",
               scheduledPath.map { ClaudeSessionHistory.isBackgroundScheduledSession(atPath: $0) } == true)
        record("scheduled: normal user session",
               normalPath.map { !ClaudeSessionHistory.isBackgroundScheduledSession(atPath: $0) } == true)
        record("scheduled: other enqueue not flagged",
               enqueueOtherPath.map { !ClaudeSessionHistory.isBackgroundScheduledSession(atPath: $0) } == true)
        record("scheduled: enqueue after first user line",
               scheduledLatePath.map { ClaudeSessionHistory.isBackgroundScheduledSession(atPath: $0) } == true)
        record("automated: sdk-cli entrypoint flagged",
               sdkCliPath.map { ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true)
        record("automated: claude-vscode not flagged",
               vscodePath.map { !ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true)
        record("automated: cli not flagged",
               cliPath.map { !ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true)
        record("automated: missing entrypoint key not flagged",
               noEntrypointPath.map { !ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true)
        record("automated: sdk-cli on later line flagged",
               lateSdkCliPath.map { ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true)
        record("automated: empty entrypoint not flagged",
               emptyEntrypointPath.map { !ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true)
        record("automated: claude-desktop not flagged",
               desktopPath.map { !ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true)
        record("automated: sdk-py entrypoint flagged",
               sdkPyPath.map { ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true)

        // background-task launch detection (drives sidebar "waiting" icon)
        let bashBg: [String: Any] = [
            "type": "tool_use",
            "id": "toolu_bash_bg",
            "name": "Bash",
            "input": ["command": "sleep 60", "run_in_background": true],
        ]
        let agentBg: [String: Any] = [
            "type": "tool_use",
            "id": "toolu_agent_bg",
            "name": "Agent",
            "input": ["prompt": "...", "run_in_background": true],
        ]
        let bashForeground: [String: Any] = [
            "type": "tool_use",
            "id": "toolu_bash_fg",
            "name": "Bash",
            "input": ["command": "ls", "run_in_background": false],
        ]
        let editTool: [String: Any] = [
            "type": "tool_use",
            "id": "toolu_edit",
            "name": "Edit",
            "input": ["file_path": "/x", "run_in_background": true],
        ]
        let textBlock: [String: Any] = ["type": "text", "text": "hello"]

        record("bg launch: Bash run_in_background:true",
               ShimProcess.isBackgroundLaunchBlock(bashBg))
        record("bg launch: Agent run_in_background:true",
               ShimProcess.isBackgroundLaunchBlock(agentBg))
        record("bg launch: foreground Bash NOT flagged",
               !ShimProcess.isBackgroundLaunchBlock(bashForeground))
        record("bg launch: Edit tool NOT flagged even with flag",
               !ShimProcess.isBackgroundLaunchBlock(editTool))
        record("bg launch: text block NOT flagged",
               !ShimProcess.isBackgroundLaunchBlock(textBlock))

        // background-task completion marker (the JSONL contract). The
        // wake-up reconcile is shim-coupled so it can't run from this
        // static probe, but the substring matcher is pure — lock it down
        // here so a CLI format drift in `<tool-use-id>` lights up the
        // probe instead of silently sticking the hourglass forever.
        let jsonlTail = """
        {"type":"queue-operation","operation":"enqueue","content":"<task-notification>\\n<task-id>aea7914f15afc48af</task-id>\\n<tool-use-id>toolu_01KDTwPWn2C3FdoCKvZSnmJx</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}
        {"type":"user","message":{"role":"user","content":"<task-notification>\\n<task-id>b6zqqmb6q</task-id>\\n<tool-use-id>toolu_01GFkSMYZ37n46jxw6D3wSAy</tool-use-id>\\n<status>killed</status>\\n</task-notification>"}}
        """
        record("bg complete: tail contains id → match",
               ShimProcess.jsonlTailHasCompletion(tail: jsonlTail, taskId: "toolu_01KDTwPWn2C3FdoCKvZSnmJx"))
        record("bg complete: second id also matches",
               ShimProcess.jsonlTailHasCompletion(tail: jsonlTail, taskId: "toolu_01GFkSMYZ37n46jxw6D3wSAy"))
        record("bg complete: unmatched id → no match",
               !ShimProcess.jsonlTailHasCompletion(tail: jsonlTail, taskId: "toolu_99XXXNEVERSEEN"))
        record("bg complete: empty tail → no match",
               !ShimProcess.jsonlTailHasCompletion(tail: "", taskId: "toolu_01KDTwPWn2C3FdoCKvZSnmJx"))
        // Partial / wrong-tag-wrapper IDs must NOT trigger a false match —
        // this is the regression case if the CLI ever changes the wrapper.
        record("bg complete: bare id without wrapper → no match",
               !ShimProcess.jsonlTailHasCompletion(tail: "toolu_01KDTwPWn2C3FdoCKvZSnmJx", taskId: "toolu_01KDTwPWn2C3FdoCKvZSnmJx"))

        // Summary
        lines.append("--- \(pass) passed, \(fail) failed ---")
        return lines.joined(separator: "\n")
    }

    private static func writeProbeJSONL(_ contents: String) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("canopy-probe-\(UUID().uuidString).jsonl")
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }
}
#endif
