import Foundation

/// Puts the caret in a session's chat composer from Swift, at the DOM level.
///
/// Every other focus path in Canopy runs through the AppKit responder chain
/// (`SessionStore.makeFocusedPaneKeyResponder`, plus `WebViewContainer`'s two
/// post-mount handoffs), and that chain cannot express "focus it again".
/// **`NSWindow.makeFirstResponder(_:)` on a view that is ALREADY the first
/// responder returns `true` without sending `resignFirstResponder` or
/// `becomeFirstResponder`** — measured with a two-view AppKit probe. So a
/// MacroPad press on the pane that already holds focus reached that handoff
/// and sent WebKit nothing. Note the scope: the REST of `focusPane` still ran
/// — it activates the app, orders the window front and clears that pane's
/// unread mark — so the press was never inert, it just never moved the caret.
/// Coming back to the session you were already in is the gesture the pad
/// exists for, and it was the one gesture that did not finish.
///
/// Focusing at the DOM level closes that without depending on the responder
/// changing: it is the same instruction whether or not the pane changed, so
/// the two cases cannot diverge again. It is NOT independent of WebKit's own
/// restore-on-becoming-first-responder — on a cross-pane press both are in
/// flight and their order has never been isolated (see the MacroPad
/// learnings, which record what the hardware run does and does not settle).
///
/// The input is located by SHAPE, never by the extension's hashed class names
/// — same reason as `InputWidthProbe` and `RecapScript` (`inputContainer_cKsPxg`
/// churns every extension release). It is NOT the same shape as theirs, and
/// `findInputEl` below carries the measurement for why: their selector is
/// right for taking a measurement and wrong for taking an action, because two
/// of its three clauses match only elements this must never focus.
enum ComposerFocusScript {
    /// Result strings the expression can evaluate to. Swift-side callers log
    /// them; they are also what makes a selector regression visible, since
    /// "the pad stopped focusing the input" and "the pad is disconnected" look
    /// identical from the user's chair.
    enum Outcome: String {
        /// The composer took focus.
        case focused
        /// The composer already WAS `document.activeElement`, so nothing was
        /// done and — deliberately — no caret was moved (see `expression`).
        /// Read that property for what it is: the document's last-focused
        /// element, which survives the window losing key status. It is not
        /// "currently holds keyboard focus", and the looser meaning is the one
        /// wanted here — an element that is still the document's focused one
        /// gets the caret back from WebKit on activation without any help.
        /// Both observed hardware presses returned `focused`, so this branch
        /// is unmeasured rather than ruled out.
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
        // NOT the same selector as InputWidthProbe.findInputEl, and the
        // difference is measured rather than stylistic. Against the bundled
        // extension 2.1.263:
        //
        //   - the composer is `contentEditable:"plaintext-only"` with
        //     `role:"textbox"` and `aria-label:"Message input"`. Attribute
        //     selectors match on the exact value, so the probe's
        //     `[contenteditable="true"]` clause never matches it — the
        //     `[role="textbox"]` clause is the one carrying it, and it is the
        //     bundle's only `role:"textbox"`.
        //   - `[contenteditable="true"]` matches exactly three things, all of
        //     them elements we must NOT focus: a Bash permission request's
        //     editable command box (`permissionRequestInput bashCommand`) and
        //     the sidebar's session/group rename-in-place spans.
        //   - `[contenteditable="plaintext-only"]` additionally matches
        //     AskUserQuestion's "Other" field and the permission dialog's
        //     "Tell Claude what to do instead" box.
        //
        // Those wrong elements cluster in the `asking` state — the raised-hand
        // LED, i.e. the single press this feature exists to serve — and they
        // sit near the bottom of the viewport, so a first-match-wins scan over
        // the generic shapes redirects the user's next keystroke into a
        // command box. Ask for the composer's own signature instead.
        var vh = window.innerHeight || document.documentElement.clientHeight;
        var candidates = document.querySelectorAll('[role="textbox"]');
        for (var i = 0; i < candidates.length; i++) {
          // Bottom half of the viewport, so a future second textbox mounted
          // above the fold can't win ahead of the composer.
          var rect = candidates[i].getBoundingClientRect();
          if (rect.bottom > vh * 0.5 && rect.width > 0) return candidates[i];
        }
        // No fallback, and that is the other deliberate divergence. The two
        // sibling copies fall through to `candidates[0]` when nothing passes
        // the gate, because a width measured off the wrong element is a
        // cosmetic misalignment. Here the consequence is an action, and the
        // fallback would also report `focused`, swallowing the `no-input`
        // signal that is the only way a DOM change surfaces here. If the
        // extension ever drops `role="textbox"`, this returns null and says
        // so — loudly not working beats quietly focusing the wrong thing.
        return null;
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
