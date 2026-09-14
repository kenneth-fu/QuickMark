import Foundation
import Markdown

/// Walks a parsed Markdown tree and emits an HTML fragment.
///
/// `swift-markdown` ships a Markdown formatter but no HTML one, so this is the
/// piece we own. Everything it emits is escaped unless the source explicitly
/// asked for raw HTML, and even then a short deny list drops the tags that
/// could execute or phone home.
struct HTMLRenderer: MarkupVisitor {
    typealias Result = String

    /// Column alignments for the table currently being visited.
    private var columnAlignments: [Table.ColumnAlignment?] = []

    /// Heading slugs already emitted, so duplicate headings get unique anchors.
    private var usedAnchors: Set<String> = []

    /// How many `Link` nodes deep we currently are, to avoid nesting anchors.
    private var linkDepth = 0

    /// Embeds local images, since the web view cannot fetch them itself.
    private var images: ImageInliner

    private init(baseURL: URL?) {
        images = ImageInliner(baseURL: baseURL)
    }

    /// - Parameter baseURL: the directory the document lives in, used to
    ///   resolve relative image references. Pass nil to skip local images.
    static func render(_ document: Document, baseURL: URL? = nil) -> String {
        var renderer = HTMLRenderer(baseURL: baseURL)
        return renderer.visit(document)
    }

    // MARK: - Traversal

    mutating func defaultVisit(_ markup: any Markup) -> String {
        renderChildren(of: markup)
    }

    private mutating func renderChildren(of markup: any Markup) -> String {
        var out = ""
        for child in markup.children {
            out += visit(child)
        }
        return out
    }

    // MARK: - Block elements

    mutating func visitDocument(_ document: Document) -> String {
        renderChildren(of: document)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = renderChildren(of: paragraph)

        // A paragraph whose only content is an image reads better as a figure:
        // it lets the stylesheet centre it and cap its width.
        if paragraph.childCount == 1, paragraph.child(at: 0) is Image {
            return "<figure>\(inner)</figure>\n"
        }

        return "<p>\(inner)</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = renderChildren(of: heading)
        let anchor = uniqueAnchor(for: heading.plainText)
        return "<h\(heading.level) id=\"\(anchor)\">\(inner)</h\(heading.level)>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let language = codeBlock.language?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""
        let code = Self.escape(codeBlock.code)

        guard !language.isEmpty else {
            return "<pre><code>\(code)</code></pre>\n"
        }

        let cssClass = Self.escapeAttribute("language-\(language)")
        return """
        <pre data-lang="\(cssClass.replacingOccurrences(of: "language-", with: ""))">\
        <code class="\(cssClass)">\(code)</code></pre>

        """
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        let inner = renderChildren(of: blockQuote)

        // GitHub alert syntax: a blockquote opening with [!NOTE], [!WARNING] etc.
        if let alert = Self.alertKind(in: blockQuote) {
            let body = inner.replacingOccurrences(
                of: "[!\(alert.uppercased())]",
                with: ""
            )
            return """
            <blockquote class="alert alert-\(alert)">\
            <p class="alert-title">\(alert.capitalized)</p>\(body)</blockquote>

            """
        }

        return "<blockquote>\(inner)</blockquote>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        var classes = [Self.isLoose(list) ? "loose" : "tight"]
        if list.listItems.contains(where: { $0.checkbox != nil }) {
            classes.append("task-list")
        }
        return "<ul class=\"\(classes.joined(separator: " "))\">\n\(renderChildren(of: list))</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let cssClass = Self.isLoose(list) ? "loose" : "tight"
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        return "<ol class=\"\(cssClass)\"\(start)>\n\(renderChildren(of: list))</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        let inner = renderChildren(of: listItem)

        guard let checkbox = listItem.checkbox else {
            return "<li>\(inner)</li>\n"
        }

        let checked = checkbox == .checked ? " checked" : ""
        return """
        <li class="task-list-item">\
        <input type="checkbox" disabled\(checked)>\(inner)</li>

        """
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        Self.sanitizeRawHTML(html.rawHTML)
    }

    // MARK: - Tables

    mutating func visitTable(_ table: Table) -> String {
        columnAlignments = table.columnAlignments
        defer { columnAlignments = [] }
        return "<div class=\"table-wrap\"><table>\n\(renderChildren(of: table))</table></div>\n"
    }

