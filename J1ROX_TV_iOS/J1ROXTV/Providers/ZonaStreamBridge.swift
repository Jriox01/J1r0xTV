import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Only asks the site's SDK for URLs. There is no HTML video player here.
@MainActor final class ZonaStreamBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[JSONValue], Error>?
    private var deadline: Task<Void, Never>?
    private let nonce = UUID().uuidString

    static func streams(kpID: String, episodeKey: String?) async throws -> [JSONValue] {
        let bridge = ZonaStreamBridge()
        return try await bridge.run(kpID: kpID, episodeKey: episodeKey)
    }

    private func run(kpID: String, episodeKey: String?) async throws -> [JSONValue] {
        guard let numericID = Int(kpID), numericID > 0 else { throw ProviderError.mediaNotFound }
        let arguments = try JSONEncoder().encode(["nonce": nonce, "episode": episodeKey ?? ""])
        let json = String(decoding: arguments, as: UTF8.self)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.userContentController.add(self, name: "zonaResult")
                let web = WKWebView(frame: .init(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
                self.webView = web
                web.navigationDelegate = self
                #if canImport(UIKit)
                web.isUserInteractionEnabled = false
                web.alpha = 0.01
                let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first { $0.isKeyWindow }
                window?.addSubview(web)
                #endif
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 55_000_000_000) }
                    catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
                web.loadHTMLString("""
                <!doctype html><meta charset="utf-8"><script>
                const args = \(json), results = [];
                let finished = false, settle;
                function finish(error) {
                  if (finished) return; finished = true; clearTimeout(settle);
                  window.webkit.messageHandlers.zonaResult.postMessage({nonce: args.nonce, error: error || '', results});
                }
                async function start() {
                  try {
                    const sdk = window['ru.zona.stream.site'];
                    if (!sdk) return finish('sdk');
                    const provider = await sdk.createStreamsProvider({getStreamDurationInMicroseconds: () => '1000000000'});
                    provider.getStreams(\(numericID), false, args.episode || null, {
                      onStreamsReceived: value => {
                        if (finished) return;
                        try {
                          const result = JSON.parse(value);
                          if (Array.isArray(result.videoStreams)) results.push(result);
                          // Allow other extractors to supply voices, but bound selection latency.
                          if (results.some(r => r.videoStreams.some(s => ['HLS','mp4'].includes(s.resolution) && !s.parameters?.urlTransform))) {
                            clearTimeout(settle); settle = setTimeout(() => finish(), 2500);
                          }
                        } catch (_) {}
                      },
                      onCompletion: () => finish()
                    });
                  } catch (_) { finish('sdk'); }
                }
                </script><script src="https://kinoserial.online/loader.js" onload="start()" onerror="finish('network')"></script>
                """, baseURL: URL(string: "https://kinoserial.online/"))
            }
        }, onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } })
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.name == "zonaResult",
              let body = message.body as? [String: Any], body["nonce"] as? String == nonce else { return }
        guard (body["error"] as? String ?? "").isEmpty,
              let objects = body["results"] as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: objects),
              let result = try? JSONDecoder().decode([JSONValue].self, from: data) else {
            finish(.failure(ProviderError.unavailable)); return
        }
        finish(.success(result))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(ProviderError.unavailable)) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The resolver must never open a portal, popup, or external application.
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == "about" || url?.absoluteString == "https://kinoserial.online/" ? .allow : .cancel)
    }
    private func finish(_ result: Result<[JSONValue], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zonaResult")
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        #if canImport(UIKit)
        webView?.removeFromSuperview()
        #endif
        webView = nil
        continuation.resume(with: result)
    }
}
