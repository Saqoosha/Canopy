import Foundation

/// Puts the caret in a session's chat composer from Swift, at the DOM level.
///
/// The MacroPad needs this because the AppKit responder chain cannot express
/// "focus it again". **`NSWindow.makeFirstResponder(_:)` on a view that is
/// ALREADY the first responder returns `true` without sending
/// `resignFirstResponder` or `becomeFirstResponder`** — measured with a
/// two-view probe. So a press on the pane that already held focus reached
/// `SessionStore.makeFocusedPaneKeyResponder` and sent WebKit nothing. Only
/// that handoff was inert: the rest of `focusPane` still activated the app,
/// ordered the window front and cleared the unread mark, so the press moved
/// everything except the caret.
///
/// Focusing at the DOM level does not depend on the responder changing, so
/// the same-pane and cross-pane presses run one instruction and cannot
/// diverge again. It is NOT ordered against WebKit's own
/// restore-on-becoming-first-responder — on a cross-pane press both are in
/// flight, and which lands last has never been isolated.
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
        /// element, which survives the window losing key status, not
        /// "currently holds keyboard focus". Both observed hardware presses
        /// returned `focused`, so this branch is unmeasured rather than ruled
        /// out.
        case alreadyFocused = "already-focused"
        /// Nothing matched. Three known causes, and the routine one is last:
        /// the page has not mounted a composer yet (auth screen, first
        /// paint); the composer lost the `role="textbox"` + `contenteditable`
        /// pair `findInputEl` asks for, an attribute-level drift and the
        /// specific failure that selector choice buys; or **a permission
        /// request is pending and the composer is empty**, in which case the
        /// extension sets the whole prompt-input container to `display:none`
        /// (measured on 2.1.263: `permissionRequests.length > 0 &&
        /// !promptInputActive`), the rect collapses and the width gate drops
        /// it. That third case is the `asking` state — the raised-hand LED,
        /// the press this feature most exists to serve — so it is neither
        /// rare nor a fault, and it is what stops a pad press from stealing
        /// keyboard focus from the permission dialog. It stops being true the
        /// moment the composer holds a draft, which is the one window where a
        /// press could still take focus off that dialog.
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
        // The composer is the one element that is BOTH `contenteditable` and
        // `role="textbox"`. Measured against the bundled extension 2.1.263,
        // where each half ALONE matches something this must never focus:
        //
        //   - `[role="textbox"]` also matches Monaco's hidden `inputarea` — a
        //     real <textarea> that does `setAttribute("role","textbox")` and
        //     `setAttribute("aria-multiline","true")`, so neither attribute
        //     discriminates. It is mounted by Canopy's own ContentViewer and
        //     by the extension's diff editor. It is 1x1 rather than hidden,
        //     and it renders wherever the caret is — top-left when there is no
        //     visible cursor — so the viewport gate below sometimes drops it
        //     and sometimes does not. Position-dependent is the same as
        //     unreliable here; the gate is not what excludes it.
        //   - `[contenteditable]` also matches a Bash permission request's
        //     editable command box, AskUserQuestion's "Other" field, the
        //     permission dialog's reject box, and the sidebar's
        //     rename-in-place spans. The first three render inside the
        //     composer overlay AHEAD of the input, so a first-match scan
        //     reaches them first — and they appear in the `asking` state,
        //     which is the raised-hand LED, i.e. the press this feature most
        //     exists to serve. Landing there would put the user's next
        //     keystroke into a command box.
        //
        // Note the spelling trap in the second bullet: the composer is
        // `contenteditable="plaintext-only"`, and attribute selectors match on
        // the exact value, so `InputWidthProbe`'s `[contenteditable="true"]`
        // never matches it at all. Presence, not value, is what is wanted.
        var vh = window.innerHeight || document.documentElement.clientHeight;
        var candidates = document.querySelectorAll('[role="textbox"][contenteditable]');
        for (var i = 0; i < candidates.length; i++) {
          // Bottom half of the viewport, so a future second composer-shaped
          // element above the fold can't win ahead of the real one.
          var rect = candidates[i].getBoundingClientRect();
          if (rect.bottom > vh * 0.5 && rect.width > 0) return candidates[i];
        }
        // No `candidates[0]` fallback, unlike the sibling copies of this
        // scan. Theirs report a measurement, where a mispick is a cosmetic
        // misalignment; this one takes an action, and a mispick would also
        // return `focused` and swallow the `no-input` signal that is the only
        // way a DOM change surfaces here. Loudly not working beats quietly
        // focusing the wrong thing.
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
