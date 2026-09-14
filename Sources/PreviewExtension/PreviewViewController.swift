import Cocoa
import os
import Quartz
import WebKit

/// Inspect with:
///     log show --last 5m --info --predicate 'subsystem == "com.puiwaifu.QuickMark"'
/// Note that `log show --start` reads local time, so a UTC timestamp there
/// silently matches nothing.
let qmLog = Logger(subsystem: "com.puiwaifu.QuickMark", category: "preview")

/// The Quick Look preview extension's principal class.
///
/// Quick Look instantiates this, calls `preparePreviewOfFile(at:)`, and takes a
/// snapshot once the completion handler fires. Calling that handler early gives
/// a blank preview, so it is held until the web view reports the load finished.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView!
    private var completion: ((Error?) -> Void)?

    /// Quick Look gives an extension a limited window to produce a preview.
    /// If the web view somehow never reports back, fail visibly rather than
    /// leaving the panel spinning.
    private static let loadTimeout: TimeInterval = 5

    // MARK: - View

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false

        self.webView = webView
        self.view = webView
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let source = try PreviewSource.load(contentsOf: url)
            let html: String

            switch source.kind {
            case .markdown:
                // Local images are read here and embedded as data URIs, so the
                // page itself never touches the filesystem and needs no base URL.
                html = HTMLPage.render(
                    MarkdownDocument(text: source.text),
                    fileName: source.fileName,
                    baseURL: url.deletingLastPathComponent()
                )

            case .epub:
                html = HTMLPage.render(
                    epubData: source.data ?? Data(),
                    fileName: source.fileName
                )

            case .dotenv, .json, .plainText:
                html = HTMLPage.render(
                    text: source.text,
                    kind: source.kind,
                    fileName: source.fileName
                )

            case .binary:
                // Claiming public.data means anything untyped reaches us,
                // including binaries. Say so rather than rendering mojibake.
                html = HTMLPage.errorPage(
                    message: "\(source.fileName) is not a text file."
                )
            }

            qmLog.info("rendered \(url.lastPathComponent, privacy: .public): \(html.count, privacy: .public) characters")

            completion = handler
            scheduleTimeout()
            webView.loadHTMLString(html, baseURL: nil)
        } catch {
            qmLog.error("could not read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")

            // Show the reason inside the preview panel instead of surfacing a
            // generic Quick Look failure.
            completion = handler
            scheduleTimeout()
            webView.loadHTMLString(
                HTMLPage.errorPage(message: error.localizedDescription),
                baseURL: nil
            )
        }
    }

    // MARK: - Completion bookkeeping

    private func scheduleTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout) { [weak self] in
            self?.finish(with: nil)
        }
    }

    /// Fires the stored handler at most once.
    private func finish(with error: Error?) {
        guard let handler = completion else { return }
        completion = nil
        handler(error)
    }
}

// MARK: - WKNavigationDelegate

extension PreviewViewController: WKNavigationDelegate {

    /// Reaching here is the only proof the page actually painted. Generating the
    /// HTML is not enough: if WebKit's content process cannot launch, rendering
    /// looks fine right up to `loadHTMLString` and the panel still comes up
    /// blank. Worth keeping as a signal.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        qmLog.info("web view painted")
        finish(with: nil)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(with: error)
    }

    /// The preview is a rendering, not a browser. Only the initial in-memory
    /// load is allowed to proceed; taps on links are ignored so a document can
    /// never navigate the panel somewhere unexpected.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
