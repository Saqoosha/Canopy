import AppKit
import UniformTypeIdentifiers

/// What the launch screen hands a new session as its first turn: the typed
/// text plus any images dropped onto the composer.
///
/// One value rather than a text parameter and an images parameter side by
/// side, because the prompt travels through five hops (launcher → `AppState` →
/// `SessionStore.openNew` → `OpenSession` → `ShimProcess`) and a second
/// parameter is one more thing each hop can forget to carry.
struct LaunchPrompt: Equatable {
    var text: String
    var images: [LaunchImage]

    /// Nil when there is nothing to send, so every call site keeps the
    /// "nil means no first turn" reading the plain-string version had.
    static func make(text: String, images: [LaunchImage]) -> LaunchPrompt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && images.isEmpty { return nil }
        return LaunchPrompt(text: trimmed, images: images)
    }

    /// The `message.content` array of the io_message, in the shape the CC
    /// webview itself builds for an attached image
    /// (`{type:"image",source:{type:"base64",media_type,data}}`, read out of
    /// extension 2.1.280's `webview/index.js`). Images go ahead of the text,
    /// which is the order the API recommends.
    func contentBlocks() -> [[String: Any]] {
        var blocks: [[String: Any]] = images.map { image in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.data.base64EncodedString(),
                ] as [String: Any],
            ]
        }
        if !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        return blocks
    }
}

/// One image dropped onto the launch composer, already in a form the API
/// accepts.
struct LaunchImage: Identifiable, Equatable {
    let id = UUID()
    let mediaType: String
    let data: Data

    /// The four media types the API — and the CC webview's own attach path —
    /// accept for an image block.
    static let acceptedMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    /// Longest side an image is sent at. The API downscales anything past
    /// ~1568px itself and refuses past 8000, so sending more only costs bytes.
    static let maxDimension: CGFloat = 2000

    /// Per-image byte ceiling. The API's limit is 5 MB of base64, which is
    /// ~3.75 MB raw; staying under it with margin.
    static let maxBytes = 3_500_000

    /// Build from raw file bytes. A file already in an accepted type and
    /// within both limits is sent verbatim (a GIF keeps its animation, a PNG
    /// its transparency); anything else — HEIC, TIFF, an oversized
    /// screenshot — is re-encoded. Nil when the bytes are not an image.
    static func make(data: Data, mediaType: String?) -> LaunchImage? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        let size = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        if let mediaType, acceptedMediaTypes.contains(mediaType),
           data.count <= maxBytes, max(size.width, size.height) <= maxDimension {
            return LaunchImage(mediaType: mediaType, data: data)
        }
        return reencoded(bitmap)
    }

    /// Scale to fit `maxDimension` and encode — PNG when that fits the byte
    /// limit (keeps text in screenshots sharp), JPEG otherwise.
    private static func reencoded(_ source: NSBitmapImageRep) -> LaunchImage? {
        let w = CGFloat(source.pixelsWide), h = CGFloat(source.pixelsHigh)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxDimension / max(w, h))
        let target = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        if let png = rep.representation(using: .png, properties: [:]), png.count <= maxBytes {
            return LaunchImage(mediaType: "image/png", data: png)
        }
        for quality in [0.85, 0.7, 0.5] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= maxBytes {
                return LaunchImage(mediaType: "image/jpeg", data: jpeg)
            }
        }
        return nil
    }

    /// An image file on disk; nil for anything that is not one.
    static func make(fileURL url: URL) -> LaunchImage? {
        guard isImageFile(url), let bytes = try? Data(contentsOf: url) else { return nil }
        return make(data: bytes, mediaType: mediaType(forFileURL: url))
    }

    /// The images a paste would carry.
    ///
    /// File URLs are read first, and when there are any they are the whole
    /// answer: copying a file in Finder also puts that file's ICON on the
    /// pasteboard as TIFF, so falling through would attach a picture of a
    /// document icon. A copied non-image file therefore yields nothing, and
    /// the paste goes through as text. Otherwise the first image
    /// representation wins — a screenshot or "Copy Image" in a browser.
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> [LaunchImage] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap { make(fileURL: $0) }
        }
        for type in pasteboard.types ?? [] {
            guard let uti = UTType(type.rawValue), uti.conforms(to: .image),
                  let data = pasteboard.data(forType: type),
                  let image = make(data: data, mediaType: uti.preferredMIMEType)
            else { continue }
            return [image]
        }
        return []
    }

    /// Media type from a file's extension, for the verbatim path above.
    static func mediaType(forFileURL url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    /// Whether a dropped file is an image at all, so a folder drop and an
    /// image drop can share one drop target.
    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}
