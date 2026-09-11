import AppKit
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "ImagePopup")

/// A native window showing one Read-tool image at up to screen size.
///
/// The in-page lightbox this replaces was a `position:fixed` overlay inside
/// the pane's WKWebView, so its `92vw` was 92% of the PANE — with several
/// panes open the "full size" view was barely larger than the thumbnail.
/// Only a window can escape the pane, so the click is forwarded here (through
/// `LinkClickHandler`, see `ImagePreviewScript.openImage`).
///
/// One window, reused: clicking another image swaps the content rather than
/// stacking windows. It is not a Canopy app window by `isCanopyWindow`'s
/// test, so Cmd+W reaches it through `handleCloseShortcut`'s non-Canopy
/// branch with no extra wiring; Escape closes it too.
///
/// Zoom follows Preview's keys: pinch, Cmd+= / Cmd+-, Cmd+0 actual size,
/// Cmd+9 fit. Double-click toggles fit and actual size.
@MainActor
final class ImagePopupWindow {
    static let shared = ImagePopupWindow()

    private var window: ImagePopupNSWindow?

    /// Fraction of the screen's visible frame the initial size may take.
    nonisolated private static let screenFraction: CGFloat = 0.9
    nonisolated private static let minimumSide: CGFloat = 160

    func show(dataURL: String, title: String) {
        guard let decoded = Self.decode(dataURL: dataURL),
              let image = NSImage(data: decoded.data)
        else {
            logger.warning("ImagePopupWindow: could not decode image data URL (\(dataURL.prefix(40), privacy: .public)…)")
            return
        }
        let window = self.window ?? ImagePopupNSWindow()
        self.window = window

        // A visible window keeps its screen (the user may have moved it to
        // another display); a fresh one opens where Canopy is.
        let screen = (window.isVisible ? window.screen : nil)
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main
        let size = Self.fittedSize(for: image.size, in: screen?.visibleFrame.size)
        let previousCenter = window.isVisible
            ? CGPoint(x: window.frame.midX, y: window.frame.midY)
            : nil

        window.title = title
        window.zoomView.setImage(image, data: decoded.data, fileName: title,
                                 fileExtension: decoded.fileExtension)
        window.setContentSize(size)
        window.zoomView.zoomToFit()
        if let previousCenter {
            var frame = window.frame
            frame.origin = CGPoint(x: previousCenter.x - frame.width / 2,
                                   y: previousCenter.y - frame.height / 2)
            if let visible = screen?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            }
            window.setFrame(frame, display: true)
        } else if let visible = screen?.visibleFrame {
            let frame = window.frame
            window.setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2,
                                          y: visible.midY - frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// The image at its own point size, shrunk to fit `screenFraction` of
    /// the screen, and raised to `minimumSide` on its short side so a tiny
    /// icon still opens a window you can grab.
    nonisolated static func fittedSize(for imageSize: CGSize, in screenSize: CGSize?) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: minimumSide, height: minimumSide)
        }
        let fitScale = screenSize.map {
            min($0.width * screenFraction / imageSize.width,
                $0.height * screenFraction / imageSize.height)
        } ?? .greatestFiniteMagnitude
        let floorScale = minimumSide / min(imageSize.width, imageSize.height)
        // The floor may raise a small image but never past the screen fit,
        // so an extreme aspect ratio cannot open a window wider than the display.
        let scale = min(max(1, floorScale), fitScale)
        return CGSize(width: max(imageSize.width * scale, minimumSide).rounded(),
                      height: max(imageSize.height * scale, minimumSide).rounded())
    }

    /// Writes the image into a per-open temp directory (Preview needs a file)
    /// and opens it there. The temp directory is left to the OS to reap:
    /// Preview may still have it open when Canopy quits.
    static func openInPreview(data: Data, fileName: String, fileExtension: String) {
        let base = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (base.isEmpty ? "image" : base) + "." + fileExtension
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Canopy-images", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            logger.error("ImagePopupWindow: could not write image for Preview: \(error.localizedDescription, privacy: .public)")
            return
        }
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        NSWorkspace.shared.open([url], withApplicationAt: preview,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                logger.error("ImagePopupWindow: Preview failed to open image: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Same, straight from a thumbnail's data URL — the session view's
    /// context menu, which never opens this window.
    static func openInPreview(dataURL: String, fileName: String) {
        guard let decoded = decode(dataURL: dataURL) else {
            logger.warning("ImagePopupWindow: could not decode image data URL for Preview")
            return
        }
        openInPreview(data: decoded.data, fileName: fileName, fileExtension: decoded.fileExtension)
    }

    /// Decodes `data:<mime>;base64,<payload>` — the only shape
    /// `ImagePreviewScript` produces.
    nonisolated static func decode(dataURL: String) -> (data: Data, fileExtension: String)? {
        guard dataURL.hasPrefix("data:"),
              let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]),
                              options: .ignoreUnknownCharacters)
        else { return nil }
        let mime = dataURL.dropFirst("data:".count).prefix { $0 != ";" }
        let ext = mime.split(separator: "/").last.map { $0 == "jpeg" ? "jpg" : String($0) } ?? "png"
        return (data, ext)
    }
}

