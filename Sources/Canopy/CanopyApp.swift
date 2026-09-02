import os.log
import Sparkle
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "App")

@main
struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @State private var sidebarStore = SessionStore.makeRestored()

    var body: some Scene {
        WindowGroup(id: "main") {
            NavigationSplitView {
                Sidebar(store: sidebarStore)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
            } detail: {
                Detail(store: sidebarStore)
            }
            .navigationSplitViewStyle(.balanced)
            // Started here rather than in `applicationDidFinishLaunching`.
            // The old reason given — that the delegate callback runs before
            // SwiftUI builds the scene — is FALSE and has been deleted rather
            // than annotated: it fires after the first render (measured while
            // debugging the entry-file sweep, see
            // `WebViewContainer.purgeOwnEntryFiles`). What is true is that
            // this is the point where the store is unambiguously alive and in
            // hand, with no `SessionStore.shared` lookup. Fires once per
            // window; `startMacroPad` is idempotent.
            .task { appDelegate.startMacroPad(store: sidebarStore) }
            // Reads ~/.claude/sessions for the names other Claude sessions use
            // to message these ones. Idempotent, so a re-run of this .task is
            // harmless; it watches and polls for the process lifetime.
            .task { PeerNameStore.shared.start() }
            .sheet(item: Binding(
                get: { sidebarStore.renameTarget },
                set: { if $0 == nil { sidebarStore.cancelRename() } }
            )) { target in
                RenameSessionSheet(
                    target: target,
                    onCommit: { sidebarStore.commitRename(target, to: $0) },
                    onCancel: { sidebarStore.cancelRename() }
                )
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appDelegate.updaterController.updater.checkForUpdates()
                }
            }
            // File menu: browser-style — New Session / Open Folder above the
            // Close pair. SwiftUI's auto-generated "Close" item is suppressed
            // by the empty `.saveItem` / `.printItem` replacements below.
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    if sidebarStore.panes.isEmpty {
                        sidebarStore.select(.launcher)
                    } else {
                        sidebarStore.openLauncherInFocusedPane()
                    }
                }
                .keyboardShortcut("n")
                Button("Open Folder…") {
                    sidebarOpenFolder()
                }
                .keyboardShortcut("o")
                Divider()
                // Browser-style: label is always "Close Session" regardless
                // of selection state. The actual handler is the keyDown monitor
                // (handleCloseShortcut here is only reached on mouse click);
                // both fall back to closing the window when no session is open.
                // Multi-pane: Cmd+W / this button closes the focused pane.
                Button("Close Session") {
                    handleCloseShortcut()
                }
                .keyboardShortcut("w")
                Button("Close Window") {
                    if let key = NSApp.keyWindow, isCanopyWindow(key) {
                        windowCloseOnly(key)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            // SwiftUI auto-injects a "Close" item with Cmd+W under the
            // .saveItem placement (and another under .printItem on some
            // macOS versions), duplicating our File > Close Session. We
            // have no Save / Revert / Print UX, so empty replacements are
            // the cleanest way to suppress those auto items.
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {}
            CommandGroup(replacing: .windowList) {
                Button("Show Main Window") {
                    showMainWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
                // Cmd+1..9 — focus the N-th pane (browser-tab semantics).
                // Grayed out when fewer than N panes exist so the shortcut
                // never lands on a phantom pane.
                ForEach(1...9, id: \.self) { idx in
                    Button("Focus Pane \(idx)") {
                        focusPane(at: idx - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: .command)
                    .disabled(!sidebarStore.panes.indices.contains(idx - 1))
                }
            }
            CommandMenu("Panes") {
                Button("Focus Previous Pane") {
                    sidebarStore.moveFocus(delta: -1, wrap: true)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(sidebarStore.panes.count < 2)

                Button("Focus Next Pane") {
                    sidebarStore.moveFocus(delta: +1, wrap: true)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(sidebarStore.panes.count < 2)

                Divider()

                Button("Load Previous Session") {
                    sidebarStore.cycleFocusedPaneSession(delta: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!sidebarStore.canCycleFocusedPaneSession)

                Button("Load Next Session") {
                    sidebarStore.cycleFocusedPaneSession(delta: +1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!sidebarStore.canCycleFocusedPaneSession)

                Divider()

                // Cmd+Ctrl+1..9 — show the N-th visible open row: load it
                // into the focused pane, OR (if the session already lives
                // in another pane, honoring the one-session-one-pane
                // invariant) jump focus to that other pane, OR (if there
                // is no focused pane yet — user just closed the last one)
                // seed the first pane via openInFocusedPane's empty-panes
                // branch. Menu label says "Show …" rather than "Load …
                // into Pane" so the focus-jump case doesn't read as broken.
                // Cmd+Shift+3..6 conflict with macOS screenshot shortcuts,
                // and Cmd+Opt+arrows already move pane focus, so Cmd+Ctrl
                // is the cleanest unused modifier here.
                //
                // `visible` cached once so the 9-item ForEach doesn't walk
                // visibleRows (recents + cloud + dedupe + sort + filter)
                // per menu re-evaluation × 9.
                let visible = visibleOpenSessionIds
                ForEach(1...9, id: \.self) { idx in
                    Button("Show Session \(idx)") {
                        loadSessionIntoFocusedPane(sidebarIndex: idx - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: [.command, .control])
                    .disabled(!visible.indices.contains(idx - 1))
                }
            }

            CommandMenu("MacroPad") {
                MacroPadCommands()
            }
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - Sidebar shell helpers

    private func focusPane(at index: Int) {
        // Cmd+1..9: move focus to the N-th pane. Out-of-range is a no-op
        // (the menu button is also disabled, but guard here for safety).
        guard sidebarStore.panes.indices.contains(index) else { return }
        sidebarStore.setFocusedPaneIndex(index)
    }

    /// Sidebar's visible open session IDs, in the order they appear. Drives
    /// Cmd+Ctrl+1..9's target lookup and per-item enable state.
    ///
    /// Launcher rows sit in the same Open block and are deliberately skipped:
    /// this shortcut loads a session INTO the focused pane, and a launcher has
    /// nothing to load. So N here counts session rows, not visual positions —
    /// Cmd+1..9 is the one that counts panes.
    private var visibleOpenSessionIds: [UUID] {
        sidebarStore.visibleRows.compactMap { row in
            if case .open(let s) = row { return s.id } else { return nil }
        }
    }

    private func loadSessionIntoFocusedPane(sidebarIndex: Int) {
        // Cmd+Ctrl+1..9: show the N-th visible open row — load into the
        // focused pane, OR jump focus to whichever pane already hosts it,
        // OR seed the first pane if the user closed the last one. All
        // three cases are `openInFocusedPane`'s branches; we don't guard
        // panes.isEmpty here so the seed path stays keyboard-reachable.
        // Out-of-range sidebar index is a no-op (menu is also disabled).
        let visible = visibleOpenSessionIds
        guard visible.indices.contains(sidebarIndex) else { return }
        sidebarStore.openInFocusedPane(visible[sidebarIndex])
    }

    private func showMainWindow() {
        if let main = NSApp.windows.first(where: { isCanopyWindow($0) }) {
            main.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Window was closed and the SwiftUI WindowGroup released it —
            // ask the scene to spawn a fresh one.
            openWindow(id: "main")
        }
    }

    private func sidebarOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Through the same retirement map the Picker applies — this path can run
        // before any launcher pane has mounted, so it cannot rely on that write-back.
        let model = UserDefaults.standard.string(forKey: "launcher.model")
            .flatMap { $0.isEmpty ? nil : $0 }
            .map(LauncherView.migratingRetiredModel)
        let effort = UserDefaults.standard.string(forKey: "launcher.effortLevel").flatMap { $0.isEmpty ? nil : $0 }
        // Use the same recents-default preference as sidebar reopens —
        // bypassing it here would leave the menu's "Open Folder…" entry as
        // the one place that ignored Settings → Default for Recents.
        sidebarStore.openNew(
            directory: url,
            model: model,
            effortLevel: effort,
            permissionMode: CanopySettings.shared.defaultPermissionMode
        )
    }
}

// MARK: - Window close interception

/// Cmd+W behaviour (browser-style): with 2+ panes, close the focused
/// pane; otherwise fall through to the single-pane legacy path
/// (non-main window → active session → main window).
/// Shared by the SwiftUI File > Close Session menu button and the
/// AppDelegate keyDown monitor so both paths stay in lockstep.
@MainActor
func handleCloseShortcut() {
    // Non-Canopy window (Settings, Sparkle alert): close it first — the
    // keyDown monitor must handle this because File > Close is suppressed.
    if let key = NSApp.keyWindow, !isCanopyWindow(key) {
        logger.debug("Cmd+W: non-Canopy window, performClose")
        key.performClose(nil)
        return
    }
    guard let store = SessionStore.shared else {
        if let key = NSApp.keyWindow, isCanopyWindow(key) {
            windowCloseOnly(key)
        }
        return
    }
    if store.panes.count > 1 {
        logger.debug("Cmd+W: closing focused pane at \(store.focusedPaneIndex)")
        store.closePane(at: store.focusedPaneIndex)
    } else {
        legacyCloseAction()
    }
}

/// Single-pane / no-pane Cmd+W: close the focused non-main window
/// first (Settings, Sparkle alert), otherwise close the active session,
/// otherwise close the main window itself.
@MainActor
func legacyCloseAction() {
    if let key = NSApp.keyWindow, !isCanopyWindow(key) {
        key.performClose(nil)
        return
    }
    if let store = SessionStore.shared, let active = store.activeSession {
        logger.debug("Cmd+W: closing active session id=\(active.id.uuidString, privacy: .public)")
        store.closeSession(active.id)
    } else if let key = NSApp.keyWindow, isCanopyWindow(key) {
        logger.debug("Cmd+W: no active session, windowCloseOnly")
        windowCloseOnly(key)
    }
}

/// Whether a window is a Canopy app window (not a panel, settings, etc.).
/// SwiftUI's `WindowGroup(id: "main")` doesn't always preserve the literal
/// identifier — observed values in the wild include `main`, `main-AppWindow-1`,
/// and the same series for the AppKit autosave name. Settings is its own
/// scene with a `com_apple_SwiftUI_Settings_window` identifier, the Sparkle
/// updater alert is an `NSPanel`. Match permissively on either signal.
@MainActor
func isCanopyWindow(_ window: NSWindow) -> Bool {
    guard window.styleMask.contains(.titled),
          !window.isKind(of: NSPanel.self)
    else { return false }
    let id = window.identifier?.rawValue ?? ""
    let autosave = window.frameAutosaveName
    return id == "main"
        || id.hasPrefix("main-AppWindow")
        || autosave.hasPrefix("main-AppWindow")
}

/// Close or hide the window without touching any sessions. Browser-style:
/// the red title-bar button and Cmd+Shift+W always operate on the *window*,
/// never on individual sessions. If background shims are still running we
/// hide so Cmd+0 can bring the window back; if nothing is running we let
/// the window actually close.
///
/// Uses `window.close()` for the close path (bypasses delegate) so this is
/// safe to call from `windowShouldClose` without re-entering the proxy.
@MainActor
func windowCloseOnly(_ window: NSWindow) {
    if AppDelegate.isTerminating {
        window.close()
        return
    }
    if ShimProcess.hasActiveSession {
        logger.debug("Window: hiding (background sessions still running)")
        window.orderOut(nil)
    } else {
        logger.debug("Window: closing (no active sessions)")
        window.close()
    }
}

/// Proxy that intercepts windowShouldClose to hide windows instead of closing them.
/// Fallback layer — the close button override is the primary mechanism.
@MainActor
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var originalDelegate: (any NSWindowDelegate)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppDelegate.isTerminating {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
        // Defensive fallback only. Cmd+W is intercepted upstream by the
        // global keyDown monitor; the red button and Cmd+Shift+W call
        // `windowCloseOnly` directly. If something else manages to invoke
        // `performClose(_:)` on a Canopy window, fall back to
        // window-only behaviour to avoid surprising session loss.
        logger.debug("windowShouldClose: unexpected performClose path, windowCloseOnly")
        windowCloseOnly(sender)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        return originalDelegate
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private var delegateProxies: [ObjectIdentifier: WindowDelegateProxy] = [:]

    /// Drives the external MacroPad. Created once, on the first window's
    /// `.task`, and kept for the process lifetime — it also owns the
    /// unread-session bookkeeping the sidebar dot reads, so it runs whether
    /// or not a pad is ever plugged in.
    private var macroPad: MacroPadController?

    @MainActor
    func startMacroPad(store: SessionStore) {
        guard macroPad == nil else { return }
        let controller = MacroPadController(store: store)
        macroPad = controller
        controller.start()
    }

    /// UserDefaults key holding the last main-window frame. We persist
    /// this ourselves rather than relying on AppKit's autosave because
    /// SwiftUI's `WindowGroup(id: "main")` assigns each fresh window
    /// instance its own internal autosave name (`main-AppWindow-1`,
    /// `-2`, ...), so a close + Cmd+0 round-trip
    /// keeps creating new keys and never restores the user's frame.
    private let savedFrameKey = "canopy.mainWindowFrame"

    /// Minimum sane size for a restored frame. Sub-minimum frames are
    /// dropped on read AND skipped on save, otherwise a transient
    /// teardown frame would persist and then silently fail to restore.
    private let minRestoredSize = NSSize(width: 600, height: 400)

    /// Set during app termination to bypass hide-on-close behavior.
    static var isTerminating = false

    /// Local event monitor that intercepts Cmd+W on the main window before
    /// AppKit dispatches it to `performClose(_:)`. Without this, Cmd+W flashes
    /// the red title-bar button (because performClose simulates a button click)
    /// even when we end up just closing the active session. Catching the
    /// keyDown here keeps the title bar still.
    private var cmdWMonitor: Any?
    private var paneFocusClickMonitor: Any?
    private var keyTypingMonitor: Any?

    // NOTE: there is deliberately NO app-wide didResizeNotification observer
    // feeding pane state. An earlier iteration distributed manual window-
    // resize deltas into pane preferredWidths from such an observer, which
    // produced a runaway growth feedback loop (distribute grows panes,
    // SwiftUI grows the window to fit, observer sees the growth as a manual
    // drag, distributes again, forever). WeightedPaneLayout derives visual
    // pane widths from the proposed bounds, so manual resize needs no state
    // change; weights are re-synced to visual widths at every pane-list
    // mutation and at divider-drag start via
    // SessionStore.normalizePaneWeightsToVisualWidths(). The per-window
    // frame-persistence observer in configureCanopyWindow is separate and
    // only saves the frame.

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        SidebarLogicProbe.runIfRequested()
        #endif
        NSWindow.allowsAutomaticWindowTabbing = false
        requestNotificationPermission()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )

        installCmdWMonitor()
        installPaneFocusClickMonitor()
        installKeyTypingMonitor()
        RecapCoordinator.shared.start()
        KeepAliveCoordinator.shared.start()

        // SwiftUI may make the first window main before our observer is
        // registered, in which case `didBecomeMainNotification` fires
        // before this point and we miss the chance to install the close
        // proxy / restore the saved frame. Sweep existing windows here.
        for window in NSApp.windows where isAppWindow(window) {
            configureCanopyWindow(window)
        }
    }

    /// Install a `.keyDown` local monitor that swallows Cmd+W on Canopy
    /// windows. The monitor runs before responder-chain dispatch, so neither
    /// `performClose(_:)` nor the SwiftUI menu's keyEquivalent ever fires —
    /// we route the keystroke straight to our session/window logic.
    /// Cmd+Shift+W (Close Window) is NOT consumed: only plain Cmd+W matches.
    private func installCmdWMonitor() {
        guard cmdWMonitor == nil else { return }
        cmdWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w"
            else { return event }
            guard NSApp.keyWindow != nil else { return event }

            logger.debug("Cmd+W intercepted (pre-performClose)")
            handleCloseShortcut()
            return nil // consume — no flash
        }
    }

    /// Route left-mouse-down clicks inside the detail column to pane focus.
    /// WKWebView eats mouse events entirely, so the SwiftUI
    /// `.simultaneousGesture(TapGesture())` on `paneCell` never fires when
    /// the user clicks the chat input or any webview surface. A local
    /// NSEvent monitor intercepts the event before AppKit dispatch: we
    /// look at the click's window-space x, subtract sidebar width, and
    /// pick which pane owns that x range. It has a second job: a click in a
    /// pane body is a deliberate act on that pane, so it stamps interaction
    /// on the MacroPad controller — see the comment at that call for why the
    /// stamp is NOT tied to the focus change. Pass the event through
    /// unchanged so WKWebView still receives it — with two exceptions, both
    /// CONSUMED because SwiftUI appears never to receive mouse-down in that
    /// band (see `PaneHeaderStrip`'s doc for what was and was not measured):
    /// a click inside a pane header's `closeButtonHitRect` closes that pane,
    /// and a double-click on a session pane's header opens the rename sheet —
    /// that second one consumed only when a sheet actually opens, so a
    /// launcher pane's header still zooms the window.
    private func installPaneFocusClickMonitor() {
        guard paneFocusClickMonitor == nil else { return }
        paneFocusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // `!isEmpty`, not `count > 1`: a double-click on a pane header
            // renames its session, and a single pane is the common case for
            // that. That guard is now LOAD-BEARING rather than merely
            // harmless — the branch below also acknowledges an unread mark,
            // which matters most with one pane. (It used to be argued here
            // that the branch was inert at one pane, because
            // `focusedPaneIndex` is clamped to 0 wherever the strip shrinks;
            // that was true only while the branch did nothing but move focus.
            // The clamp is still an invariant held in `SessionStore` rather
            // than a check here, and is still what makes the focus CALL a
            // no-op.) The cost the widening did carry: the sidebar
            // measurement and the full `PaneLayoutMetrics` computation run on
            // every left mouse-down in the single-pane case, the common one.
            guard let window = event.window, isCanopyWindow(window),
                  let store = SessionStore.shared,
                  !store.panes.isEmpty else { return event }

            // Click location in window coordinates (bottom-left origin).
            let loc = event.locationInWindow
            let contentHeight = window.contentView?.bounds.height ?? window.frame.height
            let clickX = loc.x
            let clickYFromTop = contentHeight - loc.y

            // Only route clicks inside the detail column area.
            let sidebar = PaneWindowSizer.measuredSidebarWidthTrustingCollapse(in: window)
            guard clickX > sidebar else { return event }

            // preferredWidth is a weight. Use the same layout algorithm
            // (WeightedPaneLayout via PaneLayoutMetrics) as Detail.swift
            // so click hit-testing exactly matches the visual layout.
            let contentWidth = window.contentView?.bounds.width ?? window.frame.width
            let detailW = max(0, contentWidth - sidebar)
            let widths = PaneLayoutMetrics.paneWidths(
                detailWidth: detailW,
                weights: store.panes.map(\.preferredWidth),
                dividerWidth: SessionStore.paneDividerWidth,
                minimumWidth: SessionStore.paneMinDragWidth
            )
            var xCursor = sidebar
            for index in store.panes.indices {
                let paneW = index < widths.count ? widths[index] : 0
                let paneEnd = xCursor + paneW
                if clickX >= xCursor && clickX < paneEnd {
                    // Close X first: it lives in the pane header, which macOS 26
                    // covers with the detail column's scroll-edge BackdropView
                    // (see PaneHeaderStrip's doc for what that band was and was
                    // not measured to do). Hit-test it here instead and consume
                    // the event so the click can't also start a window drag on
                    // the way out.
                    //
                    // Two limitations OF THAT KIND, accepted rather than
                    // guarded. This is not the whole inventory: the rect's
                    // geometric preconditions are listed on
                    // `closeButtonHitRect`, and where one breaks, a consumed
                    // click can land on blank header space or on the window's
                    // own traffic lights. A round of review asked for a bare-modifier
                    // test and an app-active test; the modifier test read
                    // `deviceIndependentFlagsMask`, which contains `.capsLock`
                    // — so an engaged Caps Lock killed the button outright,
                    // the reported bug back in a narrower form. Its sibling
                    // could not be shown to do anything: by the time a local
                    // monitor sees the mouse-down, `NSApp.isActive` is already
                    // true, so it cannot tell an activating click from any
                    // other. What remains, unguarded and deliberately so:
                    //   - ctrl-click and Cmd+click close the pane rather than
                    //     meaning secondary-click / "new pane".
                    //   - the click that brings a background window forward
                    //     closes a pane instead of only activating, which a
                    //     real control's default `acceptsFirstMouse == false`
                    //     would have swallowed. `closePane` keeps the session,
                    //     so the cost is re-opening a pane, not losing work.
                    // Fixing either needs a measurement first, not a guess:
                    // the guesses cost a round and shipped a worse bug. The
                    // measurement for the second one is cheap — `isKeyWindow`
                    // is set inside `NSWindow.sendEvent`, which this monitor
                    // precedes, so logging it here for a click that raises a
                    // background window would say whether it discriminates.
                    let localPoint = CGPoint(x: clickX - xCursor, y: clickYFromTop)
                    // `panes.count > 1` mirrors `PaneHeaderStrip`'s
                    // `showCloseButton`: hit-testing an X that is not drawn
                    // would close the only pane from blank header space.
                    if store.panes.count > 1,
                       PaneHeaderStrip.closeButtonHitRect(paneWidth: paneW).contains(localPoint) {
                        // notice, not debug: this is the only record that the
                        // geometry-derived branch removed a pane, and debug
                        // does not survive to a log capture. Same rule the
                        // background-reconcile subsystem follows.
                        logger.notice("""
                            [pane] close X hit: index=\(index, privacy: .public) \
                            paneW=\(paneW, privacy: .public) \
                            sidebar=\(sidebar, privacy: .public) \
                            local=(\(localPoint.x, privacy: .public),\
                            \(localPoint.y, privacy: .public))
                            """)
                        store.closePane(at: index)
                        return nil
                    }
                    // Double-click the header to rename, for the same
                    // reason the close X is hit-tested here rather than by
                    // SwiftUI: no mouse event reaches what that strip draws.
                    // Consumed ONLY when a sheet actually opened, so the
                    // click can still zoom the window otherwise — a launcher
                    // pane has no session to name, and consuming there would
                    // both fail to rename and swallow the zoom, leaving a
                    // gesture that does nothing at all.
                    // Ordered after the close X so the X keeps the smaller,
                    // more specific target.
                    if event.clickCount == 2, clickYFromTop < PaneHeaderStrip.height,
                       store.beginRenameForPane(at: index) {
                        return nil
                    }
                    // Skip the title bar so window-drag clicks don't move
                    // focus. Since the stamp below moved inside this branch,
                    // the band now also gates ACKNOWLEDGEMENT: a click in a
                    // pane's top 28pt acknowledges nothing. Hoisting the stamp
                    // above the test would fix that and would also make
                    // dragging the window by a pane's header clear that pane's
                    // mark, which is not an act on the pane — left as it is
                    // deliberately, not by omission.
                    // Deliberately applied AFTER the close-X test and
                    // not as an early return: the X's target spans y 8…40 and
                    // this band is y <= 28, so an early return would kill the
                    // top 20 of its 32pt — an intermittent failure that only
                    // works when clicked low, which is worse to diagnose than
                    // a dead button.
                    let titleBarHeight: CGFloat = 28
                    if clickYFromTop > titleBarHeight {
                        // Focus only moves when it isn't already here, but the
                        // MacroPad stamp is unconditional — and the difference
                        // is the whole point. Clearing an unread mark needs a
                        // deliberate act on that pane AFTER its turn finished
                        // (see `MacroPadUnreadTracker.markSeq`), and clicking
                        // the pane you are already in is exactly that act. Tying
                        // the stamp to the focus CHANGE would mean the one pane
                        // most likely to be lit — the one you left focused when
                        // you walked away — is the one clicking cannot
                        // acknowledge, which is how this was found.
                        if index != store.focusedPaneIndex {
                            store.setFocusedPaneIndex(index)
                        }
                        self?.macroPad?.noteInteraction(paneIndex: index)
                    }
                    break
                }
                xCursor = paneEnd + SessionStore.paneDividerWidth
            }
            return event
        }
        // `addLocalMonitorForEvents` returns nil on sandboxing/mask rejection
        // (see the NSEvent monitor coverage matrix in CLAUDE.md). There is no
        // retry — not because the `guard` above forbids one (on failure the
        // property is left nil, so a second call WOULD re-install) but
        // because there is exactly one call site, in
        // `applicationDidFinishLaunching`. Its
        // sibling `installKeyTypingMonitor` has warned about this for a
        // while; this one now has more to lose — a nil here silently takes
        // out pane focus by click, the close X, header rename, AND one of the
        // two mouse gestures that acknowledge an unread mark on an
        // already-focused pane. The other three routes survive it: typing,
        // the pad key, and a click on that session's sidebar row, which
        // reaches the controller through SwiftUI rather than this monitor.
        if paneFocusClickMonitor == nil {
            logger.warning("installPaneFocusClickMonitor: addLocalMonitorForEvents returned nil — pane focus by click, the close X, header rename, and acknowledging a MacroPad unread mark by clicking its pane are all dead (typing, the pad key, and clicking its sidebar row still acknowledge)")
        }
    }

    /// Local `.keyDown` monitor that stamps interaction — "the user is here,
    /// working in this pane" — onto the MacroPad controller. It feeds two of
    /// `MacroPadUnreadTracker`'s clearing questions, both through
    /// `stampInteraction`: *which* session the user is with, and — since the
    /// generation rule — *when*, because a keystroke is an act that can
    /// acknowledge a mark recorded before it. It says nothing about the other
    /// two: whether a human is at the machine at all (presence, computed
    /// separately in `MacroPadController.refresh()` from `CGEventSource` and
    /// the pad's own press timestamp) or whether that human is looking at
    /// Canopy (app activation, mirrored from `NSApp.isActive` by
    /// `MacroPadController.observeActivation()`). It cannot stand in for
    /// activation either, despite being a local monitor that (as a
    /// consequence of AppKit local-monitor delivery) only ever fires while
    /// Canopy is frontmost: it fires on a keystroke, not on the transition of
    /// becoming frontmost, so returning to Canopy by any means that isn't
    /// itself a keystroke into a pane — Cmd+Tab and then just looking, a
    /// click on the Dock icon — produces no event here at all. What
    /// `observeActivation()` closes is NOT "the mark clears on return":
    /// returning bumps no generation, so bare Cmd+Tab clears nothing by
    /// design. It closes the case where an act ALREADY happened while
    /// `isAppActive` was still false — a pad press, or the click that
    /// activates Canopy — and the activation has to land for that act to
    /// count.
    ///
    /// Does not care about the key's content — any keystroke into a Canopy
    /// window is the signal — but it does not literally see every key.
    /// `cmdWMonitor` is installed FIRST and returns `nil` (consuming the
    /// event) for a plain Cmd+W with a key window present; a local monitor
    /// that returns `nil` measurably stops every later-registered local
    /// monitor for the same event type from seeing that event at all —
    /// verified with a standalone two-monitor harness dispatched through
    /// `NSApp.sendEvent(_:)` (not tested against the real app, and
    /// `sendEvent(_:)` is only one of the paths an event can take to a local
    /// monitor). So a plain Cmd+W is the one keystroke this monitor never
    /// observes — narrow, since closing a session isn't "still typing in
    /// it", but worth stating precisely rather than the unconditional claim
    /// this doc used to make. Unlike `cmdWMonitor`, this monitor only
    /// observes: it MUST return the event unmodified, or every other keyDown
    /// consumer in the app (menu shortcuts, the webview's own input) stops
    /// receiving keys. Not probe-reachable — it needs a live `NSApplication`
    /// event loop, which the DEBUG probe does not run.
    private func installKeyTypingMonitor() {
        guard keyTypingMonitor == nil else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let window = event.window, isCanopyWindow(window),
                  let store = SessionStore.shared, !store.panes.isEmpty
            else { return event }
            self?.macroPad?.noteInteraction(paneIndex: store.focusedPaneIndex)
            return event
        }
        // `addLocalMonitorForEvents` returns nil on sandboxing/mask
        // rejection (see the NSEvent monitor coverage matrix in CLAUDE.md) —
        // a silent nil here would mean typing quietly stops ACKNOWLEDGING
        // MacroPad unread marks forever, since `guard keyTypingMonitor == nil`
        // above never retries once this method has run once. Not presence:
        // `CGEventSource` sees every keystroke whether or not this monitor
        // exists, so presence is the one thing a nil here cannot break.
        guard let monitor else {
            logger.warning("installKeyTypingMonitor: addLocalMonitorForEvents returned nil — keystrokes will never acknowledge a MacroPad unread mark (presence, the pad key and mouse clicks are unaffected)")
            return
        }
        keyTypingMonitor = monitor
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Read the peer names while the CLIs are still up. This is the LAST
        // point at which they exist: each CLI deletes its
        // `~/.claude/sessions/<pid>.json` on exit, and a `/rename` is an
        // in-place write that fires no directory event, so a rename inside the
        // final poll interval is only ever seen here. `ShimProcess.stop`
        // carries the same call for the close-one-session path, but quit does
        // not route live sessions through it — renaming and then quitting is
        // the headline case, and it was open until this line existed.
        PeerNameStore.shared.captureNow()

        // Saving the layout and normalizing the saved frame to one pane's
        // width are mutually exclusive — but the deciding question is
        // "will the next launch rebuild the pane strip?", NOT "did the user
        // click Save". A capture with no session pane restores to nothing
        // (see `SessionRestoreSnapshot.isEmpty`), so it has to take the
        // normalize branch too or the user gets a multi-pane-wide window
        // with a single giant pane in it.
        if Self.shouldSaveRestoreSnapshot {
            let snapshot = SessionStore.shared?.captureRestoreSnapshot()
            if let snapshot, !snapshot.isEmpty {
                SessionStorePersistence.saveRestoreSnapshot(snapshot)
            } else {
                // Reached when the store is gone (the `shared` weak ref is
                // nil) or the strip held no session pane. The first is not
                // supposed to happen and is the reason this logs: the user
                // asked to save and is getting a discard, which is otherwise
                // indistinguishable from having clicked Quit.
                if snapshot == nil {
                    logger.error("Save-and-Quit requested but SessionStore.shared is nil — layout NOT saved")
                }
                normalizeSavedFrameForSinglePane()
                SessionStorePersistence.clearRestoreSnapshot()
            }
        } else {
            normalizeSavedFrameForSinglePane()
            SessionStorePersistence.clearRestoreSnapshot()
        }
        // Quit, and only our own files — see `WebViewContainer.purgeOwnEntryFiles`.
        WebViewContainer.purgeOwnEntryFiles()
        macroPad?.shutdown()
        if let monitor = cmdWMonitor {
            NSEvent.removeMonitor(monitor)
            cmdWMonitor = nil
        }
        if let paneFocusClickMonitor {
            NSEvent.removeMonitor(paneFocusClickMonitor)
            self.paneFocusClickMonitor = nil
        }
        if let keyTypingMonitor {
            NSEvent.removeMonitor(keyTypingMonitor)
            self.keyTypingMonitor = nil
        }
    }

    /// Runs only on the discard-layout quit path. On Save-and-Quit the full
    /// multi-pane width is deliberately kept because the panes come back.
    /// Quitting with 2+ panes otherwise leaves the multi-pane window width
    /// in the saved frame, so the next session would open as one giant pane
    /// spanning the whole multi-pane-wide window. Rewrite the saved width
    /// to sidebar + the focused pane's current visual width, i.e. the
    /// window the user would get by closing the other panes before quit.
    private func normalizeSavedFrameForSinglePane() {
        guard let store = SessionStore.shared,
              store.panes.count > 1,
              let window = NSApp.windows.first(where: { isCanopyWindow($0) })
        else { return }
        let sidebar = PaneWindowSizer.measuredSidebarWidthTrustingCollapse(in: window)
        let detailW = max(0, window.frame.width - sidebar)
        let widths = PaneLayoutMetrics.paneWidths(
            detailWidth: detailW,
            weights: store.panes.map(\.preferredWidth),
            dividerWidth: SessionStore.paneDividerWidth,
            minimumWidth: SessionStore.paneMinDragWidth
        )
        let focusedW = widths.indices.contains(store.focusedPaneIndex)
            ? widths[store.focusedPaneIndex]
            : (widths.first ?? SessionStore.paneDefaultWidth)
        var frame = window.frame
        frame.size.width = sidebar + focusedW
        logger.info("normalizeSavedFrameForSinglePane: \(Int(window.frame.width)) → \(Int(frame.size.width)) (sidebar=\(Int(sidebar)) focusedPane=\(Int(focusedW)))")
        saveWindowFrame(frame)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.info("applicationShouldHandleReopen: hasVisibleWindows=\(flag)")
        // Sidebar shell: single window. Bring the existing main window forward,
        // or let the system create a fresh one if it was actually closed.
        if let main = NSApp.windows.first(where: { isAppWindow($0) }) {
            main.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    /// Set when "Restart Now" is clicked. The actual relaunch helper is
    /// spawned inside `applicationShouldTerminate` once we have committed to
    /// quitting (and crucially while the run loop is still healthy enough to
    /// run a modal alert if the spawn fails). A canceled terminate clears
    /// this flag, so no `/bin/sh` waiter is ever left polling for our pid.
    @MainActor
    private static var shouldRelaunchOnExit = false

    /// Set by the quit prompt, read by `applicationWillTerminate`, and it
    /// decides between two mutually exclusive quit-time writes (snapshot vs.
    /// single-pane frame normalization).
    @MainActor
    private static var shouldSaveRestoreSnapshot = false

    /// Schedule Canopy to relaunch by routing through `NSApp.terminate(nil)`
    /// so `applicationShouldTerminate`'s active-sessions prompt and shim
    /// cleanup still run. The `/bin/sh` waiter that re-`open`s the bundle is
    /// only spawned once we've decided to terminate.
    @MainActor
    static func relaunch() {
        Self.shouldRelaunchOnExit = true
        NSApp.terminate(nil)
    }

    /// Spawn a detached `/bin/sh` that polls our pid via `kill -0` and, once
    /// we exit, `exec`s `/usr/bin/open` against the current bundle. Pid and
    /// bundle path are passed as positional args so the bundle path is never
    /// re-interpreted by the shell. Returns `true` on success; on failure
    /// the user is shown an alert and `false` is returned so the caller can
    /// abort the quit instead of leaving them with no Canopy at all.
    private func spawnRelaunchHelper() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#,
            "canopy-relaunch",
            String(pid),
            bundlePath,
        ]
        // Detach stdio so the helper isn't anchored to launchd's pipes after
        // we exit. The Process object goes out of scope after run() returns,
        // which is fine — we're about to exit and launchd reaps the orphan.
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            logger.info("Relaunch helper scheduled (pid=\(pid, privacy: .public))")
            return true
        } catch {
            logger.error("Relaunch helper failed to spawn: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn't Restart Canopy Automatically"
            alert.informativeText = "Quit Canopy and reopen it manually to finish applying the extension update.\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sweep up shims orphaned by mid-flight reconnects so they don't trigger
        // the "session still running" prompt below — they have no UI anyway.
        ShimProcess.stopOrphanedSessions()

        if ShimProcess.hasActiveSession {
            let count = ShimProcess.activeCount
            let relaunching = Self.shouldRelaunchOnExit
            let verb = relaunching ? "Restart" : "Quit"
            let stopping = relaunching ? "Restarting" : "Quitting"
            let alert = NSAlert()
            alert.messageText = relaunching ? "Restart Canopy" : "Active Sessions Running"
            alert.informativeText = "\(count) session\(count == 1 ? " is" : "s are") still running. \(stopping) will stop all sessions.\n\nSave and \(verb) restores this pane layout and your open sessions next launch."
            alert.addButton(withTitle: "Save and \(verb)")
            alert.addButton(withTitle: verb)
            alert.addButton(withTitle: "Cancel")
            // AppKit assigns Escape by BUTTON TITLE, not by position: the one
            // titled "Cancel" gets it wherever it sits, and measuring this
            // alert on macOS 26.6 shows all three lines below already match
            // what AppKit picked. They are pinned anyway so that renaming or
            // localizing "Cancel" cannot silently move Escape onto the
            // destructive discard — with a third button titled anything else,
            // Escape ends up bound to nothing.
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""
            alert.buttons[2].keyEquivalent = "\u{1b}"
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Self.shouldSaveRestoreSnapshot = true
            case .alertSecondButtonReturn:
                Self.shouldSaveRestoreSnapshot = false
            default:
                // User backed out — clear the relaunch flag so the next normal
                // quit doesn't unexpectedly re-open Canopy.
                Self.shouldRelaunchOnExit = false
                Self.shouldSaveRestoreSnapshot = false
                return .terminateCancel
            }
        }
        // No active sessions → no alert, shouldSaveRestoreSnapshot stays false.
        // That used to mean "nothing to restore" and no longer quite does: a
        // `.dormant` session is an open row with no shim, so a store holding
        // only those reaches here with rows worth saving and gets none of them
        // saved. What gates it is `closeSession`'s promotion, and the
        // condition is narrower than it looks: it fires only when the closed
        // session WAS the selection (`else if case .session(let sel) =
        // selection, sel == id`), which in the ordinary single-strip case it
        // is — so closing paned sessions one by one keeps waking the next
        // dormant row, and this state is not reached at all. Two strip shapes
        // defeat it. A surviving launcher pane: `panes` never empties, so the
        // branch that promotes is never taken. And an ALREADY-empty strip:
        // `closePane` left `selection == .launcher`, so the closed session is
        // not the selection and nothing is promoted. Either way, closing the
        // last shim-backed session leaves dormant rows and no shim. A restore
        // itself cannot produce it, because `SessionRestoreSnapshot.isEmpty` still requires
        // a surviving session pane and so guarantees at least one shim at
        // launch. Accepted, not overlooked — those rows did not survive a
        // relaunch at all before the open block became restorable, and
        // widening this gate means an alert that says "N sessions are still
        // running" when none are.
        //
        // A neighbouring case is NOT gated here and is worth knowing about:
        // with a shim still running but no SESSION pane left in the strip
        // (Cmd+N over the last one, or closing it while a launcher pane
        // stays), the prompt DOES fire, and `applicationWillTerminate` then
        // discards the capture because `SessionRestoreSnapshot.isEmpty` is
        // pane-based. The outcome matches what the user got before this
        // feature — nothing comes back — but the capture now carries real
        // sessions on the way to the bin, and that branch logs nothing.

        // If "Restart Now" triggered this terminate, spawn the waiter now —
        // before the run loop starts winding down — so the failure alert is
        // delivered cleanly and the user can decide what to do.
        if Self.shouldRelaunchOnExit, !spawnRelaunchHelper() {
            Self.shouldRelaunchOnExit = false
            // Same reason the relaunch flag is cleared: a cancelled terminate
            // must leave no decision behind. A stale `true` would make the
            // NEXT quit — possibly one with no sessions and so no prompt —
            // silently write a restore snapshot the user never asked for.
            Self.shouldSaveRestoreSnapshot = false
            return .terminateCancel
        }

        Self.isTerminating = true
        return .terminateNow
    }

    private func isAppWindow(_ window: NSWindow) -> Bool {
        isCanopyWindow(window)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    @objc private func handleCloseButton(_ sender: NSButton) {
        guard let window = sender.window else {
            logger.warning("handleCloseButton: sender has no window reference")
            return
        }
        // The Cmd+W path is intercepted by `cmdWMonitor` before AppKit dispatches
        // `performClose(_:)`, so this only fires for real mouse clicks on the
        // red title-bar button — always window-only, never session-close.
        logger.debug("handleCloseButton: red close button clicked")
        windowCloseOnly(window)
    }

    /// Install or reinstall the close-interception delegate proxy on a window.
    private func installDelegateProxy(for window: NSWindow) {
        let windowId = ObjectIdentifier(window)
        // Already installed and still active
        if let existing = delegateProxies[windowId], window.delegate === existing { return }

        let proxy = WindowDelegateProxy()
        proxy.originalDelegate = window.delegate
        window.delegate = proxy
        delegateProxies[windowId] = proxy
    }

    @objc private func windowDidBecomeMain(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              isAppWindow(window)
        else { return }
        configureCanopyWindow(window)
    }

    /// Installs the close proxy / overrides the close button / restores
    /// the saved frame and registers the resize+move+close observers.
    /// Idempotent: only the per-window-instance bits run once.
    private func configureCanopyWindow(_ window: NSWindow) {
        // Install close interception (reinstall if SwiftUI reset the delegate)
        installDelegateProxy(for: window)

        // Override close button target/action (deferred so SwiftUI finishes its setup first).
        // This is the primary close-protection mechanism.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.target = self
                closeButton.action = #selector(self.handleCloseButton(_:))
            }
        }

        // First-time window configuration: restore the saved frame
        // ourselves (overriding SwiftUI's defaultSize / per-instance
        // autosave) and start tracking resizes so the frame survives a
        // window destroy-recreate cycle.
        guard !configuredWindows.contains(window) else { return }
        configuredWindows.add(window)

        let savedAutosave = window.frameAutosaveName
        logger.debug("configureCanopyWindow: id=\(window.identifier?.rawValue ?? "nil", privacy: .public) autosave=\(savedAutosave, privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public)")

        if let saved = readSavedWindowFrame(forScreen: window.screen) {
            // SwiftUI applies `defaultSize` synchronously during window
            // creation, then runs view updates on this RunLoop pass. A
            // single `setFrame` call here would race against any
            // late-arriving SwiftUI restore, so we apply twice: once now,
            // once one runloop later. Both calls are no-ops if the user
            // has already started resizing.
            logger.debug("  restoring saved frame: \(NSStringFromRect(saved), privacy: .public)")
            window.setFrame(saved, display: true)
            DispatchQueue.main.async {
                window.setFrame(saved, display: true)
            }
        } else {
            logger.debug("  no saved frame yet — leaving SwiftUI defaultSize")
        }

        let resizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            self.saveWindowFrame(w.frame)
        }

        let moveToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            self.saveWindowFrame(w.frame)
        }

        var closeToken: NSObjectProtocol?
        closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            NotificationCenter.default.removeObserver(resizeToken)
            NotificationCenter.default.removeObserver(moveToken)
            if let closeToken {
                NotificationCenter.default.removeObserver(closeToken)
            }
            if let self {
                self.delegateProxies.removeValue(forKey: ObjectIdentifier(window))
            }
        }
    }

    private func saveWindowFrame(_ frame: NSRect) {
        // Skip below-minimum sizes so a transient zero/tiny frame during
        // teardown doesn't get persisted and then silently rejected by
        // `readSavedWindowFrame`'s `>= 600 / >= 400` clamp on next launch.
        guard frame.size.width >= minRestoredSize.width,
              frame.size.height >= minRestoredSize.height
        else { return }
        let dict: [String: Double] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "w": frame.size.width,
            "h": frame.size.height,
        ]
        UserDefaults.standard.set(dict, forKey: savedFrameKey)
        logger.debug("saveWindowFrame: \(NSStringFromRect(frame), privacy: .public)")
    }

    /// Read the saved frame and clamp it onto the given screen so a
    /// window saved on a now-disconnected display doesn't materialize
    /// off-screen. Size is shrunk first if it exceeds the screen, then
    /// origin is clamped — otherwise `visible.maxX - rect.width` would
    /// go negative for oversized rects and the origin clamp would push
    /// the window off the left edge.
    private func readSavedWindowFrame(forScreen screen: NSScreen?) -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: savedFrameKey),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let w = dict["w"] as? Double,
              let h = dict["h"] as? Double,
              w >= 600, h >= 400
        else { return nil }
        var rect = NSRect(x: x, y: y, width: w, height: h)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let clampedW = min(rect.width, visible.width)
            let clampedH = min(rect.height, visible.height)
            rect.size = NSSize(width: clampedW, height: clampedH)
            rect.origin.x = min(max(rect.origin.x, visible.minX), visible.maxX - clampedW)
            rect.origin.y = min(max(rect.origin.y, visible.minY), visible.maxY - clampedH)
        }
        return rect
    }
}

