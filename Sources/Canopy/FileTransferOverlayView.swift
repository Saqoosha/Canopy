import SwiftUI

/// The mirror pane's answer to "did that click do anything?": a file the
/// other Mac is shipping here, with how far along it is, in the same dress as
/// `ConnectionOverlayView`. Appears only once a transfer has outlived
/// `MirrorFileReceiver.overlayDelay`, so a small file lands with no flash.
struct FileTransferOverlayView: View {
    let receiver: MirrorFileReceiver

    var body: some View {
        if receiver.isOverlayVisible {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                VStack(spacing: 14) {
                    if let error = receiver.lastError, receiver.current == nil {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.orange)
                        Text("Could not receive file")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    } else if let transfer = receiver.current {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                        Text("Receiving \(transfer.name)")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        // Drawn by hand: `ProgressView(value:)` on this material
                        // showed an empty track while the byte count beside it
                        // climbed, so the value was arriving and the bar was not.
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            GeometryReader { geometry in
                                Capsule().fill(.white)
                                    .frame(width: max(6, geometry.size.width * transfer.fraction))
                            }
                        }
                        .frame(width: 240, height: 6)
                        Text("\(Self.bytes(transfer.received)) of \(Self.bytes(transfer.size)) from \(transfer.host)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(28)
                // Fixed, so the box does not resize as "980 KB" becomes "12.3 MB".
                .frame(width: 340)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
