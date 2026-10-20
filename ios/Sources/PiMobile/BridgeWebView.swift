import SwiftUI
import WebKit

/// Full-screen WebView over the local bridge. Mirrors MainActivity on Android:
/// loopback pages stay in the WebView, everything else (OAuth providers etc.)
/// opens in the system browser; the loopback OAuth callback returns here.
struct BridgeWebView: UIViewRepresentable {

    let url: URL
    let uiHost: UIHost
    /// Invoked when the main frame fails to load (bridge may be restarting).
    let onLoadFailure: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        let handler = ScriptHandler(coordinator: context.coordinator)
        userContent.add(handler, name: "ui")

        let scriptSource = """
        window.piUI = {
          render: function(msg) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ui) {
              window.webkit.messageHandlers.ui.postMessage(typeof msg === 'string' ? { kind: 'render', json: msg } : { kind: 'render', ops: msg.ops || msg });
            }
          },
          show: function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ui) {
              window.webkit.messageHandlers.ui.postMessage({ kind: 'show' });
            }
          },
          hide: function() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ui) {
              window.webkit.messageHandlers.ui.postMessage({ kind: 'hide' });
            }
          },
          onEvent: null,
          onClose: null,
          onRestart: null
        };
        """
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        userContent.addUserScript(userScript)

        config.userContentController = userContent

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .init(red: 0.063, green: 0.063, blue: 0.078, alpha: 1) // #101014
        context.coordinator.web = web
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

    @MainActor
    final class Coordinator: NSObject {
        let parent: BridgeWebView
        var loadedURL: URL?
        weak var web: WKWebView?

        init(parent: BridgeWebView) {
            self.parent = parent
            super.init()
            setupUIHost()
        }

        func load(_ url: URL, in web: WKWebView) {
            loadedURL = url
            web.load(URLRequest(url: url))
        }

        func setupUIHost() {
            parent.uiHost.store.send = { [weak self] id, args in
                guard let self, let web = self.web else { return }
                let safeId = jsonText(id)
                let script = """
                if (window.piUI && typeof window.piUI.onEvent === 'function') {
                    window.piUI.onEvent(\(safeId), \(args));
                }
                window.dispatchEvent(new CustomEvent('ui:event', { detail: { id: \(safeId), args: \(args) } }));
                """
                Task { @MainActor in
                    _ = try? await web.evaluateJavaScript(script)
                }
            }

            parent.uiHost.store.close = { [weak self] in
                guard let self else { return }
                let script = """
                if (window.piUI && typeof window.piUI.onClose === 'function') {
                    window.piUI.onClose();
                }
                window.dispatchEvent(new CustomEvent('ui:close'));
                """
                Task { @MainActor in
                    _ = try? await self.web?.evaluateJavaScript(script)
                    self.parent.uiHost.hide()
                }
            }

            parent.uiHost.store.restart = { [weak self] in
                guard let self else { return }
                let script = """
                if (window.piUI && typeof window.piUI.onRestart === 'function') {
                    window.piUI.onRestart();
                }
                window.dispatchEvent(new CustomEvent('ui:restart'));
                """
                Task { @MainActor in
                    _ = try? await self.web?.evaluateJavaScript(script)
                }
            }
        }

        func handleUIMessage(_ message: WKScriptMessage) {
            if let str = message.body as? String {
                if !parent.uiHost.visible { parent.uiHost.show() }
                parent.uiHost.render(str)
                return
            }

            guard let dict = message.body as? [String: Any] else { return }
            let kind = (dict["kind"] as? String) ?? (dict["type"] as? String) ?? "render"

            switch kind {
            case "render", "ui.render":
                if let jsonStr = dict["json"] as? String {
                    if !parent.uiHost.visible { parent.uiHost.show() }
                    parent.uiHost.render(jsonStr)
                } else if let ops = dict["ops"],
                          let data = try? JSONSerialization.data(withJSONObject: ["ops": ops]),
                          let jsonStr = String(data: data, encoding: .utf8) {
                    if !parent.uiHost.visible { parent.uiHost.show() }
                    parent.uiHost.render(jsonStr)
                }
            case "show", "ui.show":
                parent.uiHost.show()
                if let jsonStr = dict["json"] as? String {
                    parent.uiHost.render(jsonStr)
                }
            case "hide", "ui.hide", "close", "ui.close":
                parent.uiHost.hide()
            case "reset", "ui.reset":
                parent.uiHost.render(nil)
            default:
                break
            }
        }
    }

    final class ScriptHandler: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor [weak self] in
                self?.coordinator?.handleUIMessage(message)
            }
        }
    }
}

extension BridgeWebView.Coordinator: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
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