/// Resizes the main window to fit the current pane layout, applying the
/// "grow on add / shrink on close" contract from the spec. Falls back to
/// equal-share across all panes when the desired width exceeds the current
/// screen.
enum PaneWindowSizer {
    /// Matches the ideal from navigationSplitViewColumnWidth(min:220, ideal:280, max:360)
    /// in CanopyApp.swift's NavigationSplitView; the fallback branch tolerates
    /// drift at min/max ranges.
    static let assumedSidebarWidth: CGFloat = 280

    @MainActor
    static func applyForCurrentPanes(store: SessionStore) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && isCanopyWindow($0) })
                          ?? NSApp.windows.first(where: { isCanopyWindow($0) }),
              let screen = window.screen ?? NSScreen.main else {
            logger.info("PaneWindowSizer: no Canopy window found; skipping resize")
            return
        }
        // Empty panes → leave the window alone. Resizing to sidebar-only
        // would collapse the frame while closeSession is still settling
        // selection onto the next open session / launcher.
        guard !store.panes.isEmpty else {
            logger.info("[Pane] Sizer: panes empty; skipping resize")
            return
        }

        let sidebar = measuredSidebarWidthTrustingCollapse(in: window)
        let dividers = CGFloat(max(0, store.panes.count - 1)) * SessionStore.paneDividerWidth
        let sumPaneW = store.panes.reduce(0) { $0 + $1.preferredWidth }
        let target = sidebar + sumPaneW + dividers
        let screenMax = screen.visibleFrame.width
        let currentW = window.frame.width

        let paneWidths = store.panes.map { Int($0.preferredWidth) }
        logger.info("[Pane] Sizer.apply: panes=\(paneWidths) sidebar=\(Int(sidebar)) sumPaneW=\(Int(sumPaneW)) dividers=\(Int(dividers)) target=\(Int(target)) screenMax=\(Int(screenMax)) currentWindowW=\(Int(currentW))")

        var newFrame = window.frame
        if target <= screenMax {
            newFrame.size.width = target
            logger.info("[Pane] Sizer: target fits (\(Int(target))<=\(Int(screenMax))); setting window width to target")
        } else {
            // Fallback: cap at screen and equal-share the detail column.
            let detailBudget = max(0, screenMax - sidebar - dividers)
            let share = detailBudget / CGFloat(store.panes.count)
            logger.warning("[Pane] Sizer FALLBACK: target=\(Int(target))>screenMax=\(Int(screenMax)); equal-share each pane to \(Int(share))pt")
            for i in store.panes.indices {
                store.forceSetPaneWidth(at: i, to: share)
            }
            newFrame.size.width = screenMax
        }

        // Clamp origin.x so the wider window doesn't shoot off-screen.
        if newFrame.maxX > screen.visibleFrame.maxX {
            newFrame.origin.x = max(screen.visibleFrame.minX, screen.visibleFrame.maxX - newFrame.width)
        }

        // Non-animated: setFrame(_:display:) grows/shrinks the window in
        // a single frame. Animation caused the embedded WKWebView's
        // scroll position to drift while intermediate frames sized the
        // web content column mid-flight.
        logger.info("[Pane] Sizer: resizing window \(Int(currentW)) → \(Int(newFrame.size.width))")
        window.setFrame(newFrame, display: true)
    }

    /// The single sidebar-width measurement shared by ALL consumers — the
    /// sizer (`applyForCurrentPanes`), the click monitor's hit-testing,
    /// quit-time frame normalization, and
    /// `SessionStore.normalizePaneWeightsToVisualWidths`. Trusts any
    /// laid-out split view verbatim: a measured 0 means the user really
    /// collapsed the sidebar, and treating it as 280 would shift pane
    /// hit-tests right by the phantom sidebar (click pane N → focus pane
    /// N−1, Cmd+W closes the wrong pane) or inflate the sizer's window
    /// target by 280 pt per pane operation. The `split.frame.width > 0`
    /// guard covers the startup false positive (split view not yet laid
    /// out reads as zero-width — sizing from that once caused a window
    /// grow/shrink loop back when a didResize observer fed pane state;
    /// that observer is gone, but the guard stays cheap and correct).
    /// All consumers MUST share one measurement: an earlier iteration
    /// where the sizer distrusted a collapsed sidebar (assumed 280) while
    /// weight normalization trusted it made every pane add/close drift
    /// the window ~280 pt wider whenever the sidebar was collapsed.
    @MainActor
    static func measuredSidebarWidthTrustingCollapse(in window: NSWindow) -> CGFloat {
        guard let split = findSplitView(in: window), split.frame.width > 0,
              let sidebar = split.arrangedSubviews.first
        else { return assumedSidebarWidth }
        return sidebar.frame.width
    }

    /// NavigationSplitView is backed by an NSSplitView on macOS; BFS the
    /// content view for it.
    @MainActor
    private static func findSplitView(in window: NSWindow) -> NSSplitView? {
        guard let root = window.contentView else { return nil }
        var queue: [NSView] = [root]
        while let view = queue.first {
            queue.removeFirst()
            if let split = view as? NSSplitView { return split }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
