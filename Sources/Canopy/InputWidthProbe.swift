import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "InputWidthProbe")

/// Measures the live width of the CC extension's chat-input column and
/// forwards it to Swift so `SubagentListView` can line up with the input
/// area instead of sprawling edge-to-edge on wide windows.
///
/// The chat input is a contenteditable `<div>` in current CC builds (a
/// real `<textarea>` in older ones), wrapped in a stack of Tailwind-style
/// containers whose class names churn between extension versions. Rather
/// than depend on a specific selector, the probe:
///
///   1. Finds the input control via `textarea, [contenteditable="true"],
///      [role="textbox"]` — filtered to elements in the bottom half of
///      the viewport so a Monaco overlay or a top-of-page error banner
///      can't win.
///   2. Walks up the DOM and picks the nearest ancestor rendered as a
///      rounded card (`border-radius > 0` and width < viewport). Falls
///      back to the first width-constrained ancestor with a sanity-checked
///      minimum width; returns nothing (`nil` to Swift) if neither path
///      produces a plausible column so the SwiftUI view keeps its default.
///   3. Observes the picked element with `ResizeObserver` (using
///      `borderBoxSize` so the initial `getBoundingClientRect` prime and
///      subsequent observer callbacks report the SAME box). A
///      `MutationObserver` re-attaches when React swaps the container.
///
/// De-duplicates identical widths at whole-point resolution so Retina
/// sub-pixel jitter doesn't spam the postMessage bridge (there is no
/// time-based debounce — `ResizeObserver` is already rAF-batched by the
/// browser).
///
/// Reports `null` if the target element vanishes (auth screen, error
/// state, DOM refactor) so callers can fall back to a sensible default
/// width; every fallback path logs so a silent regression (e.g. selector
/// no longer matches after a CC update) is discoverable in the unified
/// log rather than presenting as "the list is narrow on wide windows".
enum InputWidthProbe {
    /// Message body: `{ type: "input-width", width: Number | null }`.
    ///
    /// Interpolated into the JS below so the handler-name literal and this
    /// Swift constant can't drift apart — a rename here compiles into the
    /// injected script automatically.
    static let messageHandlerName = "canopyInputWidth"

    /// Whole-point minimum width the JS side will report; anything below
    /// this is treated as "probe found the wrong element" and dropped.
    /// Loose enough to accept a narrow sidebar-mode window; tight enough
    /// that a stray icon-column measurement (~200pt) never wins.
    private static let minPlausibleWidth = 300

    /// Bail out of the fallback scan after this many failed attempts —
    /// once React has clearly settled without an input control (e.g. the
    /// user is stuck on the auth screen), further polling is wasted work.
    /// The `MutationObserver` still re-triggers `attach` on later DOM
    /// changes, so a delayed mount is still handled correctly.
    private static let maxScanAttempts = 60 // 30 s at 500ms cadence

