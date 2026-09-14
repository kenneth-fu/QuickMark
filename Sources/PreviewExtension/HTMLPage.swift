import Foundation

/// Assembles the standalone HTML document handed to the web view.
///
/// The stylesheet is inlined rather than linked so the page's base URL stays
/// free for the Markdown file's own directory, which is what makes relative
/// image paths resolve.
enum HTMLPage {

    // MARK: - Markdown

    /// - Parameter baseURL: directory the document lives in, used to resolve
    ///   relative image references. They are embedded, not linked.
    static func render(
        _ document: MarkdownDocument,
        fileName: String,
        baseURL: URL? = nil,
        stylesheet: String = bundledStylesheet
    ) -> String {
        let body = HTMLRenderer.render(document.parsed, baseURL: baseURL)
        let header = frontMatterHeader(for: document)

        return page(
            title: fileName,
            body: "<article class=\"markdown-body\">\n\(header)\(body)</article>",
            stylesheet: stylesheet
        )
    }

    // MARK: - Plain text and dotenv

    /// Renders a file that is not Markdown: a `.env`, or any other text file
    /// macOS could not type more specifically.
    static func render(
        text: String,
        kind: PreviewKind,
        fileName: String,
        stylesheet: String = bundledStylesheet
    ) -> String {
        let body: String
        switch kind {
        case .dotenv:
            body = DotEnvRenderer.html(text, fileName: fileName)

        case .json:
            // A file that does not parse still gets shown, with the reason on
            // top, so a stray comma is easy to find rather than just fatal.
            do {
                body = JSONRenderer.html(try JSONParser.parse(text), fileName: fileName)
            } catch {
                body = JSONRenderer.errorHTML(error, text: text, fileName: fileName)
            }

        default:
            body = PlainTextRenderer.html(text, fileName: fileName)
        }

        return page(
            title: fileName,
            body: "<article class=\"text-body\">\n\(body)</article>",
            stylesheet: stylesheet
        )
    }

    /// EPUB arrives as bytes rather than text, so it gets its own entry point.
    static func render(
        epubData: Data,
        fileName: String,
        stylesheet: String = bundledStylesheet
    ) -> String {
        let body: String
        do {
            body = EPUBRenderer.html(try EPUBDocument.load(data: epubData), fileName: fileName)
        } catch {
            body = EPUBRenderer.errorHTML(error, fileName: fileName)
        }

        return page(
            title: fileName,
            body: "<article class=\"text-body\">\n\(body)</article>",
            stylesheet: stylesheet
        )
    }

    // MARK: - Shared shell

    private static func page(title: String, body: String, stylesheet: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <title>\(HTMLRenderer.escape(title))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Blocks scripts and remote code outright. Local images arrive already
    /// embedded as data URIs, so the page never needs filesystem access; https
    /// stays open for the badges READMEs are full of.
    private static let contentSecurityPolicy = [
        "default-src 'none'",
        "img-src data: https:",
        "style-src 'unsafe-inline'",
        "font-src 'none'",
        "script-src 'none'",
    ].joined(separator: "; ")

    /// Renders YAML front matter as a small definition list above the document.
    private static func frontMatterHeader(for document: MarkdownDocument) -> String {
        let pairs = document.frontMatterPairs
        guard !pairs.isEmpty else { return "" }

        var rows = ""
        for pair in pairs {
            rows += """
            <div class="front-matter-row">\
            <span class="front-matter-key">\(HTMLRenderer.escape(pair.key))</span>\
            <span class="front-matter-value">\(HTMLRenderer.escape(pair.value))</span>\
            </div>
            """
        }
        return "<section class=\"front-matter\">\(rows)</section>\n"
    }

    /// Anchors the bundle lookup without dragging in a view controller, so the
    /// renderer can also be exercised from the command line tool in Tools/.
    private final class BundleToken {}

    /// The stylesheet, read once from the extension bundle.
    static let bundledStylesheet: String = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "style", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            // Rendering unstyled beats rendering nothing.
            return "body { font: -apple-system-body; padding: 2rem; }"
        }
        return css
    }()

    /// Shown when a file cannot be read, or is not text at all.
    static func errorPage(message: String, stylesheet: String = bundledStylesheet) -> String {
        page(
            title: "Preview unavailable",
            body: """
            <article class="markdown-body">\
            <p class="preview-error">\(HTMLRenderer.escape(message))</p></article>
            """,
            stylesheet: stylesheet
        )
    }
}