private final class ImagePopupNSWindow: NSWindow {
    let zoomView = ImageZoomView()

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        contentView = zoomView

        let button = NSButton(title: "Open in Preview", target: zoomView,
                              action: #selector(ImageZoomView.openInPreview))
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        let holder = NSView()
        holder.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
        ])
        holder.frame.size = CGSize(width: button.fittingSize.width + 8, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        addTitlebarAccessoryViewController(accessory)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    /// Ahead of the main menu, so Cmd+0 means "actual size" here the way it
    /// does in Preview, rather than Canopy's "show main window".
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command || modifiers == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomView.zoom(by: 1.25)
        case "-": zoomView.zoom(by: 0.8)
        case "0": zoomView.zoomToActualSize()
        case "9": zoomView.zoomToFit()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// A magnifying scroll view around the image. Tracks whether the user is
/// "fitted" so a window resize keeps a fitted image fitted, and leaves a
/// zoomed one alone.
private final class ImageZoomView: NSScrollView {
    private let imageView = DoubleClickImageView()
    private var imageData = Data()
    private var fileName = "image"
    private var fileExtension = "png"
    private var isFitted = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteringClipView()
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        maxMagnification = 16
        backgroundColor = .windowBackgroundColor
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.animates = true
        imageView.onDoubleClick = { [weak self] event in self?.toggleZoom(at: event) }
        documentView = imageView

        let menu = NSMenu()
        menu.addItem(withTitle: "Open in Preview", action: #selector(openInPreview), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Actual Size", action: #selector(actualSizeAction), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(fitAction), keyEquivalent: "")
            .target = self
        self.menu = menu
        imageView.menu = menu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setImage(_ image: NSImage, data: Data, fileName: String, fileExtension: String) {
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        imageData = data
        self.fileName = fileName
        self.fileExtension = fileExtension
    }

    private var fitMagnification: CGFloat {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0 else { return 1 }
        let visible = contentSize
        return min(visible.width / size.width, visible.height / size.height)
    }

    func zoomToFit() {
        isFitted = true
        minMagnification = min(fitMagnification, 1) / 4
        magnification = fitMagnification
    }

    func zoomToActualSize() {
        isFitted = false
        setMagnification(1, centeredAt: visibleCenter)
    }

    func zoom(by factor: CGFloat) {
        isFitted = false
        setMagnification(magnification * factor, centeredAt: visibleCenter)
    }

    private var visibleCenter: CGPoint {
        let r = documentVisibleRect
        return CGPoint(x: r.midX, y: r.midY)
    }

    override func magnify(with event: NSEvent) {
        isFitted = false
        super.magnify(with: event)
    }

    private func toggleZoom(at event: NSEvent) {
        if isFitted {
            isFitted = false
            let point = imageView.convert(event.locationInWindow, from: nil)
            setMagnification(1, centeredAt: point)
        } else {
            zoomToFit()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isFitted { zoomToFit() }
    }

    @objc private func actualSizeAction() { zoomToActualSize() }
    @objc private func fitAction() { zoomToFit() }

    @objc func openInPreview() {
        ImagePopupWindow.openInPreview(data: imageData, fileName: fileName, fileExtension: fileExtension)
    }
}

/// Keeps an image smaller than the viewport centred instead of pinned to the
/// bottom-left corner, which is where `NSClipView` puts it by default.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if rect.height > doc.frame.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Clicks land on the document view, not the scroll view around it, so the
/// double-click toggle has to be caught here.
private final class DoubleClickImageView: NSImageView {
    var onDoubleClick: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick(event)
        } else {
            super.mouseDown(with: event)
        }
    }
}
