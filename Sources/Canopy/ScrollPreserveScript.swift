import Foundation

/// Injected script that preserves "was at the bottom" for the CC extension's
/// chat scroll container across pane / window resizes.
///
/// Problem: when the user drags the pane divider, the chat viewport's
/// clientHeight changes. Even if the user was pinned to the newest message,
/// the browser keeps the top of the visible area anchored to the same
/// scrollTop pixel — so a smaller viewport now shows fewer messages ending
/// somewhere above the bottom, and a larger viewport reveals blank space
/// past the last message. The React app's own "auto-scroll on new message"
/// logic doesn't fire on resize, so nothing pulls scroll back to the tail.
///
/// Fix: track each scroll container's at-bottom state on every scroll
/// event. When a ResizeObserver on that container fires (pane drag, window
/// resize, splitter drop), if the last known state was "at bottom", pin
/// scrollTop to scrollHeight on the next two rAFs (one for layout commit,
/// one for the follow-up read). Loses no state on user scroll-up because
/// the scroll listener flips the flag before the resize observer fires.
///
/// Container discovery: no dependency on CC extension class names. We
/// look at any element whose computed overflowY is `auto` or `scroll` and
/// whose scrollHeight exceeds its clientHeight. Initial scan + interval
/// rescans catch late-mounted containers (auth screen → chat); a
/// capture-phase `scroll` listener registers anything the user or the
/// app scrolls before our polling picks it up.
enum ScrollPreserveScript {
    /// Distance (px) from the bottom that still counts as "at the bottom".
    /// Small enough to distinguish deliberate scroll-up from Retina
    /// sub-pixel drift; loose enough to survive React's occasional
    /// off-by-one on message-append. Not private: ImagePreviewScript
    /// shares this threshold for its own bottom-detection heuristic.
    static let bottomThreshold = 20

    /// Interval between periodic rescans (ms). The scan is idempotent
    /// (WeakSet.has short-circuits already-known elements) so we do not
    /// cap the number of attempts — a MAX_SCANS cap would silently drop
    /// late-mounting scroll containers that never receive a user-driven
    /// scroll event (e.g. an auto-scrolling log modal that opens hours
    /// into the session). A single `querySelectorAll('*')` per second is
    /// trivially cheap even in a React-heavy DOM.
    private static let scanIntervalMs = 1000

    /// How long after a wheel / key / touch event a scroll still counts
    /// as the user's. Wheel momentum keeps emitting wheel events, and a
    /// held mouse button (scrollbar drag) is tracked separately, so this
    /// only has to bridge the gap between an input event and the scroll
    /// it causes.
    private static let userInputWindowMs = 500

