import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RecapScript")

/// Renders the session recap as a row inside the CC extension's webview, at
/// the top of the chat composer — above the input card AND above the
/// extension's own notice banners, so nothing the extension raises can bury
/// it. That is the same position the Claude Code CLI prints its
/// `away_summary` line, and where the eye already goes when returning to a
/// session.
///
/// Canopy owns the text (see `ShimProcess.requestRecap`) but not the DOM, so
/// this injects a node the extension knows nothing about and defends it
/// against React re-renders:
///
///   1. Locate the chat input by SHAPE, never by class name — the extension's
///      hashed class names (`inputContainer_cKsPxg`) churn every release.
///      Reuses `InputWidthProbe`'s heuristic: `textarea,
///      [contenteditable="true"], [role="textbox"]` filtered to the bottom
///      half of the viewport, then walk up to the nearest ancestor rendered
///      as a rounded card (`border-radius > 0`, narrower than the viewport).
///   2. From that card, climb to the top of the composer column — the run of
///      ancestors that keep the card's width — and insert the recap as its
///      FIRST child. The extension's own notice banners (e.g. Remote
///      Control, rate-limit warning, Chrome/debugger/Jupyter MCP, settings
///      errors, session errors) are laid out inside that run, above the
///      input's `form`, so anchoring to the card itself buried the recap
///      underneath whichever of them was up. First-child places it above all
///      of them and inherits the column's layout rather than needing its own.
///   3. Re-insert on every `MutationObserver` hit where the node lost its
///      anchor. React owns this subtree and will discard foreign children on
///      re-render; re-attaching is the only stable contract available.
///
/// State lives on `window.__canopyRecap` so `set` calls that arrive before
/// the input mounts (recap captured while the auth screen is up, or during
/// the extension's first paint) are replayed once an anchor appears — rather
/// than being dropped and leaving the user with no recap at all.
///
/// `findInputEl` and `findInputCard` warn through `console.warn`, which
/// Canopy's `ConsoleLogHandler` funnels into the unified log, so a selector
/// regression there shows up as a grep-able warning. `findComposerColumn`
/// deliberately does not — see it for why. There is no native fallback UI: a
/// regression should show up in the log, not as a second, differently-styled
/// strip appearing out of nowhere.
enum RecapScript {
    /// A bare call EXPRESSION, deliberately without a `window.__canopyRecap &&`
    /// guard of its own. `ShimProcess.showRecapInWebView` wraps it in a ternary
    /// that reports whether the bridge existed — a guard here as well would
    /// make that wrapper malformed, and short-circuiting to `false` with no JS
    /// error is exactly the silent drop the wrapper was added to detect.
    static func setCall(text: String) -> String {
        "window.__canopyRecap.set(\(jsStringLiteral(text)))"
    }

    static var clearCall: String {
        "window.__canopyRecap.clear()"
    }

