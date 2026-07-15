#if DEBUG
import Foundation
import os.log

/// Smoke tests for sidebar logic and other pure non-UI helpers (row
/// sort/dedup/filter, JSONL session classification, background-task
/// markers, title-generation helpers, git worktree helpers). Project has
/// no XCTest target, so we run these at app launch when
/// `CANOPY_RUN_LOGIC_PROBE=1` is set and exit.
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

        // Historic-id snapshot: `extractToolUseIds` grabs every `toolu_…`
        // occurrence in the JSONL so `detectBackgroundTaskLaunch` can
        // suppress CLI replays of already-logged assistant messages. The
        // fixture covers the three shapes the CLI writes: assistant
        // `tool_use.id`, user `tool_result.tool_use_id`, and the
        // `<tool-use-id>` completion wrapper.
        let historicJSONL = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01AAAAAAAAAAAAAAAAAA","name":"Bash","input":{"command":"echo hi","run_in_background":true}}]}}
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01AAAAAAAAAAAAAAAAAA","type":"tool_result","content":"Command running in background with ID: babcdef01"}]}}
        {"type":"queue-operation","operation":"enqueue","content":"<task-notification>\\n<task-id>abc</task-id>\\n<tool-use-id>toolu_01BBBBBBBBBBBBBBBBBB</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"nothing to see here"}]}}
        """
        let historicIds = ShimProcess.extractToolUseIds(fromText: historicJSONL)
        record("historic ids: tool_use.id extracted",
               historicIds.contains("toolu_01AAAAAAAAAAAAAAAAAA"),
               "\(historicIds)")
        record("historic ids: <tool-use-id> wrapper extracted",
               historicIds.contains("toolu_01BBBBBBBBBBBBBBBBBB"),
               "\(historicIds)")
        record("historic ids: unrelated id absent",
               !historicIds.contains("toolu_99NEVERAPPEARSXXXXX"),
               "\(historicIds)")
        record("historic ids: empty text → empty set",
               ShimProcess.extractToolUseIds(fromText: "").isEmpty)
        // Too-short "toolu_…" fragments must NOT be captured — otherwise a
        // stray `toolu_X` in a text field would poison the historic set.
        record("historic ids: short fragment rejected",
               !ShimProcess.extractToolUseIds(fromText: "prefix toolu_short suffix").contains(where: { $0.hasPrefix("toolu_") }))

        // Regex length-boundary contract. The gate `historicToolUseIds`
        // trades correctness for a load-bearing assumption: whatever the
        // extractor emits must be the EXACT id the io_message stream will
        // carry. A future CLI id-shape change that lands overlong ids
        // (say 44 chars) can't be silently truncated to a 40-char prefix,
        // or `detectBackgroundTaskLaunch` will look up the full id, miss
        // the prefix in the set, and let the ghost hourglass return.
        let idMax = "toolu_" + String(repeating: "A", count: 40)
        record("historic ids: 40-char id captured whole",
               ShimProcess.extractToolUseIds(fromText: idMax).contains(idMax))
        let idOver = "toolu_" + String(repeating: "A", count: 44)
        let overIds = ShimProcess.extractToolUseIds(fromText: idOver)
        // Either accept whole or reject — never truncate. Widening the
        // regex to accept longer ids is fine; silently truncating is not.
        record("historic ids: over-length id not truncated",
               overIds.isEmpty || overIds.contains(idOver))
        record("historic ids: 15-char id rejected (below min)",
               ShimProcess.extractToolUseIds(fromText: "toolu_" + String(repeating: "A", count: 15)).isEmpty)

        // Multiple ids on a single line — regex must iterate, not
        // short-circuit on first hit. Regression class: a future switch to
        // `firstMatch(in:)` would silently drop every id after the first.
        let multiIds = ShimProcess.extractToolUseIds(
            fromText: "prefix toolu_01AAAAAAAAAAAAAAAAAA middle toolu_01BBBBBBBBBBBBBBBBBB suffix"
        )
        record("historic ids: multiple hits on one line",
               multiIds.count == 2)

        // jsonlPath: pure static resolver. Cheap to lock the two nil
        // branches without any filesystem setup.
        record("jsonlPath: empty sessionId → nil",
               ShimProcess.jsonlPath(sessionId: "", workingDirectory: URL(fileURLWithPath: "/tmp/probe")) == nil)
        record("jsonlPath: unknown cwd → nil",
               ShimProcess.jsonlPath(
                   sessionId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                   workingDirectory: URL(fileURLWithPath: "/definitely/not/here-xyz")
               ) == nil)

        // Title-generation context: prompt extraction from session JSONL
        // (resume seeding) and first-prompt pinning (anti-drift). Noise
        // fixtures mirror the real records the CLI writes — a slash-command
        // line starts with <command-message>, a post-/compact continuation
        // carries isCompactSummary, etc.
        let promptsJSONL = """
        {"type":"user","isCompactSummary":true,"message":{"role":"user","content":"Compact summary body without the standard prefix"}}
        {"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}
        {"type":"user","message":{"role":"user","content":"fix the AO blur artifact in the renderer"},"cwd":"/tmp/probe"}
        {"type":"user","isMeta":true,"message":{"role":"user","content":"meta noise"}}
        {"type":"user","message":{"role":"user","content":"<command-message>release</command-message>\\n<command-name>/release</command-name>"}}
        {"type":"user","message":{"role":"user","content":"<local-command-stdout>done</local-command-stdout>"}}
        {"type":"user","message":{"role":"user","content":"<task-notification>\\n<task-id>abc</task-id>\\n</task-notification>"}}
        {"type":"user","message":{"role":"user","content":"<system-reminder>background task finished</system-reminder>"}}
        {"type":"user","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}
        {"type":"user","message":{"role":"user","content":"Caveat: the messages below were generated"}}
        {"type":"user","message":{"role":"user","content":"[Image #1]"}}
        {"type":"user","message":{"role":"user","content":"[Image #2] fix the toolbar icon"}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_x","content":"result"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"also check the shadow pass"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"assistant reply"}]}}
        """
        let promptsPath = writeProbeJSONL(promptsJSONL)
        defer {
            if let promptsPath { try? FileManager.default.removeItem(atPath: promptsPath) }
        }
        if let promptsPath {
            let prompts = ClaudeSessionHistory.loadUserPrompts(atPath: promptsPath)
            record("title prompts: user text extracted, noise skipped",
                   prompts == ["fix the AO blur artifact in the renderer", "fix the toolbar icon", "also check the shadow pass"],
                   "\(prompts)")
        } else {
            record("title prompts: user text extracted, noise skipped", false, "write failed")
        }
        let longHistory = ["goal", "a", "b", "c", "d", "e", "f"]
        record("title history: first prompt pinned + last 4 kept",
               ShimProcess.trimmedPromptHistory(longHistory) == ["goal", "c", "d", "e", "f"])
        record("title history: short history untouched",
               ShimProcess.trimmedPromptHistory(["goal", "a"]) == ["goal", "a"])

        // Chunked-read path: a file past the 2×128KB whole-read cap must
        // still surface the head's first prompt and the tail's recent one.
        let filler = String(repeating: "x", count: 1_000)
        var bigLines = ["{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"the original goal prompt\"}}"]
        for i in 0..<400 {
            bigLines.append("{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(filler)\(i)\"}]}}")
        }
        bigLines.append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"latest tail prompt\"}}")
        let bigPath = writeProbeJSONL(bigLines.joined(separator: "\n"))
        defer {
            if let bigPath { try? FileManager.default.removeItem(atPath: bigPath) }
        }
        if let bigPath {
            let bigPrompts = ClaudeSessionHistory.loadUserPrompts(atPath: bigPath)
            record("title prompts: chunked read keeps head goal + tail recent",
                   bigPrompts == ["the original goal prompt", "latest tail prompt"],
                   "\(bigPrompts)")
        } else {
            record("title prompts: chunked read keeps head goal + tail recent", false, "write failed")
        }

        // Chunked read with no user prompt in the head chunk: falls back to
        // tail prompts only instead of crashing or returning nothing.
        var headlessLines: [String] = []
        for i in 0..<400 {
            headlessLines.append("{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(filler)\(i)\"}]}}")
        }
        headlessLines.append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"only tail prompt here\"}}")
        let headlessPath = writeProbeJSONL(headlessLines.joined(separator: "\n"))
        defer {
            if let headlessPath { try? FileManager.default.removeItem(atPath: headlessPath) }
        }
        if let headlessPath {
            let headlessPrompts = ClaudeSessionHistory.loadUserPrompts(atPath: headlessPath)
            record("title prompts: chunked read with promptless head → tail only",
                   headlessPrompts == ["only tail prompt here"],
                   "\(headlessPrompts)")
        } else {
            record("title prompts: chunked read with promptless head → tail only", false, "write failed")
        }

        record("sanitizeBranchName: spaces → hyphens",
               GitWorktree.sanitizeBranchName("feature my branch") == "feature-my-branch")
        record("sanitizeBranchName: keeps inner slash, strips invalid",
               GitWorktree.sanitizeBranchName("  fix/title?*[gen]  ") == "fix/titlegen")
        record("sanitizeBranchName: strips leading/trailing dots",
               GitWorktree.sanitizeBranchName("..weird..") == "weird")
        record("sanitizeBranchName: empty input",
               GitWorktree.sanitizeBranchName("") == "")
        record("sanitizeBranchName: strips trailing .lock",
               GitWorktree.sanitizeBranchName("branch.lock") == "branch")
        // Garbage-only input must reduce to empty — that is what triggers the
        // suggestedBranchName fallback in the launcher.
        record("sanitizeBranchName: invalid-chars-only input → empty",
               GitWorktree.sanitizeBranchName("?*[]") == "")
        record("sanitizeBranchName: dots-only input → empty",
               GitWorktree.sanitizeBranchName("...") == "")
        record("sanitizeBranchName: collapses repeated slashes",
               GitWorktree.sanitizeBranchName("feat//x") == "feat/x")
        record("sanitizeBranchName: strips leading/trailing slashes",
               GitWorktree.sanitizeBranchName("/feat/x/") == "feat/x")

        // Default branch name: deterministic shape, and must survive its own
        // sanitizer unchanged (a git-invalid default breaks every empty-field
        // worktree launch).
        let suggested = GitWorktree.suggestedBranchName(now: Date(timeIntervalSince1970: 1_751_600_000))
        record("suggestedBranchName: work-<8 digits>-<6 digits> shape",
               suggested.range(of: #"^work-\d{8}-\d{6}$"#, options: .regularExpression) != nil,
               suggested)
        record("suggestedBranchName: git-valid as-is",
               GitWorktree.sanitizeBranchName(suggested) == suggested)

        let gitProbeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: gitProbeDir) }
        record("isGitRepo: no .git → false",
               !GitWorktree.isGitRepo(gitProbeDir))
        try? FileManager.default.createDirectory(at: gitProbeDir, withIntermediateDirectories: true)
        let gitDotGit = gitProbeDir.appendingPathComponent(".git", isDirectory: true)
        try? FileManager.default.createDirectory(at: gitDotGit, withIntermediateDirectories: true)
        record("isGitRepo: .git directory → true",
               GitWorktree.isGitRepo(gitProbeDir))
        // Worktree/submodule checkouts have a .git FILE (gitlink), not a dir —
        // both must count as a repo.
        let gitFileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: gitFileDir) }
        try? FileManager.default.createDirectory(at: gitFileDir, withIntermediateDirectories: true)
        try? "gitdir: /somewhere/.git/worktrees/x".write(
            to: gitFileDir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        record("isGitRepo: .git file (gitlink) → true",
               GitWorktree.isGitRepo(gitFileDir))

        record("projectDisplayName: managed worktree → repo · branch",
               GitWorktree.projectDisplayName(
                   for: GitWorktree.worktreesRoot
                       .appendingPathComponent("Canopy/fix-foo")) == "Canopy · fix-foo")
        record("projectDisplayName: legacy sibling layout → repo · branch",
               GitWorktree.projectDisplayName(
                   for: URL(fileURLWithPath: "/repos/Canopy-worktrees/work-123")) == "Canopy · work-123")
        record("projectDisplayName: normal dir → folder name",
               GitWorktree.projectDisplayName(
                   for: URL(fileURLWithPath: "/repos/Canopy")) == "Canopy")
        record("projectDisplayName: bare '-worktrees' folder not treated as worktree",
               GitWorktree.projectDisplayName(
                   for: URL(fileURLWithPath: "/repos/-worktrees/x")) == "x")
        record("projectDisplayName: '..'-laden path still recognized",
               GitWorktree.projectDisplayName(
                   for: GitWorktree.worktreesRoot
                       .appendingPathComponent("Other/../Canopy/fix-foo")) == "Canopy · fix-foo")

        // --- SubagentTracker ---
        // Pure value-type probe: feed io_message dicts and assert the CLI-style
        // task-list rows (launch / dedupe / tokens / finish / clear).
        let t0 = Date()
        var tracker = SubagentTracker()
        let launchMsg: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Agent",
                        "id": "toolu_A",
                        "input": [
                            "description": "CodeRabbit review",
                            "subagent_type": "coderabbit:code-reviewer",
                            "prompt": "x",
                        ],
                    ],
                    [
                        "type": "tool_use",
                        "name": "Task",
                        "id": "toolu_B",
                        "input": [
                            "description": "CodeRabbit review",
                            "subagent_type": "coderabbit:code-reviewer",
                            "prompt": "x",
                        ],
                    ],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        let launchChanged = tracker.observe(launchMsg, now: t0)
        record("subagent: launch Agent+Task → 2 running rows",
               launchChanged
                   && tracker.rows.count == 2
                   && tracker.rows[0].agentType == "coderabbit:code-reviewer"
                   && tracker.rows[0].label == "CodeRabbit review"
                   && tracker.rows[0].isRunning
                   && tracker.rows[1].isRunning,
               "changed=\(launchChanged) count=\(tracker.rows.count)")

        record("subagent: duplicate launch → observe false (dedupe by id)",
               !tracker.observe(launchMsg, now: t0)
                   && tracker.rows.count == 2)

        let usageBig: [String: Any] = [
            "type": "assistant",
            "parent_tool_use_id": "toolu_A",
            "message": [
                "role": "assistant",
                "usage": [
                    "input_tokens": 1000,
                    "cache_creation_input_tokens": 200,
                    "cache_read_input_tokens": 300,
                    "output_tokens": 500,
                ],
            ] as [String: Any],
        ]
        let usageSmall: [String: Any] = [
            "type": "assistant",
            "parent_tool_use_id": "toolu_A",
            "message": [
                "role": "assistant",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 50,
                ],
            ] as [String: Any],
        ]
        let tokensChanged = tracker.observe(usageBig, now: t0)
        let tokensIgnored = tracker.observe(usageSmall, now: t0)
        record("subagent: parent usage grows tokens; smaller total ignored",
               tokensChanged
                   && !tokensIgnored
                   && tracker.rows[0].tokens == 2000,
               "changed=\(tokensChanged) ignored=\(tokensIgnored) tokens=\(tracker.rows[0].tokens)")

        let nestedUser: [String: Any] = [
            "type": "user",
            "parent_tool_use_id": "toolu_A",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_unrelated",
                        "content": "ok",
                    ],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        let nestedChanged = tracker.observe(nestedUser, now: t0)
        record("subagent: nested user (parent_tool_use_id) → no change",
               !nestedChanged && tracker.rows.count == 2,
               "changed=\(nestedChanged) count=\(tracker.rows.count)")

        let finishA: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_A",
                        "content": "done",
                    ],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        let finishChanged = tracker.observe(finishA, now: t0)
        record("subagent: tool_result finishes matching row only",
               finishChanged
                   && !tracker.rows[0].isRunning
                   && tracker.rows[1].isRunning,
               "changed=\(finishChanged) aRunning=\(tracker.rows[0].isRunning) bRunning=\(tracker.rows[1].isRunning)")

        let resultChanged = tracker.observe(["type": "result"], now: t0)
        record("subagent: result freezes all remaining running rows",
               resultChanged
                   && tracker.rows.allSatisfy { !$0.isRunning },
               "changed=\(resultChanged) running=\(tracker.rows.filter(\.isRunning).count)")

        let nextPrompt: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": "next prompt",
            ] as [String: Any],
        ]
        let clearChanged = tracker.observe(nextPrompt, now: t0)
        record("subagent: real user prompt clears rows",
               clearChanged && tracker.rows.isEmpty,
               "changed=\(clearChanged) count=\(tracker.rows.count)")

        // New turn via message_start after result — the CLI doesn't reliably
        // echo typed prompts as user io_messages, so this is the robust clear.
        _ = tracker.observe(launchMsg, now: t0)
        _ = tracker.observe(["type": "result"], now: t0)
        let nestedStart: [String: Any] = [
            "type": "stream_event",
            "parent_tool_use_id": "toolu_A",
            "event": ["type": "message_start"] as [String: Any],
        ]
        let nestedStartChanged = tracker.observe(nestedStart, now: t0)
        let mainStart: [String: Any] = [
            "type": "stream_event",
            "event": ["type": "message_start"] as [String: Any],
        ]
        let mainStartChanged = tracker.observe(mainStart, now: t0)
        record("subagent: post-result message_start clears (nested one doesn't)",
               !nestedStartChanged && mainStartChanged && tracker.rows.isEmpty,
               "nested=\(nestedStartChanged) main=\(mainStartChanged) count=\(tracker.rows.count)")

        // Mid-turn message_start (no result yet) must NOT clear running rows.
        _ = tracker.observe(launchMsg, now: t0)
        let midTurnChanged = tracker.observe(mainStart, now: t0)
        record("subagent: mid-turn message_start keeps running rows",
               !midTurnChanged && tracker.rows.count == 2,
               "changed=\(midTurnChanged) count=\(tracker.rows.count)")

        // Bg Agent: initial `tool_result` is an ack ("Command running in
        // background with ID: bXX"), not completion. Row must stay running.
        var bgTracker = SubagentTracker()
        let bgLaunch: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Agent",
                        "id": "toolu_BG",
                        "input": [
                            "description": "background review",
                            "subagent_type": "general-purpose",
                            "run_in_background": true,
                            "prompt": "x",
                        ],
                    ],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        _ = bgTracker.observe(bgLaunch, now: t0)
        let bgAck: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_BG",
                        "content": "Command running in background with ID: b1abc",
                    ],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        let bgAckChanged = bgTracker.observe(bgAck, now: t0)
        record("subagent: bg Agent ack tool_result does NOT finish the row",
               !bgAckChanged && bgTracker.rows.count == 1 && bgTracker.rows[0].isRunning,
               "changed=\(bgAckChanged) running=\(bgTracker.rows.first?.isRunning ?? false)")
        // But main-conversation `result` still freezes the bg row (better
        // than a stuck spinner post-turn).
        let bgResultChanged = bgTracker.observe(["type": "result"], now: t0)
        record("subagent: bg row freezes on turn `result`",
               bgResultChanged && !bgTracker.rows[0].isRunning)

        // Subagent-originated `result` (has parent_tool_use_id) must NOT
        // freeze main-conversation rows — otherwise a sibling subagent
        // finishing would false-checkmark every other running row and trip
        // turnEnded, wiping the list on the next mid-turn message_start.
        var sibTracker = SubagentTracker()
        _ = sibTracker.observe(launchMsg, now: t0) // toolu_A + toolu_B running
        let subResult: [String: Any] = [
            "type": "result",
            "parent_tool_use_id": "toolu_A",
        ]
        let sibChanged = sibTracker.observe(subResult, now: t0)
        record("subagent: subagent-tagged result doesn't freeze main rows",
               !sibChanged
                   && sibTracker.rows.allSatisfy(\.isRunning),
               "changed=\(sibChanged) running=\(sibTracker.rows.filter(\.isRunning).count)")

        // Batched tool_results: parallel Agent calls completing near-
        // simultaneously arrive in a single user io_message. Every match
        // must finish, not just the first.
        var batchTracker = SubagentTracker()
        _ = batchTracker.observe(launchMsg, now: t0)
        let batchFinish: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_A", "content": "ok"],
                    ["type": "tool_result", "tool_use_id": "toolu_B", "content": "ok"],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        let batchChanged = batchTracker.observe(batchFinish, now: t0)
        record("subagent: batched tool_results finish all matching rows",
               batchChanged
                   && batchTracker.rows.allSatisfy { !$0.isRunning },
               "changed=\(batchChanged) running=\(batchTracker.rows.filter(\.isRunning).count)")

        // Malformed user content: array shape with NO tool_result blocks
        // (e.g. an empty array, or a text-only content) must NOT clear
        // rows — silently wiping the visible list on an unknown CLI shape
        // is worse than preserving stale rows.
        var preserveTracker = SubagentTracker()
        _ = preserveTracker.observe(launchMsg, now: t0)
        let emptyArrayContent: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [] as [[String: Any]],
            ] as [String: Any],
        ]
        let emptyChanged = preserveTracker.observe(emptyArrayContent, now: t0)
        record("subagent: empty content array preserves rows",
               !emptyChanged && preserveTracker.rows.count == 2)

        // Unknown-id tool_result mixed with a valid one: unknown skipped,
        // valid finished, rows NOT cleared. Guards against stale/foreign
        // tool_results (e.g. from a prior turn's bg task) wiping the list.
        var mixedTracker = SubagentTracker()
        _ = mixedTracker.observe(launchMsg, now: t0)
        let mixed: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_UNKNOWN", "content": "?"],
                    ["type": "tool_result", "tool_use_id": "toolu_A", "content": "done"],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        _ = mixedTracker.observe(mixed, now: t0)
        record("subagent: unknown-id mixed with valid → only valid finishes; rows kept",
               mixedTracker.rows.count == 2
                   && !mixedTracker.rows[0].isRunning
                   && mixedTracker.rows[1].isRunning)

        // Empty-string metadata falls back to placeholders instead of a
        // blank 190pt column.
        var placeholderTracker = SubagentTracker()
        let blankLaunch: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Agent",
                        "id": "toolu_BLANK",
                        "input": [
                            "description": "",
                            "subagent_type": "",
                            "prompt": "x",
                        ],
                    ],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        _ = placeholderTracker.observe(blankLaunch, now: t0)
        record("subagent: empty-string metadata falls back to labelled placeholder",
               placeholderTracker.rows.count == 1
                   && placeholderTracker.rows[0].agentType == "agent"
                   && placeholderTracker.rows[0].label == "Agent task")

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