    static let javascript: String = """
    (function() {
        'use strict';

        var THRESHOLD = \(bottomThreshold);
        var SCAN_MS = \(scanIntervalMs);
        var USER_INPUT_WINDOW_MS = \(userInputWindowMs);

        var known = new WeakSet();
        var atBottom = new WeakMap();
        var lastTop = new WeakMap();

        function warn(msg, err) {
            try {
                if (window.console && console.warn) {
                    console.warn('[canopy-scroll-preserve] ' + msg,
                                 err && err.message ? err.message : (err || ''));
                }
            } catch (e) {
                // Intentional: this IS the error reporter of last resort.
                // If console.warn itself throws (WebKit teardown, DOM
                // detach mid-log), there is nowhere higher to escalate to.
            }
        }

        function checkAtBottom(el) {
            return (el.scrollHeight - el.clientHeight - el.scrollTop) <= THRESHOLD;
        }

        function pinToBottom(el) {
            // Guard against detach between the ResizeObserver callback
            // and this rAF (React unmount two ticks later): reading
            // scrollHeight/clientHeight on a detached element returns 0,
            // which would silently clamp scrollTop to 0 — the opposite
            // of the user's intent.
            if (!el.isConnected) return;
            // Setting scrollTop to scrollHeight is clamped by the browser
            // to (scrollHeight - clientHeight); explicit form kept for
            // clarity and to survive future spec quirks.
            el.scrollTop = el.scrollHeight - el.clientHeight;
        }

        function isScrollable(el) {
            if (!(el instanceof Element)) return false;
            if (el.scrollHeight <= el.clientHeight + 1) return false;
            var style;
            try {
                style = getComputedStyle(el);
            } catch (e) {
                // getComputedStyle throws on detached elements caught
                // mid-reconcile, or in rare SecurityError paths. Warn
                // so a candidate silently dropped from consideration
                // shows up in the log — the failure mode otherwise
                // looks identical to a genuine "not scrollable" element.
                warn('getComputedStyle failed for candidate scroll container', e);
                return false;
            }
            var oy = style.overflowY;
            return oy === 'auto' || oy === 'scroll';
        }

        function attach(el) {
            if (known.has(el)) return;
            known.add(el);
            atBottom.set(el, checkAtBottom(el));
            lastTop.set(el, el.scrollTop);

            el.addEventListener('scroll', function() {
                atBottom.set(el, checkAtBottom(el));
                lastTop.set(el, el.scrollTop);
            }, { passive: true });

            try {
                var ro = new ResizeObserver(function() {
                    // ResizeObserver holds a STRONG reference to every
                    // observed element, so `attach`'s WeakSet/WeakMap
                    // alone can't release a container React unmounts.
                    // Long chat sessions churn scroll containers (code
                    // blocks re-render, sub-trees fold) and every stale
                    // container would stay retained for the life of
                    // the page without this self-eviction. The
                    // isConnected check also prevents the observer's
                    // final post-detach callback from calling
                    // pinToBottom on a dead node.
                    if (!el.isConnected) {
                        ro.disconnect();
                        return;
                    }
                    if (!atBottom.get(el)) return;
                    // Double rAF: a single rAF isn't always sufficient
                    // for scrollHeight to stabilize on WebKit after a
                    // ResizeObserver callback — the second rAF is a
                    // defensive post-layout-read pattern that handles
                    // both the box-metric update and any late child
                    // reconciliation on top of it.
                    requestAnimationFrame(function() {
                        requestAnimationFrame(function() {
                            pinToBottom(el);
                        });
                    });
                });
                ro.observe(el);
            } catch (e) {
                // Scroll listener above is already attached, so
                // atBottom-tracking keeps working — but the RESIZE-
                // triggered pin never fires for this element. From the
                // user's perspective the scroll-preserve fix silently
                // no-ops for this container. Warn so a future report
                // of "scroll doesn't stay at bottom" can be diagnosed
                // from the log rather than mistaken for a regression.
                warn('ScrollPreserveScript: ResizeObserver unavailable — scroll-anchoring disabled for this container', e);
            }
        }

        function scan() {
            var els = document.querySelectorAll('*');
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                if (!known.has(el) && isScrollable(el)) attach(el);
            }
        }

        // User scroll intent. A scroll-up with none of these behind it is
        // layout, not a person.
        var lastInputAt = 0;
        var pointerDown = false;
        // Only keys that scroll. Typing the next prompt mid-stream must not
        // count, and neither may Space typed into an editable.
        var SCROLL_KEYS = { ArrowUp: 1, ArrowDown: 1, PageUp: 1, PageDown: 1, Home: 1, End: 1 };
        function noteInput() { lastInputAt = Date.now(); }
        window.addEventListener('wheel', noteInput, { capture: true, passive: true });
        window.addEventListener('touchmove', noteInput, { capture: true, passive: true });
        window.addEventListener('keydown', function(e) {
            if (SCROLL_KEYS[e.key]) { noteInput(); return; }
            if (e.key === ' ' && !(e.target instanceof Element &&
                    e.target.closest('input, textarea, [contenteditable]'))) noteInput();
        }, { capture: true, passive: true });
        // `buttons` on every mouse event, not a mousedown/mouseup pair: a
        // context menu, a drag-and-drop or a release outside the webview
        // never delivers the mouseup.
        function notePointer(e) { pointerDown = e.buttons !== 0; noteInput(); }
        window.addEventListener('mousedown', notePointer, { capture: true, passive: true });
        window.addEventListener('mousemove', function(e) { pointerDown = e.buttons !== 0; }, { capture: true, passive: true });
        window.addEventListener('mouseup', notePointer, { capture: true, passive: true });
        window.addEventListener('blur', function() { pointerDown = false; });
        function userIsScrolling() {
            return pointerDown || Date.now() - lastInputAt < USER_INPUT_WINDOW_MS;
        }

        // Capture-phase scroll listener. Two jobs:
        //
        // 1. Register any element the user or app scrolls immediately,
        //    without waiting for the next periodic scan. Scroll events
        //    don't bubble but capture reaches them.
        //
        // 2. Undo a layout clamp before the extension sees it. When a
        //    block near the bottom briefly collapses and regrows in one
        //    frame, the browser clamps scrollTop down and the scroll
        //    event reports the lower value with scrollHeight already
        //    restored. The extension's scroll handler reads any
        //    input-less scroll-up away from the bottom as "the user
        //    scrolled away" and stops following new messages until the
        //    user scrolls back down by hand. Measured on 2.1.280: an
        //    Edit tool's diff (whose height caps at 200px) produced a
        //    scrollTop drop of exactly 200 with scrollHeight unchanged
        //    and no input for 8 s, and the pane stayed stuck. Capture on
        //    `document` runs before the extension's listener on the
        //    element, so re-pinning here means it reads an unchanged
        //    scrollTop and never flips.
        document.addEventListener('scroll', function(e) {
            var el = e.target;
            if (!(el instanceof Element)) return;
            if (!known.has(el)) {
                if (isScrollable(el)) attach(el);
                return;
            }
            // Transcript only (other lists scrollIntoView on purpose), a drop
            // rather than any move, and past the extension's own 1px test.
            var dropped = el.scrollTop < lastTop.get(el);
            var dH = el.scrollHeight - el.clientHeight - el.scrollTop;
            if (atBottom.get(el) && dropped && dH > 1 && !userIsScrolling() &&
                    el.querySelector('[data-transcript-message]')) {
                var before = el.scrollTop;
                pinToBottom(el);
                try {
                    console.log('[canopy-scroll-preserve] re-pinned after layout clamp: ' +
                                Math.round(before) + ' -> ' + Math.round(el.scrollTop));
                } catch (err) {}
            }
        }, { capture: true, passive: true });

        function startScanning() {
            scan();
            // No cap: see the SCAN_MS docstring on the Swift side.
            // querySelectorAll('*') + WeakSet.has short-circuit is
            // cheap enough to run forever and catches late-mounting
            // scroll containers (auth flow → chat, modal log surfaces)
            // that a capped scan would silently drop.
            setInterval(scan, SCAN_MS);
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', startScanning);
        } else {
            startScanning();
        }
    })();
    """
}
