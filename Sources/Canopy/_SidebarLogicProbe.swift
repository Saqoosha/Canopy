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

        // cwd resolution: `relocated` events (session moved into a git worktree)
        // must override the stale initial cwd; otherwise `--resume` spawns the
        // CLI in the wrong project folder and the CLI creates an empty session.
        let plainCwdJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe"}
        """
        let relocatedInHeadJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/main"}
        {"type":"relocated","sessionId":"probe","relocatedCwd":"/tmp/probe/worktree"}
        """
        let multipleRelocationsJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/main"}
        {"type":"relocated","sessionId":"probe","relocatedCwd":"/tmp/probe/wt1"}
        {"type":"relocated","sessionId":"probe","relocatedCwd":"/tmp/probe/wt2"}
        """
        // Simulate the real-world failure mode: cwd is set early, relocation
        // happens after the 128KB head window, but is within the 32KB tail.
        // Pad with filler well past the 128KB head window so the relocated
        // marker lives in the tail scan region.
        let relocatedFiller = String(repeating:
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"" +
            String(repeating: "x", count: 512) +
            "\"}}\n", count: 300)
        let relocatedInTailJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/main"}
        \(relocatedFiller){"type":"relocated","sessionId":"probe","relocatedCwd":"/tmp/probe/late-worktree"}
        {"type":"user","message":{"role":"user","content":"bye"},"cwd":"/tmp/probe/late-worktree"}
        """
        // Two relocations both past the head window — last-in-tail wins.
        let multipleInTailJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/main"}
        \(relocatedFiller){"type":"relocated","sessionId":"probe","relocatedCwd":"/tmp/probe/wt-early"}
        {"type":"relocated","sessionId":"probe","relocatedCwd":"/tmp/probe/wt-late"}
        """
        // Empty relocatedCwd must not override the initial cwd (!value.isEmpty).
        let emptyRelocatedCwdJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/main"}
        {"type":"relocated","sessionId":"probe","relocatedCwd":""}
        """
        // Substring "relocated" + relocatedCwd on a non-relocated type must be ignored.
        let relocatedNoiseJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/main"}
        \(relocatedFiller){"type":"user","message":{"role":"user","content":"we relocated the repo"},"relocatedCwd":"/tmp/probe/fake"}
        """
        // Boundary case: file size == headSize + tailSize so tailStart == headSize,
        // and the byte before tailStart is `\n` — the relocated line begins
        // exactly at the window edge and must NOT be dropped.
        let headSize = 131_072
        let tailSize = 32_768
        let boundaryFirst =
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"},\"cwd\":\"/tmp/probe/main\"}\n"
        let boundaryRelocated =
            "{\"type\":\"relocated\",\"sessionId\":\"probe\",\"relocatedCwd\":\"/tmp/probe/boundary-wt\"}\n"
        let headPadCount = headSize - boundaryFirst.utf8.count - 1
        precondition(headPadCount > 0, "boundary fixture first line exceeds headSize")
        let zPadCount = max(0, tailSize - boundaryRelocated.utf8.count)
        let boundaryJSONL =
            boundaryFirst
            + String(repeating: "x", count: headPadCount) + "\n"
            + boundaryRelocated
            + String(repeating: "z", count: zPadCount)
        // Mid-line case: byte at tailStart-1 is NOT `\n`, so the first tail
        // "line" is a truncated fragment and must be dropped (start = 1);
        // the real relocated event on the next line still wins.
        let midlineFirst =
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"},\"cwd\":\"/tmp/probe/main\"}\n"
        let midlineFragment = "truncated-json-fragment-no-newline-in-head"
        let midlineRelocated =
            "{\"type\":\"relocated\",\"sessionId\":\"probe\",\"relocatedCwd\":\"/tmp/probe/midline-wt\"}\n"
        let midlineHeadPad = headSize - midlineFirst.utf8.count
        precondition(midlineHeadPad > 0, "midline fixture first line exceeds headSize")
        let midlineTailBody = midlineFragment + "\n" + midlineRelocated
        let midlineTailPad = max(0, tailSize - midlineTailBody.utf8.count)
        let midlineJSONL =
            midlineFirst
            + String(repeating: "x", count: midlineHeadPad)
            + midlineTailBody
            + String(repeating: "z", count: midlineTailPad)
        let plainCwdPath = writeProbeJSONL(plainCwdJSONL)
        let relocatedInHeadPath = writeProbeJSONL(relocatedInHeadJSONL)
        let multipleRelocationsPath = writeProbeJSONL(multipleRelocationsJSONL)
        let relocatedInTailPath = writeProbeJSONL(relocatedInTailJSONL)
        let multipleInTailPath = writeProbeJSONL(multipleInTailJSONL)
        let emptyRelocatedCwdPath = writeProbeJSONL(emptyRelocatedCwdJSONL)
        let relocatedNoisePath = writeProbeJSONL(relocatedNoiseJSONL)
        let boundaryPath = writeProbeJSONL(boundaryJSONL)
        let midlinePath = writeProbeJSONL(midlineJSONL)
        defer {
            for path in [
                plainCwdPath, relocatedInHeadPath, multipleRelocationsPath,
                relocatedInTailPath, multipleInTailPath, emptyRelocatedCwdPath,
                relocatedNoisePath, boundaryPath, midlinePath,
            ] {
                if let path { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        record("cwd: no relocation returns initial cwd",
               plainCwdPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe")
        record("cwd: relocated in head wins over initial cwd",
               relocatedInHeadPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/worktree")
        record("cwd: last relocated wins on multiple relocations",
               multipleRelocationsPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/wt2")
        record("cwd: relocated past head window recovered from tail",
               relocatedInTailPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/late-worktree")
        record("cwd: last relocated in tail wins on multiple past head",
               multipleInTailPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/wt-late")
        record("cwd: empty relocatedCwd falls back to first cwd",
               emptyRelocatedCwdPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/main")
        record("cwd: substring relocated noise ignored",
               relocatedNoisePath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/main")
        // Sanity: fixture really puts the relocated line on the tail boundary.
        let boundaryOffsetOK: Bool = {
            guard let path = boundaryPath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else { return false }
            guard data.count == headSize + tailSize else { return false }
            guard data[headSize - 1] == 0x0A else { return false }
            let prefix = Data(boundaryRelocated.utf8.dropLast()) // without trailing \n
            return data[headSize..<(headSize + prefix.count)] == prefix
        }()
        record("cwd: relocated at exact tailStart boundary preserved",
               boundaryOffsetOK
               && boundaryPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/boundary-wt")
        // Sanity: fixture really starts the tail mid-line (byte before
        // tailStart is not `\n`), and the truncated first line is skipped.
        let midlineOffsetOK: Bool = {
            guard let path = midlinePath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else { return false }
            guard data.count == headSize + tailSize else { return false }
            guard data[headSize - 1] != 0x0A else { return false }
            return data[headSize..<(headSize + midlineFragment.utf8.count)]
                == Data(midlineFragment.utf8)
        }()
        record("cwd: mid-line tail start drops truncated fragment",
               midlineOffsetOK
               && midlinePath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/midline-wt")

        // resolveProjectPath truth table — the loadAllSessions encoded-folder
        // verification path, extracted so sidebar discovery can't silently
        // drop sessions when encodePath and the CLI's on-disk folder disagree.
        // Directory names stay alphanumeric: `decodePath`'s greedy walk only
        // joins up to 6 hyphen-split tokens, so a UUID-with-hyphens folder
        // would fail to round-trip and poison the middle-gap case.
        let fm = FileManager.default
        let stamp = String(UUID().uuidString.filter(\.isHexDigit))
        let resolveBase = fm.temporaryDirectory
            .appendingPathComponent("canopyproberesolve\(stamp)", isDirectory: true)
        let agreeDir = resolveBase.appendingPathComponent("agreecwd", isDirectory: true)
        let staleDir = resolveBase.appendingPathComponent("stalelaunch", isDirectory: true)
        let relocatedDir = resolveBase.appendingPathComponent("actualwt", isDirectory: true)
        let driftDir = resolveBase
            .appendingPathComponent("canopyprobeencodingreal", isDirectory: true)
            .appendingPathComponent("exists", isDirectory: true)
        do {
            try fm.createDirectory(at: agreeDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: staleDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: relocatedDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: driftDir, withIntermediateDirectories: true)
        } catch {
            record("resolveProjectPath: temp dirs created", false, String(describing: error))
        }
        defer { try? fm.removeItem(at: resolveBase) }

        let agreeEncoded = ClaudeSessionHistory.encodePath(agreeDir.path)
        record("resolveProjectPath: agreement returns extracted cwd",
               ClaudeSessionHistory.resolveProjectPath(
                   extractedCwd: agreeDir.path,
                   projectEncoded: agreeEncoded
               ) == agreeDir.path)

        let relocatedEncoded = ClaudeSessionHistory.encodePath(relocatedDir.path)
        precondition(
            !ClaudeSessionHistory.encodedFolderCandidates(for: staleDir.path)
                .contains(relocatedEncoded),
            "stale and relocated encodings must differ for middle-gap case"
        )
        record("resolveProjectPath: middle-gap relocation prefers decoded folder",
               ClaudeSessionHistory.resolveProjectPath(
                   extractedCwd: staleDir.path,
                   projectEncoded: relocatedEncoded
               ) == relocatedDir.path)

        let bogusEncoded = "-a-bogus-folder-name-that-decodes-to-nothing"
        let bogusDecoded = ClaudeSessionHistory.decodePath(bogusEncoded)
        precondition(
            !fm.fileExists(atPath: bogusDecoded),
            "bogus decodePath result must not exist on disk"
        )
        precondition(
            !ClaudeSessionHistory.encodedFolderCandidates(for: driftDir.path)
                .contains(bogusEncoded),
            "real cwd encoding must disagree with bogus projectEncoded"
        )
        record("resolveProjectPath: encoding drift falls back to extracted cwd",
               ClaudeSessionHistory.resolveProjectPath(
                   extractedCwd: driftDir.path,
                   projectEncoded: bogusEncoded
               ) == driftDir.path)

        record("resolveProjectPath: nil extracted cwd returns decodePath",
               ClaudeSessionHistory.resolveProjectPath(
                   extractedCwd: nil,
                   projectEncoded: bogusEncoded
               ) == bogusDecoded)
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
        // Positive lower boundary: exactly 16 alnum chars is the minimum
        // accepted. Regression class: an off-by-one flipping `>= 16` to
        // `> 16` would silently drop the shortest valid id shape while
        // still passing the 15-char reject and 40-char accept tests.
        let idMin = "toolu_" + String(repeating: "A", count: 16)
        record("historic ids: 16-char id captured (min boundary)",
               ShimProcess.extractToolUseIds(fromText: idMin).contains(idMin))

        // Trailing-underscore reject — the `(?![A-Za-z0-9_])` half of the
        // guard, which the over-length test can't reach because that one
        // trips the alphanumeric branch first. Regression class: dropping
        // the underscore check from `isAsciiAlnumOrUnderscore` would leave
        // this test as the sole tripwire.
        let withTrailingUnderscore = "toolu_" + String(repeating: "A", count: 20) + "_"
        record("historic ids: trailing underscore rejects the run",
               !ShimProcess.extractToolUseIds(fromText: withTrailingUnderscore)
                   .contains("toolu_" + String(repeating: "A", count: 20)))

        // Multi-byte neighbors — session JSONLs are Japanese/emoji-heavy.
        // The byte-scan claim in `extractToolUseIds(fromText:)` is that the
        // ASCII prefix + `[A-Za-z0-9]{16..40}` scan is safe against any
        // multi-byte characters surrounding a valid id. Regression class:
        // a future switch to `text.count` / `unicodeScalars`-based indexing
        // would silently drop ids in JP-heavy sessions.
        let idJP = "toolu_" + String(repeating: "A", count: 20)
        let jpText = "前置き " + idJP + " 🚀 後続"
        record("historic ids: id survives multi-byte JP/emoji neighbors",
               ShimProcess.extractToolUseIds(fromText: jpText).contains(idJP))

        // Back-to-back ids with no separator byte. The `i = max(end, i + prefixLen)`
        // advance is designed to prevent a valid match's trailing byte from
        // seeding a phantom re-match. With two 20-char bodies concatenated,
        // the scanner sees a single 40-char run after the first prefix
        // (`AAAA…AAAAtoolu_BBBB…` reads as prefix + `A×20` + `toolu_` +
        // `B×20`, but the alnum run after the first prefix continues into
        // `toolu_` — no separator). Contract: either both captured or
        // neither, never a truncated first-only capture.
        let backToBack = "toolu_" + String(repeating: "A", count: 20)
                       + "toolu_" + String(repeating: "B", count: 20)
        let backToBackIds = ShimProcess.extractToolUseIds(fromText: backToBack)
        record("historic ids: back-to-back ids don't yield a truncated capture",
               backToBackIds.count == 2 || backToBackIds.isEmpty)

        // Multiple ids on a single line — scanner must iterate, not
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
        record("projectDisplayName: in-repo .claude/worktrees layout → repo · branch",
               GitWorktree.projectDisplayName(
                   for: URL(fileURLWithPath: "/repos/LSE-Core/.claude/worktrees/harfbuzz-palt-fix"))
                   == "LSE-Core · harfbuzz-palt-fix")
        record("projectDisplayName: bare .claude/worktrees (no repo) falls back to folder name",
               GitWorktree.projectDisplayName(
                   for: URL(fileURLWithPath: "/.claude/worktrees/orphan")) == "orphan")
        record("projectDisplayName: in-repo layout with extra depth → folder name",
               GitWorktree.projectDisplayName(
                   for: URL(fileURLWithPath: "/repos/LSE-Core/.claude/worktrees/harfbuzz/nested"))
                   == "nested")
        record("projectDisplayName: ~/.claude/worktrees/<branch> not treated as in-repo",
               GitWorktree.projectDisplayName(
                   for: GitWorktree.worktreesRoot.appendingPathComponent("orphan-branch"))
                   == "orphan-branch")

        record("isManagedWorktree: managed layout → true",
               GitWorktree.isManagedWorktree(
                   GitWorktree.worktreesRoot.appendingPathComponent("Canopy/fix-foo")))
        record("isManagedWorktree: legacy sibling layout → true",
               GitWorktree.isManagedWorktree(
                   URL(fileURLWithPath: "/repos/Canopy-worktrees/work-123")))
        record("isManagedWorktree: normal dir → false",
               !GitWorktree.isManagedWorktree(URL(fileURLWithPath: "/repos/Canopy")))
        record("isManagedWorktree: bare '-worktrees' folder → false",
               !GitWorktree.isManagedWorktree(URL(fileURLWithPath: "/repos/-worktrees/x")))
        record("isManagedWorktree: '..'-laden path still recognized",
               GitWorktree.isManagedWorktree(
                   GitWorktree.worktreesRoot
                       .appendingPathComponent("Other/../Canopy/fix-foo")))
        record("isManagedWorktree: in-repo layout → true",
               GitWorktree.isManagedWorktree(
                   URL(fileURLWithPath: "/repos/LSE-Core/.claude/worktrees/harfbuzz")))
        record("isManagedWorktree: ~/.claude/worktrees/<branch> → false",
               !GitWorktree.isManagedWorktree(
                   GitWorktree.worktreesRoot.appendingPathComponent("orphan-branch")))

        // --- RecentDirectories worktree filter (add + load) ---
        // Uses real UserDefaults + real temp/managed-root directories, then
        // restores the prior state explicitly — Swift `defer` does NOT run
        // when `runIfRequested` finishes via `exit()`.
        do {
            let key = "recentDirectories"
            let priorStored = UserDefaults.standard.stringArray(forKey: key)
            let tmp = FileManager.default.temporaryDirectory
            let normalDir = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let repoName = "ProbeRepo-\(UUID().uuidString)"
            let worktreeParent = GitWorktree.worktreesRoot
                .appendingPathComponent(repoName, isDirectory: true)
            let worktreeDir = worktreeParent.appendingPathComponent("branch", isDirectory: true)
            try? FileManager.default.createDirectory(at: normalDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)

            // add() short-circuits on a worktree URL — UserDefaults must not change.
            UserDefaults.standard.set([normalDir.path], forKey: key)
            RecentDirectories.add(worktreeDir)
            record("RecentDirectories.add: worktree URL is not persisted",
                   UserDefaults.standard.stringArray(forKey: key) == [normalDir.path])

            // load() drops an already-persisted worktree entry — the passive
            // migration path for users upgrading from pre-guard Canopy builds.
            UserDefaults.standard.set([normalDir.path, worktreeDir.path], forKey: key)
            record("RecentDirectories.load: existing worktree entry is filtered",
                   RecentDirectories.load().map(\.path) == [normalDir.path])

            // add() still persists a normal directory (guard doesn't over-reject).
            UserDefaults.standard.set([], forKey: key)
            RecentDirectories.add(normalDir)
            record("RecentDirectories.add: normal dir persists as before",
                   UserDefaults.standard.stringArray(forKey: key) == [normalDir.path])

            // Restore the pre-probe UserDefaults key + synchronize (exit()
            // skips the run-loop flush) + best-effort tmp cleanup.
            if let priorStored {
                UserDefaults.standard.set(priorStored, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            UserDefaults.standard.synchronize()
            try? FileManager.default.removeItem(at: normalDir)
            try? FileManager.default.removeItem(at: worktreeParent)
        }

        // --- Open-session reorder (drag & drop) ---
        // Pure mapping: a move expressed against the visible (filtered) open
        // rows is applied to the master array; hidden rows keep their slots.
        record("reorder: full visible, move first to end",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "B", "C"], visible: ["A", "B", "C"],
                   fromOffsets: IndexSet(integer: 0), toOffset: 3)
                   == ["B", "C", "A"])
        record("reorder: full visible, move last to front",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "B", "C"], visible: ["A", "B", "C"],
                   fromOffsets: IndexSet(integer: 2), toOffset: 0)
                   == ["C", "A", "B"])
        record("reorder: hidden interior rows keep their slots",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "h1", "B", "h2", "C"], visible: ["A", "B", "C"],
                   fromOffsets: IndexSet(integer: 2), toOffset: 0)
                   == ["C", "h1", "A", "h2", "B"])
        record("reorder: no-op move returns master unchanged",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "h1", "B"], visible: ["A", "B"],
                   fromOffsets: IndexSet(integer: 1), toOffset: 1)
                   == ["A", "h1", "B"])
        record("reorder: out-of-range offsets return master unchanged",
               SessionStore.reorderPreservingHidden(
                   master: ["A", "B", "C"], visible: ["A", "B", "C"],
                   fromOffsets: IndexSet(integer: 5), toOffset: 0)
                   == ["A", "B", "C"]
               && SessionStore.reorderPreservingHidden(
                   master: ["A", "B", "C"], visible: ["A", "B", "C"],
                   fromOffsets: IndexSet(integer: 0), toOffset: 7)
                   == ["A", "B", "C"])

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
        // Main-conversation `result` must NOT freeze bg rows either —
        // their real completion is `completeIfPresent` (JSONL marker /
        // TaskStop). Covered in depth by the issue #91 section below;
        // keep a one-liner here so the subagent MARK stays self-contained.
        let bgResultChanged = bgTracker.observe(["type": "result"], now: t0)
        record("subagent: bg row stays running past turn `result`",
               !bgResultChanged && bgTracker.rows[0].isRunning)

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

        // Historic gate: `--resume` re-emits already-logged Agent/Task
        // tool_use blocks through io_message. `historicToolUseIds` (loaded
        // async by ShimProcess after its JSONL snapshot) must prevent
        // those from adding new rows.
        var historicTracker = SubagentTracker()
        historicTracker.loadHistoricIds(["toolu_A"])
        _ = historicTracker.observe(launchMsg, now: t0)
        record("subagent: historic tool_use skipped, non-historic added",
               historicTracker.rows.count == 1 && historicTracker.rows[0].id == "toolu_B",
               "ids=\(historicTracker.rows.map(\.id))")

        // Purge: rows that landed before the historic set loaded must
        // be dropped once it arrives. `loadHistoricIds` returns the number
        // it purged in the same call, so the shim path never sees a state
        // where the set is populated but stale rows still sit in `rows`.
        var purgeTracker = SubagentTracker()
        _ = purgeTracker.observe(launchMsg, now: t0)
        let purged = purgeTracker.loadHistoricIds(["toolu_A"])
        record("subagent: loadHistoricIds installs set AND purges race rows",
               purged == 1 && purgeTracker.rows.count == 1 && purgeTracker.rows[0].id == "toolu_B",
               "purged=\(purged) ids=\(purgeTracker.rows.map(\.id))")

        // Unknown message type — future CLI protocol extension shouldn't
        // trip a fatal. Regression class: a switch to strict enum decoding
        // would crash instead of the current no-op-with-DEBUG-log.
        var unknownTracker = SubagentTracker()
        record("subagent: unknown ioMsg type → observe false, no crash",
               !unknownTracker.observe(["type": "future_extension"], now: t0)
                   && unknownTracker.rows.isEmpty)

        // MARK: - Background task lifecycle (issue #90)
        // Pure static helpers only — pendingBackgroundTaskIds lives on
        // ShimProcess and isn't probe-visible without spawning a shim.
        let launchAck =
            "Command running in background with ID: b5nt1jeth. Output is being written to: /tmp/foo.output."
        record("bg lifecycle: extractLaunchAckTaskId finds id",
               ShimProcess.extractLaunchAckTaskId(launchAck) == "b5nt1jeth",
               "got=\(ShimProcess.extractLaunchAckTaskId(launchAck) ?? "nil")")
        record("bg lifecycle: extractLaunchAckTaskId unrelated → nil",
               ShimProcess.extractLaunchAckTaskId("hello") == nil)
        record("bg lifecycle: extractLaunchAckTaskId empty → nil",
               ShimProcess.extractLaunchAckTaskId("") == nil)
        record("bg lifecycle: extractLaunchAckTaskId prefix-only → nil",
               ShimProcess.extractLaunchAckTaskId("Command running in background with ID: ") == nil)

        let stopResult =
            #"{"message":"Successfully stopped task: b5nt1jeth (pkill -f 'wrangler dev' 2>/dev/null; sleep 1\nsh -c 'exec node_modules/.bin/wrangler dev --remote --port 8791 2>&1')","task_id":"b5nt1jeth","task_type":"local_bash","command":"..."}"#
        record("bg lifecycle: extractStoppedTaskId finds id in TaskStop JSON",
               ShimProcess.extractStoppedTaskId(stopResult) == "b5nt1jeth",
               "got=\(ShimProcess.extractStoppedTaskId(stopResult) ?? "nil")")
        record("bg lifecycle: extractStoppedTaskId unrelated → nil",
               ShimProcess.extractStoppedTaskId("hello") == nil)
        record("bg lifecycle: extractStoppedTaskId empty → nil",
               ShimProcess.extractStoppedTaskId("") == nil)
        record("bg lifecycle: extractStoppedTaskId prefix-only → nil",
               ShimProcess.extractStoppedTaskId("Successfully stopped task: ") == nil)
        record("bg lifecycle: extractLaunchAckTaskId non-alnum id truncates at first non-alnum",
               ShimProcess.extractLaunchAckTaskId("Command running in background with ID: abc-def.") == "abc")

        let plainBlock: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": "toolu_x",
            "content": launchAck,
        ]
        record("bg lifecycle: extractToolResultText plain String",
               ShimProcess.extractToolResultText(plainBlock) == launchAck)
        let arrayBlock: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": "toolu_y",
            "content": [
                ["type": "text", "text": "line one"],
                ["type": "text", "text": "line two"],
                ["type": "image", "text": "ignored"],
            ] as [[String: Any]],
        ]
        record("bg lifecycle: extractToolResultText array-of-text joins",
               ShimProcess.extractToolResultText(arrayBlock) == "line one\nline two",
               "got=\(ShimProcess.extractToolResultText(arrayBlock))")
        let missingContent: [String: Any] = ["type": "tool_result", "tool_use_id": "toolu_z"]
        record("bg lifecycle: extractToolResultText missing content → empty",
               ShimProcess.extractToolResultText(missingContent) == "")
        let nullContent: [String: Any] = [
            "type": "tool_result", "tool_use_id": "toolu_n", "content": NSNull(),
        ]
        record("bg lifecycle: extractToolResultText NSNull content → empty",
               ShimProcess.extractToolResultText(nullContent) == "")
        let emptyArray: [String: Any] = [
            "type": "tool_result", "tool_use_id": "toolu_e",
            "content": [] as [[String: Any]],
        ]
        record("bg lifecycle: extractToolResultText empty array → empty",
               ShimProcess.extractToolResultText(emptyArray) == "")
        let imageOnly: [String: Any] = [
            "type": "tool_result", "tool_use_id": "toolu_i",
            "content": [["type": "image"]] as [[String: Any]],
        ]
        record("bg lifecycle: extractToolResultText image-only blocks → empty",
               ShimProcess.extractToolResultText(imageOnly) == "")
        let missingTextField: [String: Any] = [
            "type": "tool_result", "tool_use_id": "toolu_m",
            "content": [
                ["type": "text"],
                ["type": "text", "text": "kept"],
            ] as [[String: Any]],
        ]
        record("bg lifecycle: extractToolResultText text block missing text field skips",
               ShimProcess.extractToolResultText(missingTextField) == "kept",
               "got=\(ShimProcess.extractToolResultText(missingTextField))")

        // MARK: - Bg Agent completion timing (issue #91)
        // Pure SubagentTracker state machine: bg rows must stay running past
        // the parent turn's `result`, and finish only via `completeIfPresent`
        // (wired from ShimProcess on JSONL marker / TaskStop / historic
        // reconcile). ShimProcess-side wire-up is not probe-visible — same
        // limitation as the TaskStop mapping probes under issue #90.
        do {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let t1 = Date(timeIntervalSince1970: 1_700_000_042)
            let bgId = "toolu_BG91"
            let fgId = "toolu_FG91"
            let bgLaunch: [String: Any] = [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use",
                            "name": "Agent",
                            "id": bgId,
                            "input": [
                                "description": "bg review",
                                "subagent_type": "general-purpose",
                                "run_in_background": true,
                                "prompt": "x",
                            ],
                        ],
                    ] as [[String: Any]],
                ] as [String: Any],
            ]
            let fgLaunch: [String: Any] = [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use",
                            "name": "Agent",
                            "id": fgId,
                            "input": [
                                "description": "fg review",
                                "subagent_type": "Explore",
                                "prompt": "y",
                            ],
                        ],
                    ] as [[String: Any]],
                ] as [String: Any],
            ]

            // T1: bg Agent + main-conv result → row stays isRunning
            var t1Tracker = SubagentTracker()
            _ = t1Tracker.observe(bgLaunch, now: t0)
            let t1ResultChanged = t1Tracker.observe(["type": "result"], now: t0)
            record("bg complete #91 T1: result leaves bg row running",
                   !t1ResultChanged
                       && t1Tracker.rows.count == 1
                       && t1Tracker.rows[0].isRunning
                       && t1Tracker.rows[0].id == bgId,
                   "changed=\(t1ResultChanged) running=\(t1Tracker.rows.first?.isRunning ?? false)")

            // T2: completeIfPresent after result → finishedAt == t1
            var t2Tracker = SubagentTracker()
            _ = t2Tracker.observe(bgLaunch, now: t0)
            _ = t2Tracker.observe(["type": "result"], now: t0)
            let t2Transitioned = t2Tracker.completeIfPresent(id: bgId, at: t1)
            record("bg complete #91 T2: completeIfPresent finishes bg row",
                   t2Transitioned
                       && !t2Tracker.rows[0].isRunning
                       && t2Tracker.rows[0].finishedAt == t1,
                   "transitioned=\(t2Transitioned) finishedAt=\(String(describing: t2Tracker.rows.first?.finishedAt))")

            // T3: foreground row still freezes on result
            var t3Tracker = SubagentTracker()
            _ = t3Tracker.observe(fgLaunch, now: t0)
            let t3Changed = t3Tracker.observe(["type": "result"], now: t0)
            record("bg complete #91 T3: foreground still freezes on result",
                   t3Changed
                       && t3Tracker.rows.count == 1
                       && !t3Tracker.rows[0].isRunning
                       && t3Tracker.rows[0].finishedAt == t0,
                   "changed=\(t3Changed) running=\(t3Tracker.rows.first?.isRunning ?? true)")

            // T4: unknown id → false, no mutation
            var t4Tracker = SubagentTracker()
            _ = t4Tracker.observe(bgLaunch, now: t0)
            let beforeT4 = t4Tracker.rows
            let t4Result = t4Tracker.completeIfPresent(id: "toolu_UNKNOWN", at: t1)
            record("bg complete #91 T4: unknown id → false, rows untouched",
                   !t4Result && t4Tracker.rows == beforeT4,
                   "result=\(t4Result) count=\(t4Tracker.rows.count)")

            // T5: already-finished → false, preserves earlier finishedAt
            var t5Tracker = SubagentTracker()
            _ = t5Tracker.observe(bgLaunch, now: t0)
            _ = t5Tracker.completeIfPresent(id: bgId, at: t0)
            let t5Second = t5Tracker.completeIfPresent(id: bgId, at: t1)
            record("bg complete #91 T5: already-finished is idempotent",
                   !t5Second
                       && t5Tracker.rows[0].finishedAt == t0,
                   "second=\(t5Second) finishedAt=\(String(describing: t5Tracker.rows.first?.finishedAt))")

            // T6: mixed bg + foreground → result freezes only foreground
            let mixedLaunch: [String: Any] = [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use",
                            "name": "Agent",
                            "id": bgId,
                            "input": [
                                "description": "bg review",
                                "subagent_type": "general-purpose",
                                "run_in_background": true,
                                "prompt": "x",
                            ],
                        ],
                        [
                            "type": "tool_use",
                            "name": "Agent",
                            "id": fgId,
                            "input": [
                                "description": "fg review",
                                "subagent_type": "Explore",
                                "prompt": "y",
                            ],
                        ],
                    ] as [[String: Any]],
                ] as [String: Any],
            ]
            var t6Tracker = SubagentTracker()
            _ = t6Tracker.observe(mixedLaunch, now: t0)
            let t6Changed = t6Tracker.observe(["type": "result"], now: t0)
            let t6Bg = t6Tracker.rows.first(where: { $0.id == bgId })
            let t6Fg = t6Tracker.rows.first(where: { $0.id == fgId })
            record("bg complete #91 T6: mixed batch freezes only foreground",
                   t6Changed
                       && (t6Bg?.isRunning == true)
                       && (t6Fg?.isRunning == false),
                   "changed=\(t6Changed) bgRunning=\(t6Bg?.isRunning ?? false) fgRunning=\(t6Fg?.isRunning ?? true)")

            // T7/T8 regress-guard the F1 race-fix: running bg rows must
            // survive next-turn `message_start` so a later async
            // `completeIfPresent` can still find them. If the exemption is
            // ever removed, both tests fail loudly.
            let nextTurnClear: [String: Any] = [
                "type": "stream_event",
                "event": ["type": "message_start"] as [String: Any],
            ]

            // T7: after result + next-turn message_start, running bg rows
            // are preserved; foreground rows in the batch are cleared.
            var t7Tracker = SubagentTracker()
            _ = t7Tracker.observe(mixedLaunch, now: t0)
            _ = t7Tracker.observe(["type": "result"], now: t0)
            let t7Changed = t7Tracker.observe(nextTurnClear, now: t1)
            let t7Bg = t7Tracker.rows.first(where: { $0.id == bgId })
            let t7Fg = t7Tracker.rows.first(where: { $0.id == fgId })
            record("bg complete #91 T7: message_start preserves running bg, clears fg",
                   t7Changed
                       && t7Tracker.rows.count == 1
                       && (t7Bg?.isRunning == true)
                       && t7Fg == nil,
                   "changed=\(t7Changed) count=\(t7Tracker.rows.count) bgRunning=\(t7Bg?.isRunning ?? false) fgGone=\(t7Fg == nil)")

            // T8: race-safe path — bg survives message_start, then
            // completeIfPresent finishes it with the post-clear timestamp.
            var t8Tracker = SubagentTracker()
            _ = t8Tracker.observe(bgLaunch, now: t0)
            _ = t8Tracker.observe(["type": "result"], now: t0)
            _ = t8Tracker.observe(nextTurnClear, now: t1)
            let t8Transitioned = t8Tracker.completeIfPresent(id: bgId, at: t1)
            record("bg complete #91 T8: completeIfPresent after message_start finishes bg",
                   t8Transitioned
                       && t8Tracker.rows.count == 1
                       && !t8Tracker.rows[0].isRunning
                       && t8Tracker.rows[0].finishedAt == t1,
                   "transitioned=\(t8Transitioned) finishedAt=\(String(describing: t8Tracker.rows.first?.finishedAt))")
        }

        // MARK: - Panes
        do {
            // Brief names openA / openB / recentAsOpen; only openA/openB are
            // fabricated above. Build a third OpenSession here for the seed.
            let recentAsOpen = OpenSession(
                origin: .local(cwd),
                resumeId: "open-recent",
                title: "Recent as open",
                project: "ProjectRecent",
                status: .live,
                lastActiveAt: now.addingTimeInterval(-oneHour * 2)
            )
            let store = SessionStore()
            store._probeSeedOpenSessions([openA, openB, recentAsOpen])
            record("panes: empty by default", store.panes.isEmpty)

            store.openInFocusedPane(openA.id)
            record("openInFocusedPane on empty seeds first pane",
                   store.panes.count == 1 && store.focusedPaneIndex == 0
                   && store.panes[0].content == .session(openA.id)
                   && store.panes[0].preferredWidth == SessionStore.paneDefaultWidth)

            let addedB = store.openInNewPane(openB.id)
            record("openInNewPane appends and focuses new",
                   addedB && store.panes.count == 2 && store.focusedPaneIndex == 1
                   && store.panes[1].content == .session(openB.id))

            store.openLauncherInFocusedPane()
            record("openLauncherInFocusedPane sets focused to .launcher",
                   store.panes[store.focusedPaneIndex].content == .launcher)
            store.openInFocusedPane(openB.id)   // restore session content for next tests

            let addedBAgain = store.openInNewPane(openB.id)
            record("openInNewPane on already-in-pane bounces + focuses",
                   !addedBAgain && store.panes.count == 2 && store.focusedPaneIndex == 1)

            store.moveFocus(delta: -1)
            record("moveFocus(-1) moves left", store.focusedPaneIndex == 0)
            store.moveFocus(delta: -1)
            record("moveFocus wraps", store.focusedPaneIndex == 1)

            store.closePane(at: 1)
            record("closePane shifts focus left",
                   store.panes.count == 1 && store.focusedPaneIndex == 0
                   && store.panes[0].content == .session(openA.id))

            // Closing a non-focused pane must keep focus on the same
            // underlying pane (index just shifts left if removal was before it).
            let openC = OpenSession(
                origin: .local(cwd),
                resumeId: "open-C",
                title: "Open C",
                project: "ProjectC",
                status: .live,
                lastActiveAt: now.addingTimeInterval(-oneHour * 3)
            )
            let storeKeepFocus = SessionStore()
            storeKeepFocus._probeSeedOpenSessions([openA, openB, openC])
            _ = storeKeepFocus.openInNewPane(openA.id)
            _ = storeKeepFocus.openInNewPane(openB.id)
            _ = storeKeepFocus.openInNewPane(openC.id)
            // openInNewPane focuses the newly appended pane → index 2
            // (focusedPaneIndex is private(set); cannot assign directly).
            storeKeepFocus.closePane(at: 0)
            record("closePane keeps focus when non-focused pane closed",
                   storeKeepFocus.panes.count == 2
                   && storeKeepFocus.focusedPaneIndex == 1
                   && storeKeepFocus.panes[1].content == .session(openC.id))

            // Cap
            let store2 = SessionStore()
            let sessions = (0..<6).map { i in
                OpenSession(origin: .local(cwd), resumeId: "s\(i)", title: "s\(i)", project: "p", status: .live)
            }
            store2._probeSeedOpenSessions(sessions)
            for s in sessions.prefix(5) { _ = store2.openInNewPane(s.id) }
            record("cap reached at 5", store2.panes.count == 5)
            let sixth = store2.openInNewPane(sessions[5].id)
            record("cap bounces sixth add", !sixth && store2.panes.count == 5)

            // closeSession → removePanesForClosedSession selection derivation.
            // panes=[A,C] with C focused; closing A (non-focused) must leave
            // focus on C and selection=.session(C), not the openSessions-order
            // neighbor (which would be B).
            let closeSelA = OpenSession(origin: .local(cwd), resumeId: "close-sel-A", title: "A", project: "p", status: .live)
            let closeSelB = OpenSession(origin: .local(cwd), resumeId: "close-sel-B", title: "B", project: "p", status: .live)
            let closeSelC = OpenSession(origin: .local(cwd), resumeId: "close-sel-C", title: "C", project: "p", status: .live)
            let storeCloseSel = SessionStore()
            storeCloseSel._probeSeedOpenSessions([closeSelA, closeSelB, closeSelC])
            _ = storeCloseSel.openInNewPane(closeSelA.id)
            _ = storeCloseSel.openInNewPane(closeSelC.id)
            // openInNewPane focuses newly appended → index 1 (C)
            record("closeSession pre: panes=[A,C] C focused",
                   storeCloseSel.panes.count == 2
                   && storeCloseSel.focusedPaneIndex == 1
                   && storeCloseSel.panes[1].content == .session(closeSelC.id))
            storeCloseSel.closeSession(closeSelA.id)
            record("closeSession derives selection from panes (not openSessions order)",
                   storeCloseSel.panes.count == 1
                   && storeCloseSel.focusedPaneIndex == 0
                   && storeCloseSel.panes[0].content == .session(closeSelC.id)
                   && storeCloseSel.selection == .session(closeSelC.id))

            // setAdjacentPaneWidths snap-to-floor
            let storeSnap = SessionStore()
            let snapA = OpenSession(origin: .local(cwd), resumeId: "snap-A", title: "A", project: "p", status: .live)
            let snapB = OpenSession(origin: .local(cwd), resumeId: "snap-B", title: "B", project: "p", status: .live)
            storeSnap._probeSeedOpenSessions([snapA, snapB])
            _ = storeSnap.openInNewPane(snapA.id)
            _ = storeSnap.openInNewPane(snapB.id)
            storeSnap.forceSetPaneWidth(at: 0, to: 500)
            storeSnap.forceSetPaneWidth(at: 1, to: 500)
            storeSnap.setAdjacentPaneWidths(leftIndex: 0, leftWidth: 50, rightWidth: 950)
            record("setAdjacentPaneWidths snaps left below floor",
                   storeSnap.panes[0].preferredWidth == 100
                   && storeSnap.panes[1].preferredWidth == 900)
            storeSnap.setAdjacentPaneWidths(leftIndex: 0, leftWidth: 100, rightWidth: 900)
            record("setAdjacentPaneWidths exact at floor",
                   storeSnap.panes[0].preferredWidth == 100
                   && storeSnap.panes[1].preferredWidth == 900)
            storeSnap.setAdjacentPaneWidths(leftIndex: 0, leftWidth: 950, rightWidth: 50)
            record("setAdjacentPaneWidths snaps right below floor",
                   storeSnap.panes[0].preferredWidth == 900
                   && storeSnap.panes[1].preferredWidth == 100)

            // setAdjacentPaneWidths: reject when sum < 2*floor (writes would
            // otherwise land a sub-floor / negative preferredWidth on the left).
            let storeReject = SessionStore()
            let rejectA = OpenSession(origin: .local(cwd), resumeId: "reject-A", title: "A", project: "p", status: .live)
            let rejectB = OpenSession(origin: .local(cwd), resumeId: "reject-B", title: "B", project: "p", status: .live)
            storeReject._probeSeedOpenSessions([rejectA, rejectB])
            _ = storeReject.openInNewPane(rejectA.id)
            _ = storeReject.openInNewPane(rejectB.id)
            storeReject.forceSetPaneWidth(at: 0, to: 50)
            storeReject.forceSetPaneWidth(at: 1, to: 50)
            storeReject.setAdjacentPaneWidths(leftIndex: 0, leftWidth: 30, rightWidth: 70)
            record("setAdjacentPaneWidths rejects sum below 2*floor",
                   storeReject.panes[0].preferredWidth == 50
                   && storeReject.panes[1].preferredWidth == 50)
            storeReject.setAdjacentPaneWidths(leftIndex: 0, leftWidth: -20, rightWidth: 120)
            record("setAdjacentPaneWidths rejects negative-width sum below 2*floor",
                   storeReject.panes[0].preferredWidth == 50
                   && storeReject.panes[1].preferredWidth == 50)

            // openInFocusedPane already-in-pane branch: jump focus, don't duplicate
            let storeJump = SessionStore()
            let jumpA = OpenSession(origin: .local(cwd), resumeId: "jump-A", title: "A", project: "p", status: .live)
            let jumpB = OpenSession(origin: .local(cwd), resumeId: "jump-B", title: "B", project: "p", status: .live)
            let jumpC = OpenSession(origin: .local(cwd), resumeId: "jump-C", title: "C", project: "p", status: .live)
            storeJump._probeSeedOpenSessions([jumpA, jumpB, jumpC])
            _ = storeJump.openInNewPane(jumpA.id)
            _ = storeJump.openInNewPane(jumpB.id)
            // focus at 1 (B)
            storeJump.openInFocusedPane(jumpA.id)
            record("openInFocusedPane already-in-pane jumps focus",
                   storeJump.focusedPaneIndex == 0
                   && storeJump.panes[0].content == .session(jumpA.id)
                   && storeJump.panes.count == 2)

            // openLauncherInNewPane cap-reached and normal
            let storeLaunchCap = SessionStore()
            let launchSessions = (0..<5).map { i in
                OpenSession(origin: .local(cwd), resumeId: "launch-cap-\(i)", title: "s\(i)", project: "p", status: .live)
            }
            storeLaunchCap._probeSeedOpenSessions(launchSessions)
            for s in launchSessions { _ = storeLaunchCap.openInNewPane(s.id) }
            let launchCapResult = storeLaunchCap.openLauncherInNewPane()
            record("openLauncherInNewPane at cap returns false",
                   !launchCapResult && storeLaunchCap.panes.count == 5)

            let storeLaunchOk = SessionStore()
            let launchOkA = OpenSession(origin: .local(cwd), resumeId: "launch-ok-A", title: "A", project: "p", status: .live)
            storeLaunchOk._probeSeedOpenSessions([launchOkA])
            _ = storeLaunchOk.openInNewPane(launchOkA.id)
            let launchOkResult = storeLaunchOk.openLauncherInNewPane()
            record("openLauncherInNewPane appends launcher pane",
                   launchOkResult
                   && storeLaunchOk.panes.count == 2
                   && storeLaunchOk.panes[1].content == .launcher
                   && storeLaunchOk.focusedPaneIndex == 1)
        }

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
