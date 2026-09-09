import Foundation

/// Puts the caret in a session's chat composer from Swift, at the DOM level.
///
/// Canopy's only other focus mechanism is the AppKit responder chain
/// (`SessionStore.makeFocusedPaneKeyResponder`), and that mechanism has a hole
/// the MacroPad falls straight into. **`NSWindow.makeFirstResponder(_:)` on a
/// view that is ALREADY the first responder returns `true` without sending
/// `resignFirstResponder` or `becomeFirstResponder`** — measured, not read off
/// the documentation. So the handoff that lands the caret in the composer
/// happens only on a change of responder: press the key for a pane that is not
/// focused and the target WKWebView transitions into the responder chain and
/// WebKit restores DOM focus; press the key for the pane that already has
/// focus and every call in the path is a no-op, leaving the caret wherever it
/// was. The pad exists to be pressed while looking somewhere else, so the
/// second gesture is the more common one, and it was the one doing nothing.
///
/// Focusing at the DOM level closes that without depending on responder
/// subtleties at all: it is the same instruction whether or not the pane
/// changed, so the two cases cannot diverge again.
///
/// The input is located by SHAPE, never by the extension's hashed class names
/// — the same heuristic `InputWidthProbe` and `RecapScript` use, and for the
/// same reason (`inputContainer_cKsPxg` churns every extension release).
enum ComposerFocusScript {
    /// Result strings the expression can evaluate to. `Swift`-side callers log
    /// them; they are also what makes a selector regression visible, since
    /// "the pad stopped focusing the input" and "the pad is disconnected" look
    /// identical from the user's chair.
    enum Outcome: String {
        /// The composer took focus.
        case focused
        /// It already had it — nothing to do, and deliberately no caret move
        /// (see `expression`).
        case alreadyFocused = "already-focused"
        /// No input matched the shape heuristic. Either the page has not
        /// mounted one yet (auth screen, first paint) or the extension's DOM
        /// moved out from under the heuristic.
        case noInput = "no-input"
    }

    /// A bare expression, evaluated with `WKWebView.evaluateJavaScript`,
    /// returning one of `Outcome`'s raw values.
    ///
    /// The caret is moved to the end of any existing draft, but ONLY when the
    /// element did not already hold focus. Forcing it unconditionally would
    /// yank the caret out of the middle of a half-typed prompt every time the
    /// key under the user's own hand was pressed.
    static let expression = """
    (function () {
      function findInputEl() {
        // Same shape heuristic as InputWidthProbe.findInputEl: match all
        // three input shapes (current CC builds use a contenteditable div,
        // not a textarea) and filter to the bottom half of the viewport so a
        // Monaco overlay or a top-of-page banner can't win ahead of the chat
        // input.
        var vh = window.innerHeight || document.documentElement.clientHeight;
        var candidates = document.querySelectorAll(
          'textarea, [contenteditable="true"], [role="textbox"]'
        );
        for (var i = 0; i < candidates.length; i++) {
          var rect = candidates[i].getBoundingClientRect();
          if (rect.bottom > vh * 0.5 && rect.width > 0) return candidates[i];
        }
        return candidates[0] || null;
      }

      var el = findInputEl();
      if (!el) return 'no-input';
      if (document.activeElement === el) return 'already-focused';
      el.focus();
      try {
        if (el.isContentEditable) {
          var range = document.createRange();
          range.selectNodeContents(el);
          range.collapse(false);
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        } else if (typeof el.setSelectionRange === 'function') {
          var end = (el.value || '').length;
          el.setSelectionRange(end, end);
        }
      } catch (e) {
        // The element took focus; only the caret placement failed. Report the
        // focus, because that is the part the caller asked for.
      }
      return 'focused';
    })()
    """
}
