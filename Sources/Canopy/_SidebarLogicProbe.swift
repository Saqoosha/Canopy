#if DEBUG
import AppKit
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
        let result = runAllTests()
        logger.info("\(result.summary, privacy: .public)")
        FileHandle.standardError.write(Data((result.summary + "\n").utf8))
        // Exit on the counter, never on a substring of the rendered report.
        // The report interpolates test names and detail strings, so scanning
        // it for "FAIL" makes any future case that merely *mentions* the word
        // fail the whole run — a red CI build with every assertion passing.
        exit(result.failures == 0 ? 0 : 1)
    }

    static func runAllTests() -> (summary: String, failures: Int) {
        var pass = 0
        var fail = 0
        var lines: [String] = ["=== Sidebar logic probe ==="]

        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1; lines.append("  PASS \(name)") }
            else  { fail += 1; lines.append("  FAIL \(name) — \(detail)") }
        }

        // Peer-name pinning. Every one of these is a way a renamed session
        // silently loses its name, so each states which failure it pins.
        do {
            record("peer pin: /rename is always pinned",
                   PeerNameStore.isPinned(nameSource: "user"))
            record("peer pin: a derived name is never pinned",
                   !PeerNameStore.isPinned(nameSource: "derived"))
            record("peer pin: a collision name is never pinned",
                   !PeerNameStore.isPinned(nameSource: "collision"))
            // An absent source means "set at spawn", which for a Canopy
            // session is the name Canopy itself passed. Pinning it would let a
            // /clear inside the same shim persist that name under a second
            // sessionId, and it buys nothing: the store entry that drove the
            // restore is still there to drive the next one.
            record("peer pin: an absent source is not pinned",
                   !PeerNameStore.isPinned(nameSource: nil))
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

        // Metadata scanning is by whole line, not by byte prefix. The measured
        // failure: a `/security-review` JSONL opens with a ~90KB
        // `queue-operation` carrying the whole diff, so its `type:"user"`
        // record — entrypoint, cwd and prompt all on it — starts inside the
        // head chunk and ends past it. Reading a flat head chunk left that
        // record truncated and unparseable, which read as "no user line at
        // all": the sdk-py filter never fired and the title fell back, so
        // several such rows sat in the sidebar as "Untitled".
        //
        // Every fixture below whose point is a boundary is sized off
        // `metadataHeadSize` rather than a copy of 131,072 — the same reason `metadataMaxScanSize` is not
        // private. A hardcoded 90,000 straddles the boundary only by
        // arithmetic coincidence, so moving the constant would leave these
        // passing for the wrong reason, both records inside one chunk.
        let head = ClaudeSessionHistory.metadataHeadSize
        let straddleFill = head * 7 / 10
        let giantEnqueue = "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"content\":\""
            + String(repeating: "d", count: straddleFill) + "\"}"
        func giantUserLine(_ cwd: String) -> String {
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Review this change for security vulnerabilities. "
                + String(repeating: "d", count: straddleFill)
                + "\"},\"entrypoint\":\"sdk-py\",\"cwd\":\"\(cwd)\"}"
        }
        func filler(_ bytes: Int) -> String {
            let line = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\""
                + String(repeating: "f", count: 512) + "\"}}\n"
            return String(repeating: line, count: max(1, bytes / line.utf8.count))
        }
        let giantLeadingRecordJSONL = giantEnqueue + "\n" + giantUserLine("/tmp/probe/six-keys") + "\n"
        // A record wider than the escalation ceiling keeps whatever parsed
        // below it — here nothing — rather than scanning forever.
        let overCeilingJSONL = "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"content\":\""
            + String(repeating: "d", count: ClaudeSessionHistory.metadataMaxScanSize + 100_000) + "\"}\n"
            + giantUserLine("/tmp/probe/over-ceiling") + "\n"
        // A scheduled-task enqueue ends the scan even when reaching it took an
        // escalation — so the enqueue itself has to straddle the head chunk,
        // which an earlier revision of this fixture did not do, leaving the
        // assertion true on the single-chunk path it meant to escalate past.
        let giantScheduledJSONL = "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"content\":\"<scheduled-task name=\\\"probe\\\">run</scheduled-task> "
            + String(repeating: "d", count: head + head / 10) + "\"}\n"
            + giantUserLine("/tmp/probe/scheduled") + "\n"
            // Trailing filler so the file does NOT end right after the sdk-py
            // line. Without it the next read is empty and the loop exits on
            // `atEOF` regardless, leaving the outer `while !stopScan` guard
            // deletable in silence — the inner `break` only ends the LINE loop.
            + filler(head)
        // The last record of a JSONL carries no trailing newline. It is
        // complete at EOF and must still be parsed.
        let noTrailingNewlineJSONL =
            "{\"type\":\"summary\",\"summary\":\"prior session\"}\n"
            + "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"unterminated final record\"}}"
        // The escalation gate itself. Only this fixture and `textlessUserJSONL`
        // below fail if the `sawUserRecord` break is deleted — every other one
        // reports the same answer whether the scan stops at the head chunk or
        // reads to the ceiling — so without the two of them, the one line
        // holding the whole cost argument is ungated. A cheap `ai-title` past the head chunk is the
        // lever: it wins over `firstUserMessage` if and only if it is read,
        // and the tail scan cannot rescue it because that path matches only
        // `relocated`.
        let escalationGateJSONL =
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"gate marker\"}}\n"
            + filler(head + head / 2)
            + "{\"type\":\"ai-title\",\"aiTitle\":\"ESCALATED PAST THE GATE\"}\n"
        // The changed tail bound, exercised where it actually differs — which
        // took two tries to build. A `relocated` record merely sitting after an
        // escalation is NOT enough: the line scan consumes it on its way to the
        // chunk boundary and the tail scan never runs, so the fixture passes
        // under either bound. It has to STRADDLE the byte the scan stops on.
        // Then its head half is discarded with `carry`, and bounding the tail
        // at bytes READ starts the window mid-record, the boundary probe calls
        // the remainder a fragment, and the relocation is lost by both halves.
        //
        // What it pins is the naive bytes-read bound, NOT the pre-PR constant:
        // at this file size `fileSize - tailSize` dominates the old `max(...)`
        // and the drop-first-line rule happens to spare the record. Measured,
        // so don't read the assertion as "this failed before the PR".
        let escalatedPrefix = giantEnqueue + "\n" + giantUserLine("/tmp/probe/launch") + "\n"
        let relocatedRecord = "{\"type\":\"relocated\",\"sessionId\":\"probe\",\"relocatedCwd\":\"/tmp/probe/escalated-wt\"}"
        // Two full chunks are READ (the user record closes inside the second),
        // so `scannedBytes` lands on exactly `head * 2` — `consumedBytes` stops
        // short of it, which is the whole point. Start the relocation half a
        // record before the read boundary.
        let stopOffset = head * 2
        let relocatedStart = stopOffset - relocatedRecord.utf8.count / 2
        let fillOverhead = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"\"}}\n".utf8.count
        let fillPad = relocatedStart - escalatedPrefix.utf8.count - fillOverhead
        // A trap here would land in CI's "the app never launched" bucket
        // rather than "assertions failed" — record it instead, and clamp so
        // the fixture is merely wrong rather than fatal.
        record("metadata fixture: escalated-relocated prefix fits before the stop offset",
               fillPad > 0, "fillPad=\(fillPad)")
        let escalatedRelocatedJSONL = escalatedPrefix
            + "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\""
            + String(repeating: "f", count: max(0, fillPad)) + "\"}}\n"
            + relocatedRecord + "\n"
            // Keep the file inside `stopOffset + 32768` so the tail window
            // starts at the scan's own stopping point rather than later.
            + String(repeating: "z", count: 20_000) + "\n"
        // A file whose size is an exact multiple of the head chunk, with a
        // complete but unterminated final record. The read returns exactly what
        // was asked for, so a short read never signals EOF and the scan has to
        // confirm the end before discarding what it holds.
        let exactMultipleHead =
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"first\"}}\n"
        let exactMultipleTail = "{\"type\":\"ai-title\",\"aiTitle\":\"EXACT MULTIPLE\"}"
        let exactMultiplePad = head - exactMultipleHead.utf8.count - exactMultipleTail.utf8.count - 1
        record("metadata fixture: exact-multiple padding fits inside the head chunk",
               exactMultiplePad > 0, "pad=\(exactMultiplePad)")
        let exactMultipleJSONL = exactMultipleHead
            + String(repeating: "x", count: max(0, exactMultiplePad)) + "\n"
            + exactMultipleTail
        // Array content on the first user record — the shape the title path
        // joins rather than reads whole, and the branch the `guard type ==
        // "user"` hoist moved past.
        let arrayContentJSONL =
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":"
            + "[{\"type\":\"text\",\"text\":\"first block\"},{\"type\":\"text\",\"text\":\"second block\"}]}}"
        // The documented hole: `sawUserRecord` is set before the message is
        // unwrapped, so a `tool_result`-only user record — the ordinary shape
        // after the first turn — ends the escalation while yielding no title.
        // Measured 0 of 1,047 local sessions open that way, which is why the
        // gate is not widened; pinning it means widening cannot happen by
        // accident, and the assertion says which behaviour is intended.
        let textlessUserJSONL =
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":"
            + "[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"ok\"}]}}\n"
            + filler(head + head / 2)
            + "{\"type\":\"ai-title\",\"aiTitle\":\"MISSED\"}\n"
        // The deepest escalation any fixture takes: four records, so the loop
        // runs past three chunks with a live carry. What it pins is escalation
        // DEPTH — capping the loop at two or three chunks fails here and
        // nowhere else. It does NOT pin the `Data(carry[searchStart...])`
        // re-basing copy, which was the first claim written here: dropping the
        // copy, hardcoding `searchStart = 0`, or both, changes no fixture's
        // result. The copy is a memory property, not an observable one.
        let deepRecord = { (n: Int) in
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"d\(n) "
                + String(repeating: "d", count: head * 9 / 10) + "\"}}"
        }
        let deepEscalationJSONL = (1...4).map { deepRecord($0) + "\n" }.joined()
            + "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"deep header\"},"
            + "\"entrypoint\":\"sdk-py\",\"cwd\":\"/tmp/probe/deep\"}\n"
        // Bytes that were invalid UTF-8 *on disk* used to be repaired by the
        // lossy decode and are now rejected outright. That trade is deliberate
        // and documented on `consume`; this pins it, because the cost of an
        // accidental revert is the title and the `sdk-*` filter together.
        let invalidUTF8JSONL = Data(
            Array("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"bad ".utf8)
            + [0xE9]
            + Array("\"},\"entrypoint\":\"sdk-py\"}\n".utf8)
            + Array("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"second\"}}\n".utf8)
        )
        let textlessUserPath = writeProbeJSONL(textlessUserJSONL)
        let deepEscalationPath = writeProbeJSONL(deepEscalationJSONL)
        let invalidUTF8Path = writeProbeData(invalidUTF8JSONL)
        let giantLeadingPath = writeProbeJSONL(giantLeadingRecordJSONL)
        let overCeilingPath = writeProbeJSONL(overCeilingJSONL)
        let giantScheduledPath = writeProbeJSONL(giantScheduledJSONL)
        let noTrailingNewlinePath = writeProbeJSONL(noTrailingNewlineJSONL)
        let escalationGatePath = writeProbeJSONL(escalationGateJSONL)
        let escalatedRelocatedPath = writeProbeJSONL(escalatedRelocatedJSONL)
        let exactMultiplePath = writeProbeJSONL(exactMultipleJSONL)
        let arrayContentPath = writeProbeJSONL(arrayContentJSONL)
        defer {
            for path in [giantLeadingPath, overCeilingPath, giantScheduledPath, noTrailingNewlinePath,
                         escalationGatePath, escalatedRelocatedPath, exactMultiplePath, arrayContentPath,
                         textlessUserPath, deepEscalationPath, invalidUTF8Path] {
                if let path { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        record("metadata: sdk-py behind a giant leading record flagged",
               giantLeadingPath.map { ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true,
               "path=\(giantLeadingPath ?? "nil (fixture write failed)")")
        record("metadata: title read from a record straddling the head chunk",
               giantLeadingPath.map {
                   ClaudeSessionHistory.title(atPath: $0)
                       .hasPrefix("Review this change for security vulnerabilities.")
               } == true,
               "got \(giantLeadingPath.map { ClaudeSessionHistory.title(atPath: $0) } ?? "nil")")
        record("metadata: cwd read from a record straddling the head chunk",
               giantLeadingPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/six-keys",
               "got \(giantLeadingPath.flatMap { ClaudeSessionHistory.cwd(atPath: $0) } ?? "nil")")
        record("metadata: record past the scan ceiling stays unflagged",
               overCeilingPath.map { !ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true,
               "path=\(overCeilingPath ?? "nil (fixture write failed)")")
        record("metadata: record past the scan ceiling stays Untitled",
               overCeilingPath.map { ClaudeSessionHistory.title(atPath: $0) } == "Untitled",
               "got \(overCeilingPath.map { ClaudeSessionHistory.title(atPath: $0) } ?? "nil (fixture write failed)")")
        record("metadata: scheduled-task enqueue found after escalating",
               giantScheduledPath.map { ClaudeSessionHistory.isBackgroundScheduledSession(atPath: $0) } == true,
               "path=\(giantScheduledPath ?? "nil (fixture write failed)")")
        record("metadata: scheduled-task stop leaves the later sdk-py line unread",
               giantScheduledPath.map { !ClaudeSessionHistory.isAutomatedSession(atPath: $0) } == true,
               "path=\(giantScheduledPath ?? "nil (fixture write failed)")")
        record("metadata: final record without trailing newline parsed",
               noTrailingNewlinePath.map { ClaudeSessionHistory.title(atPath: $0) } == "unterminated final record",
               "got \(noTrailingNewlinePath.map { ClaudeSessionHistory.title(atPath: $0) } ?? "nil")")
        record("metadata: a text-less user record still ends the escalation",
               textlessUserPath.map { ClaudeSessionHistory.title(atPath: $0) } == "Untitled",
               "got \(textlessUserPath.map { ClaudeSessionHistory.title(atPath: $0) } ?? "nil")")
        record("metadata: escalation survives three chunks with a live carry",
               deepEscalationPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/deep",
               "got \(deepEscalationPath.flatMap { ClaudeSessionHistory.cwd(atPath: $0) } ?? "nil")")
        record("metadata: a header line with invalid UTF-8 is rejected, not repaired",
               invalidUTF8Path.map { ClaudeSessionHistory.title(atPath: $0) } == "second",
               "got \(invalidUTF8Path.map { ClaudeSessionHistory.title(atPath: $0) } ?? "nil (fixture write failed)")")
        // Not decoration: `want = min(metadataHeadSize, ceiling - scannedBytes)`
        // is dead code only while this holds. Break the relationship and the
        // final chunk is short, on a path nothing else covers.
        record("metadata: the ceiling is an exact multiple of the head chunk",
               ClaudeSessionHistory.metadataMaxScanSize % ClaudeSessionHistory.metadataHeadSize == 0,
               "ceiling=\(ClaudeSessionHistory.metadataMaxScanSize) head=\(ClaudeSessionHistory.metadataHeadSize)")
        record("metadata: escalation stops once a user record has parsed",
               escalationGatePath.map { ClaudeSessionHistory.title(atPath: $0) } == "gate marker",
               "got \(escalationGatePath.map { ClaudeSessionHistory.title(atPath: $0) } ?? "nil")")
        // Named for the bound, not the escalation: removing escalation entirely
        // leaves this passing, because the tail scan alone rescues the record.
        // It is the sole killer for the tail bound, which is what it is here for.
        record("metadata: relocated in the tail survives the consumed-bytes bound",
               escalatedRelocatedPath.map { ClaudeSessionHistory.cwd(atPath: $0) } == "/tmp/probe/escalated-wt",
               "got \(escalatedRelocatedPath.flatMap { ClaudeSessionHistory.cwd(atPath: $0) } ?? "nil")")
        record("metadata: exact chunk-multiple keeps its unterminated last record",
               exactMultiplePath.map { ClaudeSessionHistory.title(atPath: $0) } == "EXACT MULTIPLE",
               "got \(exactMultiplePath.map { ClaudeSessionHistory.title(atPath: $0) } ?? "nil")")
        record("metadata: array content joins into the title",
               arrayContentPath.map { ClaudeSessionHistory.title(atPath: $0) } == "first block second block",
               "got \(arrayContentPath.map { ClaudeSessionHistory.title(atPath: $0) } ?? "nil")")

        // MARK: - Session selection budget (the sidebar's shrinking list)
        //
        // `loadAllSessions` used to `prefix(50)` the candidates and only then
        // drop the automated ones, so every dropped file cost a row: measured
        // 2026-09-03, the newest 50 files held 41 `sdk-*` sessions and the
        // sidebar showed 9. These pin the budget as rows KEPT, which is the
        // single property that fix turns on — reinstate the `prefix` and the
        // first assertion goes red on its own.
        //
        // Synthetic predicate on purpose: `evaluate` in production reads a
        // JSONL header, and a fixture tree big enough to exercise a ceiling of
        // 400 would be the slowest thing in this probe by an order of
        // magnitude. The numbers below are the selector's own inputs, not
        // copies of the production caps, so there is nothing here to drift.
        let selectorInput = Array(0..<100)
        let everyFifth: (Int) -> String? = { $0 % 5 == 0 ? "keep-\($0)" : nil }

        let budgeted = ClaudeSessionHistory.selectNewest(
            selectorInput, keep: 10, scanLimit: 1000, evaluate: everyFifth
        )
        // 46, not 50: the tenth survivor is at index 45 and the walk stops on
        // it rather than finishing the block of five. A `prefix(keep)` ahead
        // of the filter reads 10 and keeps 2, so the two numbers together are
        // what separate the fix from the bug.
        record("selection: the budget counts rows kept, not files read",
               budgeted.kept.count == 10 && budgeted.scanned == 46,
               "kept=\(budgeted.kept.count) scanned=\(budgeted.scanned)")
        record("selection: survivors keep candidate order",
               budgeted.kept.first == "keep-0" && budgeted.kept.last == "keep-45",
               "first=\(budgeted.kept.first ?? "nil") last=\(budgeted.kept.last ?? "nil")")

        let ceilinged = ClaudeSessionHistory.selectNewest(
            selectorInput, keep: 10, scanLimit: 20, evaluate: everyFifth
        )
        record("selection: the scan ceiling stops a poor survival ratio",
               ceilinged.kept.count == 4 && ceilinged.scanned == 20,
               "kept=\(ceilinged.kept.count) scanned=\(ceilinged.scanned)")

        // The other half of "stop on kept": stopping late is as wrong as
        // stopping early, and only this catches a selector that always runs
        // to its ceiling.
        let allAccepted = ClaudeSessionHistory.selectNewest(
            selectorInput, keep: 10, scanLimit: 1000, evaluate: { "keep-\($0)" }
        )
        record("selection: nothing is read past the keep target",
               allAccepted.kept.count == 10 && allAccepted.scanned == 10,
               "kept=\(allAccepted.kept.count) scanned=\(allAccepted.scanned)")

        let exhausted = ClaudeSessionHistory.selectNewest(
            Array(0..<3), keep: 10, scanLimit: 1000, evaluate: { "keep-\($0)" }
        )
        record("selection: running out of candidates is not hitting a limit",
               exhausted.kept.count == 3 && exhausted.scanned == 3,
               "kept=\(exhausted.kept.count) scanned=\(exhausted.scanned)")

        let zeroKeep = ClaudeSessionHistory.selectNewest(
            selectorInput, keep: 0, scanLimit: 1000, evaluate: everyFifth
        )
        record("selection: a zero keep target evaluates nothing",
               zeroKeep.kept.isEmpty && zeroKeep.scanned == 0,
               "kept=\(zeroKeep.kept.count) scanned=\(zeroKeep.scanned)")

        // A ceiling at or below the keep target makes the target unreachable,
        // and the failure is the silent short list this whole block exists
        // for. Read from the constants so it pins the relationship itself.
        record("selection: the production scan ceiling clears the keep target",
               ClaudeSessionHistory.maxSessionsToScan > ClaudeSessionHistory.maxSessionsToKeep,
               "scan=\(ClaudeSessionHistory.maxSessionsToScan) keep=\(ClaudeSessionHistory.maxSessionsToKeep)")

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
        //
        // Both fixtures open with a `type:"user"` record, so the line scan never
        // escalates — but they reach `tailStart == headSize` by different terms
        // of the `max(...)`, and only the first one reaches it via the scan.
        // Measured: `boundaryJSONL` consumes 131,072 bytes so both terms tie,
        // while `midlineJSONL`'s head region ends mid-`x`-run, leaving
        // `consumed == 84` — there `fileSize - tailSize` alone puts the window
        // at the head size. Both still test what their names say; resize either
        // and the mid-line one stops testing anything. Read `metadataHeadSize`
        // rather than a copy so the offsets follow the constant if it moves.
        let headSize = ClaudeSessionHistory.metadataHeadSize
        let tailSize = 32_768
        let boundaryFirst =
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"},\"cwd\":\"/tmp/probe/main\"}\n"
        let boundaryRelocated =
            "{\"type\":\"relocated\",\"sessionId\":\"probe\",\"relocatedCwd\":\"/tmp/probe/boundary-wt\"}\n"
        let headPadCount = headSize - boundaryFirst.utf8.count - 1
        record("metadata fixture: boundary first line fits inside the head chunk",
               headPadCount > 0, "pad=\(headPadCount)")
        let zPadCount = max(0, tailSize - boundaryRelocated.utf8.count)
        let boundaryJSONL =
            boundaryFirst
            + String(repeating: "x", count: max(0, headPadCount)) + "\n"
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
        record("metadata fixture: midline first line fits inside the head chunk",
               midlineHeadPad > 0, "pad=\(midlineHeadPad)")
        let midlineTailBody = midlineFragment + "\n" + midlineRelocated
        let midlineTailPad = max(0, tailSize - midlineTailBody.utf8.count)
        let midlineJSONL =
            midlineFirst
            + String(repeating: "x", count: max(0, midlineHeadPad))
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

        // The whole-line rule the offset advance rests on. A scan may only
        // move a pending id's offset past bytes that form complete lines: an
        // idle tick reads while the CLI is mid-append, and consuming half a
        // `<tool-use-id>` tag would advance past a marker no later scan can
        // ever re-read — a permanently stuck hourglass, silent. The matching
        // half is deliberately NOT clamped (the marker is self-delimiting, so
        // `readJSONLFromOffset` returns every byte it read as `text`).
        func line(_ s: String) -> Data { Data(s.utf8) }
        record("whole-line prefix: newline-terminated → all of it",
               ShimProcess.wholeLinePrefixLength(line("a\nbb\n")) == 5)
        record("whole-line prefix: partial trailing line → up to last newline",
               ShimProcess.wholeLinePrefixLength(line("a\nbb\npart")) == 5)
        record("whole-line prefix: no newline at all → consume nothing",
               ShimProcess.wholeLinePrefixLength(line("no terminator here")) == 0)
        record("whole-line prefix: empty → consume nothing",
               ShimProcess.wholeLinePrefixLength(Data()) == 0)
        record("whole-line prefix: a lone newline counts",
               ShimProcess.wholeLinePrefixLength(line("\n")) == 1)
        // A `Data` slice keeps its parent's indices, so a length computed by
        // subtracting from 0 instead of from `startIndex` over-counts by the
        // slice's origin — which would advance the offset past unread bytes.
        record("whole-line prefix: slice indices don't leak into the length",
               ShimProcess.wholeLinePrefixLength(line("XXXXa\nbb\npart").dropFirst(4)) == 5)

        // The scanned-byte count exists only to fill a log line, but it is
        // an unsigned subtraction whose operands genuinely invert when a read
        // restarts at 0 past a truncated file — so the unguarded version is a
        // crash raised BY logging. Both directions pinned.
        record("scanned bytes: normal case is the difference",
               ShimProcess.scannedByteCount(end: 1500, from: 500) == 1000)
        record("scanned bytes: inverted operands don't trap, count from 0",
               ShimProcess.scannedByteCount(end: 300, from: 5_000_000) == 300)

        // The contract the two halves only have TOGETHER: a marker that a
        // scan does not match must still be matchable by a later scan that
        // starts where this one stopped advancing. This is issue #132's bug
        // expressed as an assertion — a torn marker, then the rest of the
        // line arriving.
        let tornHead = "{\"a\":1}\n{\"content\":\"<tool-use-id>toolu_TORN</tool-u"
        let tornTail = "se-id></task-notification>\"}\n"
        record("torn marker: not matched while only half the tag has landed",
               !ShimProcess.jsonlTailHasCompletion(tail: tornHead, taskId: "toolu_TORN"))
        // 8 = the first line only. The advance stops before the torn line, so
        // the next scan re-reads it and sees the tag whole. The resume slice
        // is taken in BYTES, not Characters: `wholeLinePrefixLength` returns
        // a byte count, and slicing the `String` instead would agree only
        // while the fixture stays ASCII — the same byte/Character conflation
        // `readJSONLFromOffset` avoids by never routing offsets through
        // `String.utf8.count`.
        let resumeAt = ShimProcess.wholeLinePrefixLength(line(tornHead))
        let resumed = String(decoding: line(tornHead).dropFirst(resumeAt), as: UTF8.self) + tornTail
        record("torn marker: found by the next scan, because the advance stopped short",
               resumeAt == 8 && ShimProcess.jsonlTailHasCompletion(tail: resumed, taskId: "toolu_TORN"))

        // Issue #132's idle backstop re-runs the same reconcile on a timer
        // while a session sits idle with a pending bg task. Its whole safety
        // rests on the bulk-clear fallbacks staying wake-only: a session
        // whose JSONL we can't read (SSH remote — the log lives on the other
        // machine) would otherwise have its hourglass wiped ~15 s after every
        // launch, i.e. the "waiting" state would stop existing there.
        record("bg reconcile: wake may bulk-clear",
               ShimProcess.BackgroundReconcileTrigger.wake.allowsBulkClear)
        record("bg reconcile: idle backstop must NOT bulk-clear",
               !ShimProcess.BackgroundReconcileTrigger.idleBackstop.allowsBulkClear)
        // Literals, not just inequality: SWAPPING the two labels keeps them
        // distinct and passes an inequality check, while making every `[bg]`
        // line in the unified log attribute a clear to the wrong path — the
        // exact reading that diagnosed issue #132.
        record("bg reconcile: wake logs under \"wake\"",
               ShimProcess.BackgroundReconcileTrigger.wake.logLabel == "wake")
        record("bg reconcile: idle backstop logs under \"idle\"",
               ShimProcess.BackgroundReconcileTrigger.idleBackstop.logLabel == "idle")

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

        // jsonlPath: the empty-id guard needs no filesystem setup. The second
        // assertion no longer pins only the encoded-folder miss — since the
        // scan fallback landed it means "neither encoding NOR any project
        // folder holds this id", which is why the id has to be one that
        // cannot exist rather than merely one this cwd doesn't own.
        record("jsonlPath: empty sessionId → nil",
               ShimProcess.jsonlPath(sessionId: "", workingDirectory: URL(fileURLWithPath: "/tmp/probe")) == nil)
        // The id has to be minted, not typed: it is now checked against every
        // folder on the developer's real disk, and a hand-made fixture could
        // plausibly carry the old all-`a` literal.
        record("jsonlPath: an id present under no project folder at all → nil",
               ShimProcess.jsonlPath(
                   sessionId: UUID().uuidString,
                   workingDirectory: URL(fileURLWithPath: "/definitely/not/here-xyz")
               ) == nil)

        // Relocation: `EnterWorktree` moves the CLI's cwd mid-session and the
        // CLI moves the whole transcript with it, while `workingDirectory`
        // stays frozen at spawn. Nothing on the wire reports it — the
        // measurement lives on `ClaudeSessionHistory.scanForTranscript` and is
        // deliberately not restated here, because the first draft of this
        // comment restated it and got it wrong in the same commit that wrote
        // it, by restating it as "`system/init` is emitted once" — which
        // contradicts this repo's own record of the `/model` switch. The
        // corrected claim lives on `scanForTranscript`; a fourth copy here is
        // how the third one went wrong.
        //
        // **What this block does NOT pin: either CALL SITE.** The two VCS
        // refreshes in `ShimProcess` — one in `init`, one in the `result`
        // branch — are the whole user-visible feature, and reverting either
        // to `detectVCSInfo(at: workingDirectory)` leaves every assertion
        // here green, measured. Both need a live shim, so they were verified
        // on device instead, against a planted launch-restore snapshot for a
        // session that had already entered a worktree: the fixed build
        // rendered `tmp-reloc-probe · worktree-reloc-check` in the pane
        // header, the sidebar row and the status-bar pill, and the reverted
        // one rendered `tmp-reloc-probe · main` in all three. Read the
        // assertions below as pinning the PARTS, never the wiring.
        //
        // `relocatedWorkingDirectory` takes the path as a parameter and reads
        // only the parent's NAME about the path's LOCATION (it reads the
        // file's contents too), so a fixture folder anywhere exercises it —
        // no writing into the real `~/.claude/projects` for any of them. (No count
        // here on purpose: it has gone stale twice already.)
        let relocFrozen = URL(fileURLWithPath: "/tmp/probe/reloc-root")
        let relocEncoded = ClaudeSessionHistory.encodedFolderCandidates(for: relocFrozen.path)[0]
        let relocMovedJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/reloc-root"}
        {"type":"relocated","sessionId":"probe","relocatedCwd":"/tmp/probe/reloc-root/.claude/worktrees/wt"}
        """
        // Folder name == this cwd's own encoding: the session has NOT moved,
        // and the guard must answer that before opening anything. The fixture
        // deliberately CONTAINS a relocation record, so a missing guard
        // returns the worktree instead of nil — without the record the
        // cwd-equality guard below would yield nil anyway, and the assertion
        // would pass with or without the guard it is here to pin.
        if let samePath = writeProbeJSONL(relocMovedJSONL, inFolderNamed: relocEncoded) {
            record("relocate: a transcript in this cwd's own encoded folder reports no move",
                   ShimProcess.relocatedWorkingDirectory(
                       jsonlPath: samePath, workingDirectory: relocFrozen
                   ) == nil)
        }
        // Foreign folder: the file is now the authority on where the session is.
        // The folder is named by the ACTUAL encoding of the relocated cwd,
        // which is the shape a real relocation leaves behind — a literal like
        // "some-other-encoded-folder" reaches the same answer through
        // `resolveProjectPath`'s raw fallback instead of its agreement branch,
        // so it asserted the right result off the wrong path. Note this still
        // does not DISTINGUISH those branches: both return the extracted cwd.
        let relocMovedFolder = ClaudeSessionHistory.encodedFolderCandidates(
            for: "/tmp/probe/reloc-root/.claude/worktrees/wt"
        )[0]
        if let movedPath = writeProbeJSONL(relocMovedJSONL, inFolderNamed: relocMovedFolder) {
            record("relocate: a transcript in a foreign folder yields the relocated cwd",
                   ShimProcess.relocatedWorkingDirectory(
                       jsonlPath: movedPath, workingDirectory: relocFrozen
                   )?.path == "/tmp/probe/reloc-root/.claude/worktrees/wt")
        }
        // A foreign folder is evidence of a move, not proof of one — the two
        // encodings are not exhaustive of every folder the CLI has ever
        // written. When the file's own answer matches the frozen directory,
        // that is the answer, and reporting a move here would re-run
        // `detectVCSInfo` against the directory it already had.
        let relocSameCwdJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/reloc-root"}
        """
        if let sameCwdPath = writeProbeJSONL(relocSameCwdJSONL, inFolderNamed: "another-foreign-folder") {
            record("relocate: a foreign folder whose cwd still matches reports no move",
                   ShimProcess.relocatedWorkingDirectory(
                       jsonlPath: sameCwdPath, workingDirectory: relocFrozen
                   ) == nil)
        }
        // No `relocated` record at all: the plain `cwd` field still decides.
        // Described by its INPUT, because no real producer of this state has
        // been identified — a transcript in a foreign folder whose header
        // names a third directory, where neither the folder nor the frozen dir
        // is that directory. It is specifically NOT the scrolled-past-the-tail
        // relocation: a moved transcript's header is never rewritten, so it
        // names the SPAWN directory and this branch would report no move. That
        // case is reconciled by `resolveProjectPath` — see
        // `relocatedWorkingDirectory`. (Genuine encoding drift is not it
        // either: there the header and the frozen dir name the same
        // directory, so the equality guard answers first.)
        let relocPlainCwdJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/elsewhere"}
        """
        if let plainPath = writeProbeJSONL(relocPlainCwdJSONL, inFolderNamed: "third-foreign-folder") {
            record("relocate: with no relocated record the cwd field still answers",
                   ShimProcess.relocatedWorkingDirectory(
                       jsonlPath: plainPath, workingDirectory: relocFrozen
                   )?.path == "/tmp/probe/elsewhere")
        }
        // Unreadable file → nil, so a transient read failure leaves the label
        // on the frozen directory rather than blanking the branch.
        record("relocate: an unreadable transcript reports no move",
               ShimProcess.relocatedWorkingDirectory(
                   jsonlPath: "/tmp/canopy-probe-does-not-exist-9f3a/x.jsonl",
                   workingDirectory: relocFrozen
               ) == nil)

        // The middle gap: the transcript sits in a foreign folder but its own
        // cwd still names the SPAWN directory, because the `relocated` record
        // scrolled past `extractMetadata`'s tail window and the header is
        // never rewritten. Trusting the file here reported "no move" for
        // roughly one turn in ten on real transcripts. The folder must name a
        // directory that EXISTS, since that is the condition on which
        // `resolveProjectPath` prefers it.
        let gapReal = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanopyProbeGap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: gapReal, withIntermediateDirectories: true)
        let gapFolder = ClaudeSessionHistory.encodedFolderCandidates(for: gapReal.path)[0]
        let gapJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/probe/reloc-root"}
        """
        if let gapPath = writeProbeJSONL(gapJSONL, inFolderNamed: gapFolder) {
            record("relocate: a stale cwd loses to the folder the transcript actually lives in",
                   ShimProcess.relocatedWorkingDirectory(
                       jsonlPath: gapPath, workingDirectory: relocFrozen
                   )?.path == gapReal.standardizedFileURL.resolvingSymlinksInPath().path,
                   "folder \(gapFolder) decodes to an existing directory")
        }
        try? FileManager.default.removeItem(at: gapReal)

        // A cwd that differs only by a symlink is the SAME directory, and
        // saying otherwise costs a header read and a git subprocess every
        // turn forever. Not hypothetical — `~/Documents/repos` is a symlink to
        // `~/repos` here and both spellings exist as project folders.
        let linkTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanopyProbeLinkTarget-\(UUID().uuidString)")
        let linkAlias = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanopyProbeLinkAlias-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: linkTarget, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: linkAlias, withDestinationURL: linkTarget)
        let aliasJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"\(linkAlias.path)"}
        """
        if let aliasPath = writeProbeJSONL(aliasJSONL, inFolderNamed: "symlink-foreign-folder") {
            record("relocate: a cwd spelled through a symlink is not a move",
                   ShimProcess.relocatedWorkingDirectory(
                       jsonlPath: aliasPath, workingDirectory: linkTarget
                   ) == nil)
        }
        // The MIRROR of that, which is the direction the real case runs: the
        // frozen directory is the alias spelling (it comes from
        // `OpenSession.origin`, i.e. a directory picker or a restore snapshot)
        // while the transcript names the target. Only the `moved` side was
        // pinned before, so dropping the resolve from the `frozen` side left
        // the suite green while reporting a move on every turn.
        let targetJSONL = """
        {"type":"user","message":{"role":"user","content":"hello"},"cwd":"\(linkTarget.path)"}
        """
        if let targetPath = writeProbeJSONL(targetJSONL, inFolderNamed: "symlink-mirror-folder") {
            record("relocate: a FROZEN dir spelled through a symlink is not a move either",
                   ShimProcess.relocatedWorkingDirectory(
                       jsonlPath: targetPath, workingDirectory: linkAlias
                   ) == nil)
        }
        try? FileManager.default.removeItem(at: linkAlias)
        try? FileManager.default.removeItem(at: linkTarget)
        // Every `inFolderNamed:` fixture above sits under one root, so this
        // one call is the whole cleanup.
        try? FileManager.default.removeItem(at: probeFolderFixtureRoot)

        // The composition both VCS refreshes run. Neither call site is
        // reachable from here — see the note at the top of this block — but
        // everything AROUND the `detectVCSInfo` hand-off is, and it is where
        // the remote gate lives. A local transcript carrying a remote
        // session's id would otherwise name a local directory for a session
        // running on another machine.
        let vcsFrozen = URL(fileURLWithPath: "/tmp/probe/vcs-frozen")
        let vcsMoved = URL(fileURLWithPath: "/tmp/probe/vcs-moved")
        record("vcs dir: a remote session never leaves the frozen directory",
               ShimProcess.effectiveVCSDirectory(
                   sessionId: "sid", isLocal: false, workingDirectory: vcsFrozen,
                   lookup: { _, _ in "/tmp/probe/found.jsonl" }, relocated: { _, _ in vcsMoved }
               ) == vcsFrozen)
        record("vcs dir: no session id yet leaves the frozen directory",
               ShimProcess.effectiveVCSDirectory(
                   sessionId: nil, isLocal: true, workingDirectory: vcsFrozen,
                   lookup: { _, _ in "/tmp/probe/found.jsonl" }, relocated: { _, _ in vcsMoved }
               ) == vcsFrozen)
        record("vcs dir: an empty session id leaves the frozen directory",
               ShimProcess.effectiveVCSDirectory(
                   sessionId: "", isLocal: true, workingDirectory: vcsFrozen,
                   lookup: { _, _ in "/tmp/probe/found.jsonl" }, relocated: { _, _ in vcsMoved }
               ) == vcsFrozen)
        record("vcs dir: an unresolvable transcript leaves the frozen directory",
               ShimProcess.effectiveVCSDirectory(
                   sessionId: "sid", isLocal: true, workingDirectory: vcsFrozen,
                   lookup: { _, _ in nil }, relocated: { _, _ in vcsMoved }
               ) == vcsFrozen)
        record("vcs dir: a session that did not move leaves the frozen directory",
               ShimProcess.effectiveVCSDirectory(
                   sessionId: "sid", isLocal: true, workingDirectory: vcsFrozen,
                   lookup: { _, _ in "/tmp/probe/found.jsonl" }, relocated: { _, _ in nil }
               ) == vcsFrozen)
        record("vcs dir: a relocated session reads from where it moved to",
               ShimProcess.effectiveVCSDirectory(
                   sessionId: "sid", isLocal: true, workingDirectory: vcsFrozen,
                   lookup: { _, _ in "/tmp/probe/found.jsonl" }, relocated: { _, _ in vcsMoved }
               ) == vcsMoved)
        // The per-turn overload skips the lookup entirely, because that site
        // has already resolved and cached the path on the main actor.
        record("vcs dir: the path-taking form follows a move without a lookup",
               ShimProcess.effectiveVCSDirectory(
                   jsonlPath: "/tmp/probe/found.jsonl", workingDirectory: vcsFrozen,
                   relocated: { _, _ in vcsMoved }
               ) == vcsMoved)
        record("vcs dir: the path-taking form with no path stays frozen",
               ShimProcess.effectiveVCSDirectory(
                   jsonlPath: nil, workingDirectory: vcsFrozen,
                   relocated: { _, _ in vcsMoved }
               ) == vcsFrozen)

        // The resolved-path cache. Its existence check is the whole
        // invalidation strategy and deleting it reintroduces this feature's
        // own bug — the reconcile scanning a path the relocation moved away,
        // permanently, because a resolvable-but-dead path never reaches the
        // wake-path bulk clear.
        typealias JSONLCache = ShimProcess.ResolvedJSONLCache
        record("jsonl cache: nothing remembered → resolve",
               JSONLCache.decide(cached: nil, sessionId: "a", exists: { _ in true }) == .resolve)
        record("jsonl cache: a live remembered path is reused",
               JSONLCache.decide(cached: ("a", "/p.jsonl"), sessionId: "a", exists: { _ in true })
                   == .reuse("/p.jsonl"))
        record("jsonl cache: a path that has moved away is re-resolved",
               JSONLCache.decide(cached: ("a", "/p.jsonl"), sessionId: "a", exists: { _ in false })
                   == .resolve)
        record("jsonl cache: a different session id is never reused",
               JSONLCache.decide(cached: ("a", "/p.jsonl"), sessionId: "b", exists: { _ in true })
                   == .resolve)

        // Legacy folder encoding: every other fixture that reaches
        // `encodedFolderCandidates` uses paths with no `.` and no space, so `strict == legacy` and the two-candidate
        // branch never runs. Since the scan landed, losing that branch stops
        // being a miss and becomes a silent full directory scan on the main
        // actor for every session in a legacy-encoded folder.
        let legacyDir = URL(fileURLWithPath: "/tmp/probe/my.repo-\(UUID().uuidString)")
        let legacyCandidates = ClaudeSessionHistory.encodedFolderCandidates(for: legacyDir.path)
        record("encoding: a path with a dot yields BOTH candidates",
               legacyCandidates.count == 2, "got \(legacyCandidates)")
        let legacyId = UUID().uuidString
        let legacyProjectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(legacyCandidates.count == 2 ? legacyCandidates[1] : "unused")
        try? FileManager.default.createDirectory(at: legacyProjectDir, withIntermediateDirectories: true)
        let legacyTranscript = legacyProjectDir.appendingPathComponent("\(legacyId).jsonl")
        try? Data("{}\n".utf8).write(to: legacyTranscript)
        // A decoy under a foreign folder, written SECOND so it is newer. The
        // scan resolves to the newest copy, so only a lookup that actually
        // consults the legacy candidate can return the legacy path — without
        // the decoy the scan rescues the answer and the assertion passes with
        // the candidate branch deleted.
        let legacyDecoyDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent("-canopy-probe-legacy-decoy-\(legacyId)")
        try? FileManager.default.createDirectory(at: legacyDecoyDir, withIntermediateDirectories: true)
        let legacyDecoy = legacyDecoyDir.appendingPathComponent("\(legacyId).jsonl")
        try? Data("{}\n".utf8).write(to: legacyDecoy)
        record("jsonlPath: the LEGACY encoding is consulted before the scan",
               ShimProcess.jsonlPath(sessionId: legacyId, workingDirectory: legacyDir)
                   == legacyTranscript.path,
               "legacy folder \(legacyProjectDir.lastPathComponent), newer decoy present")
        try? FileManager.default.removeItem(at: legacyDecoy)
        try? FileManager.default.removeItem(at: legacyDecoyDir)
        try? FileManager.default.removeItem(at: legacyTranscript)
        try? FileManager.default.removeItem(at: legacyProjectDir)

        // The empty-id guards mask each other, so neither is pinned by the
        // `jsonlPath` assertion near the top of this block. Pin the inner one
        // directly; the outer one stays unpinned and unremarked, because
        // deleting it changes no answer while the inner guard stands.
        record("scanForTranscript: an empty session id → nil",
               ClaudeSessionHistory.scanForTranscript(sessionId: "") == nil)

        // The relocation scan must not run for a session whose transcript is
        // on another machine. Not merely wasted work: a teleported session, or
        // one that used to run locally, leaves a LOCAL transcript under the
        // same id, and without the gate a remote session would seed its titles
        // and its message count from that copy.
        let remoteId = UUID().uuidString
        let remoteFrozen = URL(fileURLWithPath: "/tmp/probe/remote-\(remoteId)")
        let remoteProjectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent("-canopy-probe-remote-\(remoteId)")
        try? FileManager.default.createDirectory(at: remoteProjectDir, withIntermediateDirectories: true)
        let remoteTranscript = remoteProjectDir.appendingPathComponent("\(remoteId).jsonl")
        let remoteFixture = """
        {"type":"user","message":{"role":"user","content":"local leftovers"}}
        {"type":"assistant","message":{"role":"assistant","content":"ok"}}
        """
        try? Data(remoteFixture.utf8).write(to: remoteTranscript)
        record("relocate: a remote session does not seed titles from a local transcript",
               ClaudeSessionHistory.loadUserPrompts(
                   sessionId: remoteId, directory: remoteFrozen, allowRelocationScan: false
               ).isEmpty)
        record("relocate: a remote session does not count a local transcript",
               ClaudeSessionHistory.countMessages(
                   sessionId: remoteId, directory: remoteFrozen, allowRelocationScan: false
               ) == 0)
        // …and the same fixture DOES resolve with the scan allowed, so the two
        // above cannot be passing merely because the fixture is unreadable.
        record("relocate: the same fixture resolves with the scan allowed",
               ClaudeSessionHistory.countMessages(
                   sessionId: remoteId, directory: remoteFrozen, allowRelocationScan: true
               ) == 2)
        try? FileManager.default.removeItem(at: remoteTranscript)
        try? FileManager.default.removeItem(at: remoteProjectDir)

        // The scan half needs the real `~/.claude/projects`, because
        // `ClaudeSessionHistory.scanForTranscript` resolves against the
        // hardcoded `claudeDir`. Same pattern the
        // restore block uses: write into a project folder that is NOT either
        // encoding of the working directory, which is exactly what a
        // relocation leaves behind.
        let scanId = UUID().uuidString
        let scanFrozen = URL(fileURLWithPath: "/tmp/probe/scan-root-\(scanId)")
        let scanProjectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent("-canopy-probe-relocated-\(scanId)")
        record("jsonlPath: before the fixture exists the id resolves nowhere",
               ShimProcess.jsonlPath(sessionId: scanId, workingDirectory: scanFrozen) == nil)
        try? FileManager.default.createDirectory(at: scanProjectDir, withIntermediateDirectories: true)
        let scanTranscript = scanProjectDir.appendingPathComponent("\(scanId).jsonl")
        try? Data("{}\n".utf8).write(to: scanTranscript)
        record("jsonlPath: a transcript under a foreign project folder is found by the scan",
               ShimProcess.jsonlPath(sessionId: scanId, workingDirectory: scanFrozen) == scanTranscript.path,
               "no encoding of \(scanFrozen.path) names that folder")
        try? FileManager.default.removeItem(at: scanTranscript)
        record("jsonlPath: removing it makes the id unresolvable again",
               ShimProcess.jsonlPath(sessionId: scanId, workingDirectory: scanFrozen) == nil)

        // Precedence: the encoded stat is the PRIMARY lookup and the scan is
        // the fallback, never the other way round. Inverting the two leaves
        // every other assertion green while turning each lookup into a
        // directory listing plus a stat per folder on the main actor — so
        // plant the same id under BOTH the encoded folder for this working
        // directory and a foreign one, and assert which path comes back.
        // Written second so the foreign folder is the NEWER file, which is
        // what makes an INVERTED-PRECEDENCE scan fail deterministically rather
        // than by luck: newest-mtime would return the foreign copy every time.
        // (It says nothing about a first-hit-wins scan, whose answer depends
        // on enumeration order — that one is pinned by the pair below.)
        let encodedProjectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(ClaudeSessionHistory.encodedFolderCandidates(for: scanFrozen.path)[0])
        try? FileManager.default.createDirectory(at: encodedProjectDir, withIntermediateDirectories: true)
        let encodedTranscript = encodedProjectDir.appendingPathComponent("\(scanId).jsonl")
        try? Data("{}\n".utf8).write(to: encodedTranscript)
        try? Data("{}\n".utf8).write(to: scanTranscript)
        record("jsonlPath: the encoded folder wins over the scan",
               ShimProcess.jsonlPath(sessionId: scanId, workingDirectory: scanFrozen) == encodedTranscript.path)
        try? FileManager.default.removeItem(at: encodedTranscript)
        try? FileManager.default.removeItem(at: encodedProjectDir)

        // Two folders holding one id: newest mtime wins, so a stale stub can
        // never outrank the live transcript. Measured on this machine as a
        // state that actually occurs — see `scanForTranscript`.
        let staleProjectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent("-canopy-probe-stale-\(scanId)")
        try? FileManager.default.createDirectory(at: staleProjectDir, withIntermediateDirectories: true)
        let staleTranscript = staleProjectDir.appendingPathComponent("\(scanId).jsonl")
        try? Data("{}\n".utf8).write(to: staleTranscript)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: staleTranscript.path
        )
        record("scanForTranscript: the newest of two copies wins",
               ClaudeSessionHistory.scanForTranscript(sessionId: scanId) == scanTranscript.path,
               "the more recently written copy wins; stale copy at \(staleProjectDir.lastPathComponent)")
        // And the other way round, so the assertion above cannot be passing on
        // whatever order the filesystem happened to enumerate.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: scanTranscript.path
        )
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: staleTranscript.path
        )
        record("scanForTranscript: reversing which copy is newest reverses the winner",
               ClaudeSessionHistory.scanForTranscript(sessionId: scanId) == staleTranscript.path)

        // Equal mtimes are reachable — two copies written in the same second,
        // or two whose attributes cannot be read — and without a second key
        // they fall back to `contentsOfDirectory` order, which is the
        // nondeterminism the tiebreak exists to remove. Assert the total order
        // by naming the winner rather than by repeating the call, since
        // `contentsOfDirectory` is stable within a process and a repetition
        // test would pass under first-enumerated-wins too.
        //
        // **It still does not pin the path key.** Measured: deleting `path`
        // from `(modified, path) > (best!.modified, best!.path)` leaves the
        // whole suite green, because on this machine the enumeration order
        // happens to agree with path order for these two folders — and nothing
        // here can make it disagree, since `contentsOfDirectory`'s order is
        // not ours to choose. What this assertion pins is that equal mtimes
        // resolve to ONE named file at all; the second key survives its own
        // mutation, recorded here so the green does not read as coverage.
        let sameStamp = Date(timeIntervalSince1970: 1_000_000)
        for path in [scanTranscript.path, staleTranscript.path] {
            try? FileManager.default.setAttributes([.modificationDate: sameStamp], ofItemAtPath: path)
        }
        record("scanForTranscript: equal mtimes break on the path, not on enumeration order",
               ClaudeSessionHistory.scanForTranscript(sessionId: scanId)
                   == max(scanTranscript.path, staleTranscript.path),
               "expected the greater path of the two equal-mtime copies")

        // A dangling symlink is NOT a transcript. `attributesOfItem` succeeds
        // on one where `fileExists` returns false and `FileHandle` cannot open
        // it, so a stat-only scan would return a path that resolves but never
        // reads — resolvable, and therefore never reaching the reconcile's
        // bulk-clear escape hatch.
        try? FileManager.default.removeItem(at: staleTranscript)
        try? FileManager.default.createSymbolicLink(
            at: staleTranscript, withDestinationURL: staleProjectDir.appendingPathComponent("gone.jsonl")
        )
        record("scanForTranscript: a dangling symlink is not a transcript",
               ClaudeSessionHistory.scanForTranscript(sessionId: scanId) == scanTranscript.path,
               "dangling link sits in \(staleProjectDir.lastPathComponent)")
        try? FileManager.default.removeItem(at: staleTranscript)
        try? FileManager.default.removeItem(at: staleProjectDir)

        // The other two lookups that resolve independently of `jsonlPath`.
        // Both were left on the encoded-only path in the first revision while
        // three comments claimed the title generator had been recovered, so
        // these assert the fallback at the two call sites rather than at the
        // shared helper.
        try? Data("""
        {"type":"user","message":{"role":"user","content":"the first prompt"}}
        {"type":"assistant","message":{"role":"assistant","content":"ok"}}
        """.utf8).write(to: scanTranscript)
        record("relocate: title-generation prompts survive the move",
               ClaudeSessionHistory.loadUserPrompts(
                   sessionId: scanId, directory: scanFrozen
               ) == ["the first prompt"],
               "got \(ClaudeSessionHistory.loadUserPrompts(sessionId: scanId, directory: scanFrozen))")
        record("relocate: the message count survives the move",
               ClaudeSessionHistory.countMessages(sessionId: scanId, directory: scanFrozen) == 2)

        try? FileManager.default.removeItem(at: scanTranscript)
        try? FileManager.default.removeItem(at: scanProjectDir)

        // Roster wire encoding. The six activity states are a contract with the
        // phone: renaming a case silently changes what the roster renders, and
        // nothing else in this repo would notice.
        record("roster: every activity state has a distinct wire name",
               Set(SessionActivity.allCases.map(RosterSnapshot.wireState(for:))).count
                   == SessionActivity.allCases.count)
        // Every case pinned by exact value, not two of them: the phone reads
        // these strings, so renaming `idle`/`working`/`unread`/`error` used to
        // pass this block while silently breaking the wire. Found by review
        // on PR #177 — the uniqueness assertion above cannot catch a rename,
        // because a rename keeps them unique.
        let expectedWireNames: [(SessionActivity, String)] = [
            (.empty, "empty"), (.idle, "idle"), (.working, "working"),
            (.background, "background"), (.asking, "asking"),
            (.unread, "unread"), (.error, "error"),
        ]
        record("roster: every wire name is pinned to its exact string",
               expectedWireNames.allSatisfy { RosterSnapshot.wireState(for: $0.0) == $0.1 })
        record("roster: the pinned list covers every activity case",
               expectedWireNames.count == SessionActivity.allCases.count)

        // A launcher pane has no session, so it must not produce a row — the phone
        // would render a nameless entry it can never act on.
        let rosterPanes = [
            PaneSlot(content: .launcher, preferredWidth: 100),
            PaneSlot(content: .session(UUID()), preferredWidth: 100),
        ]
        record("roster: a launcher pane yields no row",
               RosterSnapshot.paneIndexes(in: rosterPanes).count == 1)
        record("roster: the index is the pane's position, not the row's",
               RosterSnapshot.paneIndexes(in: rosterPanes).first?.value == 1)

        // JSON round-trip: the phone decodes this, so a key rename is a break.
        let rosterFixture = RosterSnapshot(
            machineId: "AAAA-1111", displayName: "Mac Studio",
            publishedAt: 1_700_000_000, sessionPct: 43, weeklyPct: 25,
            panes: [RosterSnapshot.Pane(
                sessionId: "s1", paneIndex: 0, title: "T", project: "P · main",
                state: "asking", stateSince: 1_699_999_000,
                contextPct: 17, model: "opus", messageCount: 42)])
        let rosterJSON = (try? JSONEncoder().encode(rosterFixture)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        record("roster: JSON carries the keys the phone reads",
               rosterJSON.contains("\"machineId\"") && rosterJSON.contains("\"stateSince\"")
                   && rosterJSON.contains("\"paneIndex\""),
               "got \(rosterJSON.prefix(120))")
        record("roster: JSON round-trips",
               (try? JSONDecoder().decode(
                   RosterSnapshot.self, from: Data(rosterJSON.utf8)))?.panes.first?.state == "asking")

        // The display name falls back rather than going blank: an empty Settings
        // field must not publish an unnamed Mac to a roster whose whole job is
        // telling two Macs apart.
        record("machine: a set display name wins",
               MachineIdentity.resolvedDisplayName(setting: "Studio", fallback: "host") == "Studio")
        record("machine: an empty setting falls back",
               MachineIdentity.resolvedDisplayName(setting: "", fallback: "host") == "host")
        record("machine: a whitespace-only setting falls back",
               MachineIdentity.resolvedDisplayName(setting: "   ", fallback: "host") == "host")
        record("machine: a set name is trimmed",
               MachineIdentity.resolvedDisplayName(setting: "  Studio  ", fallback: "host") == "Studio")
        // The id is what getByName keys on. A blank one would collide every Mac
        // into one Durable Object.
        //
        // If present, it is a 36-character UUID. Presence itself is NOT asserted:
        // CI runs on a GitHub `macos-26` VM and whether that exposes
        // IOPlatformExpertDevice was never measured, so asserting presence would
        // turn CI red on a property of the runner rather than of the code. The nil
        // case is handled by the publisher's own guard, which is where it matters.
        record("machine: a stable id, if present, is a 36-character UUID",
               MachineIdentity.stableId().map { $0.count == 36 } ?? true)

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

        // VCS-reported branch wins over the folder-name guess when present.
        // Fixture folder "feature-foo" vs branch "feature/foo" — the slash
        // flatten that `git worktree add -b` does — so a match is not
        // accidental equality of the two strings.
        let managedFeatureFoo = GitWorktree.worktreesRoot
            .appendingPathComponent("Canopy/feature-foo")
        record("projectDisplayName: no branch keeps folder guess",
               GitWorktree.projectDisplayName(for: managedFeatureFoo) == "Canopy · feature-foo")
        record("projectDisplayName: non-empty branch wins over folder",
               GitWorktree.projectDisplayName(for: managedFeatureFoo, branch: "feature/foo")
                   == "Canopy · feature/foo"
                   && GitWorktree.projectDisplayName(for: managedFeatureFoo, branch: "feature/foo")
                       != "Canopy · feature-foo")
        record("projectDisplayName: empty-string branch falls back to guess",
               GitWorktree.projectDisplayName(for: managedFeatureFoo, branch: "")
                   == "Canopy · feature-foo")
        record("projectDisplayName: branch on plain repo → folder · branch",
               GitWorktree.projectDisplayName(
                   for: URL(fileURLWithPath: "/repos/Canopy"), branch: "main")
                   == "Canopy · main")
        record("repoName: managed worktree → repo, not folder",
               GitWorktree.repoName(for: managedFeatureFoo) == "Canopy")
        record("repoName: plain dir → folder name",
               GitWorktree.repoName(for: URL(fileURLWithPath: "/repos/Canopy")) == "Canopy")

        // jj reports "<bookmark> (modified)"; only the bookmark belongs in a
        // row subtitle. Found on screen, not by the probe — the whole suite was
        // green while the sidebar read "Canopy · main (modified)".
        record("branchNameOnly: strips jj's (modified)",
               GitWorktree.branchNameOnly("main (modified)") == "main")
        record("branchNameOnly: strips jj's (empty)",
               GitWorktree.branchNameOnly("main (empty)") == "main")
        record("branchNameOnly: a plain branch is untouched",
               GitWorktree.branchNameOnly("feature/foo") == "feature/foo")
        record("branchNameOnly: parens that are not the suffix survive",
               GitWorktree.branchNameOnly("fix (wip) thing") == "fix (wip) thing")
        record("projectDisplayName: a jj status suffix never reaches the label",
               GitWorktree.projectDisplayName(
                   for: URL(fileURLWithPath: "/repos/Canopy"), branch: "main (modified)")
                   == "Canopy · main")

        // A teleported session's `project` was chosen by the teleport — the
        // cloud repo's "owner/name" when the local cwd was too ambiguous to
        // name the work — so recomputing it from that same cwd throws away the
        // label and returns the folder name it was picked to avoid.
        record("projectLabel: a teleported session keeps its chosen label",
               {
                   let s = OpenSession(
                       origin: .teleportedFrom(cloudSessionId: "cloud-1",
                                               localPath: URL(fileURLWithPath: "/tmp/ambiguous")),
                       resumeId: "tp", title: "t", project: "owner/name", status: .live)
                   s.statusBar.gitBranch = "main"
                   return s.projectLabel == "owner/name"
               }())

        // The filter and grouping key must NOT pick up the branch: appending it
        // to `SidebarRow.project` splits one repository into a bucket and a
        // picker entry per branch. A first revision of this feature did exactly
        // that, and the eight project-filter assertions below caught it.
        record("SidebarRow.project stays branch-free; displayProject carries it",
               {
                   let s = OpenSession(
                       origin: .local(GitWorktree.worktreesRoot
                           .appendingPathComponent("Canopy/feature-foo")),
                       resumeId: "row-label", title: "t", project: "Canopy", status: .live)
                   s.statusBar.gitBranch = "feature/foo"
                   let row = SidebarRow.open(s)
                   return row.project == "Canopy"
                       && row.displayProject == "Canopy · feature/foo"
               }())

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
        // Pure mapping: the visible (filtered) open rows after a move are
        // written back into the master array; hidden rows keep their slots.
        // These used to exercise `reorderPreservingHidden`, which took
        // `.onMove` offsets — that function is gone, because a drag over the
        // Open section now yields offsets in a list that also holds launcher
        // rows, so the caller strips them and hands the session order in.
        record("reorder: full visible, move first to end",
               SessionStore.applyVisibleOrder(
                   master: ["A", "B", "C"], visible: ["A", "B", "C"],
                   newVisible: ["B", "C", "A"])
                   == ["B", "C", "A"])
        record("reorder: full visible, move last to front",
               SessionStore.applyVisibleOrder(
                   master: ["A", "B", "C"], visible: ["A", "B", "C"],
                   newVisible: ["C", "A", "B"])
                   == ["C", "A", "B"])
        record("reorder: hidden interior rows keep their slots",
               SessionStore.applyVisibleOrder(
                   master: ["A", "h1", "B", "h2", "C"], visible: ["A", "B", "C"],
                   newVisible: ["C", "A", "B"])
                   == ["C", "h1", "A", "h2", "B"])
        record("reorder: no-op move returns master unchanged",
               SessionStore.applyVisibleOrder(
                   master: ["A", "h1", "B"], visible: ["A", "B"],
                   newVisible: ["A", "B"])
                   == ["A", "h1", "B"])
        // The guard the doc promises: a caller handing back a different SET
        // would silently drop or duplicate rows. Set equality alone is
        // multiset-blind, so the duplicate case pins the count check too.
        record("reorder: a non-permutation is refused, not written back",
               SessionStore.applyVisibleOrder(
                   master: ["A", "h1", "B"], visible: ["A", "B"],
                   newVisible: ["A", "C"])
                   == ["A", "h1", "B"]
               && SessionStore.applyVisibleOrder(
                   master: ["A", "h1", "B"], visible: ["A", "B"],
                   newVisible: ["A", "A", "B"])
                   == ["A", "h1", "B"])

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

        // An async Agent launched WITHOUT the `run_in_background` key — now
        // the default shape — arrives as a foreground row, so its ack would
        // finish it the instant it starts. The ack promotes the row instead.
        var noKeyTracker = SubagentTracker()
        _ = noKeyTracker.observe([
            "type": "assistant",
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": "toolu_NOKEY", "name": "Agent",
                "input": ["description": "review", "subagent_type": "general-purpose"],
            ]] as [[String: Any]]] as [String: Any],
        ], now: t0)
        record("subagent: an Agent with no run_in_background key starts foreground",
               noKeyTracker.rows.count == 1 && !noKeyTracker.rows[0].runInBackground)
        _ = noKeyTracker.observe([
            "type": "user",
            "message": ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "toolu_NOKEY",
                "content": "Async agent launched successfully.\nagentId: a1234567890abcdef (internal ID)",
            ]] as [[String: Any]]] as [String: Any],
        ], now: t0)
        record("subagent: the async ack promotes that row instead of finishing it",
               noKeyTracker.rows.count == 1
                   && noKeyTracker.rows[0].runInBackground
                   && noKeyTracker.rows[0].isRunning,
               "bg=\(noKeyTracker.rows.first?.runInBackground ?? false) running=\(noKeyTracker.rows.first?.isRunning ?? false)")
        // A foreground Agent's real result must still finish its row — the
        // promotion must not have widened into "any tool_result keeps a row
        // alive", which would hang every foreground row forever.
        var fgTracker = SubagentTracker()
        _ = fgTracker.observe([
            "type": "assistant",
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": "toolu_FG", "name": "Agent",
                "input": ["description": "review", "subagent_type": "general-purpose"],
            ]] as [[String: Any]]] as [String: Any],
        ], now: t0)
        _ = fgTracker.observe([
            "type": "user",
            "message": ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "toolu_FG",
                "content": "Here is the report you asked for.",
            ]] as [[String: Any]]] as [String: Any],
        ], now: t0)
        record("subagent: a foreground Agent's result still finishes its row",
               fgTracker.rows.count == 1 && !fgTracker.rows[0].isRunning)
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

        // The OTHER ack wording: an async `Agent` never says "Command
        // running in background", so the Bash-only prefix silently returned
        // nil for the background Agents it was asked about and killed their
        // TaskStop purge path (issue #132). Both current forms are pinned —
        // the one carrying the "internal metadata" clause and the legacy
        // bare one — because `agentId: ` is the only shared token sitting
        // immediately before the id. Named by SHAPE, not by CLI version:
        // the version that introduced the clause is 2.1.199 (issue #132 says
        // 2.1.226, which is only the version it was filed from), and a name
        // like `agentAck2_1_226` bakes a number that goes stale into an
        // assertion nobody will re-measure. Fixtures are the leading portion
        // of live acks — verbatim through the sentence after `agentId:`,
        // with the notification / output-file tail elided as irrelevant to
        // the scan — real ids included. Full rationale, including what the
        // version numbers actually measure, lives on
        // `ShimProcess.extractLaunchAckTaskId`.
        let agentAckWithMetadataClause =
            "Async agent launched successfully. (This tool result is internal metadata — never quote or paste any part of it, including the agentId below, into a user-facing reply.)\nagentId: a43f5f7881f8bf5de (internal ID - do not mention to user. Use SendMessage with to: 'a43f5f7881f8bf5de', summary: '<5-10 word recap>' to continue this agent.)\nThe agent is working in the background."
        let agentAckLegacy =
            "Async agent launched successfully.\nagentId: a525c96205f572784 (internal ID - do not mention to user. Use SendMessage with to: 'a525c96205f572784' to continue this agent.)\nThe agent is working in the background."
        record("bg lifecycle: async Agent ack (metadata-clause wording) → agentId",
               ShimProcess.extractLaunchAckTaskId(agentAckWithMetadataClause) == "a43f5f7881f8bf5de",
               "got=\(ShimProcess.extractLaunchAckTaskId(agentAckWithMetadataClause) ?? "nil")")
        record("bg lifecycle: async Agent ack (legacy wording) → agentId",
               ShimProcess.extractLaunchAckTaskId(agentAckLegacy) == "a525c96205f572784",
               "got=\(ShimProcess.extractLaunchAckTaskId(agentAckLegacy) ?? "nil")")
        record("bg lifecycle: agentId prefix-only → nil",
               ShimProcess.extractLaunchAckTaskId("agentId: ") == nil)
        // A launch that omits `run_in_background` is not necessarily
        // foreground, so the ack closes a gap `isBackgroundLaunchBlock`
        // cannot. The NEGATIVE assertions are the ones that matter: "no key"
        // has meant foreground far more often than background, and the ack
        // sentence also shows up as ordinary tool output. Counts, dates and
        // the reasoning live on `ShimProcess.isAsyncAgentLaunchAck` — not
        // copied here, because two copies of a measurement is how they end up
        // disagreeing (this comment already did, in its first draft: it said
        // "sessions" where the other said "launches").
        record("async ack: metadata-clause wording recognised",
               ShimProcess.isAsyncAgentLaunchAck(agentAckWithMetadataClause))
        record("async ack: legacy wording recognised",
               ShimProcess.isAsyncAgentLaunchAck(agentAckLegacy))
        record("async ack: a foreground Agent's result is NOT an async ack",
               !ShimProcess.isAsyncAgentLaunchAck("Here is the analysis you asked for."))
        record("async ack: a Bash bg ack is NOT an async-Agent ack",
               !ShimProcess.isAsyncAgentLaunchAck(launchAck))
        record("async ack: empty → no",
               !ShimProcess.isAsyncAgentLaunchAck(""))
        // Prefix, not substring: a foreground agent quoting the sentence in
        // its own report must not register a phantom background task.
        record("async ack: the phrase quoted mid-text does not count",
               !ShimProcess.isAsyncAgentLaunchAck(
                   "The log said \"Async agent launched successfully\" at that point."))
        // …but a prefix match is NOT sufficient on its own, and this is the
        // case that proves it: a `Bash` tool_result whose grep output begins
        // at column zero with the sentence. Three of these exist in local
        // logs — from searching these very JSONLs — and the ack text alone
        // would pend a `toolu_…` that no completion marker can ever clear.
        // The registration path's real defence is requiring a matching
        // `SubagentTracker` row, which only an Agent/Task launch creates;
        // this assertion pins that the predicate alone does NOT decide.
        let bashGrepOutput =
            "Async agent launched successfully. (This tool result is internal metadata — never quote"
        record("async ack: a Bash grep echoing the sentence is rejected (no agentId line)",
               !ShimProcess.isAsyncAgentLaunchAck(bashGrepOutput))
        // The case the Agent-row corroboration cannot catch, because the row
        // is real: a FOREGROUND agent whose report opens with the sentence
        // (an agent asked to analyse this ack — routine in this repo). Only
        // the required `agentId:` line separates it from a launch.
        record("async ack: a foreground Agent's report opening with the sentence is rejected",
               !ShimProcess.isAsyncAgentLaunchAck("""
               Async agent launched successfully is the string Canopy keys on. \
               I checked every occurrence and none of them appear outside a \
               tool_result, so the detector looks sound.
               """))
        var bashTracker = SubagentTracker()
        _ = bashTracker.observe([
            "type": "assistant",
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": "toolu_BASHGREP", "name": "Bash",
                "input": ["command": "grep -r 'Async agent launched successfully' ."],
            ]] as [[String: Any]]] as [String: Any],
        ], now: t0)
        record("async ack: …and a Bash tool_use makes no subagent row to corroborate it",
               bashTracker.rows.isEmpty)
        // The launch-side predicate keeps its meaning: an explicit false is
        // still foreground, and the absent key is still not enough on its own.
        record("async ack: absent run_in_background key is still not a launch signal",
               !ShimProcess.isBackgroundLaunchBlock([
                   "type": "tool_use", "id": "toolu_nokey", "name": "Agent",
                   "input": ["prompt": "…", "subagent_type": "general-purpose"],
               ]))

        // Precedence is a decision, not an accident: both scanners match
        // their prefix ANYWHERE in the text, so a text carrying both must
        // resolve to the Bash id. Flipping the `??` operands keeps every
        // other assertion green.
        record("bg lifecycle: Bash ack wins when a text carries both prefixes",
               ShimProcess.extractLaunchAckTaskId(
                   "Command running in background with ID: bbbbbbbbb. …\nagentId: a1111111111111111"
               ) == "bbbbbbbbb")
        // The captured id has to come back out of the stop ack unchanged —
        // that round trip is the whole point of capturing it, since the only
        // consumer is `purgePendingByTaskId`'s reverse lookup. Asserted as an
        // actual round trip (launch ack in, stop ack out, same id) rather
        // than as two independent parser checks that never meet: `a`-shaped
        // agent ids do flow through the stop path (measured in live JSONLs).
        // `launchedId != nil` is load-bearing: two nils compare equal, so
        // without it a parser that stopped matching anything at all would
        // pass this assertion instead of failing it.
        let launchedId = ShimProcess.extractLaunchAckTaskId(agentAckWithMetadataClause)
        record("bg lifecycle: agent id round-trips launch ack → stop ack",
               launchedId != nil
                   && launchedId == ShimProcess.extractStoppedTaskId("Successfully stopped task: a43f5f7881f8bf5de"),
               "launch=\(launchedId ?? "nil")")

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

        // MARK: - Context meter (issue #106)
        do {
            // Why these numbers: see `StatusBarData.compactionWindow`, which
            // owns the rationale for tracking the CLI meter's compact level
            // instead of the CC extension's pie. 923,000 is not arbitrary —
            // it is exactly the extension's old denominator (1M − 64K − 13K),
            // i.e. the point where the meter used to pin at 100%.
            let opus = StatusBarData()
            opus.contextMax = 1_000_000
            opus.maxOutputTokens = 64_000
            opus.contextUsed = 923_000
            record("context #106: 1M/64K window is 967,000 (CLI meter's compact level)",
                   opus.compactionWindow == 967_000,
                   "window=\(opus.compactionWindow)")
            record("context #106: old 100% point now reads 95%",
                   opus.contextPct == 95, "pct=\(opus.contextPct)")

            // One token above the cap must still reserve exactly the cap.
            // Pre-fix this gave 966,999, so it is the only case that catches
            // the cap being dropped or applied to the wrong side. A fixture at
            // exactly 20,000 is deliberately omitted: against `min` it is
            // indistinguishable from any `>` / `>=` spelling, so it could
            // never go red.
            let justOverCap = StatusBarData()
            justOverCap.contextMax = 1_000_000
            justOverCap.maxOutputTokens = 20_001
            record("context #106: 20,001 still reserves exactly 20,000",
                   justOverCap.compactionWindow == 967_000,
                   "window=\(justOverCap.compactionWindow)")

            // A model whose output budget is already under the cap keeps the
            // full subtraction — min() is a no-op there.
            let small = StatusBarData()
            small.contextMax = 200_000
            small.maxOutputTokens = 8_000
            record("context #106: sub-cap maxOutputTokens subtracted verbatim",
                   small.compactionWindow == 179_000,
                   "window=\(small.compactionWindow)")
            // The refusal line must use the SAME capped reserve. Swapping
            // `outputReserve` for the bare cap inside `blockedThreshold` is
            // invisible to every over-cap fixture — that would reintroduce
            // #106's exact bug shape (subtracting more reserve than the CLI
            // does) in the new threshold.
            record("context #110: sub-cap reserve is subtracted verbatim from the refusal line too",
                   small.blockedThreshold == 189_000,
                   "blocked=\(String(describing: small.blockedThreshold))")

            // Reachable in production: `contextMax` and `maxOutputTokens`
            // restore from two independent UserDefaults keys under separate
            // `> 0` guards, and the maxOutputTokens key is the newer of the
            // two — a cache written by an older build yields this state until
            // the first `result` lands.
            let noReserve = StatusBarData()
            noReserve.contextMax = 1_000_000
            noReserve.maxOutputTokens = 0
            record("context #106: zero maxOutputTokens reserves nothing",
                   noReserve.compactionWindow == 987_000,
                   "window=\(noReserve.compactionWindow)")
            // …but the THRESHOLDS must refuse to guess in that state. A 20,000
            // error in the denominator is ~2% and tolerable; the same error in
            // a refusal line printed as an absolute token count is not.
            record("context #110: zero maxOutputTokens yields no trustworthy level",
                   noReserve.contextLevel == .unknown && noReserve.blockedThreshold == nil,
                   "level=\(noReserve.contextLevel) blocked=\(String(describing: noReserve.blockedThreshold))")

            // Pre-`result` state (contextMax still 0) must not produce a
            // negative or nonsensical denominator. Split from the pct check so
            // a failure names which half broke.
            let empty = StatusBarData()
            record("context #106: unpopulated data yields zero window",
                   empty.compactionWindow == 0, "window=\(empty.compactionWindow)")
            record("context #106: unpopulated data yields 0%",
                   empty.contextPct == 0, "pct=\(empty.contextPct)")

            // The `effective > 0 ? effective : contextMax` fallback with a
            // POPULATED contextMax — the branch that returns a denominator
            // wider than the real budget. The `empty` case above can't pin it:
            // there the fallback's answer (0) is identical to the arithmetic
            // path's. Pins that a negative denominator never escapes into
            // `contextUsed * 100 / window`.
            let tiny = StatusBarData()
            tiny.contextMax = 10_000
            tiny.maxOutputTokens = 8_000
            tiny.contextUsed = 5_000
            record("context #106: non-positive window falls back to contextMax",
                   tiny.compactionWindow == 10_000, "window=\(tiny.compactionWindow)")
            record("context #106: fallback window still yields a sane pct",
                   tiny.contextPct == 50, "pct=\(tiny.contextPct)")

            // Separate instances rather than one reassigned fixture: inserting
            // a case into a shared-and-mutated block silently changes every
            // assertion after it.
            let belowLine = StatusBarData()
            belowLine.contextMax = 1_000_000
            belowLine.maxOutputTokens = 64_000
            belowLine.contextUsed = 966_999
            record("context #106: one token below the line is 99%",
                   belowLine.contextPct == 99, "pct=\(belowLine.contextPct)")

            let atLine = StatusBarData()
            atLine.contextMax = 1_000_000
            atLine.maxOutputTokens = 64_000
            atLine.contextUsed = 967_000
            record("context #106: exactly at the compact level is 100%",
                   atLine.contextPct == 100, "pct=\(atLine.contextPct)")

            // #110 flipped this: contextPct is deliberately unclamped now, so
            // the whole actionable band past the compact level is legible
            // instead of a flat 100%. `StatusBarView.thinBar` routes its fill
            // through `barFillWidth`, so the capsule can't overrun its track.
            let pastLine = StatusBarData()
            pastLine.contextMax = 1_000_000
            pastLine.maxOutputTokens = 64_000
            pastLine.contextUsed = 1_000_000
            record("context #110: past the level keeps counting, unclamped",
                   pastLine.contextPct == 103, "pct=\(pastLine.contextPct)")

            // Levels (issue #110). For 1M/64K the three lines sit at
            // warn 947,000 / compact 967,000 / blocked 977,000. Note blocked
            // is 10,000 ABOVE compact, not below — the CLI's refusal guard
            // subtracts 3,000 from the budget WITHOUT the 13,000 compaction
            // buffer, a different base. Boundaries are asserted on both sides
            // so an off-by-one in either direction goes red.
            func level(_ used: Int, max: Int = 1_000_000, out: Int = 64_000) -> StatusBarData.ContextLevel {
                let d = StatusBarData()
                d.contextMax = max
                d.maxOutputTokens = out
                d.contextUsed = used
                return d.contextLevel
            }
            record("context #110: below the warn line is ok",
                   level(946_999) == .ok, "got=\(level(946_999))")
            record("context #110: at the warn line is warn",
                   level(947_000) == .warn, "got=\(level(947_000))")
            record("context #110: one below compact is still warn",
                   level(966_999) == .warn, "got=\(level(966_999))")
            record("context #110: at the compact level is compact",
                   level(967_000) == .compact, "got=\(level(967_000))")
            record("context #110: one below blocked is still compact",
                   level(976_999) == .compact, "got=\(level(976_999))")
            record("context #110: at the refusal line is blocked",
                   level(977_000) == .blocked, "got=\(level(977_000))")

            // A second window class. Every case above shares 1M/64K, where
            // `outputReserve` is the capped branch; 200K/8K exercises the
            // verbatim branch through the level ladder, and is the config
            // where the compact→blocked band is actually several points wide.
            record("context #110: 200K/8K reaches compact at its own line",
                   level(179_000, max: 200_000, out: 8_000) == .compact,
                   "got=\(level(179_000, max: 200_000, out: 8_000))")
            record("context #110: 200K/8K reaches blocked at its own line",
                   level(189_000, max: 200_000, out: 8_000) == .blocked,
                   "got=\(level(189_000, max: 200_000, out: 8_000))")

            let blockedAt = StatusBarData()
            blockedAt.contextMax = 1_000_000
            blockedAt.maxOutputTokens = 64_000
            record("context #110: refusal threshold is 977,000, i.e. 10,000 above compact",
                   blockedAt.blockedThreshold == 977_000
                       && (blockedAt.blockedThreshold ?? 0) - blockedAt.compactionWindow == 10_000,
                   "blocked=\(String(describing: blockedAt.blockedThreshold)) compact=\(blockedAt.compactionWindow)")

            // With no trustworthy threshold the level must be `.unknown`, not
            // `.ok` — the two render differently (`StatusBarView` falls back to
            // the raw-percentage heuristic for `.unknown`) and mean different
            // things. Without the guard `tiny`'s refusal line would compute to
            // -1,000 and its 5,000 used tokens would mis-fire as `.blocked`.
            record("context #110: fallback window reports unknown, not ok",
                   tiny.contextLevel == .unknown && tiny.blockedThreshold == nil,
                   "level=\(tiny.contextLevel) blocked=\(String(describing: tiny.blockedThreshold))")
            record("context #110: unpopulated data reports unknown, not ok",
                   empty.contextLevel == .unknown && empty.blockedThreshold == nil,
                   "level=\(empty.contextLevel) blocked=\(String(describing: empty.blockedThreshold))")

            // Exactly at the fallback boundary. Nothing else makes the compact
            // arithmetic land on 0, so a `> 0` → `>= 0` slip would otherwise
            // survive — in either of its two shapes: flipped only in the level
            // gate it desynchronises that gate from `compactionWindow` and
            // puts the refusal line below the compact line (10,000 vs 33,000);
            // flipped in both it makes the compact level 0.
            let atFallbackEdge = StatusBarData()
            atFallbackEdge.contextMax = 33_000
            atFallbackEdge.maxOutputTokens = 20_000
            atFallbackEdge.contextUsed = 5_000
            record("context #110: exactly-zero derived window is still the fallback",
                   atFallbackEdge.blockedThreshold == nil
                       && atFallbackEdge.contextLevel == .unknown
                       && atFallbackEdge.compactionWindow == 33_000,
                   "blocked=\(String(describing: atFallbackEdge.blockedThreshold)) window=\(atFallbackEdge.compactionWindow)")

            // A window too narrow for the 20,000 warn offset has no warn band.
            // Claiming `.ok` there would be calm all the way to 99% of the
            // compact level, so it reports `.unknown` and lets the percentage
            // heuristic carry the signal. `warnAtZero` sits exactly ON that
            // boundary (window 20,000, warn line 0) — nothing else pins the
            // guard's `>` against `>=`.
            let warnAtZero = StatusBarData()
            warnAtZero.contextMax = 53_000
            warnAtZero.maxOutputTokens = 20_000
            record("context #110: a zero warn line is not a warn band",
                   warnAtZero.contextLevel == .unknown,
                   "got=\(warnAtZero.contextLevel) window=\(warnAtZero.compactionWindow)")

            // Separate instances, per the convention stated above.
            let narrowIdle = StatusBarData()
            narrowIdle.contextMax = 50_000
            narrowIdle.maxOutputTokens = 20_000
            narrowIdle.contextUsed = 0
            record("context #110: sub-warn-offset window reports unknown, not ok",
                   narrowIdle.contextLevel == .unknown,
                   "got=\(narrowIdle.contextLevel) window=\(narrowIdle.compactionWindow)")

            let narrowFull = StatusBarData()
            narrowFull.contextMax = 50_000
            narrowFull.maxOutputTokens = 20_000
            narrowFull.contextUsed = 27_000
            record("context #110: a narrow but derived window still reaches blocked",
                   narrowFull.contextLevel == .blocked, "got=\(narrowFull.contextLevel)")

            // The tint mapping. It lives on StatusBarData for the same reason
            // `barFillWidth` does — `StatusBarView.levelColor` is not
            // probe-reachable, and "`.unknown` at 150% must be ALERT, not
            // calm" is the entire reason `.unknown` exists. Collapsing that
            // case back to calm compiles and would otherwise stay green.
            record("context #110: unknown at a high percentage still alerts",
                   StatusBarData.tint(for: .unknown, pct: 150) == .alert,
                   "got=\(StatusBarData.tint(for: .unknown, pct: 150))")
            record("context #110: unknown just below the alert cutoff warns",
                   StatusBarData.tint(for: .unknown, pct: 79) == .warn,
                   "got=\(StatusBarData.tint(for: .unknown, pct: 79))")
            record("context #110: unknown below the warn cutoff is calm",
                   StatusBarData.tint(for: .unknown, pct: 49) == .calm,
                   "got=\(StatusBarData.tint(for: .unknown, pct: 49))")
            // The counterpart, and the actual regression assertion: a real
            // `.ok` stays calm no matter how high the percentage climbs, which
            // is exactly why `.unknown` must not be folded into it.
            record("context #110: ok stays calm at any percentage",
                   StatusBarData.tint(for: .ok, pct: 150) == .calm,
                   "got=\(StatusBarData.tint(for: .ok, pct: 150))")
            record("context #110: real levels ignore the percentage",
                   StatusBarData.tint(for: .warn, pct: 0) == .warn
                       && StatusBarData.tint(for: .compact, pct: 0) == .alert
                       && StatusBarData.tint(for: .blocked, pct: 0) == .alert,
                   "warn=\(StatusBarData.tint(for: .warn, pct: 0)) compact=\(StatusBarData.tint(for: .compact, pct: 0))")

            // The fill clamp. It lives on StatusBarData precisely so it is
            // reachable from here — `StatusBarView.thinBar` is not.
            record("context #110: fill clamps at the track width past 100%",
                   StatusBarData.barFillWidth(pct: 2_000_000, track: 40, minimum: 4) == 40,
                   "fill=\(StatusBarData.barFillWidth(pct: 2_000_000, track: 40, minimum: 4))")
            record("context #110: fill scales linearly below 100%",
                   StatusBarData.barFillWidth(pct: 50, track: 40, minimum: 4) == 20,
                   "fill=\(StatusBarData.barFillWidth(pct: 50, track: 40, minimum: 4))")
            record("context #110: a sliver of usage still draws the minimum",
                   StatusBarData.barFillWidth(pct: 1, track: 40, minimum: 4) == 4,
                   "fill=\(StatusBarData.barFillWidth(pct: 1, track: 40, minimum: 4))")
            record("context #110: zero usage draws nothing",
                   StatusBarData.barFillWidth(pct: 0, track: 40, minimum: 4) == 0,
                   "fill=\(StatusBarData.barFillWidth(pct: 0, track: 40, minimum: 4))")
            record("context #110: the minimum never overruns a narrower track",
                   StatusBarData.barFillWidth(pct: 1, track: 2, minimum: 4) == 2,
                   "fill=\(StatusBarData.barFillWidth(pct: 1, track: 2, minimum: 4))")

            // `extractStatusData` is a private instance method on a live
            // ShimProcess and isn't probe-reachable, so this locks the
            // predicate it gates on rather than the routing itself. The live
            // gate is the `assistant` branch; the `stream_event` branch is
            // deliberately ungated (see the comment there).
            record("context #106: main-turn message (null parent) accepted",
                   ShimProcess.isMainConversationMessage(["type": "assistant", "parent_tool_use_id": NSNull()]),
                   "got=\(ShimProcess.isMainConversationMessage(["type": "assistant", "parent_tool_use_id": NSNull()]))")
            record("context #106: absent parent_tool_use_id accepted",
                   ShimProcess.isMainConversationMessage(["type": "assistant"]),
                   "got=\(ShimProcess.isMainConversationMessage(["type": "assistant"]))")
            record("context #106: subagent-tagged message rejected",
                   !ShimProcess.isMainConversationMessage(["type": "assistant", "parent_tool_use_id": "toolu_A"]),
                   "got=\(ShimProcess.isMainConversationMessage(["type": "assistant", "parent_tool_use_id": "toolu_A"]))")

            // #108. These maps are `result.modelUsage` payloads from runs of
            // `claude -p --output-format stream-json --verbose
            // --include-partial-messages` against CLI 2.1.217, reduced to the
            // two fields `mainModelUsage` reads. Capture conditions are named
            // per map because they turned out to be load-bearing: the first
            // revision of this block came entirely from runs that passed
            // `--model`, which hid the default-configuration bug that
            // `defaultOpusMain` now pins.
            //
            // These cannot detect CLI drift, and no comment here should imply
            // they can: the maps are literals, so a CLI that renamed
            // `contextWindow` would break production while leaving every case
            // below green. Re-capture by hand when the `result` schema moves.

            // `--model haiku`, one Opus subagent. The #108 regression.
            let haikuMainOpusSubagent: [String: Any] = [
                "claude-haiku-4-5-20251001": ["contextWindow": 200_000, "maxOutputTokens": 32_000],
                "claude-opus-4-8[1m]": ["contextWindow": 1_000_000, "maxOutputTokens": 64_000],
            ]
            // `--model opus`, CLAUDE_CODE_DISABLE_1M_CONTEXT unset. Bare key,
            // 1M window — the suffix tracks the resolved tier, not the role.
            let opusMain: [String: Any] = [
                "claude-opus-4-8": ["contextWindow": 1_000_000, "maxOutputTokens": 64_000],
                "claude-haiku-4-5-20251001": ["contextWindow": 200_000, "maxOutputTokens": 32_000],
            ]
            // No `--model` at all — what Canopy's launcher sends by default.
            // Here `init.model` was `claude-opus-4-8[1m]` and matches, while
            // `message_start.model` was bare `claude-opus-4-8` and does not.
            // The launcher's explicit `opus[1m]` option produced the same
            // three strings, so this row covers two reachable selections.
            let defaultOpusMain: [String: Any] = [
                "claude-opus-4-8[1m]": ["contextWindow": 1_000_000, "maxOutputTokens": 64_000],
            ]

            // The regression itself: widest-wins returned 1,000,000 here.
            let narrowMain = ShimProcess.mainModelUsage(
                modelUsage: haikuMainOpusSubagent, mainModel: "claude-haiku-4-5-20251001"
            )
            record("context #108: a subagent's wider window is not adopted",
                   narrowMain?.contextWindow == 200_000 && narrowMain?.maxOutputTokens == 32_000,
                   "got=\(String(describing: narrowMain))")

            // The case widest-wins got right, which must keep working.
            let wideMain = ShimProcess.mainModelUsage(
                modelUsage: opusMain, mainModel: "claude-opus-4-8"
            )
            record("context #108: main model that IS the widest still resolves",
                   wideMain?.contextWindow == 1_000_000 && wideMain?.maxOutputTokens == 64_000,
                   "got=\(String(describing: wideMain))")

            // A miss must not degrade into the old heuristic. If this ever
            // starts returning the 1,000,000 entry, the fix has been undone.
            record("context #108: unknown main model yields nil, not the widest entry",
                   ShimProcess.mainModelUsage(
                       modelUsage: haikuMainOpusSubagent, mainModel: "claude-sonnet-5"
                   ) == nil,
                   "got=\(String(describing: ShimProcess.mainModelUsage(modelUsage: haikuMainOpusSubagent, mainModel: "claude-sonnet-5")))")

            // The default-configuration regression, both directions. With no
            // `--model`, `message_start.model` is bare and misses while
            // `init.model` carries `[1m]` and hits. Feeding the bare string
            // here reproduces exactly what the first revision of #108 shipped:
            // a permanent miss, so `contextMax` is never written — which
            // hides the meter outright on a directory with no cached pair,
            // and leaves a previous model's numbers standing on one that has.
            record("context #108: a bare model id does not match a [1m] key (the default-config miss)",
                   ShimProcess.mainModelUsage(
                       modelUsage: defaultOpusMain, mainModel: "claude-opus-4-8"
                   ) == nil,
                   "expected nil")
            let resolvedDefault = ShimProcess.mainModelUsage(
                modelUsage: defaultOpusMain, mainModel: "claude-opus-4-8[1m]"
            )
            record("context #108: the CLI's resolved [1m] id is what resolves",
                   resolvedDefault?.contextWindow == 1_000_000
                       && resolvedDefault?.maxOutputTokens == 64_000,
                   "got=\(String(describing: resolvedDefault))")

            // Before the first `system`/`init`, `cliResolvedModel` is "".
            record("context #108: empty main model yields nil",
                   ShimProcess.mainModelUsage(modelUsage: opusMain, mainModel: "") == nil,
                   "expected nil")

            record("context #108: entry without a usable contextWindow yields nil",
                   ShimProcess.mainModelUsage(
                       modelUsage: ["m": ["maxOutputTokens": 32_000]], mainModel: "m"
                   ) == nil
                       && ShimProcess.mainModelUsage(
                           modelUsage: ["m": ["contextWindow": 0]], mainModel: "m"
                       ) == nil,
                   "expected nil for both the missing and the zero case")

            // Mirrors the pre-#108 `?? 0`; `hasTrustedThresholds` is what
            // refuses to derive levels from the zero, not this function.
            record("context #108: missing maxOutputTokens degrades to 0, not to a nil result",
                   ShimProcess.mainModelUsage(
                       modelUsage: ["m": ["contextWindow": 200_000]], mainModel: "m"
                   )?.maxOutputTokens == 0,
                   "got=\(String(describing: ShimProcess.mainModelUsage(modelUsage: ["m": ["contextWindow": 200_000]], mainModel: "m")))")

            // The `.v2` infix is the whole of the cache migration, and it is
            // spelled independently in two functions, so this pins the
            // spelling. It does NOT pin the adjacent trap, which is worth
            // documenting anyway because there is nowhere better: the retired
            // v1 strings are still hardcoded at the restore site, so "DRY that
            // up" by swapping in these helpers would delete the v2 key the
            // line above just read. The restore has already happened by then
            // and every successful `result` rewrites the pair, so the damage
            // is bounded: any session ending before its first completed turn
            // leaves the next launch with no warm start. This case would stay
            // green through all of it.
            let probeDir = URL(fileURLWithPath: "/probe/dir")
            record("context #108: cache keys carry .v2, are distinct, and are not the retired keys",
                   ShimProcess.contextMaxKey(probeDir) == "statusBar.contextMax.v2./probe/dir"
                       && ShimProcess.maxOutputTokensKey(probeDir) == "statusBar.maxOutputTokens.v2./probe/dir",
                   "ctx=\(ShimProcess.contextMaxKey(probeDir)) out=\(ShimProcess.maxOutputTokensKey(probeDir))")
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

            // Cap. Derived from `paneAbsoluteCap`, never a literal: this
            // asserts that the boundary holds wherever it sits, and a
            // hardcoded count turns a deliberate cap change into two probe
            // failures that say nothing about the change.
            let store2 = SessionStore()
            let sessions = (0...SessionStore.paneAbsoluteCap).map { i in
                OpenSession(origin: .local(cwd), resumeId: "s\(i)", title: "s\(i)", project: "p", status: .live)
            }
            store2._probeSeedOpenSessions(sessions)
            for s in sessions.prefix(SessionStore.paneAbsoluteCap) { _ = store2.openInNewPane(s.id) }
            record("cap reached at paneAbsoluteCap",
                   store2.panes.count == SessionStore.paneAbsoluteCap,
                   "panes=\(store2.panes.count) cap=\(SessionStore.paneAbsoluteCap)")
            let overCap = store2.openInNewPane(sessions[SessionStore.paneAbsoluteCap].id)
            record("cap bounces the add past paneAbsoluteCap",
                   !overCap && store2.panes.count == SessionStore.paneAbsoluteCap,
                   "added=\(overCap) panes=\(store2.panes.count) cap=\(SessionStore.paneAbsoluteCap)")

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
            let launchSessions = (0..<SessionStore.paneAbsoluteCap).map { i in
                OpenSession(origin: .local(cwd), resumeId: "launch-cap-\(i)", title: "s\(i)", project: "p", status: .live)
            }
            storeLaunchCap._probeSeedOpenSessions(launchSessions)
            for s in launchSessions { _ = storeLaunchCap.openInNewPane(s.id) }
            let launchCapResult = storeLaunchCap.openLauncherInNewPane()
            record("openLauncherInNewPane at cap returns false",
                   !launchCapResult
                       && storeLaunchCap.panes.count == SessionStore.paneAbsoluteCap,
                   "added=\(launchCapResult) panes=\(storeLaunchCap.panes.count) "
                       + "cap=\(SessionStore.paneAbsoluteCap)")

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

            // MARK: Pane follows sidebar drag
            //
            // A drag moves panes by sorting the session panes into their rows'
            // order and re-anchoring every launcher the rows can describe. It
            // is not the only route that reorders panes — `openInNewPane`
            // sorts too.
            //
            // These are the first probe tests that read `visibleRows`, so they
            // are the first that a developer's own saved sidebar filter can
            // break: every `SessionStore()` loads it in its property
            // initializer, and a saved `status: .closedOnly` or a `project`
            // other than "p" empties `visibleRows` of session rows, making
            // `moveOpenRows` a silent no-op. That fails locally while passing on CI's clean
            // profile — indistinguishable from the stale-base diagnosis
            // CLAUDE.md describes. Neutralize the persisted value for the
            // whole block and put the real one back at the end.
            let savedFilter = SessionStorePersistence.loadFilter()
            SessionStorePersistence.saveFilter(SidebarFilter())
            // `defer`, not a statement at the end of the block: a trap or an
            // early exit partway through would otherwise leave the developer's
            // real sidebar filtered to whatever a case last persisted, with no
            // visible cause.
            defer { SessionStorePersistence.saveFilter(savedFilter) }

            // `filter`'s didSet persists globally, so every fixture that sets one
            // must put it back — otherwise it leaks into every `SessionStore()`
            // built after it, and the failure lands on an unrelated fixture
            // further down the block. (Measured: one `.closedOnly` fixture took
            // out four later ones.)
            func clearPersistedFilter() {
                SessionStorePersistence.saveFilter(SidebarFilter())
            }

            func dragSession(_ n: String) -> OpenSession {
                OpenSession(origin: .local(cwd), resumeId: "drag-\(n)", title: n, project: "p", status: .live)
            }

            // [A][B][C], drag C above B → [A][C][B]
            let dA = dragSession("A"), dB = dragSession("B"), dC = dragSession("C")
            let storeDrag = SessionStore()
            storeDrag._probeSeedOpenSessions([dA, dB, dC])
            _ = storeDrag.openInNewPane(dA.id)
            _ = storeDrag.openInNewPane(dB.id)
            _ = storeDrag.openInNewPane(dC.id)
            storeDrag.forceSetPaneWidth(at: 0, to: 300)
            storeDrag.forceSetPaneWidth(at: 1, to: 400)
            storeDrag.forceSetPaneWidth(at: 2, to: 500)
            let widthSumBefore = storeDrag.panes.reduce(0) { $0 + $1.preferredWidth }
            storeDrag.moveOpenRows(fromOffsets: IndexSet(integer: 2), toOffset: 1)
            record("drag reorders panes to follow sidebar",
                   storeDrag.panes.map(\.content)
                   == [.session(dA.id), .session(dC.id), .session(dB.id)])
            record("dragged pane carries its width with it",
                   storeDrag.panes[1].preferredWidth == 500
                   && storeDrag.panes[2].preferredWidth == 400)
            record("drag preserves pane count and total width",
                   storeDrag.panes.count == 3
                   && storeDrag.panes.reduce(0) { $0 + $1.preferredWidth } == widthSumBefore)
            record("focus follows the dragged session, not the slot index",
                   storeDrag.focusedPaneIndex == 1)

            // A(pane) B(no pane) C(pane); drag A below B.
            // Paned relative order is unchanged → panes must not move.
            let nA = dragSession("nA"), nB = dragSession("nB"), nC = dragSession("nC")
            let storeNoop = SessionStore()
            storeNoop._probeSeedOpenSessions([nA, nB, nC])
            _ = storeNoop.openInNewPane(nA.id)
            _ = storeNoop.openInNewPane(nC.id)
            storeNoop.moveOpenRows(fromOffsets: IndexSet(integer: 0), toOffset: 2)
            record("drag across an unpaned row leaves panes alone",
                   storeNoop.openSessions.map(\.id) == [nB.id, nA.id, nC.id]
                   && storeNoop.panes.map(\.content)
                   == [.session(nA.id), .session(nC.id)])

            // Dragging a row that has no pane at all.
            let uA = dragSession("uA"), uB = dragSession("uB"), uC = dragSession("uC")
            let storeUnpaned = SessionStore()
            storeUnpaned._probeSeedOpenSessions([uA, uB, uC])
            _ = storeUnpaned.openInNewPane(uA.id)
            _ = storeUnpaned.openInNewPane(uB.id)
            storeUnpaned.moveOpenRows(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            record("dragging an unpaned row never touches panes",
                   storeUnpaned.panes.map(\.content)
                   == [.session(uA.id), .session(uB.id)])

            // MARK: Launcher rows
            //
            // A launcher pane has a row of its own, so a launcher can no longer
            // be the reason a pane is missing from the Open block — a filter
            // still can, and four cases below turn on exactly that. Most of them
            // are one property: the rows and the panes stay the same sequence.

            func openRowIds(_ store: SessionStore) -> [String] {
                store.visibleRows.filter(\.isOpen).map(\.id)
            }

            // [A][launcher][B] renders three rows in that order.
            let iA = dragSession("iA"), iB = dragSession("iB")
            let storeRows = SessionStore()
            storeRows._probeSeedOpenSessions([iA, iB])
            _ = storeRows.openInNewPane(iA.id)
            _ = storeRows.openLauncherInNewPane()
            _ = storeRows.openInNewPane(iB.id)
            record("a launcher pane gets a row at its pane position",
                   openRowIds(storeRows) == [
                       SidebarRow.open(iA).id,
                       SidebarRow.launcher(storeRows.panes[1].id).id,
                       SidebarRow.open(iB).id,
                   ])

            // Leftmost launcher: nothing precedes it, so its row heads the list.
            let hdA = dragSession("hdA")
            let storeHead = SessionStore()
            storeHead._probeSeedOpenSessions([hdA])
            _ = storeHead.openLauncherInNewPane()
            _ = storeHead.openInNewPane(hdA.id)
            record("a leftmost launcher heads the open block",
                   openRowIds(storeHead) == [
                       SidebarRow.launcher(storeHead.panes[0].id).id,
                       SidebarRow.open(hdA).id,
                   ])

            // An open session with no pane sits in the list without occupying a
            // slot, so the launcher must be counted against PANED rows only.
            // The unpaned row is deliberately ABOVE the paned one: with it
            // below, counting every row and counting paned rows agree, and the
            // fixture pins nothing (measured — that arrangement survived the
            // mutation that counts every row).
            let upA = dragSession("upA"), upU = dragSession("upU")
            let storeUnpanedRow = SessionStore()
            storeUnpanedRow._probeSeedOpenSessions([upU, upA])
            _ = storeUnpanedRow.openInNewPane(upA.id)
            _ = storeUnpanedRow.openLauncherInNewPane()
            record("an unpaned row doesn't drift the launcher row",
                   openRowIds(storeUnpanedRow) == [
                       SidebarRow.open(upU).id,
                       SidebarRow.open(upA).id,
                       SidebarRow.launcher(storeUnpanedRow.panes[1].id).id,
                   ])

            // Two launchers behind the same session keep their pane order.
            let twA = dragSession("twA")
            let storeTwo = SessionStore()
            storeTwo._probeSeedOpenSessions([twA])
            _ = storeTwo.openInNewPane(twA.id)
            _ = storeTwo.openLauncherInNewPane()
            _ = storeTwo.openLauncherInNewPane()
            record("two launchers behind one session keep their order",
                   openRowIds(storeTwo) == [
                       SidebarRow.open(twA).id,
                       SidebarRow.launcher(storeTwo.panes[1].id).id,
                       SidebarRow.launcher(storeTwo.panes[2].id).id,
                   ])

            // The filter can hide the paned row a launcher sits behind. The
            // launcher is NOT filterable — it stands for a live pane — so it
            // must still be drawn, and it slides LEFT to where the strip says
            // it belongs rather than being pushed past the rows that are still
            // visible.
            let fvA = dragSession("fvA")
            let fvH = OpenSession(origin: .local(cwd), resumeId: "drag-fvH",
                                  title: "fvH", project: "hidden", status: .live)
            let storeFiltered = SessionStore()
            storeFiltered._probeSeedOpenSessions([fvH, fvA])
            _ = storeFiltered.openInNewPane(fvH.id)
            _ = storeFiltered.openLauncherInNewPane()
            storeFiltered.filter.project = "p"   // hides fvH
            record("a launcher survives its anchor row being filtered out",
                   openRowIds(storeFiltered) == [
                       SidebarRow.launcher(storeFiltered.panes[1].id).id,
                       SidebarRow.open(fvA).id,
                   ])
            clearPersistedFilter()

            // A launcher whose anchor pane has no visible row still belongs to
            // the OPEN block — dropping it in wherever the walk happened to end
            // would file it under a date/project heading with the recents. Uses
            // the pure function directly: `SessionStore.recents` is
            // `private(set)`, and a closed row is the whole point here.
            let closedNeighbour = SessionEntry(id: "closed-neighbour", title: "closed",
                                               timestamp: Date(), projectDirectory: cwd)
            let strandedLauncher = PaneSlot(content: .launcher, preferredWidth: 400)
            let interleaved = SessionStore.interleavingLaunchers(
                into: [SidebarRow.closedLocal(closedNeighbour)],
                panes: [PaneSlot(content: .session(UUID()), preferredWidth: 400), strandedLauncher]
            )
            record("a launcher never lands among the closed rows",
                   interleaved.map(\.id) == [
                       SidebarRow.launcher(strandedLauncher.id).id,
                       SidebarRow.closedLocal(closedNeighbour).id,
                   ])

            // [A][launcher][B]; drag B (row 2) above A. Index-pinning the
            // launcher renders [B][launcher][A] — self-consistent, but not the
            // order the user dropped. Rows are derived from the strip, so the
            // two can never visibly disagree; what pinning loses is the drop.
            let lA = dragSession("lA"), lB = dragSession("lB")
            let storeLaunch = SessionStore()
            storeLaunch._probeSeedOpenSessions([lA, lB])
            _ = storeLaunch.openInNewPane(lA.id)
            _ = storeLaunch.openLauncherInNewPane()
            _ = storeLaunch.openInNewPane(lB.id)
            storeLaunch.moveOpenRows(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            record("a session dragged past a launcher takes the launcher's row order with it",
                   storeLaunch.panes.map(\.content)
                   == [.session(lB.id), .session(lA.id), .launcher]
                   && openRowIds(storeLaunch) == [
                       SidebarRow.open(lB).id,
                       SidebarRow.open(lA).id,
                       SidebarRow.launcher(storeLaunch.panes[2].id).id,
                   ])

            // Dragging the launcher ROW moves its pane and nothing else.
            let dlA = dragSession("dlA"), dlB = dragSession("dlB")
            let storeDragLauncher = SessionStore()
            storeDragLauncher._probeSeedOpenSessions([dlA, dlB])
            _ = storeDragLauncher.openInNewPane(dlA.id)
            _ = storeDragLauncher.openLauncherInNewPane()
            _ = storeDragLauncher.openInNewPane(dlB.id)
            let draggedLauncherId = storeDragLauncher.panes[1].id
            storeDragLauncher.moveOpenRows(fromOffsets: IndexSet(integer: 1), toOffset: 0)
            record("dragging a launcher row moves its pane, leaving sessions alone",
                   storeDragLauncher.openSessions.map(\.id) == [dlA.id, dlB.id]
                   && storeDragLauncher.panes.map(\.content)
                   == [.launcher, .session(dlA.id), .session(dlB.id)]
                   && storeDragLauncher.panes[0].id == draggedLauncherId)

            // Dragging it to the far end, the direction that has no anchor to
            // fall back on if the walk ever stopped early.
            let dtA = dragSession("dtA"), dtB = dragSession("dtB")
            let storeDragTail = SessionStore()
            storeDragTail._probeSeedOpenSessions([dtA, dtB])
            _ = storeDragTail.openLauncherInNewPane()
            _ = storeDragTail.openInNewPane(dtA.id)
            _ = storeDragTail.openInNewPane(dtB.id)
            storeDragTail.setFocusedPaneIndex(0)   // the launcher
            storeDragTail.moveOpenRows(fromOffsets: IndexSet(integer: 0), toOffset: 3)
            record("a launcher row dragged to the end lands rightmost",
                   storeDragTail.panes.map(\.content)
                   == [.session(dtA.id), .session(dtB.id), .launcher])

            // Focus is held by SLOT, so moving the focused launcher's row must
            // carry the focus with it rather than hand it to whatever now sits
            // at its old index.
            record("dragging the focused launcher row carries its focus",
                   storeDragTail.focusedPaneIndex == 2
                   && storeDragTail.panes[storeDragTail.focusedPaneIndex].content == .launcher)

            // The round trip both directions have to satisfy: read the rows off
            // the panes, read the anchors back off those rows, and rebuilding
            // must reproduce the pane strip exactly. One configuration, not a
            // proof — the filtered cases below pin the direction that a count-
            // based interleave got wrong, and the property holds only because
            // both directions now speak in session ids.
            let rtA = dragSession("rtA"), rtB = dragSession("rtB"), rtC = dragSession("rtC")
            let storeRT = SessionStore()
            storeRT._probeSeedOpenSessions([rtA, rtB, rtC])
            _ = storeRT.openLauncherInNewPane()
            _ = storeRT.openInNewPane(rtA.id)
            _ = storeRT.openLauncherInNewPane()
            _ = storeRT.openInNewPane(rtB.id)
            let rtRows = storeRT.visibleRows.filter(\.isOpen)
            var rtRank: [UUID: Int] = [:]
            for (i, session) in storeRT.openSessions.enumerated() { rtRank[session.id] = i }
            // Fed a SHUFFLED strip, not the strip the rows came from. With the
            // real order as input the assertion was self-fulfilling: it also
            // passed when `placingLaunchers` was mutated to `return panes`,
            // because the bail-out output and the expected output were the same
            // array. Reversing the input makes the rebuild do real work, and
            // the expectation is still the order the rows describe.
            record("rows and panes round-trip through interleave + anchors",
                   SessionStore.placingLaunchers(
                       storeRT.panes.reversed(),
                       rank: rtRank,
                       anchors: SessionStore.launcherAnchors(inRowOrder: rtRows, panes: storeRT.panes)
                   ).map(\.id) == storeRT.panes.map(\.id))

            // An anchor naming a session with no pane can't be honoured. It
            // must degrade to the head rather than drop the pane — a dropped
            // slot takes a live WKWebView off the strip.
            let orphanPanes = storeRT.panes
            // Asserting the resulting ORDER, not just the count: the final
            // permutation guard returns the input unchanged on failure, so a
            // count assertion passes on the bail-out path too and pins only the
            // second half of its own name.
            record("an unhonourable anchor degrades to the head, never to a lost pane",
                   SessionStore.placingLaunchers(
                       orphanPanes,
                       rank: rtRank,
                       anchors: orphanPanes.compactMap { slot in
                           if case .launcher = slot.content {
                               return SessionStore.LauncherAnchor(slot: slot.id, after: rtC.id)
                           }
                           return nil
                       }
                   ).map(\.content)
                   == [.launcher, .launcher, .session(rtA.id), .session(rtB.id)])

            // A filter hiding a paned row must not let an unrelated drag move a
            // launcher pane. Four reviewers found this independently, two by
            // running it: reading every launcher's anchor back off the FILTERED
            // rows re-homes the ones whose own anchor row is hidden.
            let khA = dragSession("khA"), khC = dragSession("khC")
            let khH = OpenSession(origin: .local(cwd), resumeId: "drag-khH",
                                  title: "khH", project: "hidden", status: .live)
            let storeHiddenLaunch = SessionStore()
            storeHiddenLaunch._probeSeedOpenSessions([khH, khA, khC])
            _ = storeHiddenLaunch.openInNewPane(khH.id)
            _ = storeHiddenLaunch.openLauncherInNewPane()
            _ = storeHiddenLaunch.openInNewPane(khA.id)
            _ = storeHiddenLaunch.openInNewPane(khC.id)
            let hiddenLaunchSlot = storeHiddenLaunch.panes[1].id
            storeHiddenLaunch.filter.project = "p"   // hides khH
            // khH's row is hidden, so the launcher draws at the head: the visible
            // rows are [L, khA, khC]. Drag khC above khA. The launcher's anchor
            // row is the hidden one, so the rows cannot describe it and the
            // strip's anchor wins — its pane must not move. (Being un-dragged is
            // NOT what protects it: a launcher whose anchor row is visible does
            // follow a session drag, which the "carries it with the drop"
            // fixture below pins. The "dragged past a launcher" fixture above
            // cannot pin it — there the strip anchor and the row anchor happen
            // to be the same session, so it passes either way.)
            storeHiddenLaunch.moveOpenRows(fromOffsets: IndexSet(integer: 2), toOffset: 1)
            record("a filtered drag leaves an untouched launcher pane where it was",
                   storeHiddenLaunch.panes.map(\.content)
                   == [.session(khH.id), .launcher,
                       .session(khC.id), .session(khA.id)]
                   && storeHiddenLaunch.panes[1].id == hiddenLaunchSlot)
            clearPersistedFilter()

            // `paneIndex(forSlot:)` resolves a launcher row to its pane. Three
            // view-layer callers depend on it, one of which decides which pane
            // a close X removes from the strip. (Every call site matches
            // `case .launcher`, and a launcher pane has no session behind it —
            // that X removes the slot and nothing else. A session row's X takes
            // a different path entirely, `closeSession`.) Round 2
            // moved it out of the view layer so the probe could reach it, and
            // then nothing reached it: `panes.isEmpty ? nil : 0` survived the
            // whole suite. The realistic wrong version is "first launcher
            // pane", which is right until a second launcher opens.
            let piA = dragSession("piA"), piB = dragSession("piB")
            let storeSlotIndex = SessionStore()
            storeSlotIndex._probeSeedOpenSessions([piA, piB])
            _ = storeSlotIndex.openInNewPane(piA.id)
            _ = storeSlotIndex.openLauncherInNewPane()
            _ = storeSlotIndex.openInNewPane(piB.id)
            _ = storeSlotIndex.openLauncherInNewPane()
            let firstLauncherSlot = storeSlotIndex.panes[1].id
            let secondLauncherSlot = storeSlotIndex.panes[3].id
            record("paneIndex(forSlot:) finds each launcher's own pane",
                   storeSlotIndex.paneIndex(forSlot: firstLauncherSlot) == 1
                   && storeSlotIndex.paneIndex(forSlot: secondLauncherSlot) == 3
                   && storeSlotIndex.paneIndex(forSlot: storeSlotIndex.panes[0].id) == 0)
            storeSlotIndex.closePane(at: 1)
            record("paneIndex(forSlot:) returns nil for a pane that closed",
                   storeSlotIndex.paneIndex(forSlot: firstLauncherSlot) == nil
                   && storeSlotIndex.paneIndex(forSlot: secondLauncherSlot) == 2)

            // The empty state's predicate: launcher rows alone must not keep
            // "No sessions match your filter." off screen, and a session row
            // must switch it off.
            record("only-launcher rows still count as an empty sidebar",
                   SessionStore.holdsOnlyLauncherRows([.launcher(UUID()), .launcher(UUID())])
                   && SessionStore.holdsOnlyLauncherRows([])
                   && !SessionStore.holdsOnlyLauncherRows([.launcher(UUID()), .open(piA)]))

            // A SESSION dragged across a launcher carries the launcher with the
            // drop, even though the user never grabbed it. Rows [A][L][B], drag
            // A to the bottom: the drop reads [L][B][A], and anchoring L to A
            // regardless would render [B][A][L] — the panes disagreeing with
            // the order the user just dropped, which is the whole contract.
            let xsA = dragSession("xsA"), xsB = dragSession("xsB")
            let storeCrossing = SessionStore()
            storeCrossing._probeSeedOpenSessions([xsA, xsB])
            _ = storeCrossing.openInNewPane(xsA.id)
            _ = storeCrossing.openLauncherInNewPane()
            _ = storeCrossing.openInNewPane(xsB.id)
            storeCrossing.moveOpenRows(fromOffsets: IndexSet(integer: 0), toOffset: 3)
            record("a session dragged across a launcher carries it with the drop",
                   storeCrossing.panes.map(\.content)
                   == [.launcher, .session(xsB.id), .session(xsA.id)]
                   && openRowIds(storeCrossing) == [
                       SidebarRow.launcher(storeCrossing.panes[0].id).id,
                       SidebarRow.open(xsB).id,
                       SidebarRow.open(xsA).id,
                   ])

            // A launcher the rows CANNOT describe keeps the strip's anchor even
            // while another launcher is being dragged: with one parked behind a
            // filter-hidden pane, re-reading every anchor off the rows drags it
            // across that pane too. (An earlier version of this fixture picked
            // up no launcher at all, and back then the function returned early
            // in that case, so it never reached the rule.)
            let m1A = dragSession("m1A")
            let m1H = OpenSession(origin: .local(cwd), resumeId: "drag-m1H",
                                  title: "m1H", project: "hidden", status: .live)
            let storeOneLauncher = SessionStore()
            storeOneLauncher._probeSeedOpenSessions([m1H, m1A])
            _ = storeOneLauncher.openInNewPane(m1H.id)
            _ = storeOneLauncher.openLauncherInNewPane()      // behind the hidden pane
            _ = storeOneLauncher.openInNewPane(m1A.id)
            _ = storeOneLauncher.openLauncherInNewPane()      // behind the visible pane
            let parkedLauncher = storeOneLauncher.panes[1].id
            let draggedLauncher = storeOneLauncher.panes[3].id
            storeOneLauncher.filter.project = "p"   // hides m1H
            // Rows are [parked, m1A, dragged]; drag the last one to the head.
            storeOneLauncher.moveOpenRows(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            record("dragging one launcher leaves another parked behind a hidden pane",
                   storeOneLauncher.panes[0].id == draggedLauncher
                   && storeOneLauncher.panes[2].id == parkedLauncher
                   && storeOneLauncher.panes.map(\.content)
                   == [.launcher, .session(m1H.id), .launcher, .session(m1A.id)])
            clearPersistedFilter()

            // `rowsCanAnchor` must count PANED visible rows, not merely visible
            // ones. An unpaned row is visible but occupies no slot, so a row
            // list holding only unpaned rows still cannot say where a launcher
            // sits in the strip — and `launcherAnchors(inRowOrder:)` skips it,
            // resolving every anchor to the head. Accepting any open row here
            // survived the whole suite: no fixture occupied this middle state
            // (every other launcher drag has a paned row visible, and the
            // `.closedOnly` one has no open row at all).
            let rcU = dragSession("rcU")   // unpaned, project "p", stays visible
            let rcH = OpenSession(origin: .local(cwd), resumeId: "drag-rcH",
                                  title: "rcH", project: "hidden", status: .live)
            let storeUnpanedOnly = SessionStore()
            storeUnpanedOnly._probeSeedOpenSessions([rcH, rcU])
            _ = storeUnpanedOnly.openInNewPane(rcH.id)
            _ = storeUnpanedOnly.openLauncherInNewPane()
            storeUnpanedOnly.filter.project = "p"   // hides rcH; rcU has no pane
            // Rows are [L, rcU]; drag the launcher below the unpaned row.
            storeUnpanedOnly.moveOpenRows(fromOffsets: IndexSet(integer: 0), toOffset: 2)
            record("a visible row with no pane can't anchor a launcher",
                   storeUnpanedOnly.panes.map(\.content)
                   == [.session(rcH.id), .launcher])
            clearPersistedFilter()

            // The exception to the exception: a launcher whose anchor row is
            // hidden normally keeps its pane anchor, but if the USER dragged
            // that launcher the drop is a statement about it and outranks the
            // strip — even though honouring it crosses the hidden pane.
            let exA = dragSession("exA")
            let exH = OpenSession(origin: .local(cwd), resumeId: "drag-exH",
                                  title: "exH", project: "hidden", status: .live)
            let storeExplicit = SessionStore()
            storeExplicit._probeSeedOpenSessions([exH, exA])
            _ = storeExplicit.openInNewPane(exH.id)
            _ = storeExplicit.openLauncherInNewPane()
            _ = storeExplicit.openInNewPane(exA.id)
            storeExplicit.filter.project = "p"   // hides exH
            // Rows are [L, exA] (L drew at the head, its anchor being hidden);
            // drag L below exA.
            storeExplicit.moveOpenRows(fromOffsets: IndexSet(integer: 0), toOffset: 2)
            record("an explicitly dragged launcher honours the drop past a hidden pane",
                   storeExplicit.panes.map(\.content)
                   == [.session(exH.id), .session(exA.id), .launcher])
            clearPersistedFilter()

            // The degenerate form: a status filter hides EVERY session row, so
            // no anchor in the row order resolves. Dragging one launcher row
            // must not collapse the other launchers onto the head.
            let cdA = dragSession("cdA")
            let storeClosedOnly = SessionStore()
            storeClosedOnly._probeSeedOpenSessions([cdA])
            _ = storeClosedOnly.openInNewPane(cdA.id)
            _ = storeClosedOnly.openLauncherInNewPane()
            _ = storeClosedOnly.openLauncherInNewPane()
            let cdFirst = storeClosedOnly.panes[1].id, cdSecond = storeClosedOnly.panes[2].id
            storeClosedOnly.filter.status = .closedOnly
            // Rows are [L1, L2] and nothing else; swap them. The launchers may
            // trade places, but the session pane they both sit behind must not
            // be shoved to the right end.
            storeClosedOnly.moveOpenRows(fromOffsets: IndexSet(integer: 1), toOffset: 0)
            record("a closed-only filter can't drag the session pane across the strip",
                   storeClosedOnly.panes.map(\.content)
                   == [.session(cdA.id), .launcher, .launcher]
                   && storeClosedOnly.panes[1].id == cdSecond
                   && storeClosedOnly.panes[2].id == cdFirst)
            clearPersistedFilter()

            // The launcher's own anchor row hidden: it slides LEFT to the
            // nearest visible paned row rather than being counted past it. A
            // count-based interleave rendered this as [vB, L] — the launcher
            // drawn to the RIGHT of a pane it sits to the left of.
            let vbB = dragSession("vbB")
            let vbH = OpenSession(origin: .local(cwd), resumeId: "drag-vbH",
                                  title: "vbH", project: "hidden", status: .live)
            let storeSlideLeft = SessionStore()
            storeSlideLeft._probeSeedOpenSessions([vbH, vbB])
            _ = storeSlideLeft.openInNewPane(vbH.id)
            _ = storeSlideLeft.openLauncherInNewPane()
            _ = storeSlideLeft.openInNewPane(vbB.id)
            storeSlideLeft.filter.project = "p"   // hides vbH
            record("a launcher whose anchor row is hidden draws left of the next pane",
                   openRowIds(storeSlideLeft) == [
                       SidebarRow.launcher(storeSlideLeft.panes[1].id).id,
                       SidebarRow.open(vbB).id,
                   ])
            clearPersistedFilter()

            // `launcherAnchors(inRowOrder:)` must skip UNPANED rows. The
            // launcher is what moves here, ending up below an unpaned row;
            // anchoring to that row would put it at the head instead, since an
            // unpaned session has no pane to sit behind.
            let unA = dragSession("unA"), unU = dragSession("unU")
            let storeUnpanedDrag = SessionStore()
            storeUnpanedDrag._probeSeedOpenSessions([unA, unU])
            _ = storeUnpanedDrag.openInNewPane(unA.id)
            _ = storeUnpanedDrag.openLauncherInNewPane()
            // Rows are [unA, L, unU]; drag L to the end, below the unpaned row.
            storeUnpanedDrag.moveOpenRows(fromOffsets: IndexSet(integer: 1), toOffset: 3)
            record("a launcher dragged below an unpaned row keeps its real anchor",
                   storeUnpanedDrag.panes.map(\.content)
                   == [.session(unA.id), .launcher])

            // Out-of-range offsets from the UI must be refused, not trapped.
            let obA = dragSession("obA"), obB = dragSession("obB")
            let storeBounds = SessionStore()
            storeBounds._probeSeedOpenSessions([obA, obB])
            _ = storeBounds.openInNewPane(obA.id)
            _ = storeBounds.openInNewPane(obB.id)
            storeBounds.moveOpenRows(fromOffsets: IndexSet(integer: 99), toOffset: 0)
            storeBounds.moveOpenRows(fromOffsets: IndexSet(integer: 0), toOffset: -1)
            storeBounds.moveOpenRows(fromOffsets: IndexSet(integer: 0), toOffset: 99)
            record("out-of-range drag offsets are refused without trapping",
                   storeBounds.openSessions.map(\.id) == [obA.id, obB.id]
                   && storeBounds.panes.map(\.content)
                   == [.session(obA.id), .session(obB.id)])

            // A pane pointing at a session no longer open parks LAST, and the
            // stable sort keeps two such panes in their existing order. Nothing
            // else constructs that state, so both were unpinned.
            let orA = dragSession("orA")
            let orGhost1 = UUID(), orGhost2 = UUID()
            let orphanStrip = [
                PaneSlot(content: .session(orGhost1), preferredWidth: 400),
                PaneSlot(content: .session(orA.id), preferredWidth: 400),
                PaneSlot(content: .session(orGhost2), preferredWidth: 400),
            ]
            record("panes pointing at closed sessions park last, in their old order",
                   SessionStore.placingLaunchers(orphanStrip, rank: [orA.id: 0], anchors: [])
                       .map(\.content)
                   == [.session(orA.id), .session(orGhost1), .session(orGhost2)])

            // Cmd+click aims at the ROW, so the row holds still and the new
            // pane sorts to where that row already sits. Giving fA a pane
            // while fC already has one puts fA's pane on the LEFT, because
            // fA's row is above fC's — the rows never move.
            let fA = dragSession("fA"), fB = dragSession("fB"), fC = dragSession("fC")
            let storeDrift = SessionStore()
            storeDrift._probeSeedOpenSessions([fA, fB, fC])
            _ = storeDrift.openInNewPane(fC.id)
            _ = storeDrift.openInNewPane(fA.id)
            record("a new pane sorts to its row's position, rows unmoved",
                   storeDrift.openSessions.map(\.id) == [fA.id, fB.id, fC.id]
                   && storeDrift.panes.map(\.content)
                   == [.session(fA.id), .session(fC.id)])
            record("focus follows the new pane after it sorts left",
                   storeDrift.focusedPaneIndex == 0)

            // The reported case: Cmd+click the TOP row while later rows hold
            // the panes, and the new pane must land leftmost.
            let tT = dragSession("tT"), tB1 = dragSession("tB1"), tB2 = dragSession("tB2")
            let storeTop = SessionStore()
            storeTop._probeSeedOpenSessions([tT, tB1, tB2])
            _ = storeTop.openInNewPane(tB1.id)
            _ = storeTop.openInNewPane(tB2.id)
            _ = storeTop.openInNewPane(tT.id)
            record("Cmd+click on the top row opens its pane leftmost",
                   storeTop.panes.map(\.content)
                   == [.session(tT.id), .session(tB1.id), .session(tB2.id)]
                   && storeTop.openSessions.map(\.id) == [tT.id, tB1.id, tB2.id]
                   && storeTop.focusedPaneIndex == 0)

            // An open row's click — Cmd held or not — routes through
            // openInFocusedPane. Cmd must never grow a pane from a row
            // that is already open: that pushes it to the right end, which
            // reads as the sidebar moving things on its own.
            let cA = dragSession("cA"), cB = dragSession("cB")
            let storeCmd = SessionStore()
            storeCmd._probeSeedOpenSessions([cA, cB])
            _ = storeCmd.openInNewPane(cA.id)
            storeCmd.openInFocusedPane(cB.id)
            record("open-row click replaces the focused pane, never adds one",
                   storeCmd.panes.count == 1
                   && storeCmd.panes[0].content == .session(cB.id))

            // MARK: Row follows pane assignment
            //
            // The mirror image of the drag: when a session enters a pane by a
            // route that doesn't already place it right, the ROW moves, never
            // the pane. Reported case — clicking an unpaned session while the
            // MIDDLE pane is focused left its row at the top, so the sidebar
            // stopped reading as a map of the pane strip.
            let rM = dragSession("rM"), rS = dragSession("rS")
            let rW = dragSession("rW"), rP = dragSession("rP")
            let storeRow = SessionStore()
            storeRow._probeSeedOpenSessions([rM, rS, rW, rP])
            _ = storeRow.openInNewPane(rS.id)
            _ = storeRow.openInNewPane(rW.id)
            _ = storeRow.openInNewPane(rP.id)
            storeRow.setFocusedPaneIndex(1)
            storeRow.openInFocusedPane(rM.id)
            record("clicking an unpaned session moves its row to the pane's rank",
                   storeRow.panes.map(\.content)
                   == [.session(rS.id), .session(rM.id), .session(rP.id)]
                   && storeRow.openSessions.map(\.id)
                   == [rS.id, rM.id, rW.id, rP.id])

            // Leftmost pane: land directly ABOVE the next paned row rather
            // than on the far side of the unpaned rows in between.
            let bA = dragSession("bA"), bB = dragSession("bB"), bC = dragSession("bC")
            let storeLeft = SessionStore()
            storeLeft._probeSeedOpenSessions([bB, bC, bA])
            _ = storeLeft.openInNewPane(bB.id)
            _ = storeLeft.openInNewPane(bC.id)
            storeLeft.setFocusedPaneIndex(0)
            storeLeft.openInFocusedPane(bA.id)
            record("leftmost pane pulls its row directly above the next paned row",
                   storeLeft.panes.map(\.content)
                   == [.session(bA.id), .session(bC.id)]
                   && storeLeft.openSessions.map(\.id) == [bB.id, bA.id, bC.id])

            // Pure selection still moves nothing: a session that already has a
            // pane takes the focus-only branch, which never touches the rows.
            let pA = dragSession("pA"), pB = dragSession("pB")
            let storeSel = SessionStore()
            storeSel._probeSeedOpenSessions([pA, pB])
            _ = storeSel.openInNewPane(pA.id)
            _ = storeSel.openInNewPane(pB.id)
            storeSel.setFocusedPaneIndex(0)
            storeSel.openInFocusedPane(pB.id)
            record("selecting an already-paned session moves no row",
                   storeSel.openSessions.map(\.id) == [pA.id, pB.id]
                   && storeSel.focusedPaneIndex == 1)

            // A launcher pane's row is not a session row, so it must not shift
            // the rank a session pane is compared against.
            let gX = dragSession("gX"), gA = dragSession("gA"), gB = dragSession("gB")
            let storeGap = SessionStore()
            storeGap._probeSeedOpenSessions([gX, gA, gB])
            _ = storeGap.openInNewPane(gA.id)
            _ = storeGap.openLauncherInNewPane()
            _ = storeGap.openInNewPane(gB.id)
            storeGap.setFocusedPaneIndex(2)
            storeGap.openInFocusedPane(gX.id)
            record("launcher panes don't skew the row rank",
                   storeGap.panes.map(\.content)
                   == [.session(gA.id), .launcher, .session(gX.id)]
                   && storeGap.openSessions.map(\.id) == [gA.id, gX.id, gB.id])

            // The rank check earns its keep here: a newly-opened session is
            // already last in both orders, so opening it in a new pane must
            // NOT hoist its row above an unpaned row sitting between.
            let qA = dragSession("qA"), qU = dragSession("qU"), qB = dragSession("qB")
            let storeQuiet = SessionStore()
            storeQuiet._probeSeedOpenSessions([qA, qU, qB])
            _ = storeQuiet.openInNewPane(qA.id)
            _ = storeQuiet.openInNewPane(qB.id)
            record("opening a new pane leaves an already-correct row alone",
                   storeQuiet.openSessions.map(\.id) == [qA.id, qU.id, qB.id])

            // Multi-row drag downward. Lifting EVERY dragged pane out before
            // re-inserting is what makes this land right — moving them one at
            // a time turned [A][B][C][D] into [A][B][D][C] because the first
            // insert shifted the index the second rank was computed against.
            let mA = dragSession("mA"), mB = dragSession("mB")
            let mC = dragSession("mC"), mD = dragSession("mD")
            let storeMulti = SessionStore()
            storeMulti._probeSeedOpenSessions([mA, mB, mC, mD])
            for s in [mA, mB, mC, mD] { _ = storeMulti.openInNewPane(s.id) }
            storeMulti.moveOpenRows(fromOffsets: IndexSet([1, 2]), toOffset: 4)
            record("multi-row downward drag lands panes in the sidebar's final order",
                   storeMulti.openSessions.map(\.id) == [mA.id, mD.id, mB.id, mC.id]
                   && storeMulti.panes.map(\.content)
                   == [.session(mA.id), .session(mD.id),
                       .session(mB.id), .session(mC.id)])

            // Upward multi-row drag — the direction the downward case can't
            // pin, because it is where a rank could exceed the rebuilt prefix.
            let uA2 = dragSession("uA2"), uB2 = dragSession("uB2")
            let uC2 = dragSession("uC2"), uD2 = dragSession("uD2")
            let storeUp = SessionStore()
            storeUp._probeSeedOpenSessions([uA2, uB2, uC2, uD2])
            for s in [uA2, uB2, uC2, uD2] { _ = storeUp.openInNewPane(s.id) }
            storeUp.moveOpenRows(fromOffsets: IndexSet([2, 3]), toOffset: 0)
            record("multi-row upward drag lands panes in the sidebar's final order",
                   storeUp.panes.map(\.content) == storeUp.openSessions.map {
                       PaneContent.session($0.id)
                   })

            // A dragged set mixing a row that has a pane with one that doesn't.
            let xA = dragSession("xA"), xU = dragSession("xU")
            let xB = dragSession("xB"), xC = dragSession("xC")
            let storeMix = SessionStore()
            storeMix._probeSeedOpenSessions([xA, xU, xB, xC])
            for s in [xA, xB, xC] { _ = storeMix.openInNewPane(s.id) }
            storeMix.moveOpenRows(fromOffsets: IndexSet([1, 2]), toOffset: 0)
            record("a drag mixing paned and unpaned rows still matches row order",
                   storeMix.panes.map(\.content)
                   == storeMix.openSessions
                       .filter { s in storeMix.paneIndex(forSession: s.id) != nil }
                       .map { PaneContent.session($0.id) })

            // A paned row the filter is hiding. `applyVisibleOrder` keeps its
            // ROW at its master position, and sorting the panes off that
            // master order reproduces the same placement — no separate pinning
            // rule. The earlier revision pinned hidden panes by slot instead,
            // which broke as soon as an unpaned row joined the mix (see the
            // next case). `filter`'s didSet persists globally; the block-level
            // save/restore covers it.
            let hA = dragSession("hA"), hB = dragSession("hB"), hC = dragSession("hC")
            let hH = OpenSession(origin: .local(cwd), resumeId: "drag-hH",
                                 title: "hH", project: "hidden", status: .live)
            let storeHidden = SessionStore()
            storeHidden._probeSeedOpenSessions([hA, hH, hB, hC])
            for s in [hA, hH, hB, hC] { _ = storeHidden.openInNewPane(s.id) }
            storeHidden.filter.project = "p"   // hides hH, whose project is "hidden"
            storeHidden.moveOpenRows(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            record("panes follow row order across a filter-hidden pane",
                   storeHidden.openSessions.map(\.id)
                   == [hC.id, hH.id, hA.id, hB.id]
                   && storeHidden.panes.map(\.content)
                   == [.session(hC.id), .session(hH.id),
                       .session(hA.id), .session(hB.id)])
            clearPersistedFilter()

            // The case slot-pinning got wrong: a hidden PANED row plus a
            // visible UNPANED row. Rows end [C, B, A] with B hidden, so the
            // paned order is B then A and the panes must invert. Pinning B's
            // pane at slot 1 left [A][B] — inverted against the rows, and
            // invisible until the filter cleared.
            let yA = dragSession("yA"), yC = dragSession("yC")
            let yB = OpenSession(origin: .local(cwd), resumeId: "drag-yB",
                                 title: "yB", project: "hidden", status: .live)
            let storeInvert = SessionStore()
            storeInvert._probeSeedOpenSessions([yA, yB, yC])
            _ = storeInvert.openInNewPane(yA.id)
            _ = storeInvert.openInNewPane(yB.id)
            storeInvert.filter.project = "p"   // hides yB
            storeInvert.moveOpenRows(fromOffsets: IndexSet(integer: 0), toOffset: 2)
            record("a drag crossing a hidden pane inverts the panes with the rows",
                   storeInvert.openSessions.map(\.id) == [yC.id, yB.id, yA.id]
                   && storeInvert.panes.map(\.content)
                   == [.session(yB.id), .session(yA.id)])
            clearPersistedFilter()

        }

        // MARK: - Recap (see RecapGate / ShimProcess recap filters)
        //
        // These pin the two failure modes review found in the recap filters:
        // a substring match that destroyed any message merely QUOTING the
        // command wrapper, and the ordering rule that decides whether a
        // slash command's output survives replay. Both are pure functions on
        // plain dictionaries, so they need no shim, webview, or filesystem.
        do {
            func userMsg(_ text: String) -> [String: Any] {
                ["type": "user", "message": ["role": "user", "content": text] as [String: Any]]
            }
            func userBlocks(_ text: String) -> [String: Any] {
                ["type": "user", "message": [
                    "role": "user",
                    "content": [["type": "text", "text": text]],
                ] as [String: Any]]
            }
            let wrapper = "<command-name>/recap</command-name>\n            <command-message>recap</command-message>"
            let localOut: [String: Any] = ["type": "system", "subtype": "local_command",
                                           "content": "<local-command-stdout>…</local-command-stdout>"]

            // --- isRecapEcho: matches, in both content shapes
            record("isRecapEcho matches bare /recap (string content)",
                   ShimProcess.isRecapEcho(userMsg("/recap")))
            record("isRecapEcho matches bare /recap (block content)",
                   ShimProcess.isRecapEcho(userBlocks("  /recap  ")))
            record("isRecapEcho matches the command-name wrapper",
                   ShimProcess.isRecapEcho(userMsg(wrapper)))

            // --- isRecapEcho: must NOT match. These are the regressions.
            record("isRecapEcho ignores a message quoting the wrapper",
                   !ShimProcess.isRecapEcho(userMsg(
                       "why does <command-name>/recap</command-name> get stripped?")))
            record("isRecapEcho ignores /recap mentioned mid-sentence",
                   !ShimProcess.isRecapEcho(userMsg("run /recap when you get back")))
            record("isRecapEcho ignores an unrelated slash command",
                   !ShimProcess.isRecapEcho(userMsg("/cost")))
            record("isRecapEcho ignores a message with no content key",
                   !ShimProcess.isRecapEcho(["type": "user", "message": [:] as [String: Any]]))
            record("isRecapEcho ignores a malformed message",
                   !ShimProcess.isRecapEcho(["type": "user"]))

            // --- strippingRecapArtifacts: drops the pair, keeps everything else
            let stripped = ShimProcess.strippingRecapArtifacts([
                userMsg("first real prompt"), userMsg(wrapper), localOut, userMsg("second real prompt"),
            ])
            record("strippingRecapArtifacts drops the command and its output",
                   stripped.count == 2, "got \(stripped.count)")

            let otherCommand = ShimProcess.strippingRecapArtifacts([userMsg("/cost"), localOut])
            record("strippingRecapArtifacts keeps another command's output",
                   otherCommand.count == 2, "got \(otherCommand.count)")

            let noRecap = [userMsg("hello"), userMsg("world")]
            record("strippingRecapArtifacts returns a recap-free list unchanged",
                   ShimProcess.strippingRecapArtifacts(noRecap).count == 2)

            let orphan = ShimProcess.strippingRecapArtifacts([
                userMsg(wrapper), userMsg("typed while it ran"), localOut,
            ])
            record("strippingRecapArtifacts only pairs the IMMEDIATELY following entry",
                   orphan.count == 2, "got \(orphan.count)")

            let consecutive = ShimProcess.strippingRecapArtifacts([
                userMsg(wrapper), userMsg(wrapper), localOut,
            ])
            record("strippingRecapArtifacts handles back-to-back recap commands",
                   consecutive.isEmpty, "got \(consecutive.count)")

            // --- strippingRecapFromReplay: unwraps both envelope shapes
            let bare: [String: Any] = ["type": "response",
                                       "response": ["messages": [userMsg(wrapper), localOut]] as [String: Any]]
            let bareOut = ShimProcess.strippingRecapFromReplay(bare)
            let bareCount = ((bareOut["response"] as? [String: Any])?["messages"] as? [[String: Any]])?.count
            record("strippingRecapFromReplay strips a bare response", bareCount == 0,
                   "got \(String(describing: bareCount))")

            let wrapped: [String: Any] = ["type": "from-extension", "message": bare]
            let wrappedOut = ShimProcess.strippingRecapFromReplay(wrapped)
            let wrappedCount = (((wrappedOut["message"] as? [String: Any])?["response"] as? [String: Any])?["messages"] as? [[String: Any]])?.count
            record("strippingRecapFromReplay strips a from-extension response", wrappedCount == 0,
                   "got \(String(describing: wrappedCount))")

            let unrelated: [String: Any] = ["type": "io_message", "message": ["type": "assistant"]]
            record("strippingRecapFromReplay leaves an unrelated message untouched",
                   (ShimProcess.strippingRecapFromReplay(unrelated)["type"] as? String) == "io_message")

            // --- RecapGate: the eligibility rules
            var gate = RecapGate()
            record("RecapGate declines a session with no turns",
                   gate.ineligibilityReason(hasHistoricConversation: false) != nil)
            record("RecapGate names the remote carve-out",
                   gate.ineligibilityReason(hasHistoricConversation: false, isRemote: true)?
                       .contains("remote") == true)
            record("RecapGate permits a resumed session with history and no new turns",
                   gate.ineligibilityReason(hasHistoricConversation: true) == nil)
            gate.noteUserTurn()
            record("RecapGate permits after one genuine turn",
                   gate.ineligibilityReason(hasHistoricConversation: false) == nil)
            gate.recapLanded()
            record("RecapGate declines a repeat with no new turn",
                   gate.ineligibilityReason(hasHistoricConversation: false) != nil)
            record("RecapGate stays declined even with history seeded",
                   gate.ineligibilityReason(hasHistoricConversation: true) != nil)
            gate.noteUserTurn()
            record("RecapGate permits again after a new turn",
                   gate.ineligibilityReason(hasHistoricConversation: false) == nil)

            // --- synthetic-capture rule: the `/cost`-captured-as-recap fix
            record("recap claims a synthetic reply when nothing else was submitted",
                   ShimProcess.mayCaptureSyntheticReply(contended: false))
            record("recap yields the synthetic reply once the user has submitted",
                   !ShimProcess.mayCaptureSyntheticReply(contended: true))

            // --- RecapScript escaping: model output is hostile by default
            record("RecapScript escapes quotes and backslashes",
                   RecapScript.setCall(text: "he said \"hi\"\\done")
                       .contains("\\\"hi\\\"") )
            record("RecapScript escapes newlines rather than breaking the literal",
                   !RecapScript.setCall(text: "line1\nline2").contains("\n"))
        }

        // MARK: - Prompt-cache keep-alive (see KeepAliveGate / KeepAliveCoordinator)
        //
        // Every number here is DERIVED from the production constant rather
        // than re-typed. The probe has already been burned twice by fixtures
        // that spelled a value inline: when the constant moved, the failure
        // accused the property being pinned instead of the number that went
        // stale. What is worth pinning is that the boundary holds wherever
        // it sits.
        do {
            let interval = KeepAliveGate.defaultInterval
            let ceiling = KeepAliveGate.rateLimitCeiling
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            var gate = KeepAliveGate()

            // --- Nothing cached yet
            record("KeepAliveGate declines a shim with no API activity",
                   gate.ineligibilityReason(now: t0, interval: interval, rateLimitPct: 0, hasCustomApi: false) != nil)

            // --- The freshness boundary, asserted on BOTH sides
            gate.noteActivity(at: t0)
            record("KeepAliveGate declines while the cache is still fresh",
                   gate.ineligibilityReason(now: t0.addingTimeInterval(interval - 1), interval: interval, rateLimitPct: 0, hasCustomApi: false) != nil)
            record("KeepAliveGate permits exactly at the interval",
                   gate.ineligibilityReason(now: t0.addingTimeInterval(interval), interval: interval, rateLimitPct: 0, hasCustomApi: false) == nil)
            record("KeepAliveGate permits past the interval",
                   gate.ineligibilityReason(now: t0.addingTimeInterval(interval * 2), interval: interval, rateLimitPct: 0, hasCustomApi: false) == nil)

            // --- The rate-limit ceiling, both sides
            let due = t0.addingTimeInterval(interval)
            record("KeepAliveGate permits just below the rate-limit ceiling",
                   gate.ineligibilityReason(now: due, interval: interval, rateLimitPct: ceiling - 1, hasCustomApi: false) == nil)
            record("KeepAliveGate declines at the rate-limit ceiling",
                   gate.ineligibilityReason(now: due, interval: interval, rateLimitPct: ceiling, hasCustomApi: false) != nil)
            record("KeepAliveGate declines above the rate-limit ceiling",
                   gate.ineligibilityReason(now: due, interval: interval, rateLimitPct: 100, hasCustomApi: false) != nil)

            // --- Freshness is checked before the ceiling, so a fresh
            // session at 100% reports the cheap reason, not the quota one.
            // Ordering is a documented property of the gate, not an
            // accident of how the conditions happen to be written.
            record("KeepAliveGate reports freshness ahead of the quota ceiling",
                   gate.ineligibilityReason(now: t0, interval: interval, rateLimitPct: 100, hasCustomApi: false)?
                       .contains("fresh") == true)

            // --- The custom-provider carve-out outranks everything, including
            // an otherwise-due session with quota to spare.
            record("KeepAliveGate declines a custom API provider even when due",
                   gate.ineligibilityReason(now: due, interval: interval, rateLimitPct: 0, hasCustomApi: true) != nil)
            record("KeepAliveGate names the custom-provider carve-out",
                   gate.ineligibilityReason(now: due, interval: interval, rateLimitPct: 0, hasCustomApi: true)?
                       .contains("5m") == true)

            // --- Sending restarts the window and advances the counter
            var sent = KeepAliveGate()
            sent.noteActivity(at: t0)
            record("KeepAliveGate starts with no refreshes sent", sent.sentCount == 0)
            sent.noteKeepAliveSent(at: due)
            record("KeepAliveGate counts a sent refresh", sent.sentCount == 1)
            record("KeepAliveGate restarts the window from the refresh",
                   sent.ineligibilityReason(now: due, interval: interval, rateLimitPct: 0, hasCustomApi: false) != nil)
            record("KeepAliveGate comes due again one interval after the refresh",
                   sent.ineligibilityReason(now: due.addingTimeInterval(interval), interval: interval, rateLimitPct: 0, hasCustomApi: false) == nil)

            // --- isKeepAliveEcho: the swallow's only handle on "this turn
            // is ours". A keep-alive turn has an ordinary model id, so
            // unlike the recap there is no `<synthetic>` tag to fall back
            // on and a miss here means the reply is swallowed while the
            // prompt stays visible.
            func echoBlocks(_ text: String) -> [String: Any] {
                ["type": "user", "message": [
                    "role": "user",
                    "content": [["type": "text", "text": text]],
                ] as [String: Any]]
            }
            func echoString(_ text: String) -> [String: Any] {
                ["type": "user", "message": ["role": "user", "content": text] as [String: Any]]
            }
            record("isKeepAliveEcho matches the injected prompt in block form",
                   ShimProcess.isKeepAliveEcho(echoBlocks(KeepAliveGate.promptText)))
            record("isKeepAliveEcho matches the injected prompt in string form",
                   ShimProcess.isKeepAliveEcho(echoString(KeepAliveGate.promptText)))
            record("isKeepAliveEcho tolerates surrounding whitespace",
                   ShimProcess.isKeepAliveEcho(echoBlocks("\n  " + KeepAliveGate.promptText + "  \n")))
            // The substring trap `isRecapEcho` already documents: a user
            // pasting a transcript excerpt, or filing a bug about this
            // feature, must not have their message deleted.
            record("isKeepAliveEcho refuses a message merely QUOTING the prompt",
                   !ShimProcess.isKeepAliveEcho(echoBlocks("why did Canopy send \"" + KeepAliveGate.promptText + "\"?")))
            record("isKeepAliveEcho refuses an unrelated prompt",
                   !ShimProcess.isKeepAliveEcho(echoBlocks("fix the failing test")))
            record("isKeepAliveEcho refuses a message with no message payload",
                   !ShimProcess.isKeepAliveEcho(["type": "user"]))

            // --- The prompt's TAG is load-bearing twice over: the
            // prompt-history skip list matches on it, and the replay filter
            // matches the whole text. Assert the relationship, not the prose
            // — a reword should not turn a spelling change into a red test.
            record("keep-alive prompt opens with the shared tag",
                   KeepAliveGate.promptText.hasPrefix(KeepAliveGate.promptPrefix))

            // --- The constants themselves. Deriving every fixture from them
            // means every assertion above passes for ANY value they hold,
            // including feature-destroying ones: set the interval past the
            // CLI's 1h TTL and every refresh buys a full write instead of a
            // hit — the exact inversion the gate's doc says should cause
            // this feature to be deleted — with the probe still green. The
            // 3600 below is the CLI's TTL, an external fact this code has no
            // constant for, so writing it here is not a re-typing.
            record("keep-alive interval stays inside the CLI's 1h cache TTL",
                   KeepAliveGate.defaultInterval < 3600 && KeepAliveGate.defaultInterval > 0)
            record("rate-limit ceiling is a percentage that can actually gate",
                   (1...99).contains(KeepAliveGate.rateLimitCeiling))

            // --- A non-finite interval must not trap inside a pure value
            // type. `Int(_: Double)` traps on one, and the decline-reason
            // string builds two. Not reachable through
            // `CANOPY_KEEPALIVE_MINUTES` today — the coordinator rejects a
            // non-finite value first — so this pins the pure type refusing
            // to depend on a caller's validation, not a live crash.
            var infGate = KeepAliveGate()
            infGate.noteActivity(at: t0)
            record("KeepAliveGate refuses a non-finite interval instead of trapping",
                   infGate.ineligibilityReason(now: due, interval: .infinity, rateLimitPct: 0, hasCustomApi: false) != nil)
            record("KeepAliveGate refuses a zero interval",
                   infGate.ineligibilityReason(now: due, interval: 0, rateLimitPct: 0, hasCustomApi: false) != nil)

            // --- Which sessions count as running on a custom endpoint.
            //
            // The first version of this block computed its expectation with
            // the SAME expression the implementation uses, so deleting the
            // whole inherited-environment branch left it green on every
            // machine where the variable is unset — which is every CI
            // runner. A test that mirrors the code measures nothing.
            //
            // These use real `ModelProvider` values instead. The env half
            // still cannot be asserted without mutating the process
            // environment, and is deliberately left unpinned rather than
            // mirrored; `sessionUsesCustomEndpoint` carries the reasoning.
            var enabledProvider = ModelProvider()
            enabledProvider.baseURL = "https://example.invalid/v1"
            var emptyProvider = ModelProvider()
            emptyProvider.baseURL = ""
            record("an enabled provider counts as a custom endpoint",
                   ShimProcess.sessionUsesCustomEndpoint(enabledProvider))
            // The bug this replaced: testing mere presence declined a
            // selected-but-empty provider forever, on a session that
            // actually runs on ordinary subscriber auth.
            record("a provider with an empty baseURL does not count",
                   !ShimProcess.sessionUsesCustomEndpoint(emptyProvider)
                       || !(ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"] ?? "").isEmpty)

            // --- **An attempt costs an interval whether or not it worked.**
            // A rollback that made a FAILED refresh retry immediately was
            // written, shipped for one round, and removed: nothing else
            // holds the session back afterwards — the latch is cleared and
            // `isWorking` never rose, because every keep-alive frame is
            // dropped ahead of `trackWorkingState` — so the retry cadence
            // collapsed from the 55-minute interval to the coordinator's
            // 60-second tick. Against a standing 429 that is one real
            // injected turn per minute all night. These assertions are what
            // turn re-introducing it red.
            var attemptGate = KeepAliveGate()
            attemptGate.noteActivity(at: t0)
            let dueNow = t0.addingTimeInterval(interval)
            record("KeepAliveGate is due before an attempted refresh",
                   attemptGate.ineligibilityReason(now: dueNow, interval: interval, rateLimitPct: 0, hasCustomApi: false) == nil)
            attemptGate.noteKeepAliveSent(at: dueNow)
            record("KeepAliveGate blocks immediately after an attempt",
                   attemptGate.ineligibilityReason(now: dueNow, interval: interval, rateLimitPct: 0, hasCustomApi: false) != nil)
            // A tick later — the storm's cadence — it must still refuse.
            record("KeepAliveGate still refuses one tick after an attempt",
                   attemptGate.ineligibilityReason(now: dueNow.addingTimeInterval(60), interval: interval, rateLimitPct: 0, hasCustomApi: false) != nil)
            record("KeepAliveGate is due again only a full interval after the attempt",
                   attemptGate.ineligibilityReason(now: dueNow.addingTimeInterval(interval), interval: interval, rateLimitPct: 0, hasCustomApi: false) == nil)
            record("KeepAliveGate counts the attempt",
                   attemptGate.sentCount == 1)

            // --- The stamp never moves backwards. Its two callers read
            // different clocks, so a regression here would grant an early
            // refresh on nothing but skew.
            var backGate = KeepAliveGate()
            backGate.noteActivity(at: due)
            backGate.noteActivity(at: t0)
            record("KeepAliveGate never moves the activity stamp backwards",
                   backGate.ineligibilityReason(now: due, interval: interval, rateLimitPct: 0, hasCustomApi: false) != nil)

            // --- The SWALLOW. This is the part of the feature that deletes
            // messages, and the part whose one shipped bug was a wrong
            // swallow — reverting the `system/init` case used to leave the
            // whole suite green while the pane spun forever.
            func envelope(_ ioMsg: [String: Any]) -> [String: Any] {
                ["type": "from-extension", "message": ["type": "io_message", "message": ioMsg] as [String: Any]]
            }
            let initMsg = envelope(["type": "system", "subtype": "init"])
            let statusMsg = envelope(["type": "system", "subtype": "status"])
            let lifecycleMsg = envelope(["type": "command_lifecycle"])
            let assistantMsg = envelope(["type": "assistant"])
            let streamMsg = envelope(["type": "stream_event"])
            let rateLimitMsg = envelope(["type": "rate_limit_event"])
            let okResult = envelope(["type": "result", "subtype": "success"])
            let errResult = envelope(["type": "result", "subtype": "error_during_execution"])
            let flaggedResult = envelope(["type": "result", "subtype": "success", "is_error": true])
            let echoMsg = envelope(echoBlocks(KeepAliveGate.promptText))
            let otherUserMsg = envelope(echoBlocks("fix the failing test"))

            record("disposition passes everything through when no refresh is in flight",
                   ShimProcess.keepAliveDisposition(initMsg, inFlight: false, echoSeen: false) == .passThrough)
            // The shipped bug, now one red assertion.
            record("disposition swallows system/init before the echo",
                   ShimProcess.keepAliveDisposition(initMsg, inFlight: true, echoSeen: false) == .swallow)
            record("disposition swallows command_lifecycle before the echo",
                   ShimProcess.keepAliveDisposition(lifecycleMsg, inFlight: true, echoSeen: false) == .swallow)
            // Measured, and deliberately NOT swallowed — it carries the
            // permission-mode UI state and was not what set busy.
            record("disposition passes system/status through",
                   ShimProcess.keepAliveDisposition(statusMsg, inFlight: true, echoSeen: false) == .passThrough)
            record("disposition marks the echo on our own prompt",
                   ShimProcess.keepAliveDisposition(echoMsg, inFlight: true, echoSeen: false) == .swallowMarkingEcho)
            record("disposition passes a genuine prompt racing the refresh",
                   ShimProcess.keepAliveDisposition(otherUserMsg, inFlight: true, echoSeen: false) == .passThrough)
            // Before the echo a turn on the wire cannot be ours; swallowing
            // it would delete somebody else's reply.
            record("disposition passes an assistant frame through before the echo",
                   ShimProcess.keepAliveDisposition(assistantMsg, inFlight: true, echoSeen: false) == .passThrough)
            record("disposition passes a stream_event through before the echo",
                   ShimProcess.keepAliveDisposition(streamMsg, inFlight: true, echoSeen: false) == .passThrough)
            record("disposition swallows an assistant frame after the echo",
                   ShimProcess.keepAliveDisposition(assistantMsg, inFlight: true, echoSeen: true) == .swallow)
            record("disposition swallows a stream_event after the echo",
                   ShimProcess.keepAliveDisposition(streamMsg, inFlight: true, echoSeen: true) == .swallow)
            record("disposition never swallows rate_limit_event",
                   ShimProcess.keepAliveDisposition(rateLimitMsg, inFlight: true, echoSeen: true) == .passThrough)
            // Claiming a result without the echo eats the next REAL turn's,
            // and nothing else clears the webview's busy flag.
            record("disposition abandons the flight on a result with no echo",
                   ShimProcess.keepAliveDisposition(okResult, inFlight: true, echoSeen: false) == .abandonFlightPassingThrough)
            record("disposition completes the flight on a successful result",
                   ShimProcess.keepAliveDisposition(okResult, inFlight: true, echoSeen: true) == .completeFlight(refreshed: true))
            // A failed turn is not a refresh. Recording it as one made the
            // gate sleep past the point the cache actually lapsed, while the
            // log said "completed".
            record("disposition reports a failed result as NOT refreshed",
                   ShimProcess.keepAliveDisposition(errResult, inFlight: true, echoSeen: true) == .completeFlight(refreshed: false))
            record("disposition reports an is_error result as NOT refreshed",
                   ShimProcess.keepAliveDisposition(flaggedResult, inFlight: true, echoSeen: true) == .completeFlight(refreshed: false))
            record("disposition treats an unrecognised result shape as success",
                   ShimProcess.keepAliveDisposition(envelope(["type": "result"]), inFlight: true, echoSeen: true) == .completeFlight(refreshed: true))

            // --- Replay. The live swallow keeps the transcript clean only
            // for the process that injected; the JSONL keeps a real user
            // record plus a real reply, so reopening a session kept warm
            // overnight replayed a dozen bubble pairs.
            let replay: [[String: Any]] = [
                ["type": "user", "message": ["role": "user", "content": "real question"] as [String: Any]],
                ["type": "assistant", "message": ["role": "assistant"] as [String: Any]],
                echoBlocks(KeepAliveGate.promptText),
                ["type": "assistant", "message": ["role": "assistant"] as [String: Any]],
                ["type": "user", "message": ["role": "user", "content": "another question"] as [String: Any]],
            ]
            let stripped = ShimProcess.strippingKeepAliveArtifacts(replay)
            record("replay drops the keep-alive prompt and its reply",
                   stripped.count == replay.count - 2)
            record("replay keeps the user's own turns",
                   stripped.filter { $0["type"] as? String == "user" }.count == 2)
            record("replay leaves a conversation with no keep-alive untouched",
                   ShimProcess.strippingKeepAliveArtifacts(Array(replay.prefix(2))).count == 2)

            // --- Through the REPLAY ENTRY POINT, not the filter directly.
            // The assertions above call `strippingKeepAliveArtifacts`, so
            // unwiring it from `strippingRecapFromReplay` — the only thing
            // that actually runs on a `get_session` response — left them all
            // green. Same unprotected-wiring shape the disposition
            // extraction closed one level down.
            let envelope: [String: Any] = [
                "type": "from-extension",
                "message": ["response": ["messages": replay] as [String: Any]] as [String: Any],
            ]
            let out = ShimProcess.strippingRecapFromReplay(envelope)
            let outMessages = ((out["message"] as? [String: Any])?["response"] as? [String: Any])?["messages"] as? [[String: Any]]
            record("the replay entry point strips keep-alive turns, not just the filter",
                   outMessages?.count == replay.count - 2)
            record("the replay entry point keeps the user's own turns",
                   outMessages?.filter { $0["type"] as? String == "user" }.count == 2)

            // Only the reply IMMEDIATELY after the prompt goes. If the model
            // ignored the instruction and used a tool, the extra records
            // survive — erring toward showing too much, since the
            // alternative deletes conversation nobody can get back.
            let toolRun: [[String: Any]] = [
                echoBlocks(KeepAliveGate.promptText),
                ["type": "assistant", "message": ["role": "assistant"] as [String: Any]],
                ["type": "user", "message": ["role": "user", "content": "tool result"] as [String: Any]],
                ["type": "assistant", "message": ["role": "assistant"] as [String: Any]],
            ]
            let toolOut = ShimProcess.strippingKeepAliveArtifacts(toolRun)
            record("replay keeps records beyond the immediate reply",
                   toolOut.count == 2)
        }

        // MARK: - MacroPad wire protocol / SessionActivity / unread tracker
        //
        // Pure value-type coverage for the pad's host-side contract. The
        // serial / IOKit half is intentionally not exercised here — those
        // need a real device or a mocked fd, and a silent decode bug is the
        // one that would switch the user's pane or light the wrong color.

        // --- MacroPadLineDecoder.parse: one line at a time
        record("macropad decode: HELLO 1 4",
               MacroPadLineDecoder.parse("HELLO 1 4") == .hello(version: 1, keyCount: 4),
               "got \(String(describing: MacroPadLineDecoder.parse("HELLO 1 4")))")
        // Zero keys is a connected board with no NeoKey wired, not a broken
        // line — treating it as invalid is a regression with a real symptom.
        record("macropad decode: HELLO 1 0 is a valid zero-key board",
               MacroPadLineDecoder.parse("HELLO 1 0") == .hello(version: 1, keyCount: 0),
               "got \(String(describing: MacroPadLineDecoder.parse("HELLO 1 0")))")
        // Every loosening of `K` is a way for garbage to move the user's pane.
        record("macropad decode: K with trailing junk is dropped",
               MacroPadLineDecoder.parse("K 3 1 xyz") == nil,
               "got \(String(describing: MacroPadLineDecoder.parse("K 3 1 xyz")))")
        record("macropad decode: K with a non-binary state is dropped",
               MacroPadLineDecoder.parse("K 3 2") == nil,
               "got \(String(describing: MacroPadLineDecoder.parse("K 3 2")))")
        record("macropad decode: K with a negative index is dropped",
               MacroPadLineDecoder.parse("K -1 1") == nil,
               "got \(String(describing: MacroPadLineDecoder.parse("K -1 1")))")
        record("macropad decode: PONG 1 6",
               MacroPadLineDecoder.parse("PONG 1 6") == .pong(version: 1, keyCount: 6),
               "got \(String(describing: MacroPadLineDecoder.parse("PONG 1 6")))")
        record("macropad decode: bare PONG",
               MacroPadLineDecoder.parse("PONG") == .pong(version: nil, keyCount: nil),
               "got \(String(describing: MacroPadLineDecoder.parse("PONG")))")
        record("macropad decode: K press",
               MacroPadLineDecoder.parse("K 2 1") == .key(index: 2, pressed: true),
               "got \(String(describing: MacroPadLineDecoder.parse("K 2 1")))")
        record("macropad decode: K release",
               MacroPadLineDecoder.parse("K 2 0") == .key(index: 2, pressed: false),
               "got \(String(describing: MacroPadLineDecoder.parse("K 2 0")))")
        // A partial K must be DROPPED, never defaulted to key 0 — defaulting
        // would silently switch the user's focused pane.
        record("macropad decode: partial K dropped",
               MacroPadLineDecoder.parse("K 2") == nil,
               "got \(String(describing: MacroPadLineDecoder.parse("K 2")))")
        record("macropad decode: non-numeric K index dropped",
               MacroPadLineDecoder.parse("K x 1") == nil,
               "got \(String(describing: MacroPadLineDecoder.parse("K x 1")))")
        record("macropad decode: ERR message",
               MacroPadLineDecoder.parse("ERR unknown Z") == .deviceError("unknown Z"),
               "got \(String(describing: MacroPadLineDecoder.parse("ERR unknown Z")))")
        record("macropad decode: unknown verb dropped",
               MacroPadLineDecoder.parse("MOO") == nil,
               "got \(String(describing: MacroPadLineDecoder.parse("MOO")))")
        record("macropad decode: trailing CR tolerated",
               MacroPadLineDecoder.parse("PONG 1 4\r") == .pong(version: 1, keyCount: 4),
               "got \(String(describing: MacroPadLineDecoder.parse("PONG 1 4\r")))")

        // --- MacroPadLineDecoder.feed: chunk reassembly + reset
        do {
            var d = MacroPadLineDecoder()
            let first = d.feed(Data("K 1".utf8))
            let second = d.feed(Data(" 1\nK 0 0\n".utf8))
            record("macropad feed: split line reassembles",
                   first.isEmpty
                       && second == [.key(index: 1, pressed: true), .key(index: 0, pressed: false)],
                   "first=\(first) second=\(second)")

            var d2 = MacroPadLineDecoder()
            _ = d2.feed(Data("K 1".utf8))
            d2.reset()
            let afterReset = d2.feed(Data("PONG\n".utf8))
            record("macropad feed: reset drops buffered partial",
                   afterReset == [.pong(version: nil, keyCount: nil)],
                   "got \(afterReset)")
        }

        // --- MacroPadCommand.line / wireBytes
        record("macropad encode: color",
               MacroPadCommand.color(index: 0, rgb: 0xFF8000).line == "C 0 ff8000",
               "got \(MacroPadCommand.color(index: 0, rgb: 0xFF8000).line)")
        record("macropad encode: color zero-padded",
               MacroPadCommand.color(index: 3, rgb: 0x000000).line == "C 3 000000",
               "got \(MacroPadCommand.color(index: 3, rgb: 0x000000).line)")
        record("macropad encode: breathe",
               MacroPadCommand.breathe(index: 1, rgb: 0x00FFA0, periodMs: 2000, floorPercent: 40).line
                   == "S 1 00ffa0 2000 40",
               "got \(MacroPadCommand.breathe(index: 1, rgb: 0x00FFA0, periodMs: 2000, floorPercent: 40).line)")
        record("macropad encode: breathe floor clamped",
               MacroPadCommand.breathe(index: 0, rgb: 0xFF8000, periodMs: 2000, floorPercent: 140).line
                   == "S 0 ff8000 2000 100",
               "got \(MacroPadCommand.breathe(index: 0, rgb: 0xFF8000, periodMs: 2000, floorPercent: 140).line)")
        record("macropad encode: brightness clamped",
               MacroPadCommand.brightness(percent: 130).line == "B 100"
                   && MacroPadCommand.brightness(percent: -5).line == "B 0",
               "got \(MacroPadCommand.brightness(percent: 130).line)/\(MacroPadCommand.brightness(percent: -5).line)")
        record("macropad encode: ping and reset",
               MacroPadCommand.ping.line == "P" && MacroPadCommand.reset.line == "R",
               "got \(MacroPadCommand.ping.line)/\(MacroPadCommand.reset.line)")
        record("macropad encode: wireBytes ends with newline",
               MacroPadCommand.ping.wireBytes.last == UInt8(ascii: "\n"),
               "got \(Array(MacroPadCommand.ping.wireBytes))")

        // --- SessionActivity priority ladder
        do {
            let crashed = OpenSession(origin: .local(cwd), resumeId: "act-crash",
                                      title: "c", project: "P", status: .crashed(exitCode: 1))
            crashed.isThinking = true
            record("activity: crashed beats thinking → error",
                   SessionActivity.of(crashed, isUnread: false) == .error)

            let asking = OpenSession(origin: .local(cwd), resumeId: "act-ask",
                                     title: "a", project: "P", status: .live)
            asking.isThinking = true
            asking.isAsking = true
            record("activity: asking beats thinking",
                   SessionActivity.of(asking, isUnread: false) == .asking)

            let spawning = OpenSession(origin: .local(cwd), resumeId: "act-spawn",
                                       title: "s", project: "P", status: .spawning)
            record("activity: spawning → working",
                   SessionActivity.of(spawning, isUnread: false) == .working)

            let waiting = OpenSession(origin: .local(cwd), resumeId: "act-wait",
                                      title: "w", project: "P", status: .live)
            waiting.isWaiting = true
            record("activity: waiting alone → background",
                   SessionActivity.of(waiting, isUnread: false) == .background)

            let unread = OpenSession(origin: .local(cwd), resumeId: "act-unread",
                                     title: "u", project: "P", status: .live)
            record("activity: unread flag alone → unread",
                   SessionActivity.of(unread, isUnread: true) == .unread)

            let idle = OpenSession(origin: .local(cwd), resumeId: "act-idle",
                                   title: "i", project: "P", status: .live)
            record("activity: plain live → idle",
                   SessionActivity.of(idle, isUnread: false) == .idle)

            // Three states breathe; what must hold is that asking breathes
            // strictly deeper than any of them. If a second state ever ties
            // or beats it, the pad can no longer say "this one needs a human"
            // from peripheral vision.
            record("activity: asking breathes deepest",
                   SessionActivity.breathIsOrdered,
                   "floors \(SessionActivity.allCases.map { ($0, $0.breath?.floorPercent) })")
            let animated = SessionActivity.allCases.filter { $0.breath != nil }
            record("activity: only working/background/asking animate",
                   Set(animated) == Set([.working, .background, .asking]),
                   "got \(animated)")
            record("activity: every breath shares one period",
                   Set(animated.compactMap { $0.breath?.periodMs }).count == 1,
                   "periods \(animated.compactMap { $0.breath?.periodMs })")

            let colors = Set(SessionActivity.allCases.map(\.ledColor))
            record("activity: every ledColor is distinct",
                   colors.count == SessionActivity.allCases.count,
                   "unique=\(colors.count) cases=\(SessionActivity.allCases.count)")
        }

        // --- MacroPadUnreadTracker edge detection
        do {
            let idA = UUID()
            let idB = UUID()
            let threshold = MacroPadUnreadTracker.presenceThreshold

            var tracker = MacroPadUnreadTracker()
            tracker.update([.init(id: idA, isThinking: true)],
                           lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            tracker.update([.init(id: idA, isThinking: false)],
                           lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            record("unread: finish with no interaction becomes unread",
                   tracker.unread.contains(idA),
                   "unread=\(tracker.unread)")

            // Requirement: the last-interacted-with session, with the system
            // having seen input recently, clears.
            var recent = MacroPadUnreadTracker()
            recent.update([.init(id: idA, isThinking: true)],
                          lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            recent.update([.init(id: idA, isThinking: false)],
                          lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            // The clear is a SEPARATE, LATER act now: seq 2 against a mark
            // recorded at seq 1. Sending the prompt (seq 1) no longer clears
            // the turn it starts - see `markSeq`.
            recent.update([.init(id: idA, isThinking: false)],
                          lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: last-interacted session with recent system input clears",
                   !recent.unread.contains(idA),
                   "unread=\(recent.unread)")

            // Finding 1, reproduced directly: the previous commit's rule
            // (keystroke recency alone, 60 s) would clear this — 31 s is
            // "typed recently" under that window. It shouldn't: 31 s of
            // system-wide silence is well past the 30 s idle threshold, so
            // "attributed to this session" is not enough on its own — the
            // user may well have typed it and then walked away.
            var idle = MacroPadUnreadTracker()
            idle.update([.init(id: idA, isThinking: true)],
                        lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: threshold + 1, isAppActive: true)
            idle.update([.init(id: idA, isThinking: false)],
                        lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: threshold + 1, isAppActive: true)
            // Generation 2 so the ordering clause passes: presence is then the
            // only thing that can refuse this clear, which is what this
            // fixture is named for. Without it the guard short-circuits at
            // the ordering clause and the assertion holds for the wrong
            // reason — measured: deleting the presence clause outright left
            // the whole probe green.
            idle.update([.init(id: idA, isThinking: false)],
                        lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: threshold + 1, isAppActive: true)
            record("unread: last-interacted session but system idle past threshold still marks",
                   idle.unread.contains(idA),
                   "unread=\(idle.unread)")

            // The bug this round fixes, reproduced directly: the pad has no
            // HID interface (CLAUDE.md's "Serial (CDC), never HID"), so a
            // MacroPad key press cannot register with `CGEventSource` at
            // all. `MacroPadController.refresh` covers that by feeding the
            // tracker `MacroPadController.effectivePresence(...)` rather than
            // OS input alone — called here exactly as `refresh()` calls it,
            // not re-derived as an inline `min`, so this test can actually
            // fail if a future edit drops the pad term from the real
            // combination (an inline `min(staleOSInput, recentPadPress)`
            // would keep passing even then — it isn't calling the production
            // code at all). OS input is stale (past threshold) but the pad
            // was pressed moments ago, so the combined reading is recent and
            // the session clears. Passing OS idle alone — what the previous
            // round of this fix did — would fail this exactly like the "idle
            // past threshold" case just above.
            var padPresent = MacroPadUnreadTracker()
            let staleOSInput = threshold + 5
            let recentPadPress: TimeInterval = 0
            let padPresentReading = MacroPadController.effectivePresence(
                secondsSinceOSInput: staleOSInput, secondsSincePadPress: recentPadPress
            )
            padPresent.update([.init(id: idA, isThinking: true)],
                              lastInteractedSessionId: idA, interactionSeq: 1,
                              secondsSincePresence: padPresentReading, isAppActive: true)
            padPresent.update([.init(id: idA, isThinking: false)],
                              lastInteractedSessionId: idA, interactionSeq: 1,
                              secondsSincePresence: padPresentReading, isAppActive: true)
            padPresent.update([.init(id: idA, isThinking: false)],
                              lastInteractedSessionId: idA, interactionSeq: 2,
                              secondsSincePresence: padPresentReading, isAppActive: true)
            record("unread: OS input stale but a recent pad press still clears",
                   !padPresent.unread.contains(idA),
                   "unread=\(padPresent.unread)")

            // Both sources stale: still marked. A stale pad press must not
            // by itself keep the session artificially "present".
            var bothStale = MacroPadUnreadTracker()
            let stalePadPress = threshold + 5
            let bothStaleReading = MacroPadController.effectivePresence(
                secondsSinceOSInput: staleOSInput, secondsSincePadPress: stalePadPress
            )
            bothStale.update([.init(id: idA, isThinking: true)],
                             lastInteractedSessionId: idA, interactionSeq: 1,
                             secondsSincePresence: bothStaleReading, isAppActive: true)
            bothStale.update([.init(id: idA, isThinking: false)],
                             lastInteractedSessionId: idA, interactionSeq: 1,
                             secondsSincePresence: bothStaleReading, isAppActive: true)
            bothStale.update([.init(id: idA, isThinking: false)],
                             lastInteractedSessionId: idA, interactionSeq: 2,
                             secondsSincePresence: bothStaleReading, isAppActive: true)
            record("unread: OS input stale and pad press also stale still marks",
                   bothStale.unread.contains(idA),
                   "unread=\(bothStale.unread)")

            // Both sources recent: clears, same as either alone.
            var bothRecent = MacroPadUnreadTracker()
            let bothRecentReading = MacroPadController.effectivePresence(
                secondsSinceOSInput: 0, secondsSincePadPress: 0
            )
            bothRecent.update([.init(id: idA, isThinking: true)],
                              lastInteractedSessionId: idA, interactionSeq: 1,
                              secondsSincePresence: bothRecentReading, isAppActive: true)
            bothRecent.update([.init(id: idA, isThinking: false)],
                              lastInteractedSessionId: idA, interactionSeq: 1,
                              secondsSincePresence: bothRecentReading, isAppActive: true)
            bothRecent.update([.init(id: idA, isThinking: false)],
                              lastInteractedSessionId: idA, interactionSeq: 2,
                              secondsSincePresence: bothRecentReading, isAppActive: true)
            record("unread: both presence sources recent clears",
                   !bothRecent.unread.contains(idA),
                   "unread=\(bothRecent.unread)")

            // `effectivePresence` itself, pinned directly: which argument
            // wins is the property a caller could invert by accident (e.g.
            // swapping the two parameters at a call site) and neither of the
            // tests above would notice, since both use symmetric inputs in
            // one case and only check the tracker's downstream behaviour in
            // the others.
            record("presence: effectivePresence takes the smaller (more recent) reading",
                   MacroPadController.effectivePresence(secondsSinceOSInput: 40, secondsSincePadPress: 5) == 5
                   && MacroPadController.effectivePresence(secondsSinceOSInput: 5, secondsSincePadPress: 40) == 5)

            // A session that is NOT the last-interacted one stays marked no
            // matter how recent system input was — presence without
            // attribution to THIS session clears nothing. Since `markSeq` the
            // guard now refuses one clause earlier (the lookup for `idA`, which
            // holds no mark), so this no longer isolates attribution from the
            // ordering clause; it pins the outcome, not the reason.
            var other = MacroPadUnreadTracker()
            other.update([.init(id: idB, isThinking: true)],
                         lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            other.update([.init(id: idB, isThinking: false)],
                         lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            record("unread: a session that isn't last-interacted stays marked despite recent input",
                   other.unread.contains(idB),
                   "unread=\(other.unread)")

            // lastInteractedSessionId == nil: nothing is ever cleared,
            // however recent secondsSincePresence claims to be.
            var neverInteracted = MacroPadUnreadTracker()
            neverInteracted.update([.init(id: idA, isThinking: true)],
                                   lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            neverInteracted.update([.init(id: idA, isThinking: false)],
                                   lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            record("unread: nil lastInteractedSessionId never clears",
                   neverInteracted.unread.contains(idA),
                   "unread=\(neverInteracted.unread)")

            // Threshold boundary, both sides: inclusive at exactly the
            // threshold, stale just past it.
            var boundaryClear = MacroPadUnreadTracker()
            boundaryClear.update([.init(id: idA, isThinking: true)],
                                 lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            boundaryClear.update([.init(id: idA, isThinking: false)],
                                 lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: threshold, isAppActive: true)
            boundaryClear.update([.init(id: idA, isThinking: false)],
                                 lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: threshold, isAppActive: true)
            record("unread: exactly at the idle threshold still clears (inclusive)",
                   !boundaryClear.unread.contains(idA),
                   "unread=\(boundaryClear.unread)")

            var boundaryStale = MacroPadUnreadTracker()
            boundaryStale.update([.init(id: idA, isThinking: true)],
                                 lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            boundaryStale.update([.init(id: idA, isThinking: false)],
                                 lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: threshold + 0.001, isAppActive: true)
            boundaryStale.update([.init(id: idA, isThinking: false)],
                                 lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: threshold + 0.001, isAppActive: true)
            record("unread: just past the idle threshold does not clear",
                   boundaryStale.unread.contains(idA),
                   "unread=\(boundaryStale.unread)")

            // A last-interacted id whose session is no longer live (its pane
            // closed) must not crash and must leave nothing stale. Since
            // `markSeq`, the guard refuses one condition EARLIER than it used
            // to — at the `markSeq[id]` lookup, which here was never populated
            // (this id never finished a turn), so the live-prune is not what
            // empties it HERE. The prune itself is pinned elsewhere — since
            // membership became the mark, deleting it fails the
            // "disappeared id is pruned" fixture below. It used to be
            // genuinely unobservable, when the unread set and the generations
            // were two collections and only the set was public.
            var staleId = MacroPadUnreadTracker()
            staleId.update([.init(id: idB, isThinking: true)],
                           lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            staleId.update([.init(id: idB, isThinking: false)],
                           lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            record("unread: a last-interacted id with no live session doesn't crash or leave anything stale",
                   staleId.unread.contains(idB),
                   "unread=\(staleId.unread)")

            var unmapped = MacroPadUnreadTracker()
            unmapped.update([.init(id: idB, isThinking: true)],
                            lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            unmapped.update([.init(id: idB, isThinking: false)],
                            lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            unmapped.update([], lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            record("unread: disappeared id is pruned",
                   !unmapped.unread.contains(idB),
                   "unread=\(unmapped.unread)")

            // A session that vanishes *while thinking* and comes back idle
            // never had its finish observed within one continuous lifetime,
            // so it must not be marked. Covers the `wasThinking` pruning that
            // the test above leaves untouched.
            var relaunch = MacroPadUnreadTracker()
            relaunch.update([.init(id: idA, isThinking: true)],
                            lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            relaunch.update([], lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            relaunch.update([.init(id: idA, isThinking: false)],
                            lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            record("unread: close-and-reopen does not fake a finish",
                   !relaunch.unread.contains(idA),
                   "unread=\(relaunch.unread)")

            // Clearing must be per-session, not "wipe the set when the
            // last-interacted session is present".
            var pair = MacroPadUnreadTracker()
            pair.update([.init(id: idA, isThinking: true),
                         .init(id: idB, isThinking: true)],
                        lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            pair.update([.init(id: idA, isThinking: false),
                         .init(id: idB, isThinking: false)],
                        lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            let bothMarked = pair.unread.contains(idA) && pair.unread.contains(idB)
            pair.update([.init(id: idA, isThinking: false),
                         .init(id: idB, isThinking: false)],
                        lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: interacting with one session clears only that session",
                   bothMarked && !pair.unread.contains(idA) && pair.unread.contains(idB),
                   "bothMarked=\(bothMarked) unread=\(pair.unread)")

            // `refresh()` runs many times per second; a mark that survived
            // only one pass would show green for a single frame.
            var repeated = MacroPadUnreadTracker()
            repeated.update([.init(id: idA, isThinking: true)],
                            lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            repeated.update([.init(id: idA, isThinking: false)],
                            lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            repeated.update([.init(id: idA, isThinking: false)],
                            lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            record("unread: mark survives a repeated identical refresh",
                   repeated.unread.contains(idA),
                   "unread=\(repeated.unread)")

            // The regression this fix closes: "presence subsumes app
            // activation, since input only reaches the frontmost app" is
            // false for `secondsSincePresence`, which is system-wide OS
            // idle time — it drops to near-zero from typing into ANY app,
            // Canopy included or not. Last-interacted session, presence
            // recent, but Canopy backgrounded must NOT clear — without the
            // `isAppActive` condition this is exactly the case that cleared
            // wrongly (a session finishes while the user works in another
            // app, having last touched this session in Canopy moments
            // earlier).
            var backgroundedRecent = MacroPadUnreadTracker()
            backgroundedRecent.update([.init(id: idA, isThinking: true)],
                                      lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: false)
            backgroundedRecent.update([.init(id: idA, isThinking: false)],
                                      lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: false)
            // Generation 2 so `isAppActive` is the only clause left that can
            // refuse. This is the assertion CLAUDE.md's ladder records as
            // guarding a condition that was once deleted on a false argument,
            // so it is the one that most needs to fail when that happens.
            backgroundedRecent.update([.init(id: idA, isThinking: false)],
                                      lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: false)
            record("unread: last-interacted + recent presence but Canopy backgrounded still marks (the regression)",
                   backgroundedRecent.unread.contains(idA),
                   "unread=\(backgroundedRecent.unread)")

            // Same inputs, Canopy frontmost: clears. Isolates `isAppActive`
            // as the only thing distinguishing this from the case above.
            var frontmostRecent = MacroPadUnreadTracker()
            frontmostRecent.update([.init(id: idA, isThinking: true)],
                                   lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            frontmostRecent.update([.init(id: idA, isThinking: false)],
                                   lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            frontmostRecent.update([.init(id: idA, isThinking: false)],
                                   lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: last-interacted + recent presence + Canopy frontmost clears",
                   !frontmostRecent.unread.contains(idA),
                   "unread=\(frontmostRecent.unread)")

            // Frontmost alone is not enough either — the ORIGINAL bug this
            // whole file exists to fix: Canopy frontmost, a pane left
            // focused, but the user walked away (presence stale) must still
            // mark. `isAppActive` is necessary, not sufficient.
            var frontmostStale = MacroPadUnreadTracker()
            frontmostStale.update([.init(id: idA, isThinking: true)],
                                  lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: threshold + 1, isAppActive: true)
            frontmostStale.update([.init(id: idA, isThinking: false)],
                                  lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: threshold + 1, isAppActive: true)
            frontmostStale.update([.init(id: idA, isThinking: false)],
                                  lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: threshold + 1, isAppActive: true)
            record("unread: last-interacted + Canopy frontmost but presence stale still marks",
                   frontmostStale.unread.contains(idA),
                   "unread=\(frontmostStale.unread)")

            // Backgrounded and stale: still marks, same as every other
            // incomplete combination — nothing here is a coincidence of two
            // conditions happening to agree.
            var backgroundedStale = MacroPadUnreadTracker()
            backgroundedStale.update([.init(id: idA, isThinking: true)],
                                     lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: threshold + 1, isAppActive: false)
            backgroundedStale.update([.init(id: idA, isThinking: false)],
                                     lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: threshold + 1, isAppActive: false)
            backgroundedStale.update([.init(id: idA, isThinking: false)],
                                     lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: threshold + 1, isAppActive: false)
            record("unread: backgrounded and presence stale still marks",
                   backgroundedStale.unread.contains(idA),
                   "unread=\(backgroundedStale.unread)")

            // The bug this round fixes, replayed from the hardware log
            // (2026-08-27, Studio, MacroPad over the TCP bridge): the user
            // typed a prompt at t=0, the turn finished at t=11 s, and the
            // logged decision showed the mark inserted and removed inside ONE
            // update (the row itself is quoted on `logUnreadDecision`, which
            // also carries the caveat that its format has since changed). Every one of the
            // three conditions then in force was satisfied by the keystroke
            // that STARTED the turn, so no turn shorter than
            // `presenceThreshold` could ever light the LED. The user's
            // report was the sharper form of it: green appeared only when
            // Canopy was backgrounded, i.e. only when `isAppActive` happened
            // to fail. The bound is not "turns shorter than the threshold" —
            // presence is reset by any input anywhere on the Mac, so it was
            // any turn whose finish landed within `presenceThreshold` of the
            // user touching anything.
            var sameAct = MacroPadUnreadTracker()
            sameAct.update([.init(id: idA, isThinking: true)],
                           lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            sameAct.update([.init(id: idA, isThinking: false)],
                           lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 11, isAppActive: true)
            record("unread: the keystroke that started a turn does not clear that turn's finish",
                   sameAct.unread.contains(idA),
                   "unread=\(sameAct.unread)")

            // Strictly newer, not merely different: a repeated refresh
            // carrying the same generation is not an act.
            var sameSeqAgain = MacroPadUnreadTracker()
            sameSeqAgain.update([.init(id: idA, isThinking: true)],
                                lastInteractedSessionId: idA, interactionSeq: 7, secondsSincePresence: 0, isAppActive: true)
            sameSeqAgain.update([.init(id: idA, isThinking: false)],
                                lastInteractedSessionId: idA, interactionSeq: 7, secondsSincePresence: 0, isAppActive: true)
            sameSeqAgain.update([.init(id: idA, isThinking: false)],
                                lastInteractedSessionId: idA, interactionSeq: 7, secondsSincePresence: 0, isAppActive: true)
            record("unread: an interaction at the mark's own generation never clears it",
                   sameSeqAgain.unread.contains(idA),
                   "unread=\(sameSeqAgain.unread)")

            // An OLDER generation cannot clear either — the comparison is
            // ordered, not an inequality test.
            var olderSeq = MacroPadUnreadTracker()
            olderSeq.update([.init(id: idA, isThinking: true)],
                            lastInteractedSessionId: idA, interactionSeq: 9, secondsSincePresence: 0, isAppActive: true)
            olderSeq.update([.init(id: idA, isThinking: false)],
                            lastInteractedSessionId: idA, interactionSeq: 9, secondsSincePresence: 0, isAppActive: true)
            olderSeq.update([.init(id: idA, isThinking: false)],
                            lastInteractedSessionId: idA, interactionSeq: 3, secondsSincePresence: 0, isAppActive: true)
            record("unread: an older generation does not clear a newer mark",
                   olderSeq.unread.contains(idA),
                   "unread=\(olderSeq.unread)")

            // Walking away, coming back and pressing the pad: the mark
            // survives an arbitrary number of refreshes at the marking
            // generation and clears on the first act after it. This is the
            // whole gesture the feature exists for, end to end.
            var walkAway = MacroPadUnreadTracker()
            walkAway.update([.init(id: idA, isThinking: true)],
                            lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            walkAway.update([.init(id: idA, isThinking: false)],
                            lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 5, isAppActive: true)
            let litWhileAway = walkAway.unread.contains(idA)
            for _ in 0..<20 {
                walkAway.update([.init(id: idA, isThinking: false)],
                                lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 300, isAppActive: true)
            }
            let stillLit = walkAway.unread.contains(idA)
            walkAway.update([.init(id: idA, isThinking: false)],
                            lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: lit at finish, survives the absence, clears on the first act after it",
                   litWhileAway && stillLit && !walkAway.unread.contains(idA),
                   "lit=\(litWhileAway) stillLit=\(stillLit) unread=\(walkAway.unread)")

            // A second turn re-arms: the generation that cleared the first
            // mark must not also clear the next one.
            var secondTurn = MacroPadUnreadTracker()
            secondTurn.update([.init(id: idA, isThinking: true)],
                              lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            secondTurn.update([.init(id: idA, isThinking: false)],
                              lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            secondTurn.update([.init(id: idA, isThinking: false)],
                              lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            let firstCleared = !secondTurn.unread.contains(idA)
            secondTurn.update([.init(id: idA, isThinking: true)],
                              lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            secondTurn.update([.init(id: idA, isThinking: false)],
                              lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: a second turn re-arms and the generation that cleared the first does not clear it",
                   firstCleared && secondTurn.unread.contains(idA),
                   "firstCleared=\(firstCleared) unread=\(secondTurn.unread)")
            // Per-session keying, pinned directly. Collapsing the lookup to
            // the SMALLEST generation in the table passes every other fixture,
            // because in all of them the marks share one generation and `min`
            // is indistinguishable from the keyed lookup — and it reinstates
            // this PR's own bug in the multi-pane case the feature exists for:
            // A lit at gen 1, the user types into B at gen 2, B's turn
            // finishes at gen 2, and `2 > min(1, 2)` clears B with the
            // keystroke that started it. `.max()` is a DIFFERENT collapse and
            // this fixture does not catch it; `maxCollapse` below does.
            var crossSession = MacroPadUnreadTracker()
            crossSession.update([.init(id: idA, isThinking: true), .init(id: idB, isThinking: false)],
                                lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            crossSession.update([.init(id: idA, isThinking: false), .init(id: idB, isThinking: false)],
                                lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            let aLitFirst = crossSession.unread.contains(idA)
            crossSession.update([.init(id: idA, isThinking: false), .init(id: idB, isThinking: true)],
                                lastInteractedSessionId: idB, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            crossSession.update([.init(id: idA, isThinking: false), .init(id: idB, isThinking: false)],
                                lastInteractedSessionId: idB, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: a mark is compared against ITS OWN generation, not another session's",
                   aLitFirst && crossSession.unread.contains(idA) && crossSession.unread.contains(idB),
                   "aLitFirst=\(aLitFirst) unread=\(crossSession.unread)")

            // The other collapse of the per-session lookup, which the fixture
            // above does NOT catch: taking the largest generation in the
            // table. Measured — `.values.max()` passes every other assertion
            // here. Its divergence is narrow and real: another pane finishing
            // in the SAME update as your acknowledging act makes `max` equal
            // `interactionSeq`, so the click on the pane you are looking at
            // clears nothing.
            var maxCollapse = MacroPadUnreadTracker()
            maxCollapse.update([.init(id: idA, isThinking: true), .init(id: idB, isThinking: false)],
                               lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            maxCollapse.update([.init(id: idA, isThinking: false), .init(id: idB, isThinking: true)],
                               lastInteractedSessionId: nil, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            // A is lit at gen 1. Now act on A at gen 2 while B finishes in the
            // same call, recording B's mark at gen 2. Keyed, A clears; under a
            // `max` collapse the comparison is `2 > 2` and A survives.
            maxCollapse.update([.init(id: idA, isThinking: false), .init(id: idB, isThinking: false)],
                               lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: a concurrent finish elsewhere does not block the acknowledging act",
                   !maxCollapse.unread.contains(idA) && maxCollapse.unread.contains(idB),
                   "unread=\(maxCollapse.unread)")

            // A second finish while still unacknowledged must RE-ARM the mark:
            // an act taken between the two finishes has not seen the later
            // one, so allowing it to clear is the same shape as the keystroke
            // that cleared its own turn. Measured — restricting the `markSeq`
            // write to the set-insertion branch passes every other assertion.
            //
            // The whole second turn runs with Canopy BACKGROUNDED, which is
            // what keeps the mark standing across it — the divergence only
            // exists while the session is still unread when it finishes
            // again. A first draft of this fixture let the intervening act
            // clear the mark, so both the keyed and the insertion-only
            // versions re-marked identically and it caught nothing.
            var rearm = MacroPadUnreadTracker()
            rearm.update([.init(id: idA, isThinking: true)],
                         lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            rearm.update([.init(id: idA, isThinking: false)],
                         lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            // An act at gen 2, taken while Canopy is backgrounded so it cannot
            // clear — and a second turn that starts and finishes before the
            // user comes back.
            rearm.update([.init(id: idA, isThinking: true)],
                         lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: false)
            rearm.update([.init(id: idA, isThinking: false)],
                         lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: false)
            // Canopy comes forward. The gen-2 act predates the second finish,
            // so it must NOT suffice: keyed, the mark now sits at gen 2 and
            // `2 > 2` refuses. Without the re-arm it would still sit at gen 1
            // and this would clear a turn the user has never acknowledged.
            rearm.update([.init(id: idA, isThinking: false)],
                         lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: a second finish re-arms, so the act taken before it no longer suffices",
                   rearm.unread.contains(idA),
                   "unread=\(rearm.unread)")

            // `Outcome` is the ONLY signal for a mark inserted and cleared
            // inside one call, and nothing asserted it existed.
            var outcomes = MacroPadUnreadTracker()
            outcomes.update([.init(id: idA, isThinking: true)],
                            lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            let onFinish = outcomes.update([.init(id: idA, isThinking: false)],
                                           lastInteractedSessionId: idA, interactionSeq: 1, secondsSincePresence: 0, isAppActive: true)
            let onAck = outcomes.update([.init(id: idA, isThinking: false)],
                                        lastInteractedSessionId: idA, interactionSeq: 2, secondsSincePresence: 0, isAppActive: true)
            record("unread: update reports the mark it armed and the mark it cleared",
                   onFinish.marked == [idA] && onFinish.cleared.isEmpty
                   && onAck.cleared == [idA] && onAck.marked.isEmpty,
                   "onFinish=\(onFinish) onAck=\(onAck)")

            // The tripwire itself: a finish and a clear inside ONE call is the
            // regression's signature, and it must be unreachable.
            record("unread: no single update both arms and clears the same mark",
                   onFinish.marked.isDisjoint(with: onFinish.cleared),
                   "onFinish=\(onFinish)")

            // --- InteractionStamp: the counter that feeds the ordering rule.
            // Deleting its increment left the whole probe green while the
            // feature was dead — every generation 0, `0 > 0` false, nothing
            // ever clearing. These are the assertions that mutation now fails.
            var stamp = InteractionStamp()
            record("stamp: a fresh stamp names no session and sits at generation zero",
                   stamp.sessionId == nil && stamp.seq == 0,
                   "stamp=\(stamp)")
            stamp.stamp(idA)
            let afterFirst = stamp.seq
            stamp.stamp(idA)
            record("stamp: restamping the SAME session still advances the generation",
                   stamp.sessionId == idA && stamp.seq > afterFirst,
                   "afterFirst=\(afterFirst) stamp=\(stamp)")
            stamp.stamp(idB)
            record("stamp: stamping another session moves the id and advances again",
                   stamp.sessionId == idB && stamp.seq > afterFirst + 1,
                   "stamp=\(stamp)")

            // --- the indicator's symbol table. A misspelled SF Symbol renders
            // as a broken-image glyph and is invisible until someone looks at
            // the window; `square.grid.2x2.slash` shipped in a draft of the
            // source selector and does not exist.
            //
            // Two things this does NOT buy, both claimed by an earlier version
            // of this comment. A `Link` case added without a `demoCycle` entry
            // is simply never visited, and both assertions stay green — what
            // catches that is `appearance(for:)`'s exhaustive `switch`, at
            // compile time, not this. And `isEmpty` over zero iterations is
            // vacuously true, so an emptied `demoCycle` would pass everything
            // here; the count assertion below is what closes that.
            //
            // Resolution is against the RUNNING system's symbol catalog, not
            // the deployment target — CI runs macos-26 while the target is
            // macOS 15, so a symbol introduced in 26 would pass here and draw
            // broken on 15. All three current symbols predate 15 by years.
            var unresolved: [String] = []
            var blankHelp: [String] = []
            for link in MacroPadStatus.demoCycle {
                let appearance = MacroPadIndicator.appearance(for: link)
                if NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: nil) == nil {
                    unresolved.append(appearance.symbol)
                }
                if appearance.help.isEmpty { blankHelp.append(appearance.symbol) }
            }
            record("indicator: every link state resolves to a real SF Symbol",
                   unresolved.isEmpty,
                   "unresolved=\(unresolved)")
            record("indicator: every link state carries help text",
                   blankHelp.isEmpty,
                   "blank=\(blankHelp)")
            // Without this the two assertions above are vacuously green on an
            // empty cycle — `isEmpty` over nothing is true. Pinning the count
            // also makes removing a state cost an edit here.
            record("indicator: the demo cycle still covers five states",
                   MacroPadStatus.demoCycle.count == 5,
                   "count=\(MacroPadStatus.demoCycle.count)")

            // --- the refresh-skip predicate. The dangerous direction is
            // TIGHTENING it: a skipped refresh on the acknowledging act leaves
            // the mark burning until something unrelated wakes `refresh()`.
            record("skip: a refresh runs whenever the stamp moved to a new session",
                   MacroPadController.shouldRefresh(alreadyStamped: false, idIsUnread: false)
                   && MacroPadController.shouldRefresh(alreadyStamped: false, idIsUnread: true),
                   "")
            record("skip: a repeat stamp refreshes only when THAT session is unread",
                   MacroPadController.shouldRefresh(alreadyStamped: true, idIsUnread: true)
                   && !MacroPadController.shouldRefresh(alreadyStamped: true, idIsUnread: false),
                   "")

        }

        // --- MacroPadController.sessionId(atPaneIndex:in:) — the pane→session
        // lookup `refresh()`'s focus-change hook and `noteInteraction` both
        // resolve through, written once so they cannot drift apart.
        do {
            let sessionId = UUID()
            let sessionPane = PaneSlot(content: .session(sessionId), preferredWidth: 800)
            let launcherPane = PaneSlot(content: .launcher, preferredWidth: 800)
            let panes = [sessionPane, launcherPane]

            record("sessionId(atPaneIndex:): resolves a session pane",
                   MacroPadController.sessionId(atPaneIndex: 0, in: panes) == sessionId)
            record("sessionId(atPaneIndex:): a launcher pane resolves to nil",
                   MacroPadController.sessionId(atPaneIndex: 1, in: panes) == nil)
            record("sessionId(atPaneIndex:): an out-of-range index resolves to nil",
                   MacroPadController.sessionId(atPaneIndex: 2, in: panes) == nil)
            record("sessionId(atPaneIndex:): a negative index resolves to nil",
                   MacroPadController.sessionId(atPaneIndex: -1, in: panes) == nil)
            record("sessionId(atPaneIndex:): an empty pane list resolves to nil",
                   MacroPadController.sessionId(atPaneIndex: 0, in: []) == nil)
        }

        // --- SessionActivity: the SSH rung, and unread's place at the bottom
        do {
            let ssh = OpenSession(origin: .local(cwd), resumeId: "act-ssh",
                                  title: "s", project: "P", status: .live)
            ssh.connection.status = .reconnectFailed
            record("activity: reconnectFailed → error",
                   SessionActivity.of(ssh, isUnread: false) == .error)

            // `unread` firing is already covered; what was not covered is that
            // it *loses*. Moving `isUnread` up the ladder would leave every
            // other assertion green while a live background task rendered as
            // a finished session.
            let busy = OpenSession(origin: .local(cwd), resumeId: "act-busy",
                                   title: "b", project: "P", status: .live)
            busy.isWaiting = true
            let thinking = OpenSession(origin: .local(cwd), resumeId: "act-think",
                                       title: "t", project: "P", status: .live)
            thinking.isThinking = true
            let prompting = OpenSession(origin: .local(cwd), resumeId: "act-prompt",
                                        title: "p", project: "P", status: .live)
            prompting.isAsking = true
            record("activity: unread loses to background/working/asking",
                   SessionActivity.of(busy, isUnread: true) == .background
                       && SessionActivity.of(thinking, isUnread: true) == .working
                       && SessionActivity.of(prompting, isUnread: true) == .asking)

            record("activity: every ledColor fits 24 bits",
                   SessionActivity.allCases.allSatisfy { $0.ledColor <= 0x00FF_FFFF },
                   "\(SessionActivity.allCases.map { String($0.ledColor, radix: 16) })")

            // `.empty` and `.idle` share a dot colour deliberately (the pad
            // expresses "empty" as black); the rest must stay distinct.
            let dots = SessionActivity.allCases.filter { $0 != .empty }.map(\.dotRGB)
            record("activity: dot colours are distinct",
                   Set(dots.map { "\($0.red),\($0.green),\($0.blue)" }).count == dots.count,
                   "\(dots)")
        }

        // --- BreathPhase: the curve both renderers and the firmware share
        do {
            let start = Date(timeIntervalSinceReferenceDate: 1000)
            let breath = SessionActivity.Breath(periodMs: 2000, floorPercent: 10)
            let atTrough = BreathPhase.level(at: start, since: start, breath: breath)
            let atPeak = BreathPhase.level(at: start.addingTimeInterval(1), since: start, breath: breath)
            let afterFull = BreathPhase.level(at: start.addingTimeInterval(2), since: start, breath: breath)
            record("breath: phase 0 sits at the floor",
                   abs(atTrough - 0.10) < 0.0001, "got \(atTrough)")
            record("breath: half a period in reaches full",
                   abs(atPeak - 1.0) < 0.0001, "got \(atPeak)")
            record("breath: a whole period returns to the floor",
                   abs(afterFull - 0.10) < 0.0001, "got \(afterFull)")
            // Catches a floor/percent mix-up: with no room to move, the level
            // must be constant regardless of when it is sampled.
            let flat = SessionActivity.Breath(periodMs: 2000, floorPercent: 100)
            record("breath: floor 100 is constant",
                   abs(BreathPhase.level(at: start.addingTimeInterval(0.7), since: start, breath: flat) - 1.0) < 0.0001)
            // A period in milliseconds read as seconds would run 1000x fast.
            let slow = SessionActivity.Breath(periodMs: 4000, floorPercent: 0)
            record("breath: period is milliseconds",
                   abs(BreathPhase.level(at: start.addingTimeInterval(2), since: start, breath: slow) - 1.0) < 0.0001,
                   "got \(BreathPhase.level(at: start.addingTimeInterval(2), since: start, breath: slow))")
        }

        // --- RGBComponents.lerp: a transposed from/to runs every fade backwards
        do {
            let black = RGBComponents(red: 0, green: 0, blue: 0)
            let white = RGBComponents(red: 1, green: 1, blue: 1)
            record("rgb lerp: t=0 is the start colour",
                   RGBComponents.lerp(black, white, 0) == black)
            record("rgb lerp: t=1 is the end colour",
                   RGBComponents.lerp(black, white, 1) == white)
            let mid = RGBComponents.lerp(black, white, 0.5)
            record("rgb lerp: t=0.5 is the midpoint",
                   abs(mid.red - 0.5) < 0.0001 && abs(mid.green - 0.5) < 0.0001 && abs(mid.blue - 0.5) < 0.0001,
                   "got \(mid)")
        }

        // --- Decoder overflow: resync rather than fuse
        do {
            var overflow = MacroPadLineDecoder()
            // A console port spewing bytes with no newline. The trailing text
            // is chosen to look like a key press: if the decoder kept the tail
            // and fused it with the next line, this would emit `K 3 1` and
            // move the user's focused pane.
            let garbage = Data(repeating: UInt8(ascii: "x"), count: 5000) + Data("K 3 1 trailing".utf8)
            let duringOverflow = overflow.feed(garbage)
            let afterOverflow = overflow.feed(Data("\nPONG 3 4\n".utf8))
            record("macropad feed: overflow emits nothing",
                   duringOverflow.isEmpty, "got \(duringOverflow)")
            record("macropad feed: overflow resyncs without forging a key press",
                   afterOverflow == [.pong(version: 3, keyCount: 4)],
                   "got \(afterOverflow)")
        }

        // --- Encoder edges the existing assertions leave open
        record("macropad encode: breathe floor clamped at zero",
               MacroPadCommand.breathe(index: 0, rgb: 0x00FF00, periodMs: 2000, floorPercent: -10).line
                   == "S 0 00ff00 2000 0",
               "got \(MacroPadCommand.breathe(index: 0, rgb: 0x00FF00, periodMs: 2000, floorPercent: -10).line)")
        // --- The protocol-version gate. Its whole job is to protect firmware
        // nobody on the team runs any more, so a regression here is invisible
        // on current hardware and shows up as dark keys on an old pad.
        do {
            let asking = MacroPadController.command(for: .asking, at: 0, protocolVersion: 2)
            // The period and floor are DERIVED from the state, never re-typed:
            // this pins the version gate, not the tuning. Spelling 2000/10 here
            // made a breath retune report itself as a broken gate.
            let askingBreath = SessionActivity.asking.breath
            record("macropad gate: v2 breathes",
                   askingBreath.map {
                       asking == .breathe(index: 0,
                                          rgb: 0xFF8000,
                                          periodMs: $0.periodMs,
                                          floorPercent: $0.floorPercent)
                   } ?? false,
                   "got \(asking), breath \(String(describing: askingBreath))")
            record("macropad gate: v1 degrades to a steady colour",
                   MacroPadController.command(for: .asking, at: 0, protocolVersion: 1)
                       == .color(index: 0, rgb: 0xFF8000))
            // An absent version must read as 1, not as current — the firmware
            // without the field is the firmware without `S`.
            record("macropad gate: an absent version degrades too",
                   MacroPadController.command(for: .asking, at: 0, protocolVersion: nil)
                       == .color(index: 0, rgb: 0xFF8000))
            record("macropad gate: a static state is never breathed",
                   MacroPadController.command(for: .idle, at: 3, protocolVersion: 3)
                       == .color(index: 3, rgb: SessionActivity.idle.ledColor))
        }

        // --- Flipped pad. What this block does NOT pin, so it cannot be
        // read as coverage. Nothing here reaches `MacroPadController` as an
        // instance — `refresh()`, `handleKey` and `pushStates` are private on
        // a `@MainActor` class holding a live `SessionStore` and a concrete
        // device — so all of the following ship green: deleting
        // `Self.paneIndex(...)` from either call site (measured), passing
        // `panes.count` instead of the key count at either, `pushStates`
        // sending element *i* somewhere other than wire index *i*, and
        // hoisting `reversed` out of `refresh()`'s tracked closure, which is
        // the whole mechanism by which the Settings toggle relights the pad.
        // The `canopy.macroPadReversed` load/save round trip is out of reach
        // for the reason recorded at the settings note further down.
        //
        // An earlier version of this comment claimed the load-bearing
        // property is that the mapping is its own inverse. Both call sites ask
        // key→pane, so they agree by sharing one call; any bijection would do
        // the same.
        //
        // `keys` is a fixture width, not a pinned constant: the pad's width
        // comes off the wire in `HELLO`, and nothing here reads
        // `SessionStore.paneAbsoluteCap` — which is also 6, deliberately
        // (panes cap where the pad's keys run out).
        do {
            let keys = 6
            record("macropad flip: off is the identity",
                   (0..<keys).allSatisfy {
                       MacroPadController.paneIndex(forKey: $0, keyCount: keys, reversed: false) == $0
                   })
            record("macropad flip: the ends swap",
                   MacroPadController.paneIndex(forKey: 0, keyCount: keys, reversed: true) == keys - 1
                       && MacroPadController.paneIndex(forKey: keys - 1, keyCount: keys, reversed: true) == 0)
            record("macropad flip: is its own inverse",
                   (0..<keys).allSatisfy { key in
                       let pane = MacroPadController.paneIndex(forKey: key, keyCount: keys, reversed: true)
                       return MacroPadController.paneIndex(forKey: pane, keyCount: keys, reversed: true) == key
                   })
            // Implied by the involution above: an image outside the range
            // would be passed through unchanged, so `f(f(k)) == k` would
            // already have failed. Kept as a statement of the contract.
            record("macropad flip: every key is reached exactly once",
                   Set((0..<keys).map {
                       MacroPadController.paneIndex(forKey: $0, keyCount: keys, reversed: true)
                   }) == Set(0..<keys))
            // An interior key's mirror. It and the suffix filters below
            // overlap: given the ends and the involution, each is derivable
            // from the other, so neither is the load-bearing one and dropping
            // either leaves the group still determining `keyCount - 1 - index`
            // at this width. Dropping BOTH does not — the end-swapping
            // involution `{0↔5, 1↔2, 3↔4}` satisfies everything else here.
            record("macropad flip: an interior key mirrors",
                   MacroPadController.paneIndex(forKey: 1, keyCount: keys, reversed: true) == keys - 2
                       && MacroPadController.paneIndex(forKey: 2, keyCount: keys, reversed: true) == keys - 3)
            // Kept as an executable statement of where the blank keys sit;
            // see the interior assertion above for why the two overlap. Which
            // count the call sites reverse over is not reachable from here at
            // all — see the block comment.
            record("macropad flip: paned keys are a fixed suffix",
                   (0..<keys).filter {
                       MacroPadController.paneIndex(forKey: $0, keyCount: keys, reversed: true) < 2
                   } == [keys - 2, keys - 1]
                       && (0..<keys).filter {
                           MacroPadController.paneIndex(forKey: $0, keyCount: keys, reversed: true) < 3
                       } == [keys - 3, keys - 2, keys - 1])
            // A pad that reported no keys, or an index the callers already
            // refused, must pass through rather than be invented into range.
            //
            // The zero-key case pins nothing and is kept as documentation:
            // `keyCount > 0` is implied by `index >= 0 && index < keyCount`,
            // so it can never be the decisive clause for any input and
            // deleting it is an inert mutation. The out-of-range one below is
            // the load-bearing half — the only assertion that fails when
            // either range guard is dropped, in either direction, which is
            // also why both directions share one `record`.
            record("macropad flip: a zero-key pad passes through",
                   MacroPadController.paneIndex(forKey: 2, keyCount: 0, reversed: true) == 2)
            record("macropad flip: an out-of-range index passes through",
                   MacroPadController.paneIndex(forKey: keys, keyCount: keys, reversed: true) == keys
                       && MacroPadController.paneIndex(forKey: -1, keyCount: keys, reversed: true) == -1)
            // The only assertion run at a width other than 6, which is what
            // makes it the one that catches a body reversing over a hardcoded
            // width instead of the `keyCount` it was passed.
            record("macropad flip: an odd pad's middle key is fixed",
                   MacroPadController.paneIndex(forKey: 2, keyCount: 5, reversed: true) == 2)
        }

        // --- Reset-loop detection. This never fired at its original window,
        // and nothing noticed for a whole review round.
        do {
            let base = Date(timeIntervalSinceReferenceDate: 0)
            var loop = MacroPadResetLoopDetector(window: 360, threshold: 3)
            // The firmware refuses to self-reset inside 60s of boot, so a real
            // crash loop cycles no faster than ~62s. Three of those must fire.
            let a = loop.note(at: base)
            let b = loop.note(at: base.addingTimeInterval(62))
            let c = loop.note(at: base.addingTimeInterval(124))
            record("macropad reset loop: fires on a real firmware cycle",
                   !a && !b && c, "\(a) \(b) \(c)")
            // The old 120s window could not fit two 62s gaps — the bug.
            var tooTight = MacroPadResetLoopDetector(window: 120, threshold: 3)
            _ = tooTight.note(at: base)
            _ = tooTight.note(at: base.addingTimeInterval(62))
            record("macropad reset loop: a 120s window could never fire",
                   !tooTight.note(at: base.addingTimeInterval(124)))
            // Clearing after a hit: the fourth reconnect must not re-fire.
            record("macropad reset loop: does not re-fire on the next reconnect",
                   !loop.note(at: base.addingTimeInterval(186)))
            // Eviction: spread beyond the window, nothing fires.
            var slow = MacroPadResetLoopDetector(window: 360, threshold: 3)
            _ = slow.note(at: base)
            _ = slow.note(at: base.addingTimeInterval(200))
            record("macropad reset loop: evicts past the window",
                   !slow.note(at: base.addingTimeInterval(400)))
        }

        // --- Sleep chord. Every assertion here is a way the pad could go
        // dark on a desk nobody is at, or refuse to for the person holding it.
        do {
            let base = Date(timeIntervalSinceReferenceDate: 0)
            let hold = MacroPadSleepChord.holdDuration
            let floor = MacroPadSleepChord.minimumKeyCount

            func chord(keys: Int?, _ presses: [(Int, Bool, TimeInterval)]) -> MacroPadSleepChord {
                var c = MacroPadSleepChord()
                c.setKeyCount(keys)
                for (index, pressed, offset) in presses {
                    c.note(index: index, pressed: pressed, at: base.addingTimeInterval(offset))
                }
                return c
            }

            record("macropad chord: a 6-key pad's ends are 0 and 5",
                   chord(keys: 6, [(0, true, 0), (5, true, 0)]).holdDeadline != nil)
            record("macropad chord: an end and its neighbour are not the chord",
                   chord(keys: 6, [(0, true, 0), (1, true, 0)]).holdDeadline == nil)
            record("macropad chord: an end and a non-end are not the chord",
                   chord(keys: 6, [(0, true, 0), (4, true, 0)]).holdDeadline == nil)
            // The floor is derived, so no assertion can pin the number 3. Pin
            // the ARGUMENT for it instead: the gesture's one surviving safety
            // property is that the ends are not adjacent, which needs at least
            // one key between them. This rejects a floor of 2 and would accept
            // a legitimate future 4.
            record("macropad chord: the floor leaves at least one key between the ends",
                   floor - 2 >= 1, "minimumKeyCount=\(floor)")
            // Both sides of the minimum, and both derived from the constant —
            // a re-typed 2 or 3 here would keep passing under a name that had
            // become false, which is the `paneAbsoluteCap` incident's shape.
            record("macropad chord: the narrowest pad with a chord has ends 0 and \(floor - 1)",
                   chord(keys: floor, [(0, true, 0), (floor - 1, true, 0)]).holdDeadline != nil)
            record("macropad chord: one key below the floor has no chord",
                   chord(keys: floor - 1, [(0, true, 0), (floor - 2, true, 0)]).holdDeadline == nil)
            // An unidentified pad reports no count on purpose: no gesture is
            // right where a gesture aimed at guessed indices is not.
            record("macropad chord: an unreported key count has no chord",
                   chord(keys: nil, [(0, true, 0), (5, true, 0)]).holdDeadline == nil)
            record("macropad chord: one end alone does not hold",
                   chord(keys: 6, [(0, true, 0)]).holdDeadline == nil)
            record("macropad chord: an adjacent middle pair is not the chord",
                   chord(keys: 6, [(1, true, 0), (2, true, 0)]).holdDeadline == nil)

            let both = chord(keys: 6, [(0, true, 0), (5, true, 0)])
            record("macropad chord: the deadline is one hold after the press",
                   both.holdDeadline == base.addingTimeInterval(hold),
                   "got \(String(describing: both.holdDeadline))")
            // Without this, `holdDuration = 0` passes every other assertion in
            // this block and brushing both ends sleeps the pad instantly.
            record("macropad chord: brushing both ends is not instantly the chord",
                   both.holdDeadline.map { $0 > base } == true)

            // Measured from the SECOND end down: a thumb resting on key 0 all
            // evening must not shorten the gesture to a tap on key 5.
            record("macropad chord: the hold starts at the second end",
                   chord(keys: 6, [(0, true, 0), (5, true, 60)]).holdDeadline
                       == base.addingTimeInterval(60 + hold))

            // A press with no release before it means the release was lost on
            // the wire, and the clock restarts so the deadline moves LATER.
            // That the CONTROLLER then re-aims its timer at the new deadline
            // — the actual round-1 bug — is not asserted here. Observing the
            // re-aim would mean reading `chordDeadline` after a synchronous
            // `handleKey`, and both are private; watching the timer actually
            // fire additionally needs a run loop, which this probe exits
            // before turning. `MacroPadSleepChordTimerAction` below is as
            // close as this gets, and it pins the rule, not the wiring.
            record("macropad chord: a duplicate press pushes the deadline out",
                   chord(keys: 6, [(0, true, 0), (5, true, 0), (5, true, 60)]).holdDeadline
                       == base.addingTimeInterval(60 + hold))

            record("macropad chord: releasing an end drops the hold",
                   chord(keys: 6, [(0, true, 0), (5, true, 0), (0, false, 1)]).holdDeadline == nil)
            record("macropad chord: re-pressing restarts rather than resumes",
                   chord(keys: 6, [(0, true, 0), (5, true, 0), (0, false, 1), (0, true, 1)]).holdDeadline
                       == base.addingTimeInterval(1 + hold))

            // `reset()` runs the moment sleep begins, while both ends are
            // still physically held.
            var cleared = both
            cleared.reset()
            record("macropad chord: reset forgets keys that are still held",
                   cleared.holdDeadline == nil)

            // The geometry moving mid-hold is the one that sleeps a pad on a
            // chord nobody made: hold 0, 3 and 5 on a six-key pad, let a
            // `PONG` claim four keys, and (0, 3) is suddenly both ends — held
            // long enough already. The presses have to go with the count.
            var reshaped = chord(keys: 6, [(0, true, 0), (3, true, 0), (5, true, 0)])
            reshaped.setKeyCount(4)
            record("macropad chord: a key-count change cannot satisfy a chord nobody made",
                   reshaped.holdDeadline == nil)
            // Same count re-adopted is not a change, so it must not disturb a
            // hold in progress.
            var readopted = both
            readopted.setKeyCount(6)
            record("macropad chord: re-adopting the same count leaves the hold alone",
                   readopted.holdDeadline == base.addingTimeInterval(hold))

            // Wire garbage must not accumulate in the press map — the only
            // place in this subsystem where an unbounded index could. This has
            // to be asserted through `trackedKeyCount`: an out-of-range press
            // is by construction never an end, so it cannot move the deadline,
            // and a deadline-only assertion here passes with the range guard
            // deleted outright (measured).
            var forged = chord(keys: 6, [(0, true, 0), (5, true, 0)])
            forged.note(index: 9_999, pressed: true, at: base)
            forged.note(index: -1, pressed: true, at: base)
            forged.note(index: 6, pressed: true, at: base)
            record("macropad chord: out-of-range indices are dropped, not recorded",
                   forged.trackedKeyCount == 2, "tracked=\(forged.trackedKeyCount)")
            // Not evidence — measured to survive every mutation that the
            // tracked-count assertion above also catches. Kept as the sentence
            // a reader wants next to it.
            record("macropad chord: forged indices leave the hold itself alone",
                   forged.holdDeadline == base.addingTimeInterval(hold))
        }

        // --- The sleep clamp. It carries three promises — dark on the
        // gesture, dark through a reconnect, dark through a relaunch — of
        // which only the first is reachable here; the other two live in the
        // diff cache and in `UserDefaults`.
        do {
            record("macropad brightness: asleep overrides the setting",
                   MacroPadController.effectiveBrightness(percent: 60, isAsleep: true) == 0)
            record("macropad brightness: awake passes the setting through",
                   MacroPadController.effectiveBrightness(percent: 60, isAsleep: false) == 60)
            record("macropad brightness: clamped to the protocol's range",
                   MacroPadController.effectiveBrightness(percent: 150, isAsleep: false) == 100
                       && MacroPadController.effectiveBrightness(percent: -5, isAsleep: false) == 0)
        }

        // --- Which key indices the controller will act on at all. Extracted
        // because deleting the inlined bound left every assertion green
        // (measured): the forged-`K` wake it closes is the one fix in this
        // change that nothing else protects.
        do {
            record("macropad key bound: a real index on a six-key pad is accepted",
                   MacroPadController.acceptsKey(index: 5, keyCount: 6))
            record("macropad key bound: an index past the reported width is refused",
                   !MacroPadController.acceptsKey(index: 6, keyCount: 6)
                       && !MacroPadController.acceptsKey(index: 9_999, keyCount: 6))
            record("macropad key bound: a negative index is refused",
                   !MacroPadController.acceptsKey(index: -1, keyCount: 6))
            // The two counts that cannot discriminate must accept, or a
            // sleeping pad loses its only exit. Zero is the one that reads as
            // a validated count and validates nothing.
            record("macropad key bound: an unreported width accepts anything",
                   MacroPadController.acceptsKey(index: 9_999, keyCount: nil))
            record("macropad key bound: a zero width accepts anything rather than stranding the pad",
                   MacroPadController.acceptsKey(index: 0, keyCount: 0)
                       && MacroPadController.acceptsKey(index: 9_999, keyCount: 0))
        }

        // --- The scheduler's decision, extracted so it is reachable at all.
        // Pinning it does NOT pin that the controller consults it — restoring
        // the one-shot behaviour that wedged the gesture would leave all of
        // these green. It pins the rule that behaviour broke.
        do {
            let a = Date(timeIntervalSinceReferenceDate: 0)
            let b = a.addingTimeInterval(5)
            typealias Action = MacroPadSleepChordTimerAction

            record("macropad chord timer: an unmoved deadline keeps its timer",
                   Action.next(current: a, desired: a, force: false) == .leaveAlone)
            record("macropad chord timer: a moved deadline is re-aimed, never dropped",
                   Action.next(current: a, desired: b, force: false) == .aim(b))
            record("macropad chord timer: a released hold retires the timer",
                   Action.next(current: a, desired: nil, force: false) == .retire)
            record("macropad chord timer: no hold and no timer is not work",
                   Action.next(current: nil, desired: nil, force: false) == .leaveAlone)
            record("macropad chord timer: arming from nothing aims",
                   Action.next(current: nil, desired: a, force: false) == .aim(a))
            // `force` is what stops a plausible refactor from restoring the
            // round-1 wedge: move the fire body's two clears below its guards
            // and `current` holds the same deadline `desired` does, so
            // `leaveAlone` wins and nothing is armed while both ends are still
            // held. The `(a, a, true)` half is the one that pins it; the
            // `(nil, a, true)` half is inert and kept only for symmetry.
            record("macropad chord timer: force re-aims a deadline that looks unchanged",
                   Action.next(current: nil, desired: a, force: true) == .aim(a)
                       && Action.next(current: a, desired: a, force: true) == .aim(a))
            record("macropad chord timer: force still retires when the hold is gone",
                   Action.next(current: nil, desired: nil, force: true) == .retire)
        }

        record("macropad encode: rgb masked to 24 bits",
               MacroPadCommand.color(index: 0, rgb: 0xFF00_0000).line == "C 0 000000",
               "got \(MacroPadCommand.color(index: 0, rgb: 0xFF00_0000).line)")

        // MARK: - MacroPad remote endpoint parsing (remote transport)
        //
        // Parsing happens once, at the settings boundary. Every assertion
        // here is a shape that must NOT reach the socket layer as a guess.

        record("macropad endpoint: bare host takes the default port",
               MacroPadRemoteEndpoint.parse("mbp") == MacroPadRemoteEndpoint(host: "mbp", port: 8765),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("mbp")))")
        record("macropad endpoint: host:port",
               MacroPadRemoteEndpoint.parse("mbp:9000") == MacroPadRemoteEndpoint(host: "mbp", port: 9000),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("mbp:9000")))")
        record("macropad endpoint: surrounding whitespace is trimmed",
               MacroPadRemoteEndpoint.parse("  mbp:9000  ") == MacroPadRemoteEndpoint(host: "mbp", port: 9000),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("  mbp:9000  ")))")
        record("macropad endpoint: bracketed IPv6 with a port",
               MacroPadRemoteEndpoint.parse("[fd7a::1]:8765") == MacroPadRemoteEndpoint(host: "fd7a::1", port: 8765),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("[fd7a::1]:8765")))")
        record("macropad endpoint: bracketed IPv6 without a port",
               MacroPadRemoteEndpoint.parse("[fd7a::1]") == MacroPadRemoteEndpoint(host: "fd7a::1", port: 8765),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("[fd7a::1]")))")
        // A bare v6 literal is ambiguous with host:port. Rejected, never guessed.
        record("macropad endpoint: unbracketed IPv6 is rejected",
               MacroPadRemoteEndpoint.parse("fd7a::1") == nil,
               "got \(String(describing: MacroPadRemoteEndpoint.parse("fd7a::1")))")
        record("macropad endpoint: empty is nil",
               MacroPadRemoteEndpoint.parse("") == nil, "expected nil")
        record("macropad endpoint: whitespace only is nil",
               MacroPadRemoteEndpoint.parse("   ") == nil, "expected nil")
        record("macropad endpoint: empty host with a port is nil",
               MacroPadRemoteEndpoint.parse(":8765") == nil, "expected nil")
        record("macropad endpoint: port 0 is nil",
               MacroPadRemoteEndpoint.parse("mbp:0") == nil, "expected nil")
        record("macropad endpoint: port 65536 is nil",
               MacroPadRemoteEndpoint.parse("mbp:65536") == nil, "expected nil")
        record("macropad endpoint: non-numeric port is nil",
               MacroPadRemoteEndpoint.parse("mbp:abc") == nil, "expected nil")
        record("macropad endpoint: missing port after the colon is nil",
               MacroPadRemoteEndpoint.parse("mbp:") == nil, "expected nil")
        // `parsePort`'s own comment says the ASCII-digit guard exists
        // because `UInt16(raw)` alone would accept "+1" and Unicode digits.
        // "abc" (asserted above) already fails `UInt16(_:)` on its own, so it
        // proves nothing about that guard specifically — these two do.
        record("macropad endpoint: a leading-plus port is nil",
               MacroPadRemoteEndpoint.parse("mbp:+1") == nil, "expected nil")
        record("macropad endpoint: a Unicode-digit port is nil",
               MacroPadRemoteEndpoint.parse("mbp:\u{0661}\u{0662}\u{0663}") == nil, "expected nil")
        record("macropad endpoint: displayLabel round-trips",
               MacroPadRemoteEndpoint.parse("mbp")?.displayLabel == "mbp:8765",
               "got \(String(describing: MacroPadRemoteEndpoint.parse("mbp")?.displayLabel))")
        // Unbracketed input is rejected by `parse` (asserted above), but
        // `displayLabel` is reachable on any endpoint, including one built
        // directly with the memberwise initializer — so it has to defend
        // its own invariant rather than trust every caller went through
        // `parse`. Without the bracket this reads as "fd7a:115c:a1e0::5201"
        // on port "7f5d:8765", which is exactly the ambiguity `parse` exists
        // to refuse.
        record("macropad endpoint: displayLabel brackets an IPv6 host",
               MacroPadRemoteEndpoint(host: "fd7a::1", port: 8765).displayLabel == "[fd7a::1]:8765",
               "got \(MacroPadRemoteEndpoint(host: "fd7a::1", port: 8765).displayLabel)")

        // MARK: - MacroPadRemoteEndpoint.liveHostUpdate (SettingsView live typing)
        //
        // Fixes the "Remote bridge" row staying hidden until Return/blur:
        // while the source is not already `.remote`, a parseable (or
        // emptied) draft should store live; a live `.remote` selection must
        // keep deferring to `commitHost()`, and a non-empty unparseable
        // draft must store nothing so it can't wipe out a good address.
        record("macropad live host: .remote source never stores, even for a valid draft",
               MacroPadRemoteEndpoint.liveHostUpdate(
                   source: .remote(MacroPadRemoteEndpoint(host: "mbp", port: 8765)),
                   draft: "other"
               ) == nil,
               "expected nil")
        record("macropad live host: .off source stores a parseable draft",
               MacroPadRemoteEndpoint.liveHostUpdate(source: .off, draft: "mbp") == "mbp",
               "got \(String(describing: MacroPadRemoteEndpoint.liveHostUpdate(source: .off, draft: "mbp")))")
        record("macropad live host: .local source stores a parseable draft",
               MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "mbp:9000") == "mbp:9000",
               "got \(String(describing: MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "mbp:9000")))")
        record("macropad live host: a single character already parses as a bare host",
               MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "m") == "m",
               "got \(String(describing: MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "m")))")
        record("macropad live host: an empty draft stores empty",
               MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "") == "",
               "got \(String(describing: MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "")))")
        record("macropad live host: a whitespace-only draft stores empty",
               MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "   ") == "",
               "got \(String(describing: MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "   ")))")
        // A non-empty unparseable intermediate shape (mid-typing a port)
        // must not overwrite a previously-stored good address.
        record("macropad live host: a non-empty unparseable draft stores nothing",
               MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "mbp:") == nil,
               "got \(String(describing: MacroPadRemoteEndpoint.liveHostUpdate(source: .local, draft: "mbp:")))")
        record("macropad live host: an unbracketed IPv6 draft stores nothing",
               MacroPadRemoteEndpoint.liveHostUpdate(source: .off, draft: "fd7a::1") == nil,
               "got \(String(describing: MacroPadRemoteEndpoint.liveHostUpdate(source: .off, draft: "fd7a::1")))")

        // MARK: - MacroPadDevice.Endpoint.label
        //
        // Every new TCP log line routes through this. Pure, and reachable
        // from the probe module without any access-level change.
        record("macropad device endpoint: serial label is the callout path",
               MacroPadDevice.Endpoint.serial(path: "/dev/cu.usbmodem20103", interfaceNumber: 3).label
                   == "/dev/cu.usbmodem20103",
               "got \(MacroPadDevice.Endpoint.serial(path: "/dev/cu.usbmodem20103", interfaceNumber: 3).label)")
        record("macropad device endpoint: tcp label is the endpoint's displayLabel",
               MacroPadDevice.Endpoint.tcp(MacroPadRemoteEndpoint(host: "mbp", port: 9000)).label == "mbp:9000",
               "got \(MacroPadDevice.Endpoint.tcp(MacroPadRemoteEndpoint(host: "mbp", port: 9000)).label)")

        // --- MacroPadSource resolution and migration
        record("macropad source: off resolves",
               MacroPadSource.resolve(rawValue: "off", host: "") == .off, "expected .off")
        record("macropad source: local resolves",
               MacroPadSource.resolve(rawValue: "local", host: "") == .local, "expected .local")
        record("macropad source: remote resolves with a valid host",
               MacroPadSource.resolve(rawValue: "remote", host: "mbp:9000")
                   == .remote(MacroPadRemoteEndpoint(host: "mbp", port: 9000)),
               "got \(String(describing: MacroPadSource.resolve(rawValue: "remote", host: "mbp:9000")))")
        // Degrading to .local here would silently drive a DIFFERENT pad than
        // the one configured, which is the worst outcome available.
        record("macropad source: remote with an empty host degrades to off, not local",
               MacroPadSource.resolve(rawValue: "remote", host: "") == .off,
               "got \(String(describing: MacroPadSource.resolve(rawValue: "remote", host: "")))")
        record("macropad source: remote with an unparseable host degrades to off",
               MacroPadSource.resolve(rawValue: "remote", host: "mbp:abc") == .off,
               "got \(String(describing: MacroPadSource.resolve(rawValue: "remote", host: "mbp:abc")))")
        record("macropad source: an unknown selector does not resolve",
               MacroPadSource.resolve(rawValue: "banana", host: "") == nil, "expected nil")
        record("macropad source: isOff only for off",
               MacroPadSource.off.isOff && !MacroPadSource.local.isOff, "isOff is wrong")
        record("macropad source: rawValue spellings",
               MacroPadSource.off.rawValue == "off"
                   && MacroPadSource.local.rawValue == "local"
                   && MacroPadSource.remote(MacroPadRemoteEndpoint(host: "m", port: 1)).rawValue == "remote",
               "rawValue spelling changed")

        record("macropad source migration: legacy enabled=true becomes local",
               MacroPadSource.migrated(storedRaw: nil, storedHost: "", legacyEnabled: true) == .local,
               "expected .local")
        record("macropad source migration: legacy enabled=false becomes off",
               MacroPadSource.migrated(storedRaw: nil, storedHost: "", legacyEnabled: false) == .off,
               "expected .off")
        record("macropad source migration: a fresh install defaults to local",
               MacroPadSource.migrated(storedRaw: nil, storedHost: "", legacyEnabled: nil) == .local,
               "expected .local")
        // The stored selector outranks the legacy key once it exists.
        record("macropad source migration: a stored selector wins over the legacy key",
               MacroPadSource.migrated(storedRaw: "off", storedHost: "", legacyEnabled: true) == .off,
               "expected .off")
        // A garbage SELECTOR falls through to the legacy/default path. That is
        // different from a garbage ADDRESS, which degrades to .off above.
        record("macropad source migration: a garbage selector falls through to the legacy key",
               MacroPadSource.migrated(storedRaw: "banana", storedHost: "", legacyEnabled: false) == .off,
               "expected .off")

        // Deliberately no assertion here touching `CanopySettings.shared`.
        // `load()` unconditionally assigns `macroPadSource` /
        // `macroPadRemoteHost` whenever a settings.json exists at all (even
        // one with neither key present), and those assignments' `didSet`
        // fires `save()` — so merely constructing the shared instance writes
        // the real, shared `~/Library/Application Support/Canopy/settings.json`
        // (shared between this Debug build and the installed Release app;
        // see CLAUDE.md) with none of the snapshot/restore discipline every
        // other fixture in this file uses. A prior version of this block
        // asserted `["off", "local", "remote"].contains(macroPadSource.rawValue)`
        // for exactly that side effect, which was also a tautology —
        // `rawValue` can only be one of those three by construction — so it
        // bought a real hazard (a silent settings change for a user running
        // an older Release build) for zero actual coverage. The load/save
        // pair itself is still not probe-reachable and remains untested here.

        // Switching source is an explicit "I am using this pad now"; the chord
        // means "go dark". The newer, more specific verb wins — otherwise
        // every transition costs a swallowed keypress to wake the new pad.
        // `shouldClearSleep` is two conditions, and both need their own
        // assertion: `lastSource == nil` (a fresh launch) must never clear,
        // whatever the target — that's the guard against a launch silently
        // un-sleeping a pad the user put to sleep before quitting. Only once
        // `lastSource` is real does the target's `isOff` decide anything.
        record("macropad sleep: a nil lastSource never clears, whatever the target",
               !MacroPadController.shouldClearSleep(lastSource: nil, movingTo: .local)
                   && !MacroPadController.shouldClearSleep(
                       lastSource: nil,
                       movingTo: .remote(MacroPadRemoteEndpoint(host: "mbp", port: 8765))
                   )
                   && !MacroPadController.shouldClearSleep(lastSource: nil, movingTo: .off),
               "expected false for every nil-lastSource case")
        record("macropad sleep: a real change to local clears sleep",
               MacroPadController.shouldClearSleep(lastSource: .off, movingTo: .local), "expected true")
        record("macropad sleep: a real change to remote clears sleep",
               MacroPadController.shouldClearSleep(
                   lastSource: .off,
                   movingTo: .remote(MacroPadRemoteEndpoint(host: "mbp", port: 8765))
               ),
               "expected true")
        // Off disconnects, and the firmware blanks itself. Clearing the flag
        // there would silently un-sleep the pad you get back later.
        record("macropad sleep: a real change to off does not clear sleep",
               !MacroPadController.shouldClearSleep(lastSource: .local, movingTo: .off), "expected false")

        // MARK: - Session restore snapshot
        do {
            func snapSession(
                _ id: String,
                origin: SessionRestoreSnapshot.Session.Origin = .local(path: "/tmp/probe"),
                title: String? = nil,
                permissionMode: PermissionMode = .acceptEdits
            ) -> SessionRestoreSnapshot.Session {
                SessionRestoreSnapshot.Session(
                    resumeId: id,
                    title: title ?? id,
                    project: "probe",
                    origin: origin,
                    permissionMode: permissionMode,
                    model: nil,
                    effortLevel: nil,
                    providerId: nil,
                    lastActiveAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            }
            func snapPane(_ id: String?, _ w: CGFloat = 800) -> SessionRestoreSnapshot.Pane {
                SessionRestoreSnapshot.Pane(
                    content: id.map { .session(resumeId: $0) } ?? .launcher,
                    width: w
                )
            }
            let always: (SessionRestoreSnapshot.Session) -> Bool = { _ in true }

            let original = SessionRestoreSnapshot(
                sessions: [
                    snapSession("a", origin: .local(path: "/tmp/a")),
                    snapSession("b", origin: .remote(host: "mbp", path: "/tmp/b")),
                ],
                panes: [snapPane("a", 700), snapPane(nil, 500), snapPane("b", 900)],
                focusedPaneIndex: 2
            )
            // Record the throw rather than `try!`-ing it: a trap here reads in
            // CI as "the app never launched", which is the one failure mode the
            // probe job's summary-line check exists to tell apart.
            do {
                let encoded = try JSONEncoder().encode(original)
                let decoded = try JSONDecoder().decode(SessionRestoreSnapshot.self, from: encoded)
                record("restore: JSON round-trip preserves sessions, panes, and focus",
                       decoded == original)
            } catch {
                record("restore: JSON round-trip preserves sessions, panes, and focus",
                       false, "threw \(error)")
            }

            let dropOne = SessionRestoreSnapshot(
                sessions: [snapSession("keep"), snapSession("drop")],
                panes: [snapPane("keep", 640), snapPane("drop", 720)],
                focusedPaneIndex: 0
            )
            let afterDrop = dropOne.sanitized(paneCap: 5) { $0.resumeId == "keep" }
            record("restore: an unresumable session drops its pane with it",
                   afterDrop.sessions.map(\.resumeId) == ["keep"]
                       && afterDrop.panes.count == 1)
            record("restore: the surviving pane keeps its width and content",
                   afterDrop.panes.first?.width == 640
                       && afterDrop.panes.first?.content == .session(resumeId: "keep"))

            // Four panes with focus in the MIDDLE, not on the last one. With
            // only three the final clamp lands on the same index the shift
            // does, so the assertion passes even with the `droppedBeforeFocus`
            // bookkeeping deleted — it measures the clamp and nothing else.
            let focusShift = SessionRestoreSnapshot(
                sessions: (0..<4).map { snapSession("s\($0)") },
                panes: (0..<4).map { snapPane("s\($0)") },
                focusedPaneIndex: 2
            )
            let afterFocus = focusShift.sanitized(paneCap: 5) { $0.resumeId != "s0" }
            record("restore: focus follows content when an earlier pane is dropped",
                   afterFocus.focusedPaneIndex == 1
                       && afterFocus.panes[1].content == .session(resumeId: "s2"),
                   "focus=\(afterFocus.focusedPaneIndex) panes=\(afterFocus.panes.map(\.content))")

            let overFocus = SessionRestoreSnapshot(
                sessions: [snapSession("only")],
                panes: [snapPane("only")],
                focusedPaneIndex: 9
            )
            let afterClamp = overFocus.sanitized(paneCap: 5, sessionIsResumable: always)
            record("restore: focus is clamped when it points past surviving panes",
                   afterClamp.focusedPaneIndex == 0)

            let dup = SessionRestoreSnapshot(
                sessions: [snapSession("same")],
                panes: [snapPane("same", 111), snapPane("same", 222)],
                focusedPaneIndex: 1
            )
            let afterDup = dup.sanitized(paneCap: 5, sessionIsResumable: always)
            record("restore: duplicate resumeId keeps only the leftmost pane",
                   afterDup.panes.count == 1 && afterDup.panes[0].width == 111)

            let capped = SessionRestoreSnapshot(
                sessions: (0..<4).map { snapSession("c\($0)") },
                panes: (0..<4).map { snapPane("c\($0)", CGFloat(100 + $0)) },
                focusedPaneIndex: 0
            )
            let afterCap = capped.sanitized(paneCap: 2, sessionIsResumable: always)
            record("restore: panes beyond the cap are dropped, not the whole snapshot",
                   afterCap.panes.count == 2)
            let referenced = Set(afterCap.panes.compactMap { pane -> String? in
                if case .session(let id) = pane.content { return id }
                return nil
            })
            // A pane lost to the cap demotes its session to a dormant row now
            // rather than erasing it — the whole point of restoring the open
            // block and not just the strip. Assert BOTH halves: the sessions
            // survive, and the panes really were capped, or a sanitize that
            // stopped capping would read as this rule working.
            record("restore: a session stranded by the cap survives as an unpaned row",
                   afterCap.sessions.map(\.resumeId) == ["c0", "c1", "c2", "c3"]
                       && referenced.sorted() == ["c0", "c1"],
                   "sessions=\(afterCap.sessions.map(\.resumeId)) paned=\(referenced.sorted())")

            let launcherOnly = SessionRestoreSnapshot(
                sessions: [snapSession("gone")],
                panes: [snapPane(nil), snapPane("gone")],
                focusedPaneIndex: 0
            )
            let afterLauncherOnly = launcherOnly.sanitized(paneCap: 5) { _ in false }
            record("restore: no surviving session pane collapses the snapshot to empty",
                   afterLauncherOnly.isEmpty && afterLauncherOnly.panes.isEmpty
                       && afterLauncherOnly.sessions.isEmpty
                       && afterLauncherOnly.focusedPaneIndex == 0,
                   "panes=\(afterLauncherOnly.panes.count) sessions=\(afterLauncherOnly.sessions.count)")

            // A strip of nothing but launchers still collapses even when its
            // session is alive on disk, and this is the boundary that was moved
            // and moved back: basing the collapse on a surviving SESSION would
            // keep this snapshot, and the launch it produces has no shim, so
            // the quit prompt that writes the snapshot never fires again. The
            // fixture must be launcher-only for real — reusing `launcherOnly`
            // above does not test this, because that one carries a session pane.
            let trueLauncherOnly = SessionRestoreSnapshot(
                sessions: [snapSession("live")],
                panes: [snapPane(nil), snapPane(nil)],
                focusedPaneIndex: 1
            )
            let afterTrueLauncherOnly = trueLauncherOnly.sanitized(paneCap: 5, sessionIsResumable: always)
            record("restore: a launcher-only strip collapses even when its session survives",
                   afterTrueLauncherOnly.isEmpty && afterTrueLauncherOnly.sessions.isEmpty
                       && afterTrueLauncherOnly.panes.isEmpty,
                   "sessions=\(afterTrueLauncherOnly.sessions.map(\.resumeId)) "
                       + "panes=\(afterTrueLauncherOnly.panes.count)")

            // The unpaned survivor rule, in the shape that isolates it from
            // the cap: two resumable sessions, only one of them paned. The
            // unpaned one is kept as a dormant row and the strip still holds a
            // session pane, so nothing collapses.
            let unpanedSurvivor = SessionRestoreSnapshot(
                sessions: [snapSession("paned"), snapSession("unpaned")],
                panes: [snapPane("paned")],
                focusedPaneIndex: 0
            )
            let afterUnpaned = unpanedSurvivor.sanitized(paneCap: 5, sessionIsResumable: always)
            record("restore: a session no pane refers to is kept, not dropped",
                   afterUnpaned.sessions.map(\.resumeId) == ["paned", "unpaned"]
                       && afterUnpaned.panes.count == 1,
                   "sessions=\(afterUnpaned.sessions.map(\.resumeId)) panes=\(afterUnpaned.panes.count)")

            var mismatched = original
            mismatched.version = SessionRestoreSnapshot.currentVersion + 1
            record("restore: a version mismatch is discarded as empty",
                   mismatched.sanitized(paneCap: 5, sessionIsResumable: always).isEmpty)

            let onePane = SessionRestoreSnapshot(
                sessions: [snapSession("solo")],
                panes: [snapPane("solo")],
                focusedPaneIndex: 0
            )
            record("restore: isEmpty is false for a snapshot with one session pane",
                   !onePane.isEmpty)

            let ghostPath = "/nonexistent-probe-path-9f3a"
            let remoteGhost = snapSession("remote-ghost", origin: .remote(host: "nowhere", path: ghostPath))
            // Can't verify ≠ gone: SSH sessions are accepted without a local check.
            record("restore: resumableOnDisk keeps a remote session without filesystem access",
                   SessionRestoreSnapshot.resumableOnDisk(remoteGhost))
            let localGhost = snapSession("local-ghost", origin: .local(path: ghostPath))
            record("restore: resumableOnDisk rejects a local session on a nonexistent path",
                   !SessionRestoreSnapshot.resumableOnDisk(localGhost))

            // The directory guard short-circuits the two assertions above, so
            // on their own they never reach the transcript lookup — replacing
            // `sessionFileExists` with `return true` left the whole suite
            // green. Point at a directory that DOES exist so the JSONL check
            // is the only thing left to decide the answer, and write a real
            // transcript to pin the true branch.
            //
            // These no longer pin the FOLDER ENCODING, and the widening is
            // deliberate: since `sessionFileExists` gained the relocation scan,
            // deleting its whole `encodedFolderCandidates` loop leaves all
            // four of these green, because the scan finds the file wherever it
            // sits. What survives is the weaker property — a transcript exists
            // for this id, or it does not. Nothing pins the encoded loop here
            // and nothing needs to: for a `Bool` answer it is purely a fast
            // path, so deleting it changes no result. (The precedence
            // assertion in the relocation block pins the equivalent ordering
            // in `ShimProcess.jsonlPath`, where the loop DOES decide which
            // path comes back — that is a different function, not a transfer
            // of coverage to this one.)
            let realDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CanopyProbe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
            let presentId = UUID().uuidString
            record("restore: an existing cwd with no transcript is still not resumable",
                   !SessionRestoreSnapshot.resumableOnDisk(
                       snapSession(presentId, origin: .local(path: realDir.path))))

            let encoded = ClaudeSessionHistory.encodedFolderCandidates(for: realDir.path)[0]
            let projectDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects").appendingPathComponent(encoded)
            try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let transcript = projectDir.appendingPathComponent("\(presentId).jsonl")
            try? Data("{}\n".utf8).write(to: transcript)
            record("restore: a local session with a transcript on disk is resumable",
                   SessionRestoreSnapshot.resumableOnDisk(
                       snapSession(presentId, origin: .local(path: realDir.path))),
                   "looked under \(encoded)")
            try? FileManager.default.removeItem(at: transcript)
            record("restore: deleting the transcript makes it unresumable again",
                   !SessionRestoreSnapshot.resumableOnDisk(
                       snapSession(presentId, origin: .local(path: realDir.path))))
            try? FileManager.default.removeItem(at: projectDir)

            // A session that entered a worktree mid-run is captured under the
            // directory it was SPAWNED in, while the CLI has moved its
            // transcript to the worktree's encoded folder. Before the scan
            // fallback that read as "the transcript is gone" and the pane was
            // dropped from the restore — the session did not come back at all,
            // which is why it never got as far as showing a stale label.
            let movedDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
                .appendingPathComponent("-canopy-probe-moved-\(presentId)")
            try? FileManager.default.createDirectory(at: movedDir, withIntermediateDirectories: true)
            let movedTranscript = movedDir.appendingPathComponent("\(presentId).jsonl")
            try? Data("{}\n".utf8).write(to: movedTranscript)
            record("restore: a session whose transcript moved to another folder is still resumable",
                   SessionRestoreSnapshot.resumableOnDisk(
                       snapSession(presentId, origin: .local(path: realDir.path))),
                   "no encoding of \(realDir.path) names \(movedDir.lastPathComponent)")
            try? FileManager.default.removeItem(at: movedTranscript)
            try? FileManager.default.removeItem(at: movedDir)
            try? FileManager.default.removeItem(at: realDir)

            // Duplicate session entries: capture cannot emit them, but the
            // blob is hand-editable JSON and sanitize is the laundering point.
            // Distinguishable twins: field-identical ones make "keeps only the
            // first" indistinguishable from "keeps only the last", and the rule
            // list states the first. A count alone pins neither.
            let dupSessions = SessionRestoreSnapshot(
                sessions: [snapSession("twin", title: "First"), snapSession("twin", title: "Second")],
                panes: [snapPane("twin")],
                focusedPaneIndex: 0
            )
            let afterDupSessions = dupSessions.sanitized(paneCap: 5, sessionIsResumable: always)
            record("restore: duplicate session entries collapse to the FIRST",
                   afterDupSessions.sessions.count == 1
                       && afterDupSessions.sessions.first?.title == "First",
                   "got \(afterDupSessions.sessions.map(\.title))")

            // A launcher-only strip must read as empty at BOTH ends, so the
            // quit path normalizes the window frame instead of saving a
            // snapshot the next launch will reject.
            record("restore: a launcher-only strip is empty, so it is never saved",
                   SessionRestoreSnapshot(sessions: [], panes: [snapPane(nil)], focusedPaneIndex: 0).isEmpty)
            // This kills `sessions.isEmpty` as a stand-in for the predicate:
            // sessions with no session pane are still EMPTY, the boundary that
            // was widened and reverted. `panes.isEmpty` is killed by the record
            // above, and the NOT-empty direction by `onePane`, further up.
            record("restore: sessions with no session pane are still empty",
                   SessionRestoreSnapshot(sessions: [snapSession("only")],
                                          panes: [snapPane(nil)],
                                          focusedPaneIndex: 0).isEmpty)

            // The capture half, pinned on its own, plus the round-trip
            // property that matters at the seam: what
            // capture emits must already survive sanitize untouched. A capture
            // that needed cleaning up would mean the two halves disagree about
            // the shape, and the disagreement would only ever show as silently
            // missing panes on somebody's next launch.
            let capStore = SessionStore()
            let capLocal = OpenSession(
                origin: .local(cwd),
                resumeId: "cap-local",
                title: "Cap Local",
                project: "ProjectCap",
                status: .live,
                permissionMode: .plan
            )
            let capRemote = OpenSession(
                origin: .remote(host: "mbp", path: URL(fileURLWithPath: "/remote/dir")),
                resumeId: "cap-remote",
                title: "Cap Remote",
                project: "mbp:dir",
                status: .live
            )
            // A third session that is open and NOT paned — the case capture
            // used to drop on the floor. Seeded in the MIDDLE, deliberately:
            // seeded last, "sidebar row order" and "paned first, then unpaned"
            // produce the identical list, so the order assertion below would
            // pass under an implementation that walked `panes` and appended the
            // leftovers. From the middle only row order gives this answer.
            let capUnpaned = OpenSession(
                origin: .local(cwd),
                resumeId: "cap-unpaned",
                title: "Cap Unpaned",
                project: "ProjectCap",
                status: .dormant
            )
            capStore._probeSeedOpenSessions([capLocal, capUnpaned, capRemote])
            capStore.openInFocusedPane(capLocal.id)
            _ = capStore.openInNewPane(capRemote.id)
            _ = capStore.openLauncherInNewPane()
            let captured = capStore.captureRestoreSnapshot()

            record("restore: capture mirrors the pane strip in order, launcher included",
                   captured.panes.count == 3
                       && captured.panes[0].content == .session(resumeId: "cap-local")
                       && captured.panes[1].content == .session(resumeId: "cap-remote")
                       && captured.panes[2].content == .launcher
                       && captured.focusedPaneIndex == 2,
                   "panes=\(captured.panes.map(\.content)) focus=\(captured.focusedPaneIndex)")
            record("restore: capture stores every OPEN session, in sidebar row order",
                   captured.sessions.map(\.resumeId) == ["cap-local", "cap-unpaned", "cap-remote"],
                   "got \(captured.sessions.map(\.resumeId))")
            // The unpaned one must not acquire a pane on the way through, or
            // restore would mount a shim for a session that had none. This one
            // is close to tautological — `panesOut` is built by iterating
            // `panes`, so only a capture that synthesised panes inside the
            // session loop could fail it. Kept as a cheap statement of intent,
            // not counted on as coverage.
            record("restore: capture leaves an unpaned session out of the pane strip",
                   !captured.panes.contains { $0.content == .session(resumeId: "cap-unpaned") })

            // On the "row order vs pane order" question the fixture cannot go
            // further, and the reason is a property rather than a gap: the two
            // orders are held in lockstep for PANED sessions by
            // `syncPaneOrderToRows` / `moveRowFollowingPaneAssignment`, and a
            // drag re-sorts the panes to match the rows, so no sequence of
            // operations makes them disagree. What the middle-seeded fixture
            // above pins is the only part that is decidable — where an UNPANED
            // session lands — which is exactly the part this PR added.

            // The dedupe on capture, which `sanitized`'s doc leans on by name
            // ("capture cannot emit a duplicate"). A stated invariant with
            // nothing behind it is the shape this repo has been bitten by.
            let dupCapStore = SessionStore()
            let dupA = OpenSession(origin: .local(cwd), resumeId: "same-id",
                                   title: "Dup A", project: "ProjectCap", status: .live)
            let dupB = OpenSession(origin: .local(cwd), resumeId: "same-id",
                                   title: "Dup B", project: "ProjectCap", status: .live)
            dupCapStore._probeSeedOpenSessions([dupA, dupB])
            dupCapStore.openInFocusedPane(dupA.id)
            let dupCaptured = dupCapStore.captureRestoreSnapshot()
            record("restore: capture emits one session per resumeId",
                   dupCaptured.sessions.map(\.title) == ["Dup A"],
                   "got \(dupCaptured.sessions.map(\.title))")
            // By resumeId, not by index: `record` does not abort, so a hard
            // subscript on a regressed capture traps here and the probe job
            // reports "the app never launched" instead of "an assertion failed".
            let capturedRemote = captured.sessions.first { $0.resumeId == "cap-remote" }
            record("restore: capture carries permission mode and a remote origin across",
                   captured.sessions.first?.permissionMode == .plan
                       && capturedRemote?.origin == .remote(host: "mbp", path: "/remote/dir"),
                   "mode=\(String(describing: captured.sessions.first?.permissionMode)) "
                       + "origin=\(String(describing: capturedRemote?.origin))")
            record("restore: a captured snapshot already survives sanitize unchanged",
                   captured.sanitized(paneCap: SessionStore.paneAbsoluteCap, sessionIsResumable: always)
                       == captured)

            // Field-by-field, not two hand-picked ones. Mutating title/project
            // into each other, or nilling model/effortLevel/providerId, left
            // the suite green — and providerId is the field that exists so the
            // provider's authToken never reaches the JSON, so losing it
            // silently drops the user's custom backend on restore.
            let capFull = OpenSession(
                origin: .local(cwd),
                resumeId: "cap-full",
                title: "Full Title",
                project: "FullProject",
                status: .live,
                lastActiveAt: Date(timeIntervalSince1970: 776_000_000),
                permissionMode: .plan,
                model: "opus",
                effortLevel: "high",
                customApi: ModelProvider(id: "provider-xyz", name: "Probe")
            )
            let capStore2 = SessionStore()
            capStore2._probeSeedOpenSessions([capFull])
            capStore2.openInFocusedPane(capFull.id)
            let cf = capStore2.captureRestoreSnapshot().sessions.first
            record("restore: capture carries every restorable session field",
                   cf?.resumeId == "cap-full" && cf?.title == "Full Title"
                       && cf?.project == "FullProject" && cf?.permissionMode == .plan
                       && cf?.model == "opus" && cf?.effortLevel == "high"
                       && cf?.providerId == "provider-xyz"
                       && cf?.origin == .local(path: cwd.path)
                       && cf?.lastActiveAt == Date(timeIntervalSince1970: 776_000_000),
                   "got \(String(describing: cf))")

            // Widths are copied, not recomputed — assert against whatever
            // `normalizePaneWeightsToVisualWidths()` produced rather than a
            // literal, so the assertion can't be environment-dependent.
            record("restore: capture copies each pane's width verbatim",
                   captured.panes.map(\.width) == capStore.panes.map(\.preferredWidth))

            // A teleported origin appears on no other fixture, so swapping its
            // two associated values survived every existing assertion.
            let capTele = OpenSession(
                origin: .teleportedFrom(cloudSessionId: "cloud-77", localPath: cwd),
                resumeId: "cap-tele",
                title: "Teleported",
                project: "ProjectTele",
                status: .live
            )
            let capStore3 = SessionStore()
            capStore3._probeSeedOpenSessions([capTele])
            capStore3.openInFocusedPane(capTele.id)
            let teleOrigin = capStore3.captureRestoreSnapshot().sessions.first?.origin
            record("restore: a teleported origin keeps its cloud id and path in order",
                   teleOrigin == .teleported(cloudSessionId: "cloud-77", path: cwd.path),
                   "got \(String(describing: teleOrigin))")

            // `.dormant` is only honest while nothing is mounted, so all three
            // routes that hand a session to a pane have to wake it. Assert the
            // state first: `capUnpaned` was built `.dormant` by the fixture, so
            // without this line the promotion assertion below would pass
            // vacuously on a session that was already `.spawning`.
            record("restore: an unpaned session is still dormant before a pane takes it",
                   capUnpaned.status == .dormant)
            capStore.openInFocusedPane(capUnpaned.id)
            record("restore: taking a dormant session into a pane starts it",
                   capUnpaned.status == .spawning,
                   "got \(String(describing: capUnpaned.status))")
            // The negative half: a session that was NOT dormant must come
            // through untouched. Dropping the `.dormant` clause from
            // `startIfDormant`'s guard would reset every session to `.spawning`
            // on every plain sidebar click — SpawningOverlay and a working dot
            // on a session that never stopped running.
            //
            // Read the routes, not the adjacency: `capLocal` was paned by the
            // SEED branch back at fixture setup and `capRemote` by the APPEND,
            // neither by the `openInFocusedPane(capUnpaned.id)` call just above.
            // One `.live` session is not enough, but be precise about which
            // mutation shows it. Deleting the `.dormant` clause from
            // `startIfDormant`'s single guard IS caught by `capLocal` alone,
            // since the seed branch calls it too. What `capLocal` alone misses
            // is a leak introduced at the CALL SITES — promotion inlined
            // without the guard at the content-swap and append branches, with
            // the seed branch left intact; measured, and green with only
            // `capLocal`. The content-swap branch is covered by `swapLive`.
            record("restore: the seed branch leaves a non-dormant session alone",
                   capLocal.status == .live,
                   "got \(String(describing: capLocal.status))")
            record("restore: the new-pane branch leaves a non-dormant session alone",
                   capRemote.status == .live,
                   "got \(String(describing: capRemote.status))")
            // Route 2 of 3: the append, which has its own construction site.
            // Assert the return value too — this fixture depends on staying
            // under `paneAbsoluteCap`, and a bounce would otherwise be reported
            // as "the wake didn't happen".
            let wakeNew = OpenSession(
                origin: .local(cwd),
                resumeId: "wake-new",
                title: "Wake New",
                project: "ProjectCap",
                status: .dormant
            )
            capStore._probeSeedOpenSessions([capLocal, capRemote, capUnpaned, wakeNew])
            let wakeNewTookAPane = capStore.openInNewPane(wakeNew.id)
            record("restore: opening a dormant session in a NEW pane starts it too",
                   wakeNewTookAPane && wakeNew.status == .spawning,
                   "tookPane=\(wakeNewTookAPane) status=\(String(describing: wakeNew.status))")
            // Route 3 of 3: the empty-panes seed branch. Reached whenever a
            // session is assigned to an empty strip — `closeSession`'s own
            // promotion (the dominant one, and no click on the dormant row at
            // all), Cmd+Ctrl+1..9, or a click after the strip was emptied by
            // hand. Never by a restore coming back with no panes, as an earlier
            // draft of this comment said: `sanitized`'s `hasSessionPane` guard
            // makes that impossible. Needs its own store, not `capStore`,
            // which already holds several.
            let seedStore = SessionStore()
            let wakeSeed = OpenSession(
                origin: .local(cwd),
                resumeId: "wake-seed",
                title: "Wake Seed",
                project: "ProjectCap",
                status: .dormant
            )
            seedStore._probeSeedOpenSessions([wakeSeed])
            seedStore.openInFocusedPane(wakeSeed.id)
            record("restore: the empty-panes seed branch starts a dormant session too",
                   seedStore.panes.count == 1 && wakeSeed.status == .spawning,
                   "panes=\(seedStore.panes.count) status=\(String(describing: wakeSeed.status))")
            // The content-swap branch's negative, which the two `.live`
            // assertions above cannot reach: `seedStore` now has a pane, so
            // this call swaps content rather than seeding.
            let swapLive = OpenSession(
                origin: .local(cwd),
                resumeId: "swap-live",
                title: "Swap Live",
                project: "ProjectCap",
                status: .live
            )
            seedStore._probeSeedOpenSessions([wakeSeed, swapLive])
            seedStore.openInFocusedPane(swapLive.id)
            record("restore: the content-swap branch leaves a non-dormant session alone",
                   swapLive.status == .live,
                   "got \(String(describing: swapLive.status))")

            // `startIfDormant` sits BELOW `openInNewPane`'s cap guard, and the
            // ordering is the whole point: promoted above it, a Cmd+click that
            // bounces off the cap would leave the session `.spawning` with no
            // pane and no shim — the permanently breathing "working" dot
            // `.dormant` exists to prevent, and unrecoverable without paning it.
            // The cap comes from the constant, never a literal: it moved 5 → 6
            // once already and a re-typed value asserts only that nobody
            // changed their mind.
            let capStore4 = SessionStore()
            let bounced = OpenSession(
                origin: .local(cwd),
                resumeId: "bounced",
                title: "Bounced",
                project: "ProjectCap",
                status: .dormant
            )
            capStore4._probeSeedOpenSessions([bounced])
            // Bounded, not `while panes.count < cap`: that loop's termination
            // depends on `openLauncherInNewPane` always succeeding below the
            // cap, and if a guard is ever added there the probe hangs to CI's
            // `timeout-minutes`, which reports as "the app never launched" —
            // the one bucket ci.yml's summary-line check exists to keep apart.
            for _ in 0..<SessionStore.paneAbsoluteCap {
                _ = capStore4.openLauncherInNewPane()
            }
            let bounceTookAPane = capStore4.openInNewPane(bounced.id)
            record("restore: a dormant session bounced by the pane cap stays dormant",
                   !bounceTookAPane && bounced.status == .dormant
                       && capStore4.panes.count == SessionStore.paneAbsoluteCap,
                   "tookPane=\(bounceTookAPane) status=\(String(describing: bounced.status)) "
                       + "panes=\(capStore4.panes.count)")

            // `.dormant`'s whole reason to exist over reusing `.spawning` is
            // that it reads as `.idle` rather than as the breathing cyan of a
            // working session. That claim lives in a fall-through — `of` has no
            // `.dormant` arm — so nothing would fail if someone added one.
            let dormantForDot = OpenSession(
                origin: .local(cwd),
                resumeId: "dot-dormant",
                title: "Dot",
                project: "ProjectCap",
                status: .dormant
            )
            record("restore: a dormant session reads as idle, not working",
                   SessionActivity.of(dormantForDot, isUnread: false) == .idle,
                   "got \(SessionActivity.of(dormantForDot, isUnread: false))")

            // `applyRestoreSnapshot` was long documented as un-probe-able
            // because `resumableOnDisk` hits the real filesystem and would drop
            // synthetic fixtures. That is true only of LOCAL sessions: a remote
            // one is accepted unchecked (asserted above), so a remote-origin
            // fixture drives the whole apply path with no filesystem setup at
            // all. What that buys is the one line this feature is: the
            // paned/unpaned status split, which every other assertion here
            // leaves free to be inverted.
            let applyStore = SessionStore()
            applyStore.applyRestoreSnapshot(SessionRestoreSnapshot(
                sessions: [
                    snapSession("ap-paned", origin: .remote(host: "h", path: "/a")),
                    snapSession("ap-unpaned", origin: .remote(host: "h", path: "/b")),
                ],
                panes: [snapPane("ap-paned", 700)],
                focusedPaneIndex: 0
            ))
            let applyPaned = applyStore.openSessions.first { $0.resumeId == "ap-paned" }
            let applyUnpaned = applyStore.openSessions.first { $0.resumeId == "ap-unpaned" }
            record("restore: apply gives the paned session a shim-bound .spawning",
                   applyPaned?.status == .spawning,
                   "got \(String(describing: applyPaned?.status))")
            record("restore: apply gives the unpaned session .dormant",
                   applyUnpaned?.status == .dormant,
                   "got \(String(describing: applyUnpaned?.status))")
            record("restore: apply keeps the snapshot's session order and panes only the paned one",
                   applyStore.openSessions.map(\.resumeId) == ["ap-paned", "ap-unpaned"]
                       && applyStore.panes.count == 1
                       && applyStore.panes.first?.preferredWidth == 700,
                   "sessions=\(applyStore.openSessions.map(\.resumeId)) "
                       + "panes=\(applyStore.panes.count)")

            // The second round trip, which is what a user gets by restoring and
            // quitting again without touching anything. Nothing else pins that
            // dormant rows survive it — capture's own seam assertion runs on a
            // hand-built store, not on one apply produced.
            let reCaptured = applyStore.captureRestoreSnapshot()
            record("restore: apply then capture reproduces the sessions and the strip",
                   reCaptured.sessions.map(\.resumeId) == ["ap-paned", "ap-unpaned"]
                       && reCaptured.panes.map(\.content) == [.session(resumeId: "ap-paned")],
                   "sessions=\(reCaptured.sessions.map(\.resumeId)) panes=\(reCaptured.panes.map(\.content))")

            // A snapshot that sanitize collapses leaves the store untouched.
            // What this does NOT pin is `applyRestoreSnapshot`'s own
            // `guard !clean.isEmpty` — measured: deleting that guard keeps the
            // suite green, because `sanitized` has already returned an empty
            // snapshot by then, so the code below it builds nothing either way.
            // The guard's remaining job is the log line, and a log line is not
            // reachable from here. Nor does it kill apply reading the RAW
            // snapshot — also measured; that mutation is MASKED by the guard
            // itself, since a launcher-only snapshot is `isEmpty` either way.
            // The `applyLaunderStore` fixture below is what pins the
            // sanitize call.
            let applyEmptyStore = SessionStore()
            applyEmptyStore.applyRestoreSnapshot(SessionRestoreSnapshot(
                sessions: [snapSession("ap-none", origin: .remote(host: "h", path: "/a"))],
                panes: [snapPane(nil)],
                focusedPaneIndex: 0
            ))
            record("restore: apply restores nothing when sanitize collapses the snapshot",
                   applyEmptyStore.openSessions.isEmpty && applyEmptyStore.panes.isEmpty,
                   "sessions=\(applyEmptyStore.openSessions.count) panes=\(applyEmptyStore.panes.count)")

            // Apply must launder its input, not trust it: a pane whose session
            // is unresumable has to be gone from the strip. Skipping the
            // `sanitized` call keeps the whole suite green otherwise — the
            // pure assertions above test `sanitized` in isolation and never
            // establish that apply calls it.
            let applyLaunderStore = SessionStore()
            applyLaunderStore.applyRestoreSnapshot(SessionRestoreSnapshot(
                sessions: [
                    snapSession("ap-ghost", origin: .local(path: "/nonexistent-probe-path-9f3a")),
                    snapSession("ap-alive", origin: .remote(host: "h", path: "/a")),
                ],
                panes: [snapPane("ap-ghost", 300), snapPane("ap-alive", 400)],
                focusedPaneIndex: 1
            ))
            record("restore: apply drops a pane whose session is unresumable",
                   applyLaunderStore.openSessions.map(\.resumeId) == ["ap-alive"]
                       && applyLaunderStore.panes.count == 1
                       && applyLaunderStore.panes.first?.preferredWidth == 400,
                   "sessions=\(applyLaunderStore.openSessions.map(\.resumeId)) "
                       + "panes=\(applyLaunderStore.panes.map(\.preferredWidth))")

            // Two paned sessions, the pane order REVERSED against the session
            // order, so the pane→session mapping and the focus index are both
            // decidable. With one pane neither is: any mapping and any clamp
            // give the same answer.
            let applyOrderStore = SessionStore()
            applyOrderStore.applyRestoreSnapshot(SessionRestoreSnapshot(
                sessions: [
                    snapSession("ap2-a", origin: .remote(host: "h", path: "/a")),
                    snapSession("ap2-b", origin: .remote(host: "h", path: "/b")),
                ],
                panes: [snapPane("ap2-b", 400), snapPane("ap2-a", 500)],
                focusedPaneIndex: 1
            ))
            let ap2a = applyOrderStore.openSessions.first { $0.resumeId == "ap2-a" }
            let ap2b = applyOrderStore.openSessions.first { $0.resumeId == "ap2-b" }
            record("restore: apply binds each pane to ITS session, not to whichever came first",
                   ap2b.map { applyOrderStore.paneIndex(forSession: $0.id) } == 0
                       && ap2a.map { applyOrderStore.paneIndex(forSession: $0.id) } == 1,
                   "b=\(String(describing: ap2b.map { applyOrderStore.paneIndex(forSession: $0.id) })) "
                       + "a=\(String(describing: ap2a.map { applyOrderStore.paneIndex(forSession: $0.id) }))")
            record("restore: apply carries the stored focus rather than resetting to 0",
                   applyOrderStore.focusedPaneIndex == 1
                       && ap2a.map { applyOrderStore.selection == .session($0.id) } == true,
                   "focus=\(applyOrderStore.focusedPaneIndex)")

            // The bypass-permissions clamp, which `clampedPermissionMode`'s own
            // doc calls the third route to a `PermissionMode` and the only one
            // whose input is hand-editable JSON.
            //
            // The opt-in is FORCED off for the duration, and that is the whole
            // assertion: expressed against whatever the machine happens to
            // have (`clamped == optIn ? .bypassPermissions : .acceptEdits`)
            // this passes with the clamp deleted on any machine that has the
            // opt-in ON — measured, on this one.
            //
            // `defer`, not two statements after the read, and not because a
            // trap is likely: this write goes through `CanopySettings.save()`
            // to `~/Library/Application Support/Canopy/settings.json`, which is
            // named after the APP and so is shared with the installed Release
            // build. Every other real key the probe touches is a per-bundle-id
            // UserDefaults domain; this one is not, so a trap here would leave
            // the user's installed Canopy with its bypass opt-in forced off.
            // `defaultPermissionMode` is restored too, because the opt-in's
            // `didSet` clamps it as a side effect.
            let savedBypassOptIn = CanopySettings.shared.allowDangerouslySkipPermissions
            let savedDefaultMode = CanopySettings.shared.defaultPermissionMode
            defer {
                CanopySettings.shared.allowDangerouslySkipPermissions = savedBypassOptIn
                CanopySettings.shared.defaultPermissionMode = savedDefaultMode
            }
            CanopySettings.shared.allowDangerouslySkipPermissions = false
            let applyClampStore = SessionStore()
            applyClampStore.applyRestoreSnapshot(SessionRestoreSnapshot(
                sessions: [snapSession("ap-bypass",
                                       origin: .remote(host: "h", path: "/a"),
                                       permissionMode: .bypassPermissions)],
                panes: [snapPane("ap-bypass")],
                focusedPaneIndex: 0
            ))
            let clamped = applyClampStore.openSessions.first?.permissionMode
            record("restore: apply clamps a stored .bypassPermissions when the opt-in is off",
                   clamped == .acceptEdits,
                   "got \(String(describing: clamped))")
        }

        // Summary. Note `grep -c 'record('` does NOT equal this count: the
        // `func record(` definition matches too, and a few call sites only
        // fire on failure. Read the printed number, don't count the source.
        //
        // CI parses this line and fails the job when `pass` drops
        // below `EXPECTED_ASSERTIONS` in .github/workflows/ci.yml — the exit
        // code cannot tell "every assertion passed" from "half of them never
        // ran", and this function is long enough that a dropped block is a
        // realistic way to lose coverage silently. Removing assertions on
        // purpose means lowering that number in the same commit; adding them
        // needs no change. Keep the format in step with the awk there.
        //
        // MARK: - Session title generation (out-of-session route)
        //
        // Every bound below is derived from the production constant. The two
        // signal thresholds are named constants *because* of this rule — they
        // were inline literals, and the fixtures re-typed them, which asserts
        // only that nobody changed their mind and fails for the wrong reason
        // when the value legitimately moves (the `paneAbsoluteCap` trap).
        do {
            let gen = SessionTitleGenerator.self

            // --- hasEnoughSignal: both sides of each condition -------------
            record("titlegen: no prompts has no signal",
                   !gen.hasEnoughSignal(prompts: []))
            let atThreshold = String(repeating: "a", count: gen.minimumSignalLength)
            record("titlegen: one prompt at the length threshold has signal",
                   gen.hasEnoughSignal(prompts: [atThreshold]))
            record("titlegen: one prompt below the threshold has none",
                   !gen.hasEnoughSignal(prompts: [String(atThreshold.dropLast())]))
            // The count condition is independent of the length one: enough
            // short prompts pass even though none could on its own.
            record("titlegen: enough short prompts have signal",
                   gen.hasEnoughSignal(
                       prompts: Array(repeating: "hi", count: gen.minimumSignalPromptCount)))
            record("titlegen: one below the count threshold has none",
                   !gen.hasEnoughSignal(
                       prompts: Array(repeating: "hi", count: gen.minimumSignalPromptCount - 1)))
            // Whitespace is not signal, on BOTH branches. It used to be
            // stripped only on the single-prompt one, so several blank prompts
            // reported signal — the exact degenerate case the gate is about.
            record("titlegen: whitespace is not signal (length branch)",
                   !gen.hasEnoughSignal(prompts: [String(repeating: " ", count: 100)]))
            record("titlegen: whitespace is not signal (count branch)",
                   !gen.hasEnoughSignal(
                       prompts: Array(repeating: "  \n ", count: gen.minimumSignalPromptCount + 1)))

            // --- sanitize -------------------------------------------------
            record("titlegen: sanitize trims and takes the first line",
                   gen.sanitize("  Fix the login bug  \nsecond line") == "Fix the login bug")
            record("titlegen: sanitize strips straight quotes",
                   gen.sanitize("\"Quoted title\"") == "Quoted title")
            // Regression pin: the opening list once held U+201D (the CLOSING
            // curly quote) and no U+201C at all, so this lost its closing quote
            // and kept its opening one.
            record("titlegen: sanitize strips curly double quotes at both ends",
                   gen.sanitize("\u{201C}Fix login\u{201D}") == "Fix login")
            record("titlegen: sanitize strips curly single quotes at both ends",
                   gen.sanitize("\u{2018}Fix login\u{2019}") == "Fix login")
            record("titlegen: sanitize strips corner brackets",
                   gen.sanitize("\u{300C}Fix login\u{300D}") == "Fix login")
            record("titlegen: sanitize strips a trailing period",
                   gen.sanitize("Refactor the parser.") == "Refactor the parser")
            record("titlegen: sanitize skips leading blank lines",
                   gen.sanitize("\n\n  Real title") == "Real title")
            record("titlegen: sanitize rejects empty output",
                   gen.sanitize("   \n  ") == nil)
            // Over-long output is prose, and is rejected rather than truncated.
            // Both sides of the bound.
            let atMax = String(repeating: "t", count: gen.maxTitleLength)
            record("titlegen: sanitize accepts output at the length cap",
                   gen.sanitize(atMax) == atMax)
            record("titlegen: sanitize rejects output past the length cap",
                   gen.sanitize(atMax + "t") == nil)
            // The cap only means "reject rather than truncate" while it equals
            // the length the app actually displays. When the two drifted apart,
            // everything in between was accepted here and truncated downstream.
            record("titlegen: the acceptance cap is the displayed length",
                   ShimProcess.truncatedTitle(atMax) == atMax)

            // --- userPrompt -----------------------------------------------
            let long = String(repeating: "x", count: gen.maxPromptLength + 50)
            let wrapped = gen.userPrompt(prompts: [long])
            record("titlegen: userPrompt delimits the messages",
                   wrapped.contains("<messages>") && wrapped.contains("</messages>"))
            record("titlegen: userPrompt truncates each prompt to the cap",
                   !wrapped.contains(String(repeating: "x", count: gen.maxPromptLength + 1)))
            // A regression to "first prompt only" would keep every assertion
            // above green while silently dropping the later-messages input the
            // system prompt is written around.
            let multi = gen.userPrompt(prompts: ["first goal", "later detail"])
            record("titlegen: userPrompt keeps every prompt",
                   multi.contains("first goal") && multi.contains("later detail"))

            // --- arguments ------------------------------------------------
            let args = gen.arguments()
            func valueAfter(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            // Drop this and the CLI goes interactive and hangs to the watchdog.
            record("titlegen: runs non-interactively", args.contains("-p"))
            // Drop this and every title silently burns the default model.
            record("titlegen: pins the cheap model", valueAfter("--model") == gen.model)
            // The persona fix itself. Measured: 9 persona-voiced titles in 200
            // with setting sources loaded, against 10 in the baseline taken
            // before the counter-instruction was added — evidence the wording
            // did not help, not that it loses to every possible wording.
            record("titlegen: setting sources are emptied", valueAfter("--setting-sources") == "")
            // Drop this and the user's MCP servers start on a call they never
            // made — the doc's own stated reason for the flag.
            record("titlegen: MCP config is strict", args.contains("--strict-mcp-config"))
            // Regression pin: a bare `{}` is rejected by the CLI with
            // `mcpServers: Invalid input: expected record, received undefined`.
            record("titlegen: empty MCP config carries the mcpServers key",
                   valueAfter("--mcp-config") == #"{"mcpServers":{}}"#)
            // Pins the flag's VALUE and nothing about its effect — measured
            // twice on CLI 2.1.217, it has none here (see `arguments`' doc).
            // The name says only what is asserted; an earlier name claimed no
            // tools were auto-approved, which the second measurement refuted.
            record("titlegen: the tool allowlist argument is empty",
                   valueAfter("--allowed-tools") == "")
            // Replacing the system prompt, not appending — appending leaves the
            // agent framing that invites the model to converse.
            record("titlegen: system prompt replaces rather than appends",
                   args.contains("--system-prompt") && !args.contains("--append-system-prompt"))
            // The real injection defence: a probe run without this system
            // prompt answered the user's question instead of titling it, and a
            // payload told to read a file came back as a title with it in place.
            // Compared against the constant rather than a re-typed fragment, so
            // rewording cannot fail this for the wrong reason.
            record("titlegen: the system prompt is the one that ships",
                   valueAfter("--system-prompt") == gen.systemPrompt)
        }

        // MARK: - The generation decision
        //
        // These rules used to live on six private fields of `ShimProcess`,
        // where the whole suite stayed green with any of them deleted — and two
        // of them ARE this feature's headline claims.
        do {
            typealias Gate = SessionTitleGenerator.TitleGenerationGate
            let cap = SessionTitleGenerator.maxGenerations
            let rich = [String(repeating: "a", count: SessionTitleGenerator.minimumSignalLength)]

            record("titlegate: a rich prompt generates",
                   Gate(userOwnsTitle: false, isRunning: false, generationCount: 0, prompts: rich)
                       .decide() == .generate)
            record("titlegate: a manual rename blocks generation",
                   Gate(userOwnsTitle: true, isRunning: false, generationCount: 0, prompts: rich)
                       .decide() == .doNothing(.userOwnsTitle))
            // Ownership outranks every other reason, so a renamed session can
            // never be talked into generating by some other state.
            record("titlegate: ownership outranks every other block",
                   Gate(userOwnsTitle: true, isRunning: true, generationCount: cap, prompts: [])
                       .decide() == .doNothing(.userOwnsTitle))
            record("titlegate: an in-flight generation blocks a second",
                   Gate(userOwnsTitle: false, isRunning: true, generationCount: 0, prompts: rich)
                       .decide() == .doNothing(.alreadyRunning))
            record("titlegate: no prompts blocks",
                   Gate(userOwnsTitle: false, isRunning: false, generationCount: 0, prompts: [])
                       .decide() == .doNothing(.noPrompts))
            // The cap. Deleting it entirely would spawn one CLI per user turn
            // forever, and nothing else in this suite would notice.
            record("titlegate: the last allowed generation still runs",
                   Gate(userOwnsTitle: false, isRunning: false, generationCount: cap - 1, prompts: rich)
                       .decide() == .generate)
            record("titlegate: the cap blocks the next one",
                   Gate(userOwnsTitle: false, isRunning: false, generationCount: cap, prompts: rich)
                       .decide() == .doNothing(.capReached))
            record("titlegate: a thin opening shows a fallback instead",
                   Gate(userOwnsTitle: false, isRunning: false, generationCount: 0, prompts: ["hi"])
                       .decide() == .installFallback)
            // Cap before signal: an exhausted session must stop installing raw
            // prompts over whatever title it already has.
            record("titlegate: the cap is checked before the signal gate",
                   Gate(userOwnsTitle: false, isRunning: false, generationCount: cap, prompts: ["hi"])
                       .decide() == .doNothing(.capReached))
        }

        // MARK: - SessionTitleStore
        //
        // These write the live UserDefaults domain — there is no separate test
        // domain — so the whole blob is snapshotted and put back. An earlier
        // version cleared only the ownership marks and left two junk titles per
        // run in the developer's real store, which also pushed the entry cap.
        do {
            let snapshot = SessionTitleStore._probeSnapshot()
            defer { SessionTitleStore._probeRestore(snapshot) }

            let sid = UUID().uuidString
            let other = UUID().uuidString

            record("titlestore: a non-UUID id is rejected and says so",
                   !SessionTitleStore.save(title: "No", forSessionId: "not-a-uuid"))
            record("titlestore: an empty title is rejected",
                   !SessionTitleStore.save(title: "", forSessionId: sid))

            record("titlestore: a valid save reports success",
                   SessionTitleStore.save(title: "Auto title", forSessionId: sid))
            record("titlestore: an automatic title is not user-owned",
                   !SessionTitleStore.isUserOwned(sid))

            SessionTitleStore.save(title: "Human title", forSessionId: sid, userOwned: true)
            record("titlestore: a manual rename marks the session user-owned",
                   SessionTitleStore.isUserOwned(sid))
            record("titlestore: a manual rename stores its title",
                   SessionTitleStore.title(forSessionId: sid) == "Human title")

            // The invariant the whole feature rests on: automatic generation
            // runs several times per launch, so it must not be able to demote a
            // name the user typed by saving over it.
            SessionTitleStore.save(title: "Auto again", forSessionId: sid)
            record("titlestore: an automatic save cannot clear the user-owned mark",
                   SessionTitleStore.isUserOwned(sid))

            // Re-keying happens when the CLI replaces a placeholder resume id.
            // The mark travels because it lives inside the record — when it was
            // a parallel set, the two could disagree and housekeeping resolved
            // that disagreement by deleting the mark.
            SessionTitleStore.migrate(fromSessionId: sid, toSessionId: other)
            record("titlestore: migrate carries the user-owned mark",
                   SessionTitleStore.isUserOwned(other) && !SessionTitleStore.isUserOwned(sid))
            record("titlestore: migrate carries the title",
                   SessionTitleStore.title(forSessionId: other) == "Auto again"
                   && SessionTitleStore.title(forSessionId: sid) == nil)

            SessionTitleStore.clearUserOwned(other)
            record("titlestore: clearUserOwned releases the session",
                   !SessionTitleStore.isUserOwned(other))
            record("titlestore: clearUserOwned keeps the title",
                   SessionTitleStore.title(forSessionId: other) == "Auto again")
        }

        // MARK: - Title-generation environment
        //
        // Added because a reviewer measured that commenting out the entrypoint
        // scrub left the whole suite green: the fix for a real bug (a sidebar
        // row per generation) was ungated while the floor went up by 74.
        do {
            let key = "CLAUDE_CODE_ENTRYPOINT"
            let prior = ProcessInfo.processInfo.environment[key]
            defer {
                if let prior { setenv(key, prior, 1) } else { unsetenv(key) }
            }
            setenv(key, "claude-vscode", 1)
            let cli = URL(fileURLWithPath: "/usr/local/bin/claude")
            let env = SessionTitleGenerator.environment(customApi: nil, cli: cli)
            // The transcript this feature writes stays out of the sidebar only
            // because `isAutomated` reads the CLI's entrypoint — which comes
            // from this variable, not from `-p`. Inherited, it is not `sdk-*`
            // and the row shows up.
            record("titleenv: the inherited entrypoint is scrubbed",
                   env[key] == nil)
            record("titleenv: the CLI's own directory is on PATH",
                   (env["PATH"] ?? "").contains(cli.deletingLastPathComponent().path))

            // A provider-only setup must not fall back to an inherited
            // Anthropic key pointing at a different endpoint.
            var provider = ModelProvider()
            provider.baseURL = "https://example.invalid"
            provider.authToken = "t"
            provider.haikuModel = "some-haiku"
            setenv("ANTHROPIC_API_KEY", "leftover", 1)
            defer { unsetenv("ANTHROPIC_API_KEY") }
            let providerEnv = SessionTitleGenerator.environment(customApi: provider, cli: cli)
            record("titleenv: a custom provider drops any inherited API key",
                   providerEnv["ANTHROPIC_API_KEY"] == nil)
            record("titleenv: a custom provider redirects the endpoint and model",
                   providerEnv["ANTHROPIC_BASE_URL"] == "https://example.invalid"
                   && providerEnv["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "some-haiku")
        }

        // MARK: - Store eviction, migration and corruption
        //
        // Each of these is a policy with a long rationale comment and, until
        // now, no coverage at all — which is the shape CLAUDE.md warns about:
        // a floor counts assertions, it cannot say any of them protects
        // anything.
        do {
            let snapshot = SessionTitleStore._probeSnapshot()
            defer { SessionTitleStore._probeRestore(snapshot) }

            // --- eviction ---------------------------------------------------
            SessionTitleStore._probeReset()
            let cap = SessionTitleStore._probeMaxEntries
            // The two special ids are the LEXICALLY SMALLEST in the store, and
            // that is what makes these fixtures bite. `write` sorts candidates
            // by (not-owned first, then id), so the victim is the smallest
            // non-owned candidate. With random UUIDs both guards could be
            // deleted and each assertion would still pass ~199 runs in 200 —
            // measured, not assumed. Pinned here so removing either guard puts
            // that guard's own id in the victim slot immediately.
            for _ in 0..<(cap - 1) {
                SessionTitleStore.save(title: "auto", forSessionId: UUID().uuidString)
            }
            let owned = "00000000-0000-4000-8000-000000000001"
            SessionTitleStore.save(title: "human", forSessionId: owned, userOwned: true)
            record("eviction: the store fills to its cap",
                   SessionTitleStore._probeCount() == cap)

            let newest = "00000000-0000-4000-8000-000000000002"
            SessionTitleStore.save(title: "newest", forSessionId: newest)
            record("eviction: the store stays at its cap",
                   SessionTitleStore._probeCount() == cap)
            // The bug the `protecting` parameter exists for: dictionary order is
            // hash-seeded, so a plain prefix could evict the entry inserted one
            // line earlier — a rename discarded by the call performing it.
            record("eviction: the record just written survives",
                   SessionTitleStore.title(forSessionId: newest) == "newest")
            // A human-chosen name is the one entry that cannot be regenerated.
            record("eviction: a user-named record outlives automatic ones",
                   SessionTitleStore.title(forSessionId: owned) == "human"
                   && SessionTitleStore.isUserOwned(owned))

            // --- legacy migration -------------------------------------------
            // The one path standing between an existing user and losing every
            // stored title on upgrade.
            let legacyPlain = UUID().uuidString
            let legacyOwned = UUID().uuidString
            SessionTitleStore._probeSeedLegacy(
                titles: [legacyPlain: "old auto", legacyOwned: "old human"],
                owned: [legacyOwned]
            )
            record("migration: legacy titles are carried forward",
                   SessionTitleStore.title(forSessionId: legacyPlain) == "old auto"
                   && SessionTitleStore.title(forSessionId: legacyOwned) == "old human")
            record("migration: the legacy user-owned mark is carried forward",
                   SessionTitleStore.isUserOwned(legacyOwned)
                   && !SessionTitleStore.isUserOwned(legacyPlain))

            // --- corruption fails closed, then recovers ---------------------
            // The contract is per-call and the ORDER is the whole point: the
            // call that DISCOVERS a corrupt blob refuses, parks the bytes and
            // clears the live key, so the refusal lasts exactly one call.
            // Treating "cannot read" as "nothing there" would let one save
            // overwrite every stored title; never clearing the key would make
            // titling dead for the life of the install. Both halves are pinned.
            SessionTitleStore._probeReset()
            SessionTitleStore.save(title: "keep me", forSessionId: UUID().uuidString)

            SessionTitleStore._probeCorrupt()
            record("corruption: the discovering read degrades to empty",
                   SessionTitleStore._probeCount() == 0)
            record("corruption: the unreadable blob is parked, not discarded",
                   SessionTitleStore._probeHasParkedBlob())
            record("corruption: a later call recovers",
                   SessionTitleStore.save(title: "after", forSessionId: UUID().uuidString))

            // Same again with a WRITE as the discovering call — the branch that
            // actually protects the data.
            SessionTitleStore._probeCorrupt()
            record("corruption: the discovering write is refused",
                   !SessionTitleStore.save(title: "clobber", forSessionId: UUID().uuidString))
            record("corruption: a later write succeeds",
                   SessionTitleStore.save(title: "later", forSessionId: UUID().uuidString))
        }

        // MARK: - Rename entry points
        do {
            let snapshot = SessionTitleStore._probeSnapshot()
            defer { SessionTitleStore._probeRestore(snapshot) }
            // Reset, like the block above. Without it these run on top of the
            // developer's real store, and a local store that is corrupt or at
            // its cap turns every rename assertion red — pointing the report at
            // rename when the fault is elsewhere.
            SessionTitleStore._probeReset()

            let renameId = UUID().uuidString
            let renamable = OpenSession(
                origin: .local(cwd),
                resumeId: renameId,
                title: "Before",
                project: "ProjectA",
                status: .live,
                lastActiveAt: now
            )
            let store = SessionStore()
            store._probeSeedOpenSessions([renamable])

            store.beginRename(row: .open(renamable))
            record("rename: an open row targets its resume id and live session",
                   store.renameTarget?.sessionId == renameId
                   && store.renameTarget?.openSessionId == renamable.id
                   && store.renameTarget?.currentTitle == "Before")

            store.cancelRename()
            record("rename: cancel clears the target", store.renameTarget == nil)

            let closedId = UUID().uuidString
            let closed = SessionEntry(
                id: closedId, title: "Closed one",
                timestamp: now, projectDirectory: cwd
            )
            store.beginRename(row: .closedLocal(closed))
            record("rename: a closed row targets the entry id with no live session",
                   store.renameTarget?.sessionId == closedId
                   && store.renameTarget?.openSessionId == nil)

            // A cloud title belongs to the server, and a launcher row stands
            // for no session at all. Server ownership is the reason; the id
            // shape is not, and nothing here establishes what a cloud id looks
            // like either way.
            store.cancelRename()
            store.beginRename(row: .closedCloud(cloudFresh))
            record("rename: a cloud row is refused", store.renameTarget == nil)
            store.beginRename(row: .launcher(UUID()))
            record("rename: a launcher row is refused", store.renameTarget == nil)

            // Pane entry point. The Bool is what the click monitor consumes on:
            // consuming a double-click that opened nothing would swallow the
            // window zoom too.
            record("rename: an out-of-range pane index is refused",
                   !store.beginRenameForPane(at: 0))
            store.openInFocusedPane(renamable.id)
            record("rename: a session pane opens the sheet",
                   store.beginRenameForPane(at: 0)
                   && store.renameTarget?.sessionId == renameId)
            store.cancelRename()
            store.openLauncherInNewPane()
            record("rename: a launcher pane is refused",
                   !store.beginRenameForPane(at: store.panes.count - 1)
                   && store.renameTarget == nil)

            // Commit.
            store.beginRename(row: .open(renamable))
            // `if let`, not `guard`: the previous version's comment claimed it
            // "falls through", which a guard body cannot do, and its `return`
            // skipped the summary line — so CI would have reported a real
            // assertion failure as "the app never launched", which is exactly
            // the bucket separation the probe job exists to provide.
            if let target = store.renameTarget {
            store.commitRename(target, to: "   ")
            record("rename: an empty title dismisses without writing",
                   store.renameTarget == nil
                   && SessionTitleStore.title(forSessionId: renameId) == nil
                   && renamable.title == "Before")

            store.beginRename(row: .open(renamable))
            store.commitRename(target, to: "Before")
            record("rename: an unchanged title dismisses without writing",
                   store.renameTarget == nil
                   && SessionTitleStore.title(forSessionId: renameId) == nil)

            store.beginRename(row: .open(renamable))
            store.commitRename(target, to: "  A better name  ")
            record("rename: a commit applies to the live session",
                   renamable.title == "A better name")
            record("rename: a commit persists the title",
                   SessionTitleStore.title(forSessionId: renameId) == "A better name")
            // Without the mark the name is overwritten a few turns into the
            // next launch — the exact failure the feature exists to prevent.
            record("rename: a commit marks the title user-owned",
                   SessionTitleStore.isUserOwned(renameId))

            // The sheet imposes no length limit; every automatic writer
            // truncates, so a rename that did not would be the one title that
            // renders long until the next launch quietly shortened it.
            let overlong = String(repeating: "z", count: SessionTitleGenerator.maxTitleLength + 20)
            store.beginRename(row: .open(renamable))
            if let t2 = store.renameTarget {
                store.commitRename(t2, to: overlong)
            }
            record("rename: a commit truncates to the displayed length",
                   renamable.title.count <= SessionTitleGenerator.maxTitleLength
                   && renamable.title == ShimProcess.truncatedTitle(overlong))

            // The race `commitRename` names in its own doc, and the reason it
            // resolves the key from the live session rather than the captured
            // target: a launcher-born session starts on a placeholder id that
            // `backfillResumeId` replaces the moment the CLI reports its real
            // one, which can happen while the sheet is open. Committing against
            // the captured value writes the mark under a dead id — and the
            // title self-heals through another path while the mark does not, so
            // the name survives one launch and is taken back the next.
            let placeholder = UUID().uuidString
            let realId = UUID().uuidString
            let racing = OpenSession(
                origin: .local(cwd),
                resumeId: placeholder,
                title: "Placeholder era",
                project: "ProjectA",
                status: .live,
                lastActiveAt: now
            )
            let raceStore = SessionStore()
            raceStore._probeSeedOpenSessions([racing])
            raceStore.beginRename(row: .open(racing))
            if let raceTarget = raceStore.renameTarget {
                // Exactly what `backfillResumeId` does, while the sheet is up.
                racing.resumeId = realId
                raceStore.commitRename(raceTarget, to: "Named mid-backfill")
                record("rename: a commit follows a resume-id backfill",
                       SessionTitleStore.title(forSessionId: realId) == "Named mid-backfill"
                       && SessionTitleStore.isUserOwned(realId))
                record("rename: a commit writes nothing under the dead placeholder",
                       SessionTitleStore.title(forSessionId: placeholder) == nil)
            } else {
                    record("rename: backfill fixture has a target", false, "no target")
                }
            } else {
                record("rename: commit fixtures have a target", false, "beginRename produced none")
            }
        }

        // MARK: - Launcher model retirement map
        do {
            // Derived from the production constants, never re-typed: a fixture that
            // spells the ids inline asserts only that nobody changed their mind.
            for row in LauncherView._probeModelOptions where !row.isEmpty {
                record("model map: a listed row is left alone (\(row))",
                       LauncherView.migratingRetiredModel(row) == row)
            }

            // The property that matters is closure, not any one pair: every id the
            // list has ever shipped must land on a row the list still offers, or the
            // Picker comes up blank for whoever had it stored.
            let listed = Set(LauncherView._probeModelOptions)
            var unlisted: [String] = []
            for old in LauncherView._probeRetiredModelIds {
                let mapped = LauncherView.migratingRetiredModel(old)
                if !listed.contains(mapped) { unlisted.append("\(old)→\(mapped)") }
            }
            record("model map: every retired id lands on a listed row",
                   unlisted.isEmpty, unlisted.joined(separator: ", "))

            // Idempotent, because `onAppear` runs on every launcher mount and Cmd+O
            // reads the same stored value independently.
            var unstable: [String] = []
            for old in LauncherView._probeRetiredModelIds {
                let once = LauncherView.migratingRetiredModel(old)
                if LauncherView.migratingRetiredModel(once) != once { unstable.append(old) }
            }
            record("model map: migrating twice is migrating once",
                   unstable.isEmpty, unstable.joined(separator: ", "))

            record("model map: an unknown id passes through untouched",
                   LauncherView.migratingRetiredModel("some-future-model") == "some-future-model")
        }

        // Summary
        lines.append("--- \(pass) passed, \(fail) failed ---")
        return (lines.joined(separator: "\n"), fail)
    }

    /// Raw-bytes variant, for fixtures that must contain a byte sequence a
    /// `String` cannot hold (invalid UTF-8 on disk).
    private static func writeProbeData(_ contents: Data) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("canopy-probe-\(UUID().uuidString).jsonl")
        do {
            try contents.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
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

    /// The one root every `inFolderNamed:` fixture lives under, so the caller
    /// can remove them all with a single `removeItem` — the flat
    /// `writeProbeJSONL(_:)` leaks loose files, and leaking a directory tree
    /// per fixture is a worse version of the same habit. Suffixed per process
    /// because two probe runs would otherwise share it and the first to reach
    /// the cleanup would delete the other's live fixtures mid-assertion.
    static let probeFolderFixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("canopy-probe-folders-\(ProcessInfo.processInfo.processIdentifier)")

    /// Same, but with control over the PARENT FOLDER'S NAME — the only thing
    /// `ShimProcess.relocatedWorkingDirectory` reads about the path's
    /// location. A unique directory sits above it so two fixtures can claim
    /// the same folder name without colliding.
    private static func writeProbeJSONL(_ contents: String, inFolderNamed folder: String) -> String? {
        let dir = probeFolderFixtureRoot
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(folder)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).jsonl")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }
}
#endif
