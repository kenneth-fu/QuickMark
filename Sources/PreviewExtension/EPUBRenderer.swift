import Foundation

/// Renders an EPUB as a preview: cover, metadata, table of contents, and as
/// much of the book as the budget allows.
///
/// A preview is a glance, not a reader, so the content is capped. What matters
/// is answering "what is this book and what is in it" without waiting.
enum EPUBRenderer {

    /// Total sanitised chapter HTML to emit before stopping.
    static let contentBudget = 300_000

    /// Spine documents to walk, whichever limit is reached first.
    static let maximumChapters = 30

    /// Cover images above this are skipped rather than embedded.
    static let maximumCoverBytes = 4 * 1024 * 1024

    static func html(_ book: EPUBDocument, fileName: String) -> String {
        var out = PlainTextRenderer.header(
            fileName: fileName,
            detail: detail(for: book)
        )

        out += "<div class=\"epub\">"
        out += headerHTML(book)
        out += tableOfContentsHTML(book)

        var budget = contentBudget
        var chaptersRendered = 0
        var content = ""

        for item in book.spine.prefix(maximumChapters) {
            guard budget > 0 else { break }
            guard item.mediaType.contains("xhtml") || item.mediaType.contains("html")
                || item.path.lowercased().hasSuffix("html") else { continue }
            guard let raw = book.text(atArchivePath: item.path) else { continue }

            let body = sanitizedBody(raw, chapterPath: item.path, book: book)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let title = chapterTitle(for: item.path, in: book)
            let heading = title.map {
                "<h2 class=\"epub-chapter-title\">\(HTMLRenderer.escape($0))</h2>"
            } ?? ""

            content += "<article class=\"epub-chapter\">\(heading)\(body)</article>"
            budget -= body.count
            chaptersRendered += 1
        }

        out += "<section class=\"epub-content\">\(content)</section>"

        let shown = chaptersRendered
        let total = book.spine.count
        if shown < total {
            out += """
            <p class="truncation-note">Showing \(shown) of \(total) documents. \
            Open the book in a reader for the rest.</p>
            """
        }

        out += "</div>\n"
        return out
    }

    static func errorHTML(_ error: Error, fileName: String) -> String {
        """
        <div class="json-error">\
        <span class="json-error-label">Unreadable EPUB</span>\
        <span class="json-error-message">\(HTMLRenderer.escape(error.localizedDescription))</span>\
        </div>

        """ + PlainTextRenderer.header(fileName: fileName, detail: "not previewable")
    }

    // MARK: - Header

    private static func detail(for book: EPUBDocument) -> String {
        let count = book.spine.count
        return count == 1 ? "1 document" : "\(count) documents"
    }

    private static func headerHTML(_ book: EPUBDocument) -> String {
        var rows = ""

        func row(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows += """
            <div class="epub-meta-row">\
            <span class="epub-meta-key">\(HTMLRenderer.escape(label))</span>\
            <span class="epub-meta-value">\(HTMLRenderer.escape(value))</span>\
            </div>
            """
        }

        let metadata = book.metadata
        row("Author", metadata.creators.joined(separator: ", "))
        row("Publisher", metadata.publisher)
        row("Date", metadata.date)
        row("Language", metadata.language)
        row("Identifier", metadata.identifier)

        let title = metadata.title.map {
            "<h1 class=\"epub-title\">\(HTMLRenderer.escape($0))</h1>"
        } ?? ""

        let summary = metadata.description.map {
            "<p class=\"epub-description\">\(HTMLRenderer.escape($0))</p>"
        } ?? ""

        return """
        <header class="epub-header">\
        \(coverHTML(book))\
        <div class="epub-meta">\(title)<div class="epub-meta-rows">\(rows)</div>\(summary)</div>\
        </header>
        """
    }

    private static func coverHTML(_ book: EPUBDocument) -> String {
        guard let path = book.coverPath,
              let bytes = book.data(atArchivePath: path),
              bytes.count <= maximumCoverBytes,
              let mime = ImageInliner.mimeType(for: (path as NSString).pathExtension)
        else { return "" }

        return "<img class=\"epub-cover\" alt=\"Cover\" src=\"data:\(mime);base64,\(bytes.base64EncodedString())\">"
    }

    // MARK: - Contents

