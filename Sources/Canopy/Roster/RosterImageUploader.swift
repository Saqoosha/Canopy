import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RosterImage")

/// Read された画像を relay の R2 に置く。
///
/// **`RosterNotifier` と違って、これは fire-and-forget ではない。** 呼び出し側は
/// 成功を待ってからイベントを送る —— 行が出た = バイトは在る、という関係を
/// 守るため。壊れたサムネイルが出る状態を作らない。
enum RosterImageUploader {
    /// サムネイルの長辺、ピクセル。実測で 1440×900 のスクショが JPEG 19KB に
    /// なる値（`docs/session-images.md` の表）。行に出る大きさに対して十分で、
    /// 480 にすると 35KB、800 で 77KB。
    static let thumbnailMaxPixelSize = 320
    /// サムネイルの JPEG 品質。上の実測と同じ 0.65。
    static let thumbnailQuality = 0.65
    /// 原寸の上限、バイト。超えたら何もアップロードせず、呼び出し側は素の
    /// レンチ行を出す。relay 側の上限（12MiB）より低いのは意図的 —— Mac が
    /// 先に出るので、こちらの上限を relay の上限で追い越せないようにする。
    static let maxFullBytes = 8 * 1024 * 1024

    /// 画像の実ピクセル寸法。デコードせずにヘッダだけ読む。
    ///
    /// **EXIF orientation が 5〜8（90 度回転系）なら幅と高さを入れ替えて返す。**
    /// `kCGImagePropertyPixelWidth/Height` はエンコードされたままの寸法で、
    /// 表示上の寸法ではない。一方 `thumbnail(from:)` は
    /// `kCGImageSourceCreateThumbnailWithTransform: true` で回転を焼き込んだ
    /// サムネイルを作る —— ここで寸法を合わせておかないと、電話が受け取る
    /// width/height とサムネイルの実際の見た目が矛盾する（縦横比が逆になる）。
    /// **この関数とその transform オプションは対で変えること** —— 片方だけ
    /// 直すと今日の壊れ方が向きを変えて再発する。
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int
        if let orientation, (5...8).contains(orientation) {
            return (height, width)
        }
        return (width, height)
    }

    /// 長辺 `thumbnailMaxPixelSize` の JPEG。**元より大きくはしない** —— ただし
    /// それを保証しているのは下の `min` ではなく ImageIO 自身。
    /// `CGImageSourceCreateThumbnailAtIndex` は `Always` を付けても元の寸法を
    /// 超えて拡大しない（macOS で実測: 100×60 に上限 320 を渡しても 100×60）。
    /// `min` はその挙動に依存しない書き方として残しているだけで、load-bearing
    /// ではない。以前ここには「`Always` だと小さい絵が上限まで引き伸ばされる」
    /// と書いてあったが、測ったら偽だった。
    static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let size = pixelSize(of: data)
        else { return nil }
        let longEdge = min(max(size.width, size.height), thumbnailMaxPixelSize)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            // EXIF の向きを焼き込む。しないと、電話が向きを知らないまま
            // 横倒しのサムネイルを描く。
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: thumbnailQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
        return out as Data
    }

    /// full と thumb を PUT する。両方成功したときだけ true。
    ///
    /// **片方だけ成功した状態を成功と呼ばない。** thumb だけ在れば行に絵は
    /// 出るがタップが 404 になり、full だけ在れば行に穴が空く。どちらも
    /// 「行が出た = バイトは在る」を破る。
    static func upload(sessionId: String, eventId: String,
                       full: Data, thumb: Data, mediaType: String) async -> Bool {
        guard let target = await resolvedTarget() else { return false }
        async let a = put(target: target, sessionId: sessionId, eventId: eventId,
                          variant: "full", body: full, mediaType: mediaType)
        async let b = put(target: target, sessionId: sessionId, eventId: eventId,
                          variant: "thumb", body: thumb, mediaType: "image/jpeg")
        // Not `await a && b` — `&&`'s second operand is `@autoclosure`, and an
        // `async let` cannot be captured inside one (compile error). Awaiting
        // both to plain `Bool`s first sidesteps it without changing that both
        // uploads run concurrently above.
        let (fullOK, thumbOK) = await (a, b)
        return fullOK && thumbOK
    }

    /// `RosterNotifier.resolvedTarget` と同じ 3 つ組を同じ順で確かめる。
    /// https の拒否も同じ理由（CWE-319）—— ここも Bearer secret を運ぶ。
    @MainActor
    private static func resolvedTarget() -> (machineId: String, base: URLComponents, secret: String)? {
        let settings = CanopySettings.shared
        guard settings.rosterEnabled,
              let machineId = MachineIdentity.stableId(),
              var components = URLComponents(string: settings.rosterEndpoint)
        else { return nil }
        components.path = "/image"
        guard components.scheme == "https" else {
            logger.error("roster endpoint must be https; refusing to send the secret over \(components.scheme ?? "no scheme", privacy: .public)")
            return nil
        }
        guard let secret = RosterPublisher.sharedSecretForNotifier() else { return nil }
        return (machineId, components, secret)
    }

    private static func put(target: (machineId: String, base: URLComponents, secret: String),
                            sessionId: String, eventId: String, variant: String,
                            body: Data, mediaType: String) async -> Bool {
        var components = target.base
        components.queryItems = [
            URLQueryItem(name: "machine", value: target.machineId),
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "event", value: eventId),
            URLQueryItem(name: "variant", value: variant),
        ]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(target.secret)", forHTTPHeaderField: "Authorization")
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 {
                logger.notice("roster image \(variant, privacy: .public) returned \(code, privacy: .public)")
                return false
            }
            return true
        } catch {
            logger.notice("roster image \(variant, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
