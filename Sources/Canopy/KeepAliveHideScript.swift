import Foundation

/// Hides a prompt-cache refresh turn from the transcript, on screen only.
///
/// Since the extension's composer grew a prompt-cache countdown (2.1.268),
/// `ShimProcess.consumeKeepAliveTraffic` forwards the refresh's frames to
/// the webview so that countdown stays true — the reasoning is on that
/// function. The price is that the webview now renders the turn: our
/// `[Canopy keep-alive] …` prompt as a user bubble and the model's `OK`
/// beneath it. This script is what takes both back off the screen.
///
/// **What it matches.** A user bubble whose whole trimmed text equals
/// `KeepAliveGate.promptText` — the same whole-text rule
/// `ShimProcess.isKeepAliveEcho` applies on the wire, and for the same
/// reason: a prefix match would also hide a genuine prompt that QUOTES the
/// tag, together with whatever the model said in reply. What is hidden is
/// that bubble's whole TURN: the extension wraps each user prompt and the
/// rows it produced in one `turn_…` element, so the model's `OK` — which
/// streams in after the bubble mounts — lands inside an element already
/// hidden, and a real prompt queued behind the refresh opens a turn of its
/// own. The first revision walked the bubble's following siblings instead
/// and hid exactly one row, measured: the user row sits inside the turn's
/// `stickyHeader`, so the reply is never its sibling.
///
/// **What it depends on.** Class-name PREFIXES the extension has kept
/// stable across versions — `userMessage_` for the bubble (a prefix
/// `canopy-overrides.css` already relies on) and `turn_` for the wrapper,
/// matched as a whole class token so `returnButton_` and the like cannot
/// hit. With no `turn_` ancestor the bubble's own `userMessageContainer_`
/// row is hidden instead, which leaves the reply visible; either drift
/// costs a stray bubble once an hour, never a hidden real turn, and the
/// `[keepalive-hide]` console line names what was hidden.
///
/// Hiding is an attribute plus an injected stylesheet rather than an inline
/// `style`, so a re-render that rewrites `className` cannot un-hide a row.
enum KeepAliveHideScript {
    static var javascript: String {
        let promptJSON = String(
            data: (try? JSONEncoder().encode(KeepAliveGate.promptText)) ?? Data("\"\"".utf8),
            encoding: .utf8
        ) ?? "\"\""
        return """
        (function() {
            var PROMPT = \(promptJSON);
            var ATTR = 'data-canopy-keepalive-hidden';
            var seen = new WeakSet();

            var style = document.createElement('style');
            style.textContent = '[' + ATTR + '] { display: none !important; }';
            (document.head || document.documentElement).appendChild(style);

            function hasClassPrefix(el, prefix) {
                if (!el || el.nodeType !== 1 || typeof el.className !== 'string') return false;
                var tokens = el.className.split(/\\s+/);
                for (var i = 0; i < tokens.length; i++) {
                    if (tokens[i].indexOf(prefix) === 0) return true;
                }
                return false;
            }

            function turnOf(bubble) {
                for (var e = bubble.parentElement; e; e = e.parentElement) {
                    if (hasClassPrefix(e, 'turn_')) return e;
                }
                return null;
            }

            function scan() {
                var bubbles = document.querySelectorAll('[class*="userMessage_"]');
                for (var i = 0; i < bubbles.length; i++) {
                    var b = bubbles[i];
                    if (seen.has(b)) continue;
                    var text = (b.textContent || '').trim();
                    if (!text) continue; // not mounted yet; look again next batch
                    seen.add(b);
                    if (text !== PROMPT) continue;
                    var target = turnOf(b) || b.closest('[class*="userMessageContainer_"]');
                    if (!target) {
                        console.log('[keepalive-hide] bubble matched but neither turn_ nor userMessageContainer_ ancestor found — leaving it visible');
                        continue;
                    }
                    if (target.hasAttribute(ATTR)) continue;
                    target.setAttribute(ATTR, '1');
                    console.log('[keepalive-hide] hid ' + target.className);
                }
            }

            var scheduled = false;
            function schedule() {
                if (scheduled) return;
                scheduled = true;
                requestAnimationFrame(function() { scheduled = false; scan(); });
            }

            function start() {
                scan();
                new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
            }
            if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);
        })();
        """
    }
}