    private static func tableOfContentsHTML(_ book: EPUBDocument) -> String {
        guard !book.toc.isEmpty else { return "" }

        var items = ""
        for entry in book.toc {
            items += """
            <li class="epub-toc-item depth-\(min(entry.depth, 5))">\
            \(HTMLRenderer.escape(entry.title))</li>
            """
        }

        return """
        <details class="epub-toc" open>\
        <summary>Contents <span class="epub-toc-count">\(book.toc.count)</span></summary>\
        <ol class="epub-toc-list">\(items)</ol>\
        </details>
        """
    }

    private static func chapterTitle(for path: String, in book: EPUBDocument) -> String? {
        book.toc.first { $0.path == path }?.title
    }

    // MARK: - Chapter sanitising

    /// Extracts the body of a chapter and removes anything that could execute or
    /// reach the network.
    ///
    /// This deliberately strips rather than escapes. The whole-document escape
    /// used for inline HTML in Markdown would turn one `<style>` block into a
    /// screen of visible tag soup, which is the wrong outcome for a chapter.
    static func sanitizedBody(_ xhtml: String, chapterPath: String, book: EPUBDocument) -> String {
        var body = extractBody(xhtml)

        // Elements removed along with their contents.
        for tag in ["script", "style", "iframe", "object", "embed", "form", "svg", "video", "audio"] {
            body = replacing(body, pattern: "<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: "")
            // An unclosed one would otherwise leave its opening tag behind.
            body = replacing(body, pattern: "</?\(tag)\\b[^>]*>", with: "")
        }

        // Void elements that carry no content but can still load or redirect.
        for tag in ["link", "meta", "base", "source", "track"] {
            body = replacing(body, pattern: "<\(tag)\\b[^>]*/?>", with: "")
        }

        // Inline event handlers, and javascript: in any attribute.
        body = replacing(body, pattern: "\\son\\w+\\s*=\\s*\"[^\"]*\"", with: "")
        body = replacing(body, pattern: "\\son\\w+\\s*=\\s*'[^']*'", with: "")
        body = replacing(body, pattern: "javascript:", with: "")

        return inlineImages(in: body, chapterPath: chapterPath, book: book)
    }

    private static func extractBody(_ xhtml: String) -> String {
        guard let open = range(of: "<body\\b[^>]*>", in: xhtml) else {
            // No body element: drop any head wholesale and take what is left.
            return replacing(xhtml, pattern: "<head\\b[^>]*>.*?</head\\s*>", with: "")
        }
        let afterOpen = xhtml[open.upperBound...]
        guard let close = afterOpen.range(of: "</body", options: [.caseInsensitive]) else {
            return String(afterOpen)
        }
        return String(afterOpen[..<close.lowerBound])
    }

    /// Rewrites `<img src>` to a data URI read from the archive. The web view
    /// cannot reach inside the zip, so an image is either embedded or dropped.
    private static func inlineImages(
        in html: String,
        chapterPath: String,
        book: EPUBDocument
    ) -> String {
        guard html.range(of: "<img", options: .caseInsensitive) != nil else { return html }

        let directory = (chapterPath as NSString).deletingLastPathComponent
        guard let regex = try? NSRegularExpression(
            pattern: "(<img\\b[^>]*?\\ssrc\\s*=\\s*)([\"'])(.*?)\\2",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return html }

        let text = html as NSString
        var out = ""
        var cursor = 0

        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let source = text.substring(with: match.range(at: 3))
            out += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            let prefix = text.substring(with: match.range(at: 1))
            let quote = text.substring(with: match.range(at: 2))

            if source.hasPrefix("data:") || source.hasPrefix("https:") {
                out += prefix + quote + source + quote
                continue
            }

            let resolved = EPUBDocument.resolve(source, against: directory)
            if let bytes = book.data(atArchivePath: resolved),
               bytes.count <= ImageInliner.maximumFileSize,
               let mime = ImageInliner.mimeType(for: (resolved as NSString).pathExtension) {
                out += prefix + quote + "data:\(mime);base64," + bytes.base64EncodedString() + quote
            } else {
                // Leave a src that resolves to nothing rather than a broken path.
                out += prefix + quote + quote
            }
        }

        out += text.substring(from: cursor)
        return out
    }

    // MARK: - Regex helpers

    private static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }

        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: replacement
        )
    }

    private static func range(of pattern: String, in text: String) -> Range<String.Index>? {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    }
}