    /// Escape a Swift string into a JS string literal for `evaluateJavaScript`.
    /// `JSONSerialization` is used rather than hand-rolled escaping so quotes,
    /// backslashes, newlines, and lone surrogates in model output can't break
    /// out of the literal.
    private static func jsStringLiteral(_ value: String) -> String {
        // `.fragmentsAllowed` lets a bare string encode without wrapping it in
        // an array. On the (unreachable) encode failure, fall back to an empty
        // literal: showing nothing beats injecting malformed JS that would
        // throw inside the extension's own page.
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8)
        else {
            logger.error("failed to encode recap text as a JS literal")
            return "\"\""
        }
        return literal
    }

    static let javascript: String = """
    (function() {
        'use strict';
        if (window.__canopyRecap) return;

        var ELEMENT_ID = 'canopy-recap-row';
        var RETRY_INTERVAL_MS = 500;
        var MAX_RETRY_ATTEMPTS = 10;   // 5 s — long enough to outlast a first paint

        var currentText = null;
        var el = null;

        function warn(msg) {
            try {
                if (window.console && console.warn) {
                    console.warn('[canopy-recap] ' + msg);
                }
            } catch (e) {}
        }

        function reportError(msg) {
            try {
                if (window.console && console.error) {
                    console.error('[canopy-recap] ' + msg);
                }
            } catch (e) {}
        }

        // Bounded retry for a recap that arrived before an anchor existed.
        //
        // The MutationObserver alone is not enough: it only fires on DOM
        // change, and the session a recap targets has by definition been idle
        // for minutes. Once the first paint settles, a webview that stops
        // mutating never retries, so the text sits in `currentText` forever
        // behind a single warn — a recap that was generated and paid for and
        // is nowhere on screen.
        //
        // Deliberately bounded and self-cancelling: it stops on the first
        // successful mount, on `clear()`, and after the cap. `mount()` is a
        // no-op when the row is already correctly placed, so a tick that
        // fires against a healthy page cannot disturb it.
        var retryTimer = null;
        var retryAttempts = 0;

        function stopRetry() {
            if (retryTimer != null) {
                clearInterval(retryTimer);
                retryTimer = null;
            }
            retryAttempts = 0;
        }

        function startRetry() {
            if (retryTimer != null) return;
            retryAttempts = 0;
            retryTimer = setInterval(function() {
                if (currentText == null) { stopRetry(); return; }
                retryAttempts++;
                if (mount()) { stopRetry(); return; }
                if (retryAttempts >= MAX_RETRY_ATTEMPTS) {
                    stopRetry();
                    // Error, not warn: this is the terminal state where a
                    // generated recap is lost with no surface showing it.
                    reportError('gave up mounting after ' + MAX_RETRY_ATTEMPTS
                        + ' attempts — recap generated but not shown');
                }
            }, RETRY_INTERVAL_MS);
        }

        // --- anchor discovery (mirrors InputWidthProbe; see its doc comment)

        function findInputEl() {
            var vh = window.innerHeight || document.documentElement.clientHeight;
            var candidates = document.querySelectorAll(
                'textarea, [contenteditable="true"], [role="textbox"]'
            );
            for (var i = 0; i < candidates.length; i++) {
                var rect = candidates[i].getBoundingClientRect();
                if (rect.bottom > vh * 0.5 && rect.width > 0) return candidates[i];
            }
            if (candidates.length > 0) {
                warn('findInputEl: no bottom-half candidate — falling back to first of ' + candidates.length);
            }
            return candidates[0] || null;
        }

        /// Nearest opaque background above `node`, so the row matches the
        /// surface it sits on instead of hard-coding a colour that would be
        /// wrong the moment the theme changes. Falls back to the CC
        /// extension's editor-background variable, then white.
        function resolveBackground(node) {
            var el = node;
            while (el && el !== document.documentElement) {
                var bg = getComputedStyle(el).backgroundColor;
                if (bg && bg !== 'transparent') {
                    // rgba(...) with a zero alpha is "no background" for our
                    // purposes — keep climbing.
                    var alpha = bg.match(/^rgba\\(.*,\\s*([\\d.]+)\\)$/);
                    if (!alpha || parseFloat(alpha[1]) > 0.95) return bg;
                }
                el = el.parentElement;
            }
            var themed = getComputedStyle(document.documentElement)
                .getPropertyValue('--vscode-editor-background');
            return (themed && themed.trim()) || '#ffffff';
        }

        // Deliberately has NO minimum-width gate, unlike InputWidthProbe's
        // otherwise-identical walk. The probe reports a measurement, so it
        // must reject implausibly narrow candidates; this only needs a node
        // to insert before. Copying the probe's 300pt floor made the recap
        // invisible in exactly the layout it was built for — panes have a
        // 100pt floor, so a 3–5 pane window has columns well under 300 and
        // no ancestor ever qualified. The recap was generated, paid for, and
        // never shown.
        function findInputCard(input) {
            var vw = document.documentElement.clientWidth;
            var firstConstrained = null;
            var node = input.parentElement;
            while (node && node !== document.body) {
                var rectW = node.getBoundingClientRect().width;
                var radius = parseFloat(getComputedStyle(node).borderTopLeftRadius) || 0;
                if (radius > 0 && rectW > 0 && rectW < vw) return node;
                if (!firstConstrained && rectW > 0 && rectW < vw - 4) {
                    firstConstrained = node;
                }
                node = node.parentElement;
            }
            if (!firstConstrained) {
                warn('findInputCard: no plausible ancestor for input el');
            } else {
                warn('findInputCard: no rounded card — using first constrained ancestor');
            }
            return firstConstrained;
        }

        // The outermost ancestor of the input card that still has the card's
        // width. Width, not class names — those churn every release.
        //
        // Wide panes land on `.inputWrapper`; narrow panes one level up, on
        // the composer overlay, because `.inputWrapper` is `max-width:680px`
        // and stops being the narrower box. Both sit above the notice
        // banners, which is the whole point.
        //
        // What keeps the climb out of the scrolling transcript is
        // `WIDTH_TOLERANCE` staying under the overlay's horizontal inset —
        // 24 against 32 (`.inputContainer_07S1Yg` is `left:16px;right:16px`,
        // measured 2026-08 on extension 2.1.222). Raise the tolerance, or let
        // the extension tighten the inset, and the row can mount off-screen.
        // Nothing warns: these stops are the NORMAL exit, so logging them
        // would fire on every healthy mount. MAX_HOPS is a backstop only.
        function findComposerColumn(card) {
            var MAX_HOPS = 6;
            var WIDTH_TOLERANCE = 24;
            var cardW = card.getBoundingClientRect().width;
            var best = card;
            var node = card;
            for (var hop = 0; hop < MAX_HOPS; hop++) {
                var parent = node.parentElement;
                if (!parent || parent === document.body) break;
                if (Math.abs(parent.getBoundingClientRect().width - cardW) > WIDTH_TOLERANCE) break;
                best = parent;
                node = parent;
            }
            return best;
        }

        // --- element

        function build() {
            var row = document.createElement('div');
            row.id = ELEMENT_ID;
            row.setAttribute('data-canopy', 'recap');
            // Inline styles only: the extension's stylesheet is not ours to
            // extend, and a <style> block would be one more node React could
            // drop independently of the row itself.
            row.style.cssText = [
                'display:flex',
                'align-items:baseline',
                'gap:6px',
                // The breathing room below the text is PADDING, not margin:
                // a margin would be transparent, and the transcript scrolls
                // underneath this whole area — so a margin reads as a strip
                // of chat content wedged between the recap and the input.
                // Padding keeps the same visual gap while the row's own
                // background stays unbroken across it.
                'margin:0',
                'padding:6px 10px 10px 10px',
                // Bottom corners stay square for the same reason: whatever
                // sits directly below — a notice banner, a permission
                // dialog, or the input card — butts against this edge, and
                // rounding it would punch two transparent notches back out.
                'border-radius:6px 6px 0 0',
                'font-size:11px',
                'line-height:1.5',
                'user-select:text',
                '-webkit-user-select:text',
                // The input area sits over the scrolling transcript in a
                // transparent container, so a background-less row lets chat
                // content show straight through it (observed: recap text
                // overlapping a tool-output block). An opaque background plus
                // a stacking context puts the row cleanly on top.
                'position:relative',
                'z-index:5'
            ].join(';');
            // Opacity would make the background translucent too, defeating
            // the point — dim the text instead, per element.
            row.style.color = 'inherit';

            var mark = document.createElement('span');
            mark.textContent = '\\u203B'; // ※ — the glyph the CLI uses
            mark.style.cssText = 'flex:0 0 auto;opacity:0.45';

            var label = document.createElement('span');
            label.textContent = 'recap:';
            label.style.cssText = 'flex:0 0 auto;font-weight:600;opacity:0.55';

            var body = document.createElement('span');
            body.setAttribute('data-canopy', 'recap-text');
            body.style.cssText = 'font-style:italic;min-width:0;opacity:0.65';

            row.appendChild(mark);
            row.appendChild(label);
            row.appendChild(body);
            return row;
        }

        /// Place (or replace) the row at the top of the composer column, above
        /// the extension's notice banners. Returns false when no anchor exists
        /// yet — the caller keeps `currentText` so a later mutation can retry.
        function mount() {
            if (currentText == null) return true;
            var input = findInputEl();
            if (!input) return false;
            var card = findInputCard(input);
            if (!card || !card.parentElement) return false;
            var column = findComposerColumn(card);

            if (!el) el = build();
            var body = el.querySelector('[data-canopy="recap-text"]');
            if (!body) {
                // Children stripped by an outer re-render. Rebuild rather than
                // throwing out of the MutationObserver callback, which would
                // fire on every subsequent DOM mutation and never recover.
                warn('recap row lost its body span — rebuilding');
                remove();
                el = build();
                body = el.querySelector('[data-canopy="recap-text"]');
            }
            // Write only on change. `textContent` always does "replace all",
            // emitting a childList record — and the MutationObserver below now
            // calls mount() unconditionally, so an unguarded write re-enters
            // this function forever. The doc above claims mount() "returns
            // without touching the DOM" when nothing moved; this is what makes
            // that true.
            if (body.textContent !== currentText) {
                body.textContent = currentText;
            }
            // Re-resolved on every mount, not just on build: a theme switch
            // re-renders the tree, and a stale light background on a dark
            // theme is worse than no background at all.
            //
            // Resolved from the column, not the card: the card carries the
            // input's own surface colour, which is not the surface this row
            // now sits on.
            var bg = resolveBackground(column);
            if (el.style.backgroundColor !== bg) {
                el.style.backgroundColor = bg;
            }

            // Already correctly positioned — do nothing, so we don't churn
            // the DOM (and retrigger our own MutationObserver) on every tick.
            if (column.firstChild === el) {
                return true;
            }
            column.insertBefore(el, column.firstChild);
            return true;
        }

        function remove() {
            if (el && el.parentElement) el.parentElement.removeChild(el);
            el = null;
        }

        window.__canopyRecap = {
            set: function(text) {
                if (typeof text !== 'string' || text.length === 0) {
                    this.clear();
                    return;
                }
                currentText = text;
                if (!mount()) {
                    // Not an error yet: the extension may still be painting.
                    // Both the observer and the bounded timer will retry.
                    warn('no input anchor yet — recap queued');
                    startRetry();
                }
            },
            clear: function() {
                currentText = null;
                stopRetry();
                remove();
            }
        };

        var observer = new MutationObserver(function() {
            if (currentText == null) return;
            // Deliberately does NOT short-circuit on "the row is still
            // attached somewhere". React can replace or move the input card
            // while leaving our row parented to a stale container — the row
            // stays in the document and passes an attachment test, but is no
            // longer above the input, and nothing would ever reposition it.
            // `mount()` already owns the real invariant (`column.firstChild
            // === el`) and returns without touching the DOM when it holds, so
            // calling it unconditionally is both correct and cheap.
            // Re-arm on failure, not just disarm on success: the timer is
            // otherwise only ever armed by `set()`, so a composer torn down
            // AFTER a successful mount (auth screen, webview reload) leaves
            // `currentText` set with nothing on screen and no log line.
            // `startRetry` is idempotent and bounded, so the worst case is a
            // teardown slower than its 5 s cap logging the terminal error
            // and then recovering.
            if (mount()) { stopRetry(); } else { startRetry(); }
        });
        observer.observe(document.body || document.documentElement,
                         { childList: true, subtree: true });
    })();
    """
}