    mutating func visitTableHead(_ head: Table.Head) -> String {
        var cells = ""
        for (index, cell) in head.cells.enumerated() {
            cells += renderCell(cell, tag: "th", column: index)
        }
        return "<thead>\n<tr>\(cells)</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ body: Table.Body) -> String {
        body.isEmpty ? "" : "<tbody>\n\(renderChildren(of: body))</tbody>\n"
    }

    mutating func visitTableRow(_ row: Table.Row) -> String {
        var cells = ""
        for (index, cell) in row.cells.enumerated() {
            cells += renderCell(cell, tag: "td", column: index)
        }
        return "<tr>\(cells)</tr>\n"
    }

    mutating func visitTableCell(_ cell: Table.Cell) -> String {
        // Reached only if a cell is visited outside a row, which cmark does not
        // produce. Rows drive cell rendering so they can supply the column index.
        renderChildren(of: cell)
    }

    private mutating func renderCell(_ cell: Table.Cell, tag: String, column: Int) -> String {
        // A cell spanned over by its neighbour carries colspan 0 and emits nothing.
        guard cell.colspan > 0, cell.rowspan > 0 else { return "" }

        var attributes = ""
        if let alignment = columnAlignments.indices.contains(column)
            ? columnAlignments[column] : nil {
            attributes += " style=\"text-align: \(Self.cssAlignment(alignment))\""
        }
        if cell.colspan > 1 { attributes += " colspan=\"\(cell.colspan)\"" }
        if cell.rowspan > 1 { attributes += " rowspan=\"\(cell.rowspan)\"" }

        return "<\(tag)\(attributes)>\(renderChildren(of: cell))</\(tag)>"
    }

    private static func cssAlignment(_ alignment: Table.ColumnAlignment) -> String {
        switch alignment {
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        }
    }

    // MARK: - Inline elements

