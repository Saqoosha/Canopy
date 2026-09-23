import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What the launch screen hands a new session as its first turn: the typed
/// text plus any images dropped or pasted onto the composer. One value, so no
/// hop between the launcher and `ShimProcess` can carry one half and drop the
/// other.
struct LaunchPrompt {
    let text: String
    let images: [LaunchImage]

    private init(text: String, images: [LaunchImage]) {
        self.text = text
        self.images = images
    }

    /// The only way to build one; nil when there is nothing to send.
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

/// One image dropped or pasted onto the launch composer, already in a form
/// the API accepts.
struct LaunchImage: Identifiable {
    let id = UUID()
    let mediaType: String
    let data: Data

    private init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }

    /// The four media types the API — and the CC webview's own attach path —
    /// accept for an image block.
    static let acceptedMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    /// Longest side an image is sent at — the CLI's own default for images.
    static let maxDimension: CGFloat = 2000

    /// Per-image byte ceiling. The API's limit is 5 MB of base64, which is
    /// ~3.75 MB raw; staying under it with margin.
    static let maxBytes = 3_500_000

    /// Build from raw image bytes. Bytes already in an accepted type and
    /// within both limits are sent verbatim (a GIF keeps its animation, a PNG
    /// its transparency); anything else — HEIC, TIFF, an oversized
    /// screenshot — is re-encoded. Nil when the bytes are not an image or
    /// cannot be brought under the limits.
    ///
    /// The type is read from the bytes, never from a file extension: a JPEG
    /// saved as `.png` would otherwise go out labelled wrong and the API
    /// refuses the whole turn.
    static func make(data: Data) -> LaunchImage? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        let size = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let mediaType = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceGetType($0) }
            .flatMap { UTType($0 as String)?.preferredMIMEType }
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
        return make(data: bytes)
    }

    /// The images a paste would carry.
    ///
    /// File URLs are read first, and when there are any they are the whole
    /// answer: copying a file in Finder also puts that file's ICON on the
    /// pasteboard as TIFF, so falling through would attach a picture of a
    /// document icon. A copied non-image file therefore yields nothing, and
    /// the paste goes through as text. Text wins next: Excel, Numbers and Word
    /// put a picture of the selection beside the text they copy. Otherwise the
    /// first image representation wins — a screenshot or "Copy Image".
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> [LaunchImage] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap { make(fileURL: $0) }
        }
        if pasteboard.types?.contains(.string) == true { return [] }
        for type in pasteboard.types ?? [] {
            guard UTType(type.rawValue)?.conforms(to: .image) == true,
                  let data = pasteboard.data(forType: type),
                  let image = make(data: data)
            else { continue }
            return [image]
        }
        return []
    }

    /// Whether a file's extension names an image type.
    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}
