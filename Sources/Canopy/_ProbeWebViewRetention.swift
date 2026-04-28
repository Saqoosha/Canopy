#if DEBUG
import SwiftUI
import WebKit
import os.log

/// Probe for the single-window-sidebar redesign:
/// validates that ZStack { ForEach { NSViewRepresentable<WKWebView> } } with
/// opacity-based visibility toggling KEEPS the WKWebView alive (DOM state
/// preserved). Look for these signals in unified log:
///
///   subsystem=sh.saqoo.Canopy category=Probe
///
///   make[N]      — NSViewRepresentable.makeNSView called for slot N
///   update[N]    — NSViewRepresentable.updateNSView called for slot N
///   dismantle[N] — NSViewRepresentable.dismantleNSView called for slot N
///   tick visible=N — the probe auto-toggled to slot N
///   loaded[N]    — WKWebView finished loading its initial URL for slot N
///
/// PASS criteria:
/// - exactly two `make[0]` and `make[1]` events ever (one per slot, lifetime).
/// - zero `dismantle[*]` events while the probe is toggling.
/// - `updateNSView` may fire on each tick but should not log destructive work.
/// - the URL bar / page state of the hidden web view stays the same after
///   coming back (visual check via screenshot).
///
/// FAIL signals:
/// - `make[0]` or `make[1]` fires more than once.
/// - `dismantle[*]` fires before the probe is dismissed.
struct ProbeRetentionView: View {
    @State private var visible = 0
    @State private var tickCount = 0

    private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Probe")
    private let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Probe: WebView retention (auto-cycles every 2s)")
                .font(.headline)
            Text("tick=\(tickCount) visible=\(visible)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            ZStack {
                ForEach(0..<2, id: \.self) { slot in
                    ProbeWebHost(slot: slot)
                        .opacity(visible == slot ? 1 : 0)
                        .allowsHitTesting(visible == slot)
                }
            }
            .frame(height: 200)
            .background(Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .onAppear {
            logger.info("probe appeared")
        }
        .onReceive(timer) { _ in
            tickCount += 1
            visible = (visible + 1) % 2
            logger.info("tick=\(tickCount, privacy: .public) visible=\(visible, privacy: .public)")
            if tickCount >= 8 {
                // Stop ourselves after 8 ticks (16 s) so logs don't spam forever.
                logger.info("probe stopping after 8 ticks")
                timer.upstream.connect().cancel()
            }
        }
    }
}

/// NSViewRepresentable that wraps a WKWebView and logs its lifecycle.
struct ProbeWebHost: NSViewRepresentable {
    let slot: Int
    private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Probe")

    func makeNSView(context: Context) -> WKWebView {
        logger.info("make[\(slot, privacy: .public)] — creating WKWebView")
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        // Load a page that we can visually identify.
        let html = """
        <!DOCTYPE html>
        <html><body style='font-family:system-ui;padding:20px;background:\(slot == 0 ? "#fce4ec" : "#e3f2fd");'>
          <h2>Slot \(slot)</h2>
          <p>If this view's WKWebView is preserved across opacity toggles,
             the counter below should KEEP its value when this slot is shown again.</p>
          <p>Counter: <span id='c'>0</span></p>
          <button onclick='document.getElementById("c").innerText=parseInt(document.getElementById("c").innerText)+1'>++</button>
          <input id='input' placeholder='Type here'>
          <p>Slot \(slot) — ts \(Date().timeIntervalSince1970)</p>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        logger.debug("update[\(slot, privacy: .public)]")
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // Note: `slot` not available in static context; coordinator carries it.
        Logger(subsystem: "sh.saqoo.Canopy", category: "Probe")
            .info("dismantle[\(coordinator.slot, privacy: .public)] — view torn down")
    }

    func makeCoordinator() -> Coordinator { Coordinator(slot: slot) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let slot: Int
        private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Probe")
        init(slot: Int) { self.slot = slot }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("loaded[\(self.slot, privacy: .public)]")
        }
    }
}
#endif