    mutating func visitText(_ text: Text) -> String {
        // Nesting an anchor inside an anchor is invalid, so leave text alone
        // when the link is already explicit.
        linkDepth > 0 ? Self.escape(text.string) : Self.linkify(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(renderChildren(of: emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(renderChildren(of: strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(renderChildren(of: strikethrough))</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Link) -> String {
        linkDepth += 1
        let inner = renderChildren(of: link)
        linkDepth -= 1

        guard let destination = link.destination,
              let safe = Self.safeURL(destination) else {
            return inner
        }

        var attributes = " href=\"\(Self.escapeAttribute(safe))\""
        if let title = link.title, !title.isEmpty {
            attributes += " title=\"\(Self.escapeAttribute(title))\""
        }
        return "<a\(attributes)>\(inner)</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let alt = Self.escapeAttribute(image.plainText)

        guard let source = image.source,
              let resolved = images.source(for: source) else {
            // A missing or unreadable image still deserves its caption.
            return alt.isEmpty ? "" : "<span class=\"missing-image\">\(alt)</span>"
        }

        var attributes = " src=\"\(Self.escapeAttribute(resolved))\" alt=\"\(alt)\""
        if let title = image.title, !title.isEmpty {
            attributes += " title=\"\(Self.escapeAttribute(title))\""
        }
        return "<img\(attributes)>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        Self.sanitizeRawHTML(inlineHTML.rawHTML)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> String {
        guard let destination = symbolLink.destination else { return "" }
        return "<code>\(Self.escape(destination))</code>"
    }

    // MARK: - Helpers

    /// CommonMark calls a list loose when a blank line separates two of its
    /// items, or separates two blocks inside one item. swift-markdown does not
    /// surface cmark's own flag, so reconstruct it from source line numbers.
    ///
    /// Note that an item merely *containing* a nested list does not make the
    /// outer list loose; only a blank line does. The answer drives spacing
    /// alone, so a missing source range degrades to tight rather than failing.
    private static func isLoose(_ list: any ListItemContainer) -> Bool {
        let items = Array(list.listItems)
        guard !items.isEmpty else { return false }

        // A blank line between two blocks inside a single item.
        if items.contains(where: { hasBlankLineBetweenSiblings(Array($0.children)) }) {
            return true
        }

        // A blank line between items. cmark stretches an item's range over the
        // blank line that follows it, so a separated item ends further down than
        // its own content does:
        //
        //     ListItem  @6:1-7:1     <- reaches into the blank line
        //     Paragraph @6:3-6:12    <- where the content actually stops
        //
        // The last item always absorbs the list's trailing newline the same way,
        // so it cannot be judged this way and is skipped.
        for item in items.dropLast() {
            guard let itemEnd = item.range?.upperBound.line,
                  let contentEnd = item.children.compactMap({ $0.range?.upperBound.line }).max()
            else { continue }

            if itemEnd > contentEnd { return true }
        }

        return false
    }

    /// True when consecutive siblings are separated by at least one blank line.
    private static func hasBlankLineBetweenSiblings(_ siblings: [any Markup]) -> Bool {
        for (previous, next) in zip(siblings, siblings.dropFirst()) {
            guard let end = previous.range?.upperBound.line,
                  let start = next.range?.lowerBound.line else { continue }
            if start > end + 1 { return true }
        }
        return false
    }

    private mutating func uniqueAnchor(for title: String) -> String {
        let base = Self.slugify(title)
        var candidate = base.isEmpty ? "section" : base
        var suffix = 1
        while usedAnchors.contains(candidate) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        usedAnchors.insert(candidate)
        return Self.escapeAttribute(candidate)
    }

    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        var slug = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if character == " " || character == "_" {
                if !lastWasDash && !slug.isEmpty {
                    slug.append("-")
                    lastWasDash = true
                }
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    private static func alertKind(in blockQuote: BlockQuote) -> String? {
        guard let first = blockQuote.child(at: 0) as? Paragraph else { return nil }
        let text = first.plainText.trimmingCharacters(in: .whitespaces)
        let kinds = ["note", "tip", "important", "warning", "caution"]
        for kind in kinds where text.lowercased().hasPrefix("[!\(kind)]") {
            return kind
        }
        return nil
    }

    // MARK: - Escaping and sanitising

    /// swift-markdown does not turn on cmark's autolink extension, so a bare URL
    /// arrives as plain text. READMEs lean on that heavily, so linkify it here.
    /// Returns escaped HTML either way.
    static func linkify(_ text: String) -> String {
        guard text.contains("://") else { return escape(text) }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = bareURLPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return escape(text) }

        var out = ""
        var cursor = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }

            var urlEnd = matchRange.upperBound
            var url = String(text[matchRange])

            // Trailing punctuation almost always belongs to the sentence, not
            // the URL. A closing paren only counts if it was opened inside.
            while let last = url.last, shouldTrim(last, from: url) {
                url.removeLast()
                urlEnd = text.index(before: urlEnd)
            }
            // Skip a bare scheme with nothing after it.
            guard let schemeEnd = url.range(of: "://"),
                  schemeEnd.upperBound < url.endIndex else { continue }

            out += escape(String(text[cursor..<matchRange.lowerBound]))
            out += "<a href=\"\(escapeAttribute(url))\">\(escape(url))</a>"
            cursor = urlEnd
        }

        out += escape(String(text[cursor...]))
        return out
    }

    private static let bareURLPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"'`]+"#
    )

    private static func shouldTrim(_ character: Character, from url: String) -> Bool {
        if ".,;:!?\"'".contains(character) { return true }
        if character == ")" {
            return url.filter { $0 == ")" }.count > url.filter { $0 == "(" }.count
        }
        return false
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(character)
            }
        }
        return out
    }

    static func escapeAttribute(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Rejects URL schemes that could execute code or reach outside the preview.
    /// Relative paths are kept as they are so images next to the document resolve
    /// against the web view's base URL.
    static func safeURL(_ raw: String, allowingData: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else {
            return trimmed // relative path, no scheme to vet
        }

        var allowed: Set<String> = ["http", "https", "mailto", "file"]
        if allowingData { allowed.insert("data") }
        return allowed.contains(scheme) ? trimmed : nil
    }

    /// Raw HTML passes through, minus anything that can run or load remotely.
    /// The web view also has JavaScript disabled, so this is belt and braces.
    static func sanitizeRawHTML(_ raw: String) -> String {
        let blocked = [
            "script", "iframe", "object", "embed", "link",
            "meta", "form", "input", "base", "style",
        ]
        let lowered = raw.lowercased()
        for tag in blocked where lowered.contains("<\(tag)") || lowered.contains("</\(tag)") {
            return escape(raw)
        }
        if lowered.contains("javascript:") || lowered.range(of: #"\son\w+\s*="#, options: .regularExpression) != nil {
            return escape(raw)
        }
        return raw
    }
}
