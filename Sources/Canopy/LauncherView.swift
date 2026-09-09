import SwiftUI

/// One pill in the launcher's context row.
///
/// A single definition rather than a modifier chain repeated per chip: the row
/// only reads as a row while every pill shares its metrics, and the first draft
/// of this screen had two of them a point taller than the rest.
///
/// `muted` means "this is the default, not a choice the user made" — it is what
/// keeps a row of five chips from reading as five settings that all need
/// attention.
private struct ChipLabel: View {
    let icon: String
    let text: String
    var muted: Bool = false
    /// Ceiling for the label, so one long name cannot push the row off screen.
    /// Middle truncation rather than tail: the ends of a branch name carry more
    /// than its middle ("fix-…-counts" beats "fix-issue-one-hundred-…").
    var maxTextWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxTextWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        // ---------------------------------------------------------------- 5.
        // Pinned, because SF Symbols do not share an intrinsic height: the
        // Continue chip swaps `plus.bubble` for `arrow.uturn.backward` and the
        // row grew a point, which moved the composer under the user's cursor.
        // A reported 1px jitter is the visible half of a layout that resizes
        // on every state change.
        .frame(height: 16)
        .foregroundStyle(muted ? Color.secondary : Color.primary)
    }
}

/// Left-aligned chips that wrap onto as many lines as they need.
///
/// SwiftUI ships no flow layout, and the two built-ins both fail here for the
/// reason `WeightedPaneLayout` documents one level up: `HStack` is single-pass
/// and never redistributes, so it overflows silently rather than wrapping.
/// This is the same `Layout` escape hatch, at a much smaller scale.
///
/// `sizeThatFits` reports the height the rows actually need for the proposed
/// width, and takes the proposal's width verbatim when it has one — returning
/// the natural content width instead is what makes a custom layout inflate its
/// parent, which is the runaway-growth bug the pane layout was built around.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private func rows(_ sizes: [CGSize], maxWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let advance = rows[rows.count - 1].isEmpty ? size.width : size.width + spacing
            // A chip wider than the whole line still gets its own row rather
            // than being dropped: `x > 0` keeps the first item on any row.
            if x + advance > maxWidth, x > 0 {
                rows.append([index])
                x = size.width
            } else {
                rows[rows.count - 1].append(index)
                x += advance
            }
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? sizes.map(\.width).reduce(0, +)
        let laidOut = rows(sizes, maxWidth: maxWidth)
        let height = laidOut.reduce(CGFloat.zero) { total, row in
            total + (row.map { sizes[$0].height }.max() ?? 0)
        } + CGFloat(max(0, laidOut.count - 1)) * lineSpacing
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return }
        var y = bounds.minY
        for row in rows(sizes, maxWidth: bounds.width) {
            var x = bounds.minX
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            for index in row {
                subviews[index].place(
                    // Centred within the row so a chip and a text field of
                    // different heights sit on one baseline.
                    at: CGPoint(x: x, y: y + (rowHeight - sizes[index].height) / 2),
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}

private extension View {
    /// The pill every context chip and composer control wears.
    ///
    /// Applied to the `Menu`, never to its label — see `ChipLabel`. Kept as
    /// one modifier so the row cannot drift a point out of alignment between
    /// chips, which is exactly what happened when each carried its own padding.
    func chipStyle() -> some View {
        // All three numbers are optical, and the asymmetry is the point: an SF
        // Symbol's ink sits inset inside its layout box, so the same metric
        // padding reads as MORE space on the icon side than beside text, and
        // macOS reserves its own trailing room for the menu indicator on top of
        // whatever is set here. So the leading side comes in from 10, and the
        // trailing side comes in further still when an indicator is present.
        // A pill with no menu keeps the wider trailing value, because there
        // its right edge is text — tight ink, and 5 would crowd it.
        padding(.leading, 8)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
            .contentShape(Capsule())
    }
}

struct LauncherView: View {
    @Bindable var appState: AppState
    @State private var selectedDirectory: URL?
    @State private var recentDirectories: [URL] = []
    @State private var isDropTargeted = false
    @State private var remoteHost: String = ""
    @State private var savedHosts: [String] = []
    @State private var isRemoteMode = false
    /// True while the SSH round trip that resolves "Continue session" for a
    /// remote host is in flight. Its own flag rather than reusing
    /// `isCreatingWorktree` so `preparingHeadline` can say which one it is
    /// waiting on.
    @State private var isResolvingRemoteSession = false
    @State private var remoteDirectory: String = "~"
    @State private var showRemoteBrowser = false
    @State private var showCloneSheet = false
    @State private var updater = ExtensionUpdater()

    // Web (Claude Code Web) session teleport
    @State private var showWebSessions = false
    @State private var webSessions: [RemoteSession] = []
    @State private var webSessionsLoading = false
    @State private var webSessionsError: String?
    @State private var teleportingSessionId: String?
    @State private var teleportError: String?
    @State private var hoveredWebSessionId: String?
    @State private var pendingBranchPrompt: BranchPrompt?
    @AppStorage("launcher.webSessionKind") private var webSessionKindRaw = RemoteSessionKind.web.rawValue
    @AppStorage("launcher.webSessionsIncludeArchived") private var webSessionsIncludeArchived = false

    @AppStorage("selectedProviderId") private var selectedProviderId = ""
    @State private var providers: [ModelProvider] = []

    @AppStorage("launcher.model") private var model = ""
    @AppStorage("launcher.effortLevel") private var effortLevel = ""
    @AppStorage("launcher.permissionMode") private var permissionModeRaw = "acceptEdits"
    @AppStorage("launcher.continueSession") private var continueSession = false

    @State private var startInWorktree = false
    @State private var isCreatingWorktree = false
    /// The prompt typed on the launch screen. Optional by design: leaving it
    /// empty is how the user says "open the directory, I will decide there",
    /// which is how roughly half of WORKTREE-BOUND sessions began — of 40 that
    /// relocated into a worktree, 19 did so only after several turns of
    /// discussion. (That is the population measured; it says nothing about
    /// sessions that never relocate.) A launcher that demanded a task up front
    /// would delete that half.
    @State private var initialPrompt = ""
    /// Which step of the worktree hand-off is running, for `preparingHeadline`
    /// — which the launcher renders on `SpawningOverlay`, not on the button.
    /// Three of them can take seconds and they fail for unrelated reasons, so
    /// "Creating Worktree…" over all three named the wrong one two times out
    /// of three.
    @State private var worktreeStage: String?
    /// Branch of `selectedDirectory`, refreshed when it changes rather than
    /// read per render — the read shells out, and a chip is drawn constantly.
    @State private var currentBranchName: String?
    /// What a new worktree will branch FROM, resolved from the selected repo,
    /// and how to say it on screen. Nil until resolved, or when nothing
    /// matched — in which case the base is the folder's own HEAD.
    @State private var baseRef: String?
    @State private var baseRefLabel: String?
    /// A base the user picked by hand, or nil to use `baseRef` — the repo's
    /// default branch, which is the right answer for almost every worktree
    /// (the new branch is going to be merged back into it, so starting
    /// anywhere else drags unmerged work into the diff).
    ///
    /// Nil by default on purpose: branching off whatever the root happened to
    /// be on is the trap this whole base-ref resolution exists to close, and a
    /// picker that opens with no recommendation just moves the trap.
    @State private var pickedBaseRef: GitWorktree.BaseCandidate?
    /// Branches offered by the picker, refreshed with the folder.
    @State private var baseCandidates: [GitWorktree.BaseCandidate] = []
    /// Presents the SSH host / remote path fields.
    ///
    /// Collapsing the old form's two SSH cards into the location chip left the
    /// menu able to CHOOSE a saved host and unable to add one — "Connect to
    /// host…" turned remote mode on with an empty host, which disables Start
    /// with nothing on screen to type into. A chip can only offer values that
    /// already exist, so anything that creates one needs somewhere to live.
    @State private var showRemoteSetup = false

    // Bare family aliases, so a row tracks the latest model in its family with no
    // release-day edit here. Measured 2026-09-02 on CLI 2.1.239: "fable" resolves to
    // claude-fable-5-1, "opus" to claude-opus-5, "sonnet" to claude-sonnet-5. The alias
    // also sidesteps a CLI version floor — that same CLI REJECTS the explicit id
    // claude-fable-5-1 ("version 2.1.251 or newer is required") while accepting "fable".
    // The cost is that a row's meaning moves under the user: these are NOT version pins,
    // and there is deliberately no way to ask for an older version from this Picker.
    //
    // NOTE: an id alone does NOT select the 200K tier — on a 1M-eligible account the CLI
    // serves 1M whatever was asked for. The 200K enforcement is the
    // CLAUDE_CODE_DISABLE_1M_CONTEXT env var ShimProcess sets for non-"[1m]" *opus*
    // selections, which is what makes "opus" 200K and "opus[1m]" 1M (both measured).
    // "sonnet[1m]" is deliberately absent: that gate is opus-only, so "sonnet" and
    // "sonnet[1m]" both measured contextWindow 1,000,000 and the second row said nothing.
    private static let modelOptions = ["", "fable", "opus", "opus[1m]", "sonnet", "haiku"]
    private static let effortOptions = ["", "low", "medium", "high", "xhigh", "max"]
    private static let permissionModes: [PermissionMode] = [.default, .plan, .auto, .acceptEdits, .dontAsk]

    /// Model ids `modelOptions` used to offer, mapped to the row that now covers them.
    /// A persisted `launcher.model` absent from the list renders as an EMPTY Picker
    /// selection — not as the old value — so every removal from `modelOptions` needs a
    /// row here or the upgrade silently blanks the control. Keys are every id the list
    /// has ever carried (`git log -S modelOptions`), including two that existed only in
    /// an unreleased tree; a stale key costs nothing, a missing one blanks the Picker.
    /// The version pins collapse onto their family alias, which is the whole point of
    /// the move to aliases — someone pinned to Fable 5 now follows Fable.
    private static let retiredModelMigrations = [
        "claude-fable-5": "fable",
        "claude-fable-5-1": "fable",
        "claude-opus-4-7": "opus",
        "claude-opus-4-7[1m]": "opus[1m]",
        "claude-opus-4-8": "opus",
        "claude-opus-5": "opus",
        "sonnet[1m]": "sonnet",
    ]

    /// The row that now covers a stored id; identity for ids still listed.
    ///
    /// BOTH readers of `launcher.model` must go through this. The Picker migrates in
    /// `onAppear` and writes the result back, so its own reads self-heal after one
    /// mount — but `CanopyApp.sidebarOpenFolder()` (Cmd+O) can spawn a session before
    /// any launcher pane has ever mounted, notably on a restore launch. A value that
    /// never met that write-back would reach the CLI as a retired pin, so the two
    /// entry points would disagree about which model the same stored string means.
    static func migratingRetiredModel(_ stored: String) -> String {
        retiredModelMigrations[stored] ?? stored
    }

    #if DEBUG
    /// Read-only views for `_SidebarLogicProbe`, so its fixtures derive from these
    /// constants instead of re-typing their values — a re-typed id asserts only that
    /// nobody changed their mind, and goes stale on the first legitimate edit.
    static var _probeModelOptions: [String] { modelOptions }
    static var _probeRetiredModelIds: [String] { Array(retiredModelMigrations.keys) }
    #endif

    /// Row height for list items (used to calculate fixed list height)
    private static let rowHeight: CGFloat = 34
    private static let listRowCount = 10

    private var launchComposer: some View {
        ScrollView {
            VStack(spacing: 12) {
                #if DEBUG
                if ProcessInfo.processInfo.environment["CANOPY_PROBE"] == "1" {
                    ProbeRetentionView()
                }
                #endif
                launchHeader
                extensionUpdateBanner
                contextChipRow
                composerBox
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }

    /// Which wait, if any, is running — nil means the composer is live.
    ///
    /// Both of these happen BEFORE a session exists, which is why neither can
    /// be reported by a session's own overlay: the worktree's path is not
    /// known until the branch is named, and the remote lookup is the round
    /// trip that decides which session to open at all. They are the same KIND
    /// of wait though, so they get the same screen — `SpawningOverlay`, the
    /// one `SessionContainer` shows a moment later. What the user sees is one
    /// continuous spinner: Naming Branch… → Creating Worktree… → Copying
    /// Build Files… → Starting <session>…
    private var preparingHeadline: String? {
        if let worktreeStage { return worktreeStage }
        // Reached only if a stage is somehow unset while the work runs; the
        // flag is what actually gates the composer, so it answers too.
        if isCreatingWorktree { return "Preparing Worktree…" }
        if isResolvingRemoteSession { return "Finding Session…" }
        return nil
    }

    var body: some View {
        Group {
            if let preparingHeadline {
                // The composer is REPLACED rather than covered: every control
                // in it is disabled for the duration anyway, and leaving it
                // visible behind a spinner invites a click that does nothing.
                SpawningOverlay(
                    headline: preparingHeadline,
                    detail: isRemoteMode
                        ? remoteHost
                        : (selectedDirectory?.lastPathComponent ?? "")
                )
            } else {
                launchComposer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            // Move a selection made in an older build onto an id this Picker still
            // lists, so the control comes up populated rather than blank.
            let migrated = Self.migratingRetiredModel(model)
            if migrated != model { model = migrated }
            loadData()
            preselectMostRecentDirectory()
            Task { await updater.checkForUpdate() }
        }
        .onChange(of: selectedProviderId) {
            if !selectedProviderId.isEmpty {
                if permissionModeRaw == PermissionMode.auto.rawValue {
                    permissionModeRaw = PermissionMode.acceptEdits.rawValue
                }
                effortLevel = ""
            }
        }
        .onChange(of: selectedDirectory) { refreshBranchName() }
        .sheet(isPresented: $showWebSessions) {
            webSessionsSection
                .padding(20)
                .frame(minWidth: 560, minHeight: 420)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Open on the most recently used folder when nothing is chosen yet.
    ///
    /// Only when nothing is chosen: this runs on every `onAppear`, and a pane
    /// that is re-shown must not throw away a folder the user picked by hand.
    /// A recent entry can name a folder that has since been deleted or is on
    /// an unmounted volume, so the list is walked rather than blindly taking
    /// its head — otherwise the screen would come up pointed at nothing and
    /// Start would fail at the shim.
    private func preselectMostRecentDirectory() {
        guard selectedDirectory == nil else { return }
        var isDirectory: ObjCBool = false
        for dir in recentDirectories
        where FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        {
            // No explicit `refreshBranchName()`: assigning `selectedDirectory`
            // fires `.onChange`, and calling both ran the whole git/VCS
            // subprocess chain twice on every launcher mount.
            selectedDirectory = dir
            return
        }
    }

    private func refreshBranchName() {
        guard let dir = selectedDirectory, GitWorktree.isGitRepo(dir) else {
            currentBranchName = nil
            baseRef = nil
            baseRefLabel = nil
            baseCandidates = []
            pickedBaseRef = nil
            return
        }
        // Cleared synchronously, so the window between picking a folder and its
        // reads finishing cannot serve the PREVIOUS folder's data. That has to
        // include `currentBranchName`: it is written last, after a third
        // detached read, and the branch chip reads it directly — so leaving it
        // out meant the chip confidently named folder A's branch while folder
        // B was selected, which is the exact bug this clear exists to stop,
        // one field short.
        currentBranchName = nil
        baseRef = nil
        baseRefLabel = nil
        baseCandidates = []
        pickedBaseRef = nil
        Task {
            let base = await Task.detached(priority: .userInitiated) { () -> (String, String)? in
                guard let ref = GitWorktree.defaultBaseRef(for: dir) else { return nil }
                return (ref, GitWorktree.displayBaseRef(ref, for: dir))
            }.value
            let candidates = await Task.detached(priority: .userInitiated) {
                GitWorktree.baseCandidates(for: dir)
            }.value
            if selectedDirectory == dir {
                baseRef = base?.0
                baseRefLabel = base?.1
                baseCandidates = candidates
            }
            let name = await Task.detached(priority: .userInitiated) {
                // The same reader the status bar uses, so the launcher cannot
                // disagree with the pane it is about to open. It matters here
                // rather than being tidiness: these repos are jj-colocated, so
                // git HEAD is permanently detached and a git-only read renders
                // "detached" on every one of them — accurate and useless.
                //
                // `branchNameOnly` strips the working-copy status this returns
                // ("main (modified)"), which belongs on a status pill and reads
                // as part of the name anywhere else.
                let raw = ShimProcess.detectVCSInfo(at: dir)?.branch ?? ""
                let cleaned = GitWorktree.branchNameOnly(raw)
                return cleaned.isEmpty ? GitWorktree.currentBranch(for: dir) : cleaned
            }.value
            // Discard a read that finished after the user moved on, or the
            // chip would name the previous folder's branch.
            if selectedDirectory == dir { currentBranchName = name }
        }
    }

    private var selectedDirectoryIsGitRepo: Bool {
        if let d = selectedDirectory {
            GitWorktree.isGitRepo(d)
        } else {
            false
        }
    }

    // MARK: - Composer
    //
    // The launch screen is one composer, not a form.
    //
    /// It replaced a vertical stack of labelled `GridRow`s — Provider, Model,
    /// Effort, Permission, Worktree, a Working Directory card, a Continue
    /// checkbox and an SSH toggle — where every session started by reading
    /// eight controls the answer to which is almost always the same as last
    /// time. The shape here is Cursor's and Codex's: **context above the box,
    /// how-to-run inside it, and nothing else on screen.**
    ///
    /// The split is not cosmetic. The chips answer *where the work happens*
    /// (folder, branch, worktree, machine, fresh-or-resume) and are the things
    /// that change between one session and the next; the controls inside the
    /// box answer *how the model runs* and mostly do not. Putting the second
    /// group inside the box is what lets the first group be a single scannable
    /// line instead of a column of labels.
    ///
    /// The lists that used to sit below (recent folders, session history, web
    /// sessions) are gone from the body rather than restyled: the sidebar
    /// already lists every session and recent project, so the launcher was
    /// rendering a second copy of it directly beside the first. What survives
    /// moved into the menu of the chip it belongs to.

    /// Icon and a line that names what is about to happen.
    ///
    /// The old header was the app icon over "Canopy" over "Start a new
    /// session" — three lines that between them said nothing the title bar and
    /// the sidebar did not. This one is folder-aware and mode-aware, so it is
    /// the only place on screen that states the whole intent in one sentence,
    /// and it changes when the Continue chip does — which is also the answer to
    /// "what happens if I type something with Continue on", asked before the
    /// screen said it anywhere.
    private var launchHeader: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text(headlineText)
                .font(.system(size: 21, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
        .padding(.bottom, 4)
    }

    private var headlineText: String {
        let place = isRemoteMode
            ? (remoteHost.isEmpty ? nil : remoteHost)
            : selectedDirectory?.lastPathComponent
        guard let place else {
            return willContinueSession ? "Where were we?" : "What should we build?"
        }
        if willContinueSession { return "Where were we in \(place)?" }
        if willCreateWorktree { return "What should we build in a new \(place) worktree?" }
        return "What should we build in \(place)?"
    }

    private var contextChipRow: some View {
        // Widest scope first, narrowing left to right: which machine, which
        // folder on it, whether a worktree is cut from that folder, and what
        // that worktree branches from.
        //
        // The branch chip sits immediately after the worktree chip because it
        // is no longer independent of it: with a worktree it reads "from main",
        // which is a property of the worktree being made, not of the folder.
        // It was second in the row before, next to the folder, and that
        // adjacency is what made "New worktree" look like it branched off
        // whatever the folder was on.
        ChipFlowLayout(spacing: 6, lineSpacing: 6) {
            locationChip
            directoryChip
            if !isRemoteMode, selectedDirectoryIsGitRepo {
                worktreeChip
                branchChip
            }
            continueChip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var directoryLabel: String {
        if isRemoteMode {
            return remoteDirectory.isEmpty ? "Choose folder" : (remoteDirectory as NSString).lastPathComponent
        }
        return selectedDirectory?.lastPathComponent ?? "Choose folder"
    }

    private var directoryChip: some View {
        Menu {
            if isRemoteMode {
                // Routed through the setup sheet rather than presenting a
                // second copy of the browser: two presenters for one
                // `showRemoteBrowser` is a state both would fight over.
                Button("Browse remote…") { showRemoteSetup = true }
            } else {
                if !recentDirectories.isEmpty {
                    Section("Recent") {
                        ForEach(recentDirectories.prefix(15), id: \.path) { dir in
                            Button(dir.lastPathComponent) { selectedDirectory = dir }
                        }
                    }
                    Divider()
                }
                Button("Open folder…") { chooseFolder() }
                Button("Clone from GitHub…") { showCloneSheet = true }
            }
        } label: {
            ChipLabel(
                icon: "folder",
                text: directoryLabel,
                muted: isRemoteMode ? remoteDirectory.isEmpty : selectedDirectory == nil
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .chipStyle()
        .help(isRemoteMode ? remoteDirectory : (selectedDirectory?.abbreviatingWithTilde ?? "No folder chosen"))
        .sheet(isPresented: $showCloneSheet) {
            CloneRepoSheet { cloned in
                selectedDirectory = cloned
                RecentDirectories.add(cloned)
                recentDirectories = RecentDirectories.load()
            }
        }
    }

    /// A label, not a control — and now drawn as one.
    ///
    /// It wore the same pill as its neighbours at first and was reported as
    /// "the branch pill doesn't do anything", which was the right reading of a
    /// wrong signal: a pill among pills invites a click. With no fill and no
    /// border the row reads as four controls and one fact.
    ///
    /// **Switching is deliberately absent, not missing.** Cursor and Codex
    /// both make their equivalent a switcher, and copying that here would be
    /// actively harmful: these repos are jj-colocated, where the git branch is
    /// not what moves the working copy (`jj edit` / `jj new` are), so a
    /// `git switch` would leave git and jj disagreeing about where the repo
    /// is. Doing it safely means detecting the VCS, refusing on a dirty tree,
    /// and speaking jj's vocabulary — a feature, not a menu.
    ///
    /// It still earns its space: this is the line that says which branch the
    /// prompt is about to run against, which is the confusion the whole
    /// branch-display fix was about.
    @ViewBuilder
    private var branchChip: some View {
        if startInWorktree, !baseCandidates.isEmpty {
            // With a worktree this chip is a control, because there is a real
            // choice behind it: which branch the new one starts from.
            Menu {
                // Most recently committed first, with the recommended one
                // marked — the picker offers the choice without asking a
                // question it can answer itself.
                ForEach(baseCandidates) { candidate in
                    Button {
                        // Choosing the recommended entry clears the override
                        // rather than pinning it, so a later folder change
                        // still moves the default with it.
                        pickedBaseRef = (candidate.name == baseRefLabel) ? nil : candidate
                    } label: {
                        // No "(recommended)" marker: the default IS the
                        // recommendation, and it opens already checked, so the
                        // word only annotated the row the checkmark was on.
                        Label(
                            candidate.name,
                            systemImage: isSelectedBase(candidate) ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                ChipLabel(icon: "arrow.triangle.branch", text: branchChipText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .chipStyle()
            .help(branchChipHelp)
        } else {
            // Without one it is a fact, not a control: Canopy does not switch
            // the branch a folder is on (see the type doc), so a pill here
            // would invite a click that cannot be honoured.
            ChipLabel(
                icon: "arrow.triangle.branch",
                text: branchChipText,
                muted: true,
                )
            // Keeps the pills' vertical metric so the row still aligns, and
            // enough horizontal room not to crowd them — everything except the
            // fill and the border, which are what said "press me".
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .help(branchChipHelp)
        }
    }

    /// With no worktree, the branch the prompt runs ON. With one, the branch
    /// the new worktree starts FROM.
    ///
    /// Those are different questions and the chip used to answer only the
    /// first, while sitting beside a "New worktree" chip — which read as "the
    /// new worktree comes off this", and was reported as exactly that
    /// confusion. It was also TRUE at the time, which is what made it worth
    /// fixing in the code rather than only in the label.
    private var branchChipText: String {
        guard startInWorktree else { return currentBranchName ?? "detached" }
        if let pickedBaseRef { return "from \(pickedBaseRef.name)" }
        return "from \(baseRefLabel ?? currentBranchName ?? "HEAD")"
    }

    private var branchChipHelp: String {
        startInWorktree
            ? "Which branch the new worktree starts from"
            : "Branch of the selected folder. Canopy does not switch branches."
    }

    private func isSelectedBase(_ candidate: GitWorktree.BaseCandidate) -> Bool {
        if let pickedBaseRef { return pickedBaseRef.ref == candidate.ref }
        return candidate.name == baseRefLabel
    }

    /// The base handed to `git worktree add`, honouring a hand-picked one.
    ///
    /// Nil reaches git as "no start-point", i.e. the folder's own HEAD. That is
    /// only correct when nothing resolved at all — see `defaultBaseRef`.
    private var resolvedBaseRef: String? {
        pickedBaseRef?.ref ?? baseRef
    }

    private var worktreeChip: some View {
        Menu {
            Button {
                startInWorktree = false
            } label: {
                Label("Work in this folder", systemImage: startInWorktree ? "" : "checkmark")
            }
            Button {
                startInWorktree = true
            } label: {
                // Just "New worktree": naming from the prompt is the only
                // way it happens now that the hand-typed field is gone, so
                // saying so described the mechanism rather than the choice.
                Label("New worktree", systemImage: startInWorktree ? "checkmark" : "")
            }
            // The base list used to hang off this menu, which split the
            // question in two: the chip that SHOWED the branch could not change
            // it, and the chip that changed it did not show it. It lives on the
            // branch chip now.
        } label: {
            ChipLabel(
                icon: startInWorktree ? "square.on.square.dashed" : "square",
                text: startInWorktree ? "New worktree" : "No worktree",
                muted: !startInWorktree
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .chipStyle()
    }

    private var locationChip: some View {
        Menu {
            Button {
                isRemoteMode = false
            } label: {
                Label("This Mac", systemImage: isRemoteMode ? "" : "checkmark")
            }
            if !savedHosts.isEmpty {
                Section("SSH") {
                    ForEach(savedHosts, id: \.self) { host in
                        Button {
                            remoteHost = host
                            isRemoteMode = true
                        } label: {
                            Label(host, systemImage: isRemoteMode && remoteHost == host ? "checkmark" : "")
                        }
                    }
                }
            }
            Divider()
            Button("Connect to host…") { showRemoteSetup = true }
        } label: {
            ChipLabel(
                icon: isRemoteMode ? "network" : "desktopcomputer",
                text: isRemoteMode ? (remoteHost.isEmpty ? "SSH host…" : remoteHost) : "This Mac",
                muted: isRemoteMode && remoteHost.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .chipStyle()
        .sheet(isPresented: $showRemoteSetup) { remoteSetupSheet }
    }

    /// Host and path for an SSH session.
    ///
    /// Purpose-built rather than the old vertical form's two cards restored:
    /// those were sized for a 560pt column and carried their own headings,
    /// which is the shape this screen just stopped being.
    private var remoteSetupSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect over SSH")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Host").font(.caption).foregroundStyle(.secondary)
                TextField("user@host or an ssh_config name", text: $remoteHost)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Directory").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("~", text: $remoteDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { showRemoteBrowser = true }
                        .disabled(remoteHost.isEmpty)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showRemoteSetup = false
                    // Leaving remote mode on with no host is the dead end this
                    // sheet exists to close, so cancelling restores local.
                    if remoteHost.trimmingCharacters(in: .whitespaces).isEmpty {
                        isRemoteMode = false
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button("Use This Host") {
                    // Trimmed before it is stored OR launched: `SSHHostStore`
                    // does not normalise, and " myhost " reaches ssh as a
                    // destination containing spaces.
                    remoteHost = remoteHost.trimmingCharacters(in: .whitespaces)
                    SSHHostStore.add(remoteHost)
                    savedHosts = SSHHostStore.hosts()
                    isRemoteMode = true
                    showRemoteSetup = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remoteHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        // Mounted on the sheet that owns the Browse button. The presenter used
        // to live on the deleted `remoteDirectoryCard`, and removing that view
        // took the browser with it — the button stayed, and did nothing.
        .sheet(isPresented: $showRemoteBrowser) {
            RemoteDirectoryBrowser(sshHost: remoteHost) { path in
                remoteDirectory = path
            }
        }
    }

    private var continueChip: some View {
        Menu {
            Button {
                continueSession = false
            } label: {
                Label("New session", systemImage: willContinueSession ? "" : "checkmark")
            }
            Button {
                continueSession = true
            } label: {
                Label(
                    willCreateWorktree
                        ? "Continue — not with a new worktree"
                        : "Continue the latest session",
                    systemImage: willContinueSession ? "checkmark" : ""
                )
            }
            // Disabled rather than hidden: a row that vanishes reads as a bug,
            // and the point is to say WHY the two cannot combine.
            .disabled(willCreateWorktree)
        } label: {
            ChipLabel(
                icon: willContinueSession ? "arrow.uturn.backward" : "plus.bubble",
                text: willContinueSession ? "Continue" : "New session",
                muted: !willContinueSession
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .chipStyle()
    }

    /// Whether this launch will actually resume something.
    ///
    /// **"Continue" and "New worktree" cannot both be honoured.** A worktree
    /// created a second ago has no session history, so `latestSession` finds
    /// nothing and the launch silently falls through to a fresh session — while
    /// the headline said "Where were we in Canopy?" and the composer said "Pick
    /// up where you left off". Three surfaces lying in agreement.
    ///
    /// The worktree wins because it is the thing the user just built a name and
    /// a checkout for. `continueSession` is deliberately NOT written to: it is
    /// a persisted preference, and flipping it here would silently lose the
    /// user's setting the moment they turned the worktree off again.
    private var willContinueSession: Bool {
        continueSession && !willCreateWorktree
    }

    /// Whether this launch will actually cut a worktree.
    ///
    /// `startInWorktree` alone is not that: the toggle survives switching to
    /// SSH or picking a non-Git folder, where the chip disappears and
    /// `startSession` bypasses worktree creation entirely — but the Continue
    /// conflict kept firing, so a persisted Continue silently launched a fresh
    /// session on a path that was never going to make a worktree.
    ///
    /// Every reader that MAKES A CLAIM about a worktree goes through this: the
    /// Continue conflict, the headline, and the composer's placeholder. The
    /// first version of this comment said "every reader" flatly, and the
    /// headline and placeholder were still on the raw toggle — so the same
    /// switch-to-SSH gesture left the screen promising "a new mbp worktree"
    /// while nothing was going to cut one. The chip's own text stays on the
    /// raw toggle deliberately: it renders only inside the gate, so the two
    /// are equivalent there and reading the toggle is what the chip is FOR.
    private var willCreateWorktree: Bool {
        startInWorktree && !isRemoteMode && selectedDirectoryIsGitRepo
    }

    private var composerPlaceholder: String {
        // Each mode says what this box will actually do with the text, because
        // the three outcomes genuinely differ: a fresh turn, a turn appended to
        // an existing conversation, or a turn that also names a branch.
        if willContinueSession { return "Pick up where you left off" }
        if willCreateWorktree { return "Describe a task — it names the branch too" }
        return "Describe a task or ask a question"
    }

    private var composerBox: some View {
        VStack(spacing: 0) {
            TextField("", text: $initialPrompt, prompt: Text(composerPlaceholder), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(3 ... 12)
                // Shift+Return inserts a newline. Measured on a standalone
                // SwiftUI harness (macOS 26.6): in a `TextField(axis:
                // .vertical)` the field editor binds a newline to
                // OPTION+Return only — plain Return submits, and Shift+Return
                // and Cmd+Return are both dead keys. So the prompt box was
                // single-line to anyone typing the chat-composer convention,
                // and the send button's `.keyboardShortcut(.return,
                // modifiers: [])` was NOT the cause: Shift+Return does not
                // match it either, which is why the press produced nothing at
                // all rather than a launch.
                //
                // The handler re-issues the binding that already works rather
                // than appending "\n" to `initialPrompt` — the caret can be
                // mid-text, and only the field editor knows where it is.
                // Undo, selection replacement and scroll-to-caret come along
                // for free.
                //
                // The shift test is `contains`, not an exact match, so
                // Shift+Option+Return and Shift+Cmd+Return insert a newline
                // too. Deliberate: an exact match would only turn those combos
                // back into the dead keys this is fixing. Every other Return
                // returns `.ignored`, which is what keeps plain Return
                // reaching the send button's shortcut and Option+Return
                // reaching the field editor unchanged — re-measured on the
                // harness with the handler installed, and the real launcher
                // checked on a Debug build.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift),
                          let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                    else { return .ignored }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .disabled(isCreatingWorktree || isResolvingRemoteSession)

            HStack(spacing: 5) {
                moreMenu
                modelChip
                if isAnthropicProvider { effortChip }
                permissionChip
                Spacer(minLength: 8)
                sendButton
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isDropTargeted ? 2 : 1)
        )
    }

    /// Everything that is neither context nor a model setting.
    ///
    /// Mirrors the `+` both reference apps put in the same corner: the drawer
    /// for actions that would each otherwise want a chip of their own and are
    /// reached once a week rather than once a session.
    private var moreMenu: some View {
        Menu {
            if !providers.isEmpty {
                Section("Provider") {
                    Button {
                        selectedProviderId = ""
                    } label: {
                        Label("Anthropic (default)",
                              systemImage: selectedProviderId.isEmpty ? "checkmark" : "")
                    }
                    ForEach(providers) { provider in
                        Button {
                            selectedProviderId = provider.id
                        } label: {
                            Label(provider.name,
                                  systemImage: selectedProviderId == provider.id ? "checkmark" : "")
                        }
                    }
                }
                Divider()
            }
            Button("Claude Code on the Web…") { Task { await toggleWebSessions() } }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var modelChip: some View {
        Menu {
            Button { model = "" } label: {
                Label("Auto", systemImage: model.isEmpty ? "checkmark" : "")
            }
            ForEach(Self.modelOptions.dropFirst(), id: \.self) { alias in
                Button { model = alias } label: {
                    Label(Self.modelDisplayName(alias), systemImage: model == alias ? "checkmark" : "")
                }
            }
        } label: {
            ChipLabel(icon: "sparkle",
                      text: model.isEmpty ? "Auto" : Self.modelDisplayName(model),
                      muted: model.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .chipStyle()
    }

    private var effortChip: some View {
        Menu {
            Button { effortLevel = "" } label: {
                Label("Auto", systemImage: effortLevel.isEmpty ? "checkmark" : "")
            }
            ForEach(Self.effortOptions.dropFirst(), id: \.self) { level in
                Button { effortLevel = level } label: {
                    Label(Self.effortDisplayName(level), systemImage: effortLevel == level ? "checkmark" : "")
                }
            }
        } label: {
            ChipLabel(icon: "gauge.with.dots.needle.33percent",
                      text: effortLevel.isEmpty ? "Auto" : Self.effortDisplayName(effortLevel),
                      muted: effortLevel.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .chipStyle()
    }

    private var permissionChip: some View {
        Menu {
            ForEach(visiblePermissionModes, id: \.rawValue) { mode in
                Button { permissionModeRaw = mode.rawValue } label: {
                    Label(mode.displayName, systemImage: permissionModeRaw == mode.rawValue ? "checkmark" : "")
                }
            }
            if CanopySettings.shared.allowDangerouslySkipPermissions {
                Button { permissionModeRaw = PermissionMode.bypassPermissions.rawValue } label: {
                    Label(PermissionMode.bypassPermissions.displayName,
                          systemImage: permissionModeRaw == PermissionMode.bypassPermissions.rawValue ? "checkmark" : "")
                }
            }
        } label: {
            ChipLabel(icon: "lock.shield", text: resolvedPermission.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .chipStyle()
    }

    /// The one control that is a button rather than a menu.
    ///
    /// Deliberately just the arrow: the three steps behind a worktree launch
    /// — naming, checkout, copying ignored files — used to be reported in this
    /// label, which put a changing sentence inside a 20pt control and reflowed
    /// the row under the cursor. They belong on `SpawningOverlay`, which has
    /// replaced this whole screen by the time there is a stage to report.
    private var sendButton: some View {
        Button {
            startSession()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canStart ? Color.accentColor : Color.secondary.opacity(0.5))
        .disabled(!canStart)
        .keyboardShortcut(.return, modifiers: [])
        .help("Start Session")
    }

    private var canStart: Bool {
        if isCreatingWorktree || isResolvingRemoteSession { return false }
        // **Deliberately NOT gated on base-ref resolution.** A gate here was
        // written and reverted in review: it cleared only from the completion
        // of three `Task.detached` reads that funnel into
        // `GitWorktree.runCommand`, which sends SIGTERM and then drains an
        // unbounded pipe — no SIGKILL escalation and no answer-anyway
        // deadline, both of which `CLIOneShot` has and argues for. A git hook
        // that ignores SIGTERM, or a grandchild holding the write end, wedges
        // that read forever, so the flag never cleared and Start went grey for
        // the life of the pane with no spinner and no log. Bricking a healthy
        // launcher is worse than the race it closed.
        //
        // The race that remains: pick a folder and press Return before the
        // reads answer, and the worktree branches from HEAD. Narrow (the reads
        // are fast on a warm repo), announced in the log by `createWorktree`'s
        // `from HEAD`, and it needs `runCommand` brought up to `CLIOneShot`'s
        // standard before a gate can be safe. Known limitation, recorded.
        return isRemoteMode
            ? !(remoteHost.trimmingCharacters(in: .whitespaces).isEmpty || remoteDirectory.isEmpty)
            : selectedDirectory != nil
    }

    // MARK: - Extension Update Banner

    @ViewBuilder
    private var extensionUpdateBanner: some View {
        switch updater.state {
        case .updateAvailable(let latestVersion, let currentVersion):
            updateBannerCard(icon: "arrow.down.circle", iconColor: .blue, tint: .blue) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extension update available")
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 6) {
                        if let currentVersion {
                            Text("v\(currentVersion) → v\(latestVersion)")
                        } else {
                            Text("v\(latestVersion)")
                        }
                        Text("·").foregroundStyle(.tertiary)
                        Link("Changelog", destination: ExtensionUpdater.changelogURL)
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Button("Update") {
                    Task { await updater.triggerInstall() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .downloading, .installing:
            let text = updater.state == .downloading ? "Downloading extension…" : "Installing extension…"
            updateBannerCard(tint: .secondary) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }

        case .done(let version):
            updateBannerCard(icon: "checkmark.circle.fill", iconColor: .green, tint: .green) {
                Text("Extension v\(version) installed. Restart Canopy to apply.")
                    .font(.system(size: 12))
                Button("Restart Now") {
                    AppDelegate.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .failed(let message):
            updateBannerCard(icon: "exclamationmark.triangle.fill", iconColor: .orange, tint: .orange) {
                Text("Update failed: \(message)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await updater.checkForUpdate() }
                }
                .controlSize(.small)
            }

        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }

    /// Ceiling for the update card, so a long failure message wraps instead of
    /// stretching the card past the composer it sits above.
    private static let bannerMaxWidth: CGFloat = 480

    private func updateBannerCard<C: View>(
        icon: String? = nil, iconColor: Color = .primary, tint: Color,
        @ViewBuilder content: () -> C
    ) -> some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).foregroundStyle(iconColor)
            }
            content()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Sized by what is in it. `fixedSize` horizontally is what actually
        // achieves that — merely dropping `maxWidth: .infinity` did not,
        // measured: the card still spanned the full column. Vertically fixed
        // too, so a long message grows the card rather than being clipped;
        // `bannerMaxWidth` is what keeps that from growing sideways instead.
        .frame(maxWidth: Self.bannerMaxWidth)
        .fixedSize(horizontal: true, vertical: true)
        // Matched to the composer's own corner and hairline rather than left
        // as a filled 8pt card: at full saturation it was the loudest thing on
        // a screen whose whole point is that the prompt box is.
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
        // Inside the card, so the idle state — which renders `EmptyView` —
        // cannot contribute a gap for a banner that is not there. It stacks on
        // the enclosing VStack's own 12, so the visible gap is ~30: this card
        // is an interruption between the headline and the composer, and at a
        // tighter spacing it read as a third element of the same group.
        .padding(.vertical, 18)
    }

    // MARK: - Session Options

    private var isAnthropicProvider: Bool { selectedProviderId.isEmpty }

    private var visiblePermissionModes: [PermissionMode] {
        if isAnthropicProvider {
            Self.permissionModes
        } else {
            Self.permissionModes.filter { $0 != .auto }
        }
    }

    private static func modelDisplayName(_ alias: String) -> String {
        // Every row is a bare family alias, so the shared variant split covers all of
        // them and no per-id case is needed: "fable" → "Fable", "opus" → "Opus",
        // "opus[1m]" → "Opus (1M)". The Picker tags "" as "Auto" itself and iterates
        // `dropFirst()`, so the empty option never reaches here.
        let (base, suffix) = ModelNameFormatter.splitVariant(alias)
        guard !base.isEmpty else { return alias }
        return base.prefix(1).uppercased() + String(base.dropFirst()) + suffix
    }

    private static func effortDisplayName(_ level: String) -> String {
        switch level {
        case "xhigh": "X-High"
        default: level.prefix(1).uppercased() + level.dropFirst()
        }
    }

    /// The typed prompt, or nil when the field is empty.
    ///
    /// Read by EVERY launch route this view owns, not just the Start button:
    /// clicking a recent directory, a session-history row, or a teleported web
    /// session all submit it too. One rule — whatever is in the field is sent
    /// to whatever session you open — because the alternative is a field that
    /// silently does nothing depending on which control was clicked, and
    /// nothing on screen would say which those are.
    private var pendingPromptForLaunch: String? {
        let trimmed = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Empty the prompt field after it has been handed to a session.
    ///
    /// Usually invisible, because starting a session unmounts this view and
    /// takes its `@State` with it. The case that survives is Cmd+click, which
    /// puts the session in a NEW pane and leaves the launcher pane standing —
    /// with the prompt still in the box, and the next Start would submit it a
    /// second time. Clearing is also what makes the field agree with what will
    /// happen: text sitting in it means text that is about to be sent.
    private func clearPendingPrompt() {
        initialPrompt = ""
    }

    // MARK: - Web Sessions Section

    private var webSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Code on the Web")
                    .font(.headline)
                Spacer()
                if showWebSessions && webSessionsLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await toggleWebSessions() }
                } label: {
                    Label(
                        showWebSessions ? "Hide" : "Show",
                        systemImage: showWebSessions ? "chevron.up" : "chevron.down"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                }
                .controlSize(.small)
            }

            if showWebSessions {
                HStack(spacing: 10) {
                    Picker("", selection: $webSessionKindRaw) {
                        ForEach(RemoteSessionKind.allCases, id: \.rawValue) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                    Toggle("Include archived", isOn: $webSessionsIncludeArchived)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.caption)
                    Spacer()
                    Button {
                        Task { await fetchWebSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .disabled(webSessionsLoading)
                }

                if let webSessionsError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(webSessionsError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") {
                            Task { await fetchWebSessions() }
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    let filtered = filteredWebSessions
                    if filtered.isEmpty && !webSessionsLoading {
                        let kind = RemoteSessionKind(rawValue: webSessionKindRaw) ?? .web
                        Text("No \(kind.displayName.lowercased()) sessions found.\(webSessionsIncludeArchived ? "" : " Toggle 'Include archived' to widen the search.")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, session in
                                    webSessionRow(session)
                                    if index < filtered.count - 1 {
                                        Divider().padding(.leading, 34)
                                    }
                                }
                            }
                        }
                        .frame(height: Self.rowHeight * CGFloat(min(filtered.count, Self.listRowCount)))
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let teleportError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(teleportError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .alert(item: $pendingBranchPrompt) { prompt in
            Alert(
                title: Text("Switch git branch?"),
                message: Text("This remote session was on branch '\(prompt.branch)'. Check it out in \(prompt.cwd.lastPathComponent) to keep file context aligned?"),
                primaryButton: .default(Text("Switch")) {
                    prompt.onDecision(true)
                },
                secondaryButton: .cancel(Text("Skip")) {
                    prompt.onDecision(false)
                }
            )
        }
        .onDisappear {
            // Safety net: if the window closes while the alert is up, fire
            // the decision so the awaiting Task can finish and shutdown the
            // bridge subprocess. ResolveOnce makes this a no-op if a button
            // already responded.
            if let prompt = pendingBranchPrompt {
                prompt.onDecision(false)
                pendingBranchPrompt = nil
            }
        }
    }

    private func webSessionRow(_ session: RemoteSession) -> some View {
        let isHovered = hoveredWebSessionId == session.id
        let isTeleporting = teleportingSessionId == session.id
        return Button {
            Task { await teleport(session) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: session.status == "running" ? "circle.fill" : "globe")
                    .foregroundStyle(session.status == "running" ? .green : .blue)
                    .font(.callout)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.summary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let owner = session.repoOwner, let name = session.repoName {
                            Text("\(owner)/\(name)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let branch = session.displayBranch {
                            Text("\u{00B7}")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(branch)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("\u{00B7}")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(Self.sessionDateFormatter.string(from: session.lastModified))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isTeleporting {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(teleportingSessionId != nil)
        .onHover { h in hoveredWebSessionId = h ? session.id : nil }
    }

    // MARK: - Session Row

    private static let sessionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: - Actions

    private var resolvedPermission: PermissionMode {
        var perm = PermissionMode(rawValue: permissionModeRaw) ?? .acceptEdits
        if perm == .bypassPermissions && !CanopySettings.shared.allowDangerouslySkipPermissions {
            perm = .acceptEdits
        }
        return perm
    }

    private func buildCustomApiConfig() -> ModelProvider? {
        guard !selectedProviderId.isEmpty else { return nil }
        return providers.first { $0.id == selectedProviderId }
    }

    private func latestSession(for directory: URL) -> SessionEntry? {
        // Query disk directly rather than filtering the in-memory `sessions`
        // list: that one comes from `loadAllSessions`, which drops entries whose
        // cwd is missing locally — fine for UI listing, wrong for continue,
        // because a directory can be gone (an unmounted volume, a deleted
        // worktree) while its transcripts are still resumable.
        //
        // Selection is by ORDER on the remote path, which never reaches this
        // `.max` — see `RemoteSessionHistory`.
        //
        // LOCAL sessions only. This reads this machine's `~/.claude/projects`,
        // and a remote session's transcripts are on the remote host — an older
        // version of this comment claimed the disk read covered SSH workspace
        // folders, which is exactly backwards and is why remote "Continue
        // session" silently started from scratch. `RemoteSessionHistory` is
        // that case; `launchLocal` routes to it.
        ClaudeSessionHistory.loadSessions(for: directory)
            .max { $0.timestamp < $1.timestamp }
    }

    /// Launch from a recent directory row. If "Continue session" is on, resume the most recent session for that directory.
    private func launchFromDirectory(_ dir: URL) {
        let selectedModel = model.isEmpty ? nil : model
        let selectedEffort = effortLevel.isEmpty ? nil : effortLevel

        var resumeId: String?
        var resumeTitle: String?
        if willContinueSession, let latest = latestSession(for: dir) {
            resumeId = latest.id
            resumeTitle = latest.title
        }
        appState.launchSession(directory: dir, resumeSessionId: resumeId, sessionTitle: resumeTitle, model: selectedModel, effortLevel: selectedEffort, permissionMode: resolvedPermission, customApi: buildCustomApiConfig(), initialPrompt: pendingPromptForLaunch)
        clearPendingPrompt()
    }

    private func startSession() {
        // The Start button is `.disabled` while a remote lookup is in flight;
        // the SSH Host and Remote Directory fields' `onSubmit` are not, so
        // Enter reaches here regardless. Before the remote branch went async
        // there was no window to re-enter — now each press spawns its own
        // lookup Task, and each Task that finishes calls `launchSession`, so
        // holding Enter opens a pane per press against one resume id.
        guard !isResolvingRemoteSession else { return }
        let selectedModel = model.isEmpty ? nil : model
        let selectedEffort = effortLevel.isEmpty ? nil : effortLevel
        let selectedPermission = resolvedPermission
        if selectedPermission != PermissionMode(rawValue: permissionModeRaw) {
            permissionModeRaw = selectedPermission.rawValue
        }

        if isRemoteMode {
            // Trimmed here as well as in the sheet: Cancel leaves an edited
            // host in place when the trimmed value is non-empty, so " newhost "
            // could still reach `ssh` — and `SSHHostStore.add` would persist
            // the untrimmed form into the saved list forever.
            remoteHost = remoteHost.trimmingCharacters(in: .whitespaces)
            guard !remoteHost.isEmpty, !remoteDirectory.isEmpty else { return }
            SSHHostStore.add(remoteHost)
            savedHosts = SSHHostStore.hosts()
            launchLocal(URL(fileURLWithPath: remoteDirectory), remoteHost: remoteHost,
                        model: selectedModel, effort: selectedEffort, permission: selectedPermission)
            return
        }

        guard let local = selectedDirectory else { return }
        guard startInWorktree, selectedDirectoryIsGitRepo else {
            launchLocal(local, remoteHost: nil,
                        model: selectedModel, effort: selectedEffort, permission: selectedPermission)
            return
        }

        // Worktree checkout can take seconds on big repos — keep it off the
        // main thread. The composer is not merely disabled while it runs: it
        // is replaced by `SpawningOverlay` (see `body`).
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sampled at the press, not after the await. `AppState.launchSession`
        // reads `NSEvent.modifierFlags` when it is called, and everything below
        // — naming, checkout, seeding — happens first, so by then the modifier
        // is long released and Cmd+click quietly lost its new pane. Same hazard
        // the SSH-continue branch documents; same fix.
        let cmdHeld = NSEvent.modifierFlags.contains(.command)
        isCreatingWorktree = true
        let repo = local
        let api = buildCustomApiConfig()
        Task {
            defer {
                isCreatingWorktree = false
                worktreeStage = nil
            }
            // There is no hand-typed name to prefer any more: the field that
            // offered one was removed as unused, and the three-rung fallback
            // below already covers every case it did.
            worktreeStage = "Naming Branch…"
            let named = await resolveBranchName(prompt: prompt, customApi: api)
            // Two worktrees started from the same prompt get the same slug, and
            // `worktree add -b` fails outright on a taken name — with no field
            // left for the user to resolve it in.
            let branchName = await Task.detached(priority: .userInitiated) {
                GitWorktree.uniqueBranchName(named, in: repo)
            }.value
            do {
                worktreeStage = "Creating Worktree…"
                // `resolvedBaseRef` is nil until the probe started by
                // `refreshBaseRef` lands, and Start is reachable before then —
                // so reading it alone silently reproduces the bug the base-ref
                // ladder exists to fix: a worktree branched from whatever HEAD
                // happens to be, invisible until somebody else's unmerged work
                // shows up in the diff. The user's own pick always wins; the
                // fallback resolves only when nothing has resolved yet.
                //
                // Deterministic where a UI gate was not. An earlier revision
                // disabled Start until the probe landed, which could latch
                // forever on a wedged probe and leave the button grey with no
                // way out. This costs one `git` call on a path already running
                // several, and cannot latch.
                let picked = resolvedBaseRef
                let worktree = try await Task.detached(priority: .userInitiated) {
                    let base = picked ?? GitWorktree.defaultBaseRef(for: repo)
                    return try GitWorktree.createWorktree(
                        repo: repo, branch: branchName, baseRef: base)
                }.value
                // A fresh worktree holds only tracked files, so for most
                // projects it cannot build until this runs. Deliberately AFTER
                // the checkout and BEFORE the session opens: seeding into a
                // half-created worktree is meaningless, and a session that
                // opens first would have its first turn racing the copy.
                if CanopySettings.shared.seedWorktreeArtifacts {
                    worktreeStage = "Copying Build Files…"
                    await Task.detached(priority: .userInitiated) {
                        // Discarded on purpose: the report is for the log, and
                        // a partial seed is not a reason to withhold a worktree
                        // the user asked for.
                        _ = GitWorktree.seedIgnoredFiles(repo: repo, worktree: worktree)
                    }.value
                }
                launchLocal(worktree, remoteHost: nil,
                            model: selectedModel, effort: selectedEffort,
                            permission: selectedPermission, openInNewPane: cmdHeld)
            } catch {
                // NSAlert instead of a SwiftUI .alert: the user can navigate
                // away mid-creation, destroying this view's @State — a
                // view-bound alert would never appear (silent failure).
                let alert = NSAlert()
                alert.messageText = "Worktree Creation Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// Branch name for a worktree the user did not name themselves.
    ///
    /// Three rungs, each strictly worse than the one above and each measured
    /// against the same 21,265-session sample (see `WorktreeBranchNamer`):
    /// a model reading the prompt, then the same prompt slugified locally with
    /// no model call, then a timestamp. The timestamp is last because it is
    /// the one that is known NOT to work — the only two worktrees Canopy's
    /// launcher has ever created were named that way and neither was reopened.
    ///
    /// The middle rung is what keeps a CLI outage, an expired login or a
    /// 20-second timeout from dropping straight to that.
    private func resolveBranchName(prompt: String, customApi: ModelProvider?) async -> String {
        if !prompt.isEmpty {
            let generated = await withCheckedContinuation { continuation in
                WorktreeBranchNamer.generate(prompt: prompt, customApi: customApi) { name in
                    continuation.resume(returning: name)
                }
            }
            if let generated, !generated.isEmpty { return generated }
            let local = GitWorktree.slugFromPrompt(prompt)
            if !local.isEmpty { return local }
        }
        return GitWorktree.suggestedBranchName()
    }

    /// `openInNewPane` is nil for every synchronous caller, which lets
    /// `AppState.launchSession` sample the modifier itself. Only a caller that
    /// crosses an `await` before reaching here has to pass one — see the
    /// worktree path and the SSH-continue branch below.
    private func launchLocal(
        _ dir: URL, remoteHost: String?, model: String?, effort: String?,
        permission: PermissionMode, openInNewPane: Bool? = nil
    ) {
        // A remote session's transcripts live on the OTHER machine, so
        // `latestSession(for:)` — which reads this machine's
        // `~/.claude/projects` — can only ever miss, or worse, hand the remote
        // CLI a local id for a conversation it has never seen. Resolve it over
        // SSH instead. See `RemoteSessionHistory`.
        //
        // Only when the user asked to continue: a fresh remote session must
        // not pay a network round trip to learn something it will not use.
        if let remoteHost, willContinueSession {
            // Captured BEFORE the await. `launchSession` samples the modifier
            // itself for every synchronous caller; this is the one route where
            // "now" is a round trip too late.
            let cmdHeld = NSEvent.modifierFlags.contains(.command)
            isResolvingRemoteSession = true
            Task {
                let latest = await RemoteSessionHistory.latestSession(host: remoteHost, directory: dir)
                isResolvingRemoteSession = false
                // A miss is not an error worth a dialog: an unreachable host
                // fails again, visibly, one step later when the shim starts,
                // and a directory with no resumable session is the ordinary
                // first-run case. Both land on a fresh session, which is what
                // this path did before the lookup existed.
                appState.launchSession(directory: dir, resumeSessionId: latest?.id, sessionTitle: latest?.title, model: model, effortLevel: effort, permissionMode: permission, remoteHost: remoteHost, customApi: buildCustomApiConfig(), openInNewPane: cmdHeld, initialPrompt: pendingPromptForLaunch)
                clearPendingPrompt()
            }
            return
        }

        var resumeId: String?
        var resumeTitle: String?
        if willContinueSession, let latest = latestSession(for: dir) {
            resumeId = latest.id
            resumeTitle = latest.title
        }
        appState.launchSession(directory: dir, resumeSessionId: resumeId, sessionTitle: resumeTitle, model: model, effortLevel: effort, permissionMode: permission, remoteHost: remoteHost, customApi: buildCustomApiConfig(), openInNewPane: openInNewPane, initialPrompt: pendingPromptForLaunch)
        clearPendingPrompt()
    }

    private func loadData() {
        ModelProviderStore.migrateIfNeeded()
        providers = ModelProviderStore.load()
        recentDirectories = RecentDirectories.load()
        savedHosts = SSHHostStore.hosts()
        // No `loadAllSessions()` here any more. Its only consumer was the
        // session-history list this screen no longer has, and the scan walks
        // every JSONL under `~/.claude/projects` parsing metadata — ~21,000
        // sessions on this machine — once per launcher pane mount. Deleting a
        // view has to delete what fed it; `latestSession(for:)` does its own
        // per-directory read and deliberately never used this.
    }

    // MARK: - Web Sessions / Teleport

    private func toggleWebSessions() async {
        showWebSessions.toggle()
        if showWebSessions && webSessions.isEmpty && !webSessionsLoading {
            await fetchWebSessions()
        }
    }

    private func fetchWebSessions() async {
        webSessionsError = nil
        webSessionsLoading = true
        defer { webSessionsLoading = false }

        do {
            let sessions = try await RemoteSessionsAPI.listAll()
            webSessions = sessions.sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
                return $0.lastModified > $1.lastModified
            }
            // Empty result is a valid response — surface it as the empty-state
            // message in the list, not as a "you might not be logged in" error.
            // Real auth/HTTP errors throw and are caught below.
        } catch {
            webSessionsError = error.localizedDescription
        }
    }

    private var filteredWebSessions: [RemoteSession] {
        let kind = RemoteSessionKind(rawValue: webSessionKindRaw) ?? .web
        return webSessions.filter { session in
            guard session.kind == kind else { return false }
            if !webSessionsIncludeArchived && session.status == "archived" { return false }
            return true
        }
    }

    private func teleport(_ session: RemoteSession) async {
        teleportError = nil
        teleportingSessionId = session.id
        defer { teleportingSessionId = nil }

        guard let cwd = resolveTeleportCwd(for: session) else {
            teleportError = "Could not find a local clone of \(session.repoOwner ?? "?")/\(session.repoName ?? "?"). Pick a working directory first."
            return
        }

        // Validate cwd exists before spawning a shim that would otherwise time
        // out 30s later with a generic error.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            teleportError = "Working directory not found: \(cwd.path)"
            return
        }

        let bridge = RemoteSessionsBridge(cwd: cwd)
        do {
            try await bridge.start()
        } catch {
            teleportError = "Teleport failed: \(error.localizedDescription)"
            bridge.shutdown()
            return
        }
        // Tear the shim down on every exit path past start(), including SwiftUI
        // task cancellation (window close mid-flight) — otherwise the Node
        // process is orphaned.
        defer { bridge.shutdown() }

        let result: TeleportResult
        do {
            result = try await bridge.teleportSession(id: session.id)
        } catch {
            teleportError = "Teleport failed: \(error.localizedDescription)"
            return
        }

        // If extension returned a branch, ask the user before checking it out.
        // If they said Switch but the checkout failed, abort instead of resuming
        // on the wrong branch — running teleported history against the wrong
        // working copy is worse than not resuming at all.
        if let branch = result.branch, !branch.isEmpty {
            let switchToBranch = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // Wrap the decision callback so the continuation can only be
                // resumed once — even if both Alert and onDisappear fire.
                let resolved = ResolveOnce(cont)
                pendingBranchPrompt = BranchPrompt(branch: branch, cwd: cwd) { decision in
                    resolved.fire(decision)
                }
            }
            pendingBranchPrompt = nil

            if switchToBranch {
                var checkoutFailed = false
                do {
                    checkoutFailed = !(try await bridge.checkoutBranch(branch))
                } catch {
                    checkoutFailed = true
                }
                if checkoutFailed {
                    try? await bridge.updateSkippedBranch(sessionId: session.id, branch: branch, failed: true)
                    teleportError = "Couldn't switch to branch '\(branch)' in \(cwd.lastPathComponent). The session was saved locally but not resumed — switch the branch manually and use Continue session, or pick a different working directory."
                    return
                }
            } else {
                try? await bridge.updateSkippedBranch(sessionId: session.id, branch: branch, failed: false)
            }
        }

        guard let localId = result.localSessionId else {
            teleportError = "Teleport completed but no local session id was returned."
            return
        }

        appState.launchSession(
            directory: cwd,
            resumeSessionId: localId,
            sessionTitle: result.summary ?? session.summary,
            model: model.isEmpty ? nil : model,
            effortLevel: effortLevel.isEmpty ? nil : effortLevel,
            permissionMode: resolvedPermission,
            customApi: buildCustomApiConfig(),
            initialPrompt: pendingPromptForLaunch
        )
        clearPendingPrompt()
    }

    private func resolveTeleportCwd(for session: RemoteSession) -> URL? {
        if let selected = selectedDirectory { return selected }

        // Find recents whose lastPathComponent matches the repo name. If
        // exactly one matches, auto-confirm. If multiple, prompt the
        // user — picking the wrong clone of "myapp" and then running
        // checkoutBranch on it could damage unrelated work.
        if let repoName = session.repoName?.lowercased() {
            let matches = recentDirectories.filter { $0.lastPathComponent.lowercased() == repoName }
            if matches.count == 1, let only = matches.first {
                return only
            }
        }

        // Either zero matches or ambiguous — prompt the user.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let owner = session.repoOwner, let name = session.repoName {
            panel.message = "Pick the local clone of \(owner)/\(name) to teleport into"
        } else {
            panel.message = "Choose a local working directory for this remote session"
        }
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            return url
        }
        return nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select a project directory"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue
            else { return }
            DispatchQueue.main.async { selectedDirectory = url }
        }
        return true
    }
}

// MARK: - Supporting Types

struct BranchPrompt: Identifiable {
    let id = UUID()
    let branch: String
    let cwd: URL
    let onDecision: (Bool) -> Void
}

/// Wraps a CheckedContinuation so it can only be resumed once. Used to bridge
/// SwiftUI alerts (which can fire buttons OR be dismissed via system gestures)
/// to async code without leaking continuations.
final class ResolveOnce<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, Never>) {
        self.cont = cont
    }
    func fire(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - URL extension

extension URL {
    var abbreviatingWithTilde: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
