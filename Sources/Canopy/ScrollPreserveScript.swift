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
    /// off-by-one on message-append.
    private static let bottomThreshold = 20

    /// How many periodic rescans to do after load; combined with the
    /// scroll-event fallback this is more than enough to catch late-
    /// mounted containers (auth flow, Monaco overlay) without hammering
    /// the DOM.
    private static let maxScanAttempts = 30

    /// Interval between periodic rescans (ms).
    private static let scanIntervalMs = 1000

    static let javascript: String = """
    (function() {
        'use strict';

        var THRESHOLD = \(bottomThreshold);
        var MAX_SCANS = \(maxScanAttempts);
        var SCAN_MS = \(scanIntervalMs);

        var known = new WeakSet();
        var atBottom = new WeakMap();

        function warn(msg, err) {
            try {
                if (window.console && console.warn) {
                    console.warn('[canopy-scroll-preserve] ' + msg,
                                 err && err.message ? err.message : (err || ''));
                }
            } catch (e) {}
        }

        function checkAtBottom(el) {
            return (el.scrollHeight - el.clientHeight - el.scrollTop) <= THRESHOLD;
        }

        function pinToBottom(el) {
            // Setting scrollTop to scrollHeight is clamped by the browser
            // to (scrollHeight - clientHeight); explicit form kept for
            // clarity and to survive future spec quirks.
            el.scrollTop = el.scrollHeight - el.clientHeight;
        }

        function isScrollable(el) {
            if (!(el instanceof Element)) return false;
            if (el.scrollHeight <= el.clientHeight + 1) return false;
            var style;
            try { style = getComputedStyle(el); }
            catch (e) { return false; }
            var oy = style.overflowY;
            return oy === 'auto' || oy === 'scroll';
        }

        function attach(el) {
            if (known.has(el)) return;
            known.add(el);
            atBottom.set(el, checkAtBottom(el));

            el.addEventListener('scroll', function() {
                atBottom.set(el, checkAtBottom(el));
            }, { passive: true });

            try {
                var ro = new ResizeObserver(function() {
                    if (!atBottom.get(el)) return;
                    // Two rAFs: first lets the browser commit the new
                    // layout (borderBoxSize etc. are already up-to-date
                    // in the ResizeObserver callback, but React children
                    // may still be reconciling); second reads the final
                    // scrollHeight and pins scrollTop.
                    requestAnimationFrame(function() {
                        requestAnimationFrame(function() {
                            pinToBottom(el);
                        });
                    });
                });
                ro.observe(el);
            } catch (e) {
                warn('ResizeObserver attach failed', e);
            }
        }

        function scan() {
            var els = document.querySelectorAll('*');
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                if (!known.has(el) && isScrollable(el)) attach(el);
            }
        }

        // Capture-phase scroll listener: any element the user or app
        // scrolls gets registered immediately, without waiting for the
        // next periodic scan. Scroll events don't bubble but capture
        // reaches them.
        document.addEventListener('scroll', function(e) {
            var el = e.target;
            if (el instanceof Element && !known.has(el) && isScrollable(el)) {
                attach(el);
            }
        }, { capture: true, passive: true });

        function startScanning() {
            scan();
            var attempts = 0;
            var timer = setInterval(function() {
                attempts++;
                if (attempts >= MAX_SCANS) {
                    clearInterval(timer);
                    return;
                }
                scan();
            }, SCAN_MS);
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', startScanning);
        } else {
            startScanning();
        }
    })();
    """
}