    static let javascript: String = """
    (function() {
        'use strict';
        var handler = (window.webkit && window.webkit.messageHandlers &&
                       window.webkit.messageHandlers.\(messageHandlerName));
        if (!handler) return;

        var MIN_WIDTH = \(minPlausibleWidth);
        var MAX_SCAN_ATTEMPTS = \(maxScanAttempts);

        var lastReported = -1;
        var observer = null;
        var observedEl = null;
        var scanTimer = null;
        var scanAttempts = 0;

        function warn(msg, err) {
            try {
                if (window.console && console.warn) {
                    console.warn('[canopy-input-width] ' + msg,
                                 err && err.message ? err.message : (err || ''));
                }
            } catch (e) {}
        }

        function send(width) {
            // Round to whole points so sub-pixel jitter (Retina fractional
            // widths) doesn't flood the bridge with equivalent updates.
            var rounded = width == null ? null : Math.round(width);
            if (rounded === lastReported) return;
            lastReported = rounded;
            try {
                handler.postMessage({ type: 'input-width', width: rounded });
            } catch (e) {
                // Reset lastReported so a legitimate retry actually retries
                // — otherwise the same value stays deduped forever after a
                // teardown-race throw.
                lastReported = -1;
                warn('postMessage failed', e);
            }
        }

        function stopScanTimer() {
            if (scanTimer != null) {
                clearInterval(scanTimer);
                scanTimer = null;
            }
        }

        function findInputEl() {
            // CC extension uses a contenteditable <div>, not a real
            // textarea. Match all three shapes so a future rewrite doesn't
            // silently break the probe. Filter to the bottom half of the
            // viewport so a Monaco overlay or top-of-page banner never
            // wins ahead of the actual chat input.
            var vh = window.innerHeight || document.documentElement.clientHeight;
            var candidates = document.querySelectorAll(
                'textarea, [contenteditable="true"], [role="textbox"]'
            );
            for (var i = 0; i < candidates.length; i++) {
                var rect = candidates[i].getBoundingClientRect();
                if (rect.bottom > vh * 0.5 && rect.width > 0) return candidates[i];
            }
            // Fall through to first match if none passes the bottom-half
            // gate — narrow windows / offscreen layouts.
            return candidates[0] || null;
        }

        /// Pick the closest ancestor of `el` that renders as a rounded card
        /// — the CC extension wraps its chat-input area in a rounded
        /// container with `border-radius > 0` and a visible border. That
        /// card's outer width is what we want the subagent list to line up
        /// with. Falls back to the first width-constrained ancestor with
        /// a sanity-checked minimum width. Returns null if no plausible
        /// column exists — callers should treat that as "no measurement".
        function findChatColumn(el) {
            var vw = document.documentElement.clientWidth;
            var firstConstrained = null;
            var node = el.parentElement;
            while (node && node !== document.body) {
                var rectW = node.getBoundingClientRect().width;
                var style = getComputedStyle(node);
                var radius = parseFloat(style.borderTopLeftRadius) || 0;
                if (radius > 0 && rectW >= MIN_WIDTH && rectW < vw) {
                    return node;
                }
                if (!firstConstrained && rectW >= MIN_WIDTH && rectW < vw - 4) {
                    firstConstrained = node;
                }
                node = node.parentElement;
            }
            if (!firstConstrained) {
                warn('findChatColumn: no plausible ancestor for input el');
            }
            return firstConstrained;
        }

        function measure(col) {
            // Use borderBoxSize so the ResizeObserver callback and this
            // initial prime read the SAME box — otherwise a border >0 card
            // gives contentRect < getBoundingClientRect and the first
            // reported width contracts on the first live update.
            return col.getBoundingClientRect().width;
        }

        function attach() {
            var ta = findInputEl();
            if (!ta) return false;
            var col = findChatColumn(ta);
            if (!col) return false;
            if (observedEl === col) {
                stopScanTimer();
                return true;
            }
            if (observer) {
                observer.disconnect();
            }
            observedEl = col;
            observer = new ResizeObserver(function(entries) {
                for (var i = 0; i < entries.length; i++) {
                    var e = entries[i];
                    var w = (e.borderBoxSize && e.borderBoxSize.length > 0)
                        ? e.borderBoxSize[0].inlineSize
                        : e.contentRect.width;
                    send(w);
                }
            });
            observer.observe(col, { box: 'border-box' });
            send(measure(col));
            stopScanTimer();
            return true;
        }

        // The extension mounts its React tree after Canopy injects, and the
        // input container appears / disappears on auth transitions. Rescan
        // periodically until we find the input (or hit the cap), then rely
        // on the DOM mutation observer to re-verify on every rerender that
        // could swap the container.
        function scanLoop() {
            if (attach()) return;
            if (scanTimer != null) return;
            scanAttempts = 0;
            scanTimer = setInterval(function() {
                scanAttempts++;
                if (attach()) return;
                if (scanAttempts >= MAX_SCAN_ATTEMPTS) {
                    warn('scan gave up after ' + scanAttempts + ' attempts');
                    stopScanTimer();
                }
            }, 500);
        }

        var domObserver = new MutationObserver(function() {
            // If the observed element got detached, look again — and
            // restart the scan loop so the periodic poll picks up cases
            // where DOM mutations pause (e.g. auth screen with no further
            // activity to trigger this observer).
            if (!observedEl || !document.contains(observedEl)) {
                observedEl = null;
                if (!attach()) {
                    send(null);
                    scanLoop();
                }
            }
        });
        domObserver.observe(document.body || document.documentElement,
                            { childList: true, subtree: true });

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', scanLoop);
        } else {
            scanLoop();
        }
    })();
    """
}

/// WKScriptMessageHandler bridge for `InputWidthProbe`. Weakly retains
/// `StatusBarData` so a webview outliving its session (transitional swap
/// during in-place subview switch) doesn't post updates into a released
/// observable — and to avoid any accidental retain cycle if a future
/// change threads the handler back through the session.
///
/// The init parameter is intentionally non-optional: a handler with a nil
/// StatusBarData would consume messages, do width arithmetic, dispatch to
/// main, and write into nothing. Callers guard at the registration site
/// so "no StatusBarData → no handler" is enforced at compile time.
@MainActor
final class InputWidthMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var statusBarData: StatusBarData?

    init(statusBarData: StatusBarData) {
        self.statusBarData = statusBarData
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKScriptMessageHandler callbacks arrive on the main thread per
        // WebKit docs, but the protocol requirement is nonisolated. Hop
        // to MainActor explicitly so the compiler enforces the actor
        // context on every access to `statusBarData` (an @Observable
        // read by SwiftUI).
        let body = message.body
        Task { @MainActor [weak self] in
            self?.handle(body: body)
        }
    }

    private func handle(body: Any) {
        guard let dict = body as? [String: Any] else {
            logger.error("input-width body is not a dictionary: \(String(describing: body), privacy: .public)")
            return
        }
        let type = dict["type"] as? String
        guard type == "input-width" else {
            logger.error("input-width unknown message type=\(String(describing: type), privacy: .public)")
            return
        }
        // Width shapes: NSNumber (positive → apply), NSNumber (0 or
        // negative → treat as "hidden / no measurement"), NSNull /
        // missing → same. Distinguish the pathological negative case in
        // logs so a JS regression doesn't hide behind the nil fallback.
        let width: CGFloat?
        if let n = dict["width"] as? NSNumber {
            let value = n.doubleValue
            if value > 0 {
                width = CGFloat(value)
            } else {
                if value < 0 {
                    logger.error("input-width received negative width \(value, privacy: .public) — probe bug")
                }
                width = nil
            }
        } else if dict["width"] is NSNull {
            width = nil
        } else {
            logger.error("input-width missing or wrong-typed width field: \(String(describing: dict["width"]), privacy: .public)")
            width = nil
        }
        let previous = statusBarData?.chatInputWidth
        statusBarData?.chatInputWidth = width
        if previous != nil, width == nil {
            logger.info("chatInputWidth reset to nil — probe lost the input element")
        }
    }
}
