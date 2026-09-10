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
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    /// 長辺 `thumbnailMaxPixelSize` の JPEG。**元より大きくはしない** ——
    /// `kCGImageSourceCreateThumbnailFromImageIfAbsent` ではなく `Always` を
    /// 使うと小さい絵も上限まで引き伸ばされ、バイトが増えるだけで行に出る
    /// 大きさは変わらない。
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
}
