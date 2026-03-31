import SwiftUI

struct ConnectionOverlayView: View {
    let connectionState: ConnectionState
    var onBackToLauncher: () -> Void

    var body: some View {
        if connectionState.isOverlayVisible {
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    statusIcon
                    Text("SSH Connection Lost")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(connectionState.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))

                    if case .reconnectFailed = connectionState.status {
                        HStack(spacing: 12) {
                            Button("Retry") {
                                connectionState.onRetry?()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(connectionState.onRetry == nil)
                            Button("Back to Launcher") { onBackToLauncher() }
                                .buttonStyle(.bordered)
                                .tint(.white)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(32)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch connectionState.status {
        case .connected:
            EmptyView()
        case .reconnecting:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .reconnectFailed:
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
        }
    }
}
