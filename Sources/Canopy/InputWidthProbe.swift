import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "InputWidthProbe")

/// Measures the live width of the CC extension's chat-input column and
/// forwards it to Swift so `SubagentListView` can line up with the input
/// area instead of sprawling edge-to-edge on wide windows.
///
/// The chat input is a `<textarea>` inside a stack of Tailwind wrappers
/// whose exact class names churn between extension versions, so this probe
/// walks up the DOM from the textarea and picks the first ancestor whose
/// rendered width is measurably narrower than the document — that's the
/// "chat column" the extension centers its content in. A `ResizeObserver`
/// keeps the reported width current across window / sidebar resizes.
///
/// The handler debounces + de-duplicates so a single resize event doesn't
/// spam the postMessage bridge, and it reports `null` if the textarea
/// vanishes (auth screen, error state) so callers can fall back to a
/// sensible default width.
enum InputWidthProbe {
    /// Message body: `{ type: "input-width", width: Number | null }`.
    static let messageHandlerName = "canopyInputWidth"

    static let javascript = """
    (function() {
        'use strict';
        var handler = (window.webkit && window.webkit.messageHandlers &&
                       window.webkit.messageHandlers.canopyInputWidth);
        if (!handler) return;

        var lastReported = -1;
        var observer = null;
        var observedEl = null;
        var scanTimer = null;

        function send(width) {
            // Round to whole points so sub-pixel jitter (Retina fractional
            // widths) doesn't flood the bridge with equivalent updates.
            var rounded = width == null ? null : Math.round(width);
            if (rounded === lastReported) return;
            lastReported = rounded;
            try { handler.postMessage({ type: 'input-width', width: rounded }); }
            catch (e) { /* handler gone during teardown */ }
        }


        /// Pick the closest ancestor of `el` that renders as a rounded card
        /// — the CC extension wraps its chat-input area in a FIELDSET (or
        /// similar) with `border-radius > 0` and a visible border. That
        /// card's outer width is exactly what we want the subagent list to
        /// line up with. Falls back to the first width-constrained
        /// ancestor, then to the element itself.
        function findChatColumn(el) {
            var vw = document.documentElement.clientWidth;
            var firstConstrained = null;
            var node = el.parentElement;
            while (node && node !== document.body) {
                var rectW = node.getBoundingClientRect().width;
                var style = getComputedStyle(node);
                var radius = parseFloat(style.borderTopLeftRadius) || 0;
                if (radius > 0 && rectW > 0 && rectW < vw) {
                    return node;
                }
                if (!firstConstrained && rectW > 0 && rectW < vw - 4) {
                    firstConstrained = node;
                }
                node = node.parentElement;
            }
            return firstConstrained || el;
        }

        function findInputEl() {
            // CC extension uses a contenteditable <div>, not a real
            // textarea. Match all three shapes so a future rewrite
            // doesn't silently break the probe.
            return document.querySelector(
                'textarea, [contenteditable="true"], [role="textbox"]'
            );
        }

        function attach() {
            var ta = findInputEl();
            if (!ta) return false;
            var col = findChatColumn(ta);
            if (observedEl === col) return true;
            if (observer) { try { observer.disconnect(); } catch (e) {} }
            observedEl = col;
            observer = new ResizeObserver(function(entries) {
                for (var i = 0; i < entries.length; i++) {
                    send(entries[i].contentRect.width);
                }
            });
            observer.observe(col);
            // Prime the first measurement — ResizeObserver fires on the
            // next frame, but the column already has a rect right now.
            send(col.getBoundingClientRect().width);
            return true;
        }

        // The extension mounts its React tree after Canopy injects, and the
        // input container appears / disappears on auth transitions. Rescan
        // periodically until we find a textarea, then re-verify on every
        // DOM mutation so a rerender that swaps the container doesn't
        // silently leave the observer pointed at a detached node.
        function scanLoop() {
            if (!attach()) {
                if (scanTimer == null) {
                    scanTimer = setInterval(function() {
                        if (attach()) { clearInterval(scanTimer); scanTimer = null; }
                    }, 500);
                }
            }
        }

        var domObserver = new MutationObserver(function() {
            // If the observed element got detached, look again.
            if (!observedEl || !document.contains(observedEl)) {
                observedEl = null;
                if (!attach()) send(null);
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
/// the `StatusBarData` so the handler doesn't keep the observable alive
/// past the webview's lifetime.
final class InputWidthMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var statusBarData: StatusBarData?

    init(statusBarData: StatusBarData?) {
        self.statusBarData = statusBarData
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage)
    {
        guard let body = message.body as? [String: Any],
              body["type"] as? String == "input-width"
        else { return }
        // `width` arrives as NSNumber (Double) or NSNull; treat missing /
        // non-positive as "no measurement" so the SwiftUI view falls back
        // to its baseline layout instead of collapsing to zero width.
        let width: CGFloat?
        if let n = body["width"] as? NSNumber, n.doubleValue > 0 {
            width = CGFloat(n.doubleValue)
        } else {
            width = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.statusBarData?.chatInputWidth = width
        }
    }
}
