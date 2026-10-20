import SwiftUI

@main
struct PiMobileApp: App {
    @StateObject private var controller = RuntimeController()

    var body: some Scene {
        WindowGroup {
            BridgeScreen()
                .environmentObject(controller)
                .preferredColorScheme(.dark)
        }
    }
}

struct BridgeScreen: View {
    @EnvironmentObject private var controller: RuntimeController

    var body: some View {
        ZStack {
            Color(red: 0.063, green: 0.063, blue: 0.078) // #101014, matches the web UI
                .ignoresSafeArea()
            switch controller.phase {
            case .preparing, .starting:
                WaitingView(phase: controller.phase)
            case .ready(let url):
                BridgeWebView(url: url) {
                    controller.bridgeLoadFailed()
                }
            case .failed(let message):
                FailureView(message: message)
            }
        }
        .task { controller.boot() }
    }
}

private struct WaitingView: View {
    let phase: RuntimeController.Phase

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text(phase == .preparing ? "preparing pi runtime…" : "starting bridge…")
                .foregroundStyle(Color(red: 0.89, green: 0.89, blue: 0.91))
            Text("first launch extracts the bundled runtime")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("runtime failed to start")
                .font(.headline)
                .foregroundStyle(Color(red: 0.89, green: 0.89, blue: 0.91))
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
    }
}
