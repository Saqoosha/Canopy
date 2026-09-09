import Foundation
import os.log

enum GitWorktree {
    private static let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "GitWorktree")

    /// All Canopy-created worktrees live here, grouped by repository name —
    /// hidden away from the projects tree so the repo's parent folder stays
    /// clean (same shape as Cursor's ~/.cursor/worktrees).
    static let worktreesRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/worktrees", isDirectory: true)

    /// Display label for a session directory. Recognized worktree layouts
    /// (managed root, `<repo>-worktrees` sibling, and in-repo
    /// `<repo>/.claude/worktrees/<branch>`) surface the repository the
    /// worktree belongs to ("Canopy · fix-foo").
    ///
    /// **`branch` is the VCS's own answer and always wins when present**, and
    /// passing it is what makes this function stop guessing. Without it the
    /// second component is the worktree FOLDER name, which only *usually*
    /// equals the branch: `git worktree add -b feature/foo` flattens the `/`
    /// to `-` in the directory name, a later `git switch` inside the worktree
    /// moves the branch while the folder name is frozen, and a checkout that
    /// is not one of the three recognized layouts produces no branch guess at
    /// all. Those cases are why a live session should pass its
    /// `StatusBarData.gitBranch`; a closed row has no process to ask, so it
    /// keeps the guess rather than showing nothing.
    ///
    /// Worktrees outside the recognized layouts fall back to the plain folder
    /// name by design.
    static func projectDisplayName(for dir: URL, branch: String? = nil) -> String {
        if let branch {
            let name = branchNameOnly(branch)
            if !name.isEmpty { return "\(repoName(for: dir)) · \(name)" }
        }
        if let parts = worktreeParts(for: dir) {
            return "\(parts.repo) · \(parts.branch)"
        }
        return dir.standardizedFileURL.lastPathComponent
    }

    /// Strip the working-copy status `ShimProcess.detectVCSInfo` appends on the
    /// jj path, where the value it reports is `"<bookmark> (empty)"` or
    /// `"<bookmark> (modified)"`. That suffix belongs on the status bar's pill,
    /// which already shows it — carried into a row subtitle it reads as part of
    /// the branch name, duplicates what is on screen a few points below, and
    /// changes as the user edits, so the label would flicker between two
    /// spellings of the same branch. Measured on this repo, which is
    /// jj-colocated: the subtitle rendered `Canopy · main (modified)`.
    ///
    /// Only the two literals that function can produce are stripped, and only
    /// as a suffix, so a git branch that genuinely contains parentheses is left
    /// alone. A jj working copy with no bookmark reports a change id instead;
    /// that is kept, since it still names the change the pane is on.
    static func branchNameOnly(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for suffix in [" (empty)", " (modified)"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The repository a directory belongs to, with no branch component: the
    /// owning repo for a recognized worktree layout, else the folder's own
    /// name. Path shape only, so it stays cheap enough for a per-row render.
    static func repoName(for dir: URL) -> String {
        worktreeParts(for: dir)?.repo ?? dir.standardizedFileURL.lastPathComponent
    }

    /// True when `dir` is a Canopy-recognized worktree — the managed root
    /// (`~/.claude/worktrees/<repo>/<branch>`), the sibling
    /// `<repo>-worktrees/<branch>` layout, or the in-repo
    /// `<repo>/.claude/worktrees/<branch>` layout. Path shape only; no
    /// filesystem check. Currently the Recents filter (both `.add` and
    /// `.load` in `RecentDirectories`) is the only caller.
    static func isManagedWorktree(_ dir: URL) -> Bool {
        worktreeParts(for: dir) != nil
    }

    // Purely lexical: standardizes the URL ("..", ".") then string-matches
    // the three known worktree layouts. Symlink resolution is skipped so this
    // stays cheap enough to call per sidebar-row render; false negatives are
    // acceptable at both call sites (a display label falls back to the plain
    // folder name; a worktree that briefly evades the Recents filter is
    // harmless).
    private static func worktreeParts(for dir: URL) -> (repo: String, branch: String)? {
        let standardized = dir.standardizedFileURL
        let name = standardized.lastPathComponent
        let parent = standardized.deletingLastPathComponent()
        // Managed layout: ~/.claude/worktrees/<repo>/<branch>
        if parent.deletingLastPathComponent().path == worktreesRoot.path {
            return (parent.lastPathComponent, name)
        }
        // Sibling layout (<repoParent>/<repo>-worktrees/<branch>): used by
        // pre-release Canopy builds and common external tooling conventions.
        let parentName = parent.lastPathComponent
        let suffix = "-worktrees"
        if parentName.hasSuffix(suffix), parentName.count > suffix.count {
            return (String(parentName.dropLast(suffix.count)), name)
        }
        // In-repo layout (<repo>/.claude/worktrees/<branch>): observed in
        // practice for repos that keep worktrees under their own
        // .claude/worktrees/ dir; path shape only, no filesystem check.
        if parentName == "worktrees",
           parent.deletingLastPathComponent().lastPathComponent == ".claude"
        {
            let repoRoot = parent.deletingLastPathComponent().deletingLastPathComponent()
            let repoName = repoRoot.lastPathComponent
            // Reject when `.claude` is at the filesystem root (`/.claude/…`):
            // there is no real repo name to surface, and `lastPathComponent`
            // on `/` returns `/`.
            // Also reject when this IS the managed root itself
            // (`~/.claude/worktrees/<branch>` — one level under worktreesRoot):
            // that path shape matches in-repo layout lexically but would
            // falsely attribute the home-dir basename as the "repo".
            if !repoName.isEmpty, repoName != "/", repoRoot.path != "/",
               parent.path != worktreesRoot.path
            {
                return (repoName, name)
            }
        }
        return nil
    }

    static func isGitRepo(_ dir: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let gitPath = dir.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
            return false
        }
        return true
    }

    static func sanitizeBranchName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: " ", with: "-")

        let invalidScalars = CharacterSet(charactersIn: "~^:?*[]\\").union(.whitespacesAndNewlines)
        s = String(s.unicodeScalars.filter { !invalidScalars.contains($0) })

        while s.contains("//") {
            s = s.replacingOccurrences(of: "//", with: "/")
        }

        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/."))

        if s.hasSuffix(".lock") {
            s = String(s.dropLast(".lock".count))
        }

        return s
    }

    /// Longest branch name accepted from either naming route.
    ///
    /// Not a git limit — git takes far longer. It is a display limit: the name
    /// becomes the worktree's folder name, and the folder name is the second
    /// half of every `Canopy · <branch>` subtitle in the sidebar.
    static let maxBranchNameLength = 40

    /// A branch name derived from the user's first prompt with no model call.
    ///
    /// The fallback under `WorktreeBranchNamer`, not a competitor to it: a
    /// model reads intent ("fix the CI assertion counts" → `ci-assert-counts`)
    /// where this only strips and joins. It exists because the alternative
    /// fallback is `suggestedBranchName`'s timestamp, and timestamps are
    /// measured to be the useless case — of the two worktrees Canopy's own
    /// launcher has ever created on this machine, both were named that way and
    /// neither was used again.
    ///
    /// Returns "" for a prompt with no ASCII word characters at all, which
    /// includes every all-Japanese prompt. That is deliberate: a branch named
    /// from nothing is worse than a timestamp, so the caller falls through.
    static func slugFromPrompt(_ prompt: String, maxLength: Int = maxBranchNameLength) -> String {
        let lowered = prompt.lowercased()
        var words: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }

        // Dropped before assembly, not after: leading filler ("please fix the
        // …") would otherwise eat the length budget and leave the name
        // describing nothing.
        let filler: Set<String> = [
            "a", "an", "the", "please", "can", "you", "could", "would", "i", "we",
            "to", "of", "in", "on", "for", "and", "or", "is", "are", "be", "it",
            "this", "that", "my", "our", "let", "s", "lets", "just", "want",
        ]
        var kept = words.filter { !filler.contains($0) }
        if kept.isEmpty { kept = words }

        var slug = ""
        for word in kept {
            let candidate = slug.isEmpty ? word : slug + "-" + word
            if candidate.count > maxLength { break }
            slug = candidate
        }
        // One word longer than the whole budget yields "" above, which would
        // fall through to a timestamp for a prompt that plainly has content.
        if slug.isEmpty, let first = kept.first {
            slug = String(first.prefix(maxLength))
        }
        return slug
    }

    static func suggestedBranchName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "work-\(formatter.string(from: now))"
    }

    /// Set when the watchdog terminated the process, so the error path can
    /// distinguish a timeout from a normal git failure.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// What a finished subprocess left behind.
    struct CommandResult {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    /// Run one short-lived tool under a watchdog.
    ///
    /// Shared by every subprocess this file spawns rather than written out per
    /// call site, because the hazard is identical at each and is not obvious:
    /// `git` blocks forever on a git-lfs credential prompt, an askpass, or a
    /// stuck hook, and `cp` blocks on a network volume that stops answering.
    /// Either one hangs the launcher with no error and nothing in the log.
    ///
    /// `wantsStdout` is a parameter rather than always-on. Draining two pipes
    /// in sequence deadlocks the moment the one NOT being read fills its 64KB
    /// buffer: the child blocks writing to it, so the stream being read never
    /// reaches EOF. A caller that needs only a status takes the single-stream
    /// path, which cannot deadlock; callers that need stdout pay for a
    /// concurrent drain (same reason `CloneRepoSheet` uses a group).
    private static func runCommand(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        wantsStdout: Bool = false
    ) throws -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let stdoutPipe = wantsStdout ? Pipe() : nil
        proc.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem { [weak proc] in
            timedOut.set()
            proc?.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        try proc.run()

        var outData = Data()
        var errData = Data()
        if let stdoutPipe {
            let group = DispatchGroup()
            let queue = DispatchQueue.global(qos: .utility)
            queue.async(group: group) { outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
            queue.async(group: group) { errData = stderrPipe.fileHandleForReading.readDataToEndOfFile() }
            group.wait()
        } else {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        proc.waitUntilExit()
        watchdog.cancel()

        if timedOut.value {
            // The hint is per-executable: this function also runs `/bin/cp`
            // for seeding, where "check git hooks" is actively misleading.
            let hint = executable.hasSuffix("git")
                ? " — check git hooks or LFS credential prompts"
                : ""
            let message = "\(executable) timed out after \(Int(timeout))s\(hint)"
            logger.error("\(message, privacy: .public)")
            throw NSError(domain: "GitWorktree", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        // Never `String(data:encoding:)`: a read that cuts a multi-byte
        // sequence makes the WHOLE buffer decode to nil, blanking a
        // diagnostic that is already the only clue about what failed.
        let stderr = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(status: proc.terminationStatus, stdout: outData, stderr: stderr)
    }

    /// Refs to try, in order, when deciding what a new worktree branches FROM.
    ///
    /// Pure so the order can be pinned: it is the whole of the policy, and the
    /// order is the part that would rot silently. `origin/HEAD` first because
    /// it is the only entry that records what the remote SAID its default
    /// branch was, rather than guessing a name — it is a local cache written
    /// at clone time, so it can be absent or stale, which is why the two
    /// conventional names follow it. Remote before local, because a local
    /// `main` can be behind.
    static let baseRefCandidates = ["origin/HEAD", "origin/main", "origin/master", "main", "master"]

    /// What a new worktree should branch from, or nil when nothing resolves.
    ///
    /// **A nil result means "use HEAD", and that is the behaviour this function
    /// exists to stop being the default.** `git worktree add -b X <path>` with
    /// no start-point branches from the repository's HEAD — so a root that had
    /// drifted onto a feature branch silently grew every new worktree on top of
    /// that feature's work. Reported as "does it mean the new worktree will be
    /// created based on that branch…?", which is exactly what it meant.
    ///
    /// Matches `EnterWorktree`'s own `worktree.baseRef: fresh` default, so the
    /// two ways of making a worktree in this project agree about where work
    /// starts.
    static func defaultBaseRef(for repo: URL, timeout: TimeInterval = 15) -> String? {
        for candidate in baseRefCandidates {
            guard let result = try? runCommand(
                "/usr/bin/git",
                ["-C", repo.path, "rev-parse", "--verify", "--quiet", candidate],
                timeout: timeout,
                wantsStdout: true
            ), result.status == 0 else { continue }
            let resolved = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { continue }
            return candidate
        }
        return nil
    }

    /// One branch a new worktree could start from.
    struct BaseCandidate: Equatable, Identifiable {
        /// What the user is shown — always the bare branch name.
        let name: String
        /// What is handed to `git worktree add`, which may be the remote copy.
        let ref: String
        var id: String { ref }
    }

    /// Merge local and remote branch names into one ordered, deduplicated list.
    ///
    /// Pure, because the two rules here are the whole of the policy and both
    /// are easy to get backwards.
    ///
    /// **The remote copy wins a tie, while the LOCAL name is displayed.** A
    /// local `main` can be behind `origin/main` by days, and starting a branch
    /// from a stale base is the quieter version of the bug this picker was
    /// added alongside — the work looks fine and only conflicts at merge. The
    /// user still thinks in "branch off main", so the name shown is `main`.
    ///
    /// Order within each source is the caller's commit-date sort. The two are
    /// CONCATENATED, remote first, so every remote entry outranks every
    /// local-only one whatever its date — a branch that exists only locally
    /// sorts below a remote one last touched a year ago. Accepted: the entry
    /// worth defaulting to is almost always a remote one, and the list is
    /// capped at `limit` rather than scanned.
    ///
    /// **The remote's own symbolic HEAD is dropped, and it does NOT look the
    /// way you would guess.** `refs/remotes/origin/HEAD` renders under
    /// `%(refname:short)` as the bare string `origin` — not `origin/HEAD` — so
    /// a filter written against the long form silently passes it through and
    /// the picker offers a branch called "origin" that duplicates whatever the
    /// default branch is. Shipped exactly that way, caught in a screenshot,
    /// and the probe had missed it because the FIXTURE used the guessed
    /// spelling too: a test written from the same wrong idea as the code
    /// agrees with it.
    static func mergeBaseCandidates(
        local: [String],
        remote: [String],
        limit: Int = 12
    ) -> [BaseCandidate] {
        var seen = Set<String>()
        var result: [BaseCandidate] = []
        for full in remote + local {
            let isRemote = full.hasPrefix("origin/")
            let name = isRemote ? String(full.dropFirst("origin/".count)) : full
            guard name != "HEAD", name != "origin", !name.isEmpty, !seen.contains(name)
            else { continue }
            seen.insert(name)
            result.append(BaseCandidate(name: name, ref: full))
            if result.count == limit { break }
        }
        return result
    }

    /// Branches a new worktree could start from, most recently committed first.
    static func baseCandidates(for repo: URL, limit: Int = 12, timeout: TimeInterval = 15) -> [BaseCandidate] {
        func names(_ refspace: String) -> [String] {
            guard let result = try? runCommand(
                "/usr/bin/git",
                ["-C", repo.path, "for-each-ref", "--sort=-committerdate",
                 "--format=%(refname:short)", refspace],
                timeout: timeout,
                wantsStdout: true
            ), result.status == 0 else { return [] }
            return String(decoding: result.stdout, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return mergeBaseCandidates(
            local: names("refs/heads"),
            remote: names("refs/remotes/origin"),
            limit: limit
        )
    }

    /// Human-readable form of a base ref, for the chip that reports it.
    ///
    /// `origin/HEAD` names a symbolic ref, not a branch anyone thinks in, so it
    /// is resolved to what it points at before being shown.
    static func displayBaseRef(_ ref: String, for repo: URL, timeout: TimeInterval = 15) -> String {
        guard ref == "origin/HEAD" else {
            return ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
        }
        guard let result = try? runCommand(
            "/usr/bin/git",
            ["-C", repo.path, "symbolic-ref", "--short", "--quiet", "refs/remotes/origin/HEAD"],
            timeout: timeout,
            wantsStdout: true
        ), result.status == 0 else { return "default" }
        let full = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "default" }
        return full.hasPrefix("origin/") ? String(full.dropFirst("origin/".count)) : full
    }

    /// `baseRef` nil keeps git's own default, which is the repository's HEAD —
    /// see `defaultBaseRef` for why callers should almost never want that.
    /// Whether a ref of this name already exists in `repo`.
    ///
    /// `git worktree add -b` creates a branch and fails outright if the name is
    /// taken. Since the hand-typed name field was removed there is no way for
    /// the user to resolve that collision, and it is reachable in the ordinary
    /// way: start two worktrees from the same prompt and the namer returns the
    /// same slug twice.
    static func refExists(_ name: String, in repo: URL, timeout: TimeInterval = 15) -> Bool {
        guard let result = try? runCommand(
            "/usr/bin/git",
            ["-C", repo.path, "rev-parse", "--verify", "--quiet", "refs/heads/\(name)"],
            timeout: timeout,
            wantsStdout: true
        ) else { return false }
        return result.status == 0
    }

    /// `branch` with a numeric suffix appended if needed to make it free.
    ///
    /// Bounded rather than looping forever: past `limit` the repo has that many
    /// branches on one slug and the caller is better off failing visibly than
    /// silently creating `foo-97`.
    static func uniqueBranchName(_ branch: String, in repo: URL, limit: Int = 20) -> String {
        guard refExists(branch, in: repo) else { return branch }
        for suffix in 2 ... limit {
            let candidate = "\(branch)-\(suffix)"
            if !refExists(candidate, in: repo) { return candidate }
        }
        return branch
    }

    static func createWorktree(
        repo: URL,
        branch: String,
        baseRef: String? = nil,
        timeout: TimeInterval = 120
    ) throws -> URL {
        let repoName = repo.lastPathComponent
        let branchComponent = branch.replacingOccurrences(of: "/", with: "-")
        let worktreesParent = worktreesRoot.appendingPathComponent(repoName, isDirectory: true)
        let worktreeURL = worktreesParent.appendingPathComponent(branchComponent, isDirectory: true)

        try FileManager.default.createDirectory(at: worktreesParent, withIntermediateDirectories: true)

        let result = try runCommand(
            "/usr/bin/git",
            ["-C", repo.path, "worktree", "add", "-b", branch, worktreeURL.path]
                + (baseRef.map { [$0] } ?? []),
            timeout: timeout
        )
        if result.status != 0 {
            let message = result.stderr.isEmpty
                ? "git worktree add failed (exit \(result.status))"
                : result.stderr
            logger.error("worktree add failed (status \(result.status)): \(message, privacy: .public)")
            throw NSError(
                domain: "GitWorktree",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        logger.notice(
            "Created worktree at \(worktreeURL.path, privacy: .private) on branch \(branch, privacy: .public) from \(baseRef ?? "HEAD", privacy: .public)"
        )
        return worktreeURL
    }

    /// The branch a directory is on, or nil when there isn't one to name.
    ///
    /// Deliberately NOT the same source as the status bar's pill, which asks
    /// the running shim (`ShimProcess.detectVCSInfo`) and can therefore report
    /// jj bookmarks and a working-copy status. There is no shim on the launch
    /// screen — no session exists yet — so this is a plain read, and it is
    /// used only to tell the user which branch the prompt is about to run
    /// against.
    ///
    /// `rev-parse --abbrev-ref HEAD` answers the literal string `HEAD` on a
    /// detached checkout, which would render as a chip naming nothing. That is
    /// rejected here rather than at the call site, the same way the status
    /// bar's own reader rejects it.
    static func currentBranch(for dir: URL, timeout: TimeInterval = 5) -> String? {
        guard let result = try? runCommand(
            "/usr/bin/git",
            ["-C", dir.path, "rev-parse", "--abbrev-ref", "HEAD"],
            timeout: timeout,
            wantsStdout: true
        ), result.status == 0 else { return nil }
        let name = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    // MARK: - Seeding a fresh worktree (probe-reachable helpers)

    /// A fresh worktree contains only tracked files, so **it usually cannot
    /// build**: the artifacts a project needs are precisely the ones it
    /// gitignores. Measured on this machine — Xcode projects generated by
    /// xcodegen (`Canopy.xcodeproj` is gitignored here), `node_modules`, and
    /// Unity's `Library`, whose cold reimport costs tens of minutes.
    ///
    /// The fix is APFS `clonefile(2)` via `cp -Rc`: copy-on-write, so the copy
    /// is near-instant and costs only metadata until the two sides diverge.
    /// Measured on a 3.4 GB / 55,971-file Unity `Library`: **10.9 s and 46 MB
    /// of real disk**, 1.3% of the source. That is what makes seeding cheap
    /// enough to do unconditionally rather than per-ecosystem.
    ///
    /// The list is not configured anywhere: `git ls-files -o -i` already knows
    /// it, so this needs no equivalent of Orca's `orca.yaml
    /// worktree.sharedDirectories` / `.worktreeinclude`. What that buys is
    /// working on the first try for a stack nobody taught it about.
    ///
    /// **This is a snapshot, not a share.** The two copies diverge after
    /// creation, which is right for a cache (Unity revalidates `Library`) and
    /// merely a good starting point for `node_modules`, which the branch's own
    /// `install` then reconciles incrementally.
    ///
    /// Cost scales with inode count, not bytes: ~5,100 files/s measured, so a
    /// large `node_modules` is ~20 s.
    enum SeedPlan: Equatable {
        /// Regular file, directory, or symlink — `cp -Rc`.
        case clone
        /// Symlink to the original instead of recreating it.
        case link
        /// Unreachable from `plan(for:)` today — every `FileAttributeType`
        /// maps to `.clone` or `.link`. Entries are skipped by `shouldSeed`
        /// and by the two guards in `seedIgnoredFiles`, not here, so a reader
        /// debugging a skipped entry should look there.
        case skip
    }

    /// First path components that must never be seeded.
    ///
    /// `.jj` is the one that would actively break things rather than merely
    /// waste time: this repo is jj-colocated, `.jj/` sits beside `.git/` at
    /// the root and IS gitignored, and a linked worktree carrying its own copy
    /// of it is not a state jj can make sense of.
    ///
    /// `.DS_Store` is only noise, and is listed to keep it out of the counts.
    static let seedDenyList: Set<String> = [".git", ".jj", ".DS_Store"]

    /// Directories that hold OTHER worktrees, denied by path prefix.
    ///
    /// Each entry is a full checkout, so seeding one of these copies every
    /// sibling worktree into the new one. Both spellings are in use here:
    /// `.claude/worktrees` is what this project's worktrees actually sit under
    /// (measured, 73 of 76 on this machine) and what `EnterWorktree` creates,
    /// and `.worktrees` is the `using-git-worktrees` skill's own default.
    ///
    /// A prefix rather than a first-component match, because `.claude` as a
    /// whole must stay seedable — `.claude/settings.local.json` is ignored too
    /// and is exactly the kind of thing a worktree wants.
    ///
    /// `seedIgnoredFiles` separately rejects any entry that contains the
    /// destination by path. The two are not redundant and neither subsumes the
    /// other: this list stops SIBLING worktrees, which the path check cannot
    /// see, and the path check stops a repo whose worktrees live somewhere
    /// this list has never heard of.
    static let seedDenyPrefixes: [String] = [".claude/worktrees", ".worktrees"]

    /// Whether one `git ls-files` entry is worth seeding.
    ///
    /// The first-component match is what makes `.jj/repo/store` fall to the
    /// same rule as a bare `.jj/`: git emits the collapsed form when the whole
    /// directory is ignored and individual paths under it when it is not, and
    /// only one of those two shapes would be caught by an exact comparison.
    static func shouldSeed(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let relative = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let first = relative.split(separator: "/").first else { return false }
        if seedDenyList.contains(String(first)) { return false }
        for prefix in seedDenyPrefixes
        where relative == prefix || relative.hasPrefix(prefix + "/") {
            return false
        }
        return true
    }

    /// How to reproduce one entry in the worktree.
    ///
    /// **A FIFO must be linked, never cloned, and this is not hypothetical
    /// here.** `cp` recreates a named pipe as a NEW, empty pipe — measured —
    /// and 1Password's Environments feature mounts secrets as a FIFO at
    /// `<repo>/.env`. A cloned one is a pipe nothing ever writes to, so the
    /// first `dotenv` read in the worktree blocks forever: the app hangs with
    /// no error. Re-mounting is not an escape either, because 1Password caps a
    /// device at ten enabled local `.env` files and nothing on this side can
    /// free a slot. A symlink to the original works, because that FIFO is
    /// re-readable.
    ///
    /// Sockets and device nodes take the same branch for the weaker reason
    /// that a recreated one is meaningless; nothing has been measured there.
    /// Symlinks are NOT in that branch — `cp -Rc` reproduces a symlink as a
    /// symlink (measured), which is already the right answer and costs nothing.
    static func plan(for type: FileAttributeType) -> SeedPlan {
        switch type {
        case .typeRegular, .typeDirectory, .typeSymbolicLink:
            return .clone
        case .typeCharacterSpecial, .typeBlockSpecial, .typeSocket:
            return .link
        default:
            // `FileAttributeType` has no FIFO case, so a named pipe arrives as
            // `.typeUnknown`. That is exactly the case this branch exists for,
            // and it is why the default is `.link` rather than `.skip`.
            return .link
        }
    }

    struct SeedReport: Equatable {
        var cloned = 0
        var linked = 0
        var skipped = 0
        var failed = 0

        var summary: String {
            "cloned \(cloned), linked \(linked), skipped \(skipped), failed \(failed)"
        }
    }

    /// Ignored entries under `repo`, as git reports them.
    ///
    /// `-z` rather than newline-separated output: without it git quotes any
    /// path containing a non-ASCII byte, a space, or a quote
    /// (`"Assets/\303\251.png"`), and the caller would then have to unquote C
    /// escapes correctly to avoid building a path to nothing. `--directory`
    /// collapses a wholly-ignored directory to one entry, which is what keeps
    /// `node_modules` a single `cp` instead of 100,000.
    static func ignoredEntries(repo: URL, timeout: TimeInterval = 60) throws -> [String] {
        let result = try runCommand(
            "/usr/bin/git",
            ["-C", repo.path, "ls-files", "-z", "-o", "-i", "--exclude-standard", "--directory"],
            timeout: timeout,
            wantsStdout: true
        )
        guard result.status == 0 else {
            // `.private` for the same reason the clone-failure line below is:
            // git's stderr here names the repository path and can name
            // individual ignored paths, and these lines reach disk.
            logger.notice("ls-files failed (status \(result.status)): \(result.stderr, privacy: .private)")
            return []
        }
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map { String($0) }
    }

    /// Copy the repo's ignored build artifacts into a fresh worktree.
    ///
    /// Never throws. A worktree that seeded nothing is the state every
    /// worktree was in before this existed — worse, but usable — so a failure
    /// here must not lose the user the worktree they asked for. Failures are
    /// counted and logged instead.
    @discardableResult
    static func seedIgnoredFiles(
        repo: URL,
        worktree: URL,
        perEntryTimeout: TimeInterval = 300
    ) -> SeedReport {
        var report = SeedReport()
        let entries: [String]
        do {
            entries = try ignoredEntries(repo: repo)
        } catch {
            logger.notice("seed: could not list ignored entries: \(error.localizedDescription, privacy: .public)")
            return report
        }

        let fm = FileManager.default
        let destRoot = worktree.standardizedFileURL
        for entry in entries {
            let relative = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            guard shouldSeed(relative) else {
                report.skipped += 1
                continue
            }
            let source = repo.appendingPathComponent(relative).standardizedFileURL
            // The second of the two guards named on `seedDenyPrefixes`: refuse an
            // entry that IS the destination or contains it. Without this a
            // repo whose worktrees live under some other ignored directory
            // would copy the worktree into itself while writing into it.
            if destRoot.path == source.path || destRoot.path.hasPrefix(source.path + "/") {
                report.skipped += 1
                continue
            }
            let dest = worktree.appendingPathComponent(relative)
            // A fresh worktree holds only tracked files, so a collision means
            // the path is tracked on this branch and the ignored copy is not
            // the authority on it.
            guard !fm.fileExists(atPath: dest.path) else {
                report.skipped += 1
                continue
            }

            // A failed stat must NOT fall through to `.typeUnknown`: that case
            // is deliberately mapped to `.link` because it is how a FIFO
            // arrives, so an unreadable regular file would be reproduced as a
            // symlink INTO the source repo — edits in the worktree would then
            // write back into the root checkout, silently, counted as `linked`.
            guard let attrs = try? fm.attributesOfItem(atPath: source.path) else {
                report.failed += 1
                logger.notice("seed: cannot stat \(relative, privacy: .private)")
                continue
            }
            let type = (attrs[.type] as? FileAttributeType) ?? .typeUnknown
            do {
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                switch plan(for: type) {
                case .skip:
                    report.skipped += 1
                case .link:
                    try fm.createSymbolicLink(at: dest, withDestinationURL: source)
                    report.linked += 1
                case .clone:
                    // `-c` FORCES clonefile and fails when the filesystem
                    // cannot do it, which is the behaviour we want: falling
                    // back to a real byte copy would turn an 11-second seed of
                    // a 3.4 GB directory into minutes of disk churn the user
                    // never asked for. A non-APFS volume gets no seed and a
                    // log line.
                    let result = try runCommand(
                        "/bin/cp",
                        ["-Rc", source.path, dest.path],
                        timeout: perEntryTimeout
                    )
                    if result.status == 0 {
                        report.cloned += 1
                    } else {
                        report.failed += 1
                        // `.private` on the path: an ignored entry's name can
                        // carry a client or product name, and these lines
                        // reach disk.
                        logger.notice(
                            "seed: clone failed for \(relative, privacy: .private): \(result.stderr, privacy: .public)"
                        )
                    }
                }
            } catch {
                report.failed += 1
                logger.notice(
                    "seed: \(relative, privacy: .private) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        // `notice`, not `info`: `info` is ring-buffer only, and "why does this
        // worktree not build" is asked long after the fact.
        logger.notice("seed: \(report.summary, privacy: .public) into \(worktree.lastPathComponent, privacy: .private)")
        return report
    }
}
