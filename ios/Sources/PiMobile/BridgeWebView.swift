import SwiftUI
import WebKit

/// Full-screen WebView over the local bridge. Mirrors MainActivity on Android:
/// loopback pages stay in the WebView, everything else (OAuth providers etc.)
/// opens in the system browser; the loopback OAuth callback returns here.
struct BridgeWebView: UIViewRepresentable {

    let url: URL
    /// Invoked when the main frame fails to load (bridge may be restarting).
    let onLoadFailure: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .init(red: 0.063, green: 0.063, blue: 0.078, alpha: 1) // #101014
        context.coordinator.load(url, in: web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        // reload when the bridge URL changed after a restart
        if context.coordinator.loadedURL != url {
            context.coordinator.load(url, in: web)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: BridgeWebView
        var loadedURL: URL?

        init(parent: BridgeWebView) {
            self.parent = parent
        }

        func load(_ url: URL, in web: WKWebView) {
            loadedURL = url
            web.load(URLRequest(url: url))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
                decisionHandler(.cancel)
                return
            }
            let host = url.host ?? ""
            let isLoopback = ["http", "https"].contains(scheme) && ["127.0.0.1", "localhost"].contains(host)
            if isLoopback {
                decisionHandler(.allow)
                return
            }
            // OAuth providers, custom schemes (tel:, mailto:) → leave the app
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                parent.onLoadFailure()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadFailure()
        }
    }
}
