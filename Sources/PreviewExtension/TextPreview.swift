import Foundation

/// What a file should be rendered as.
///
/// QuickMark claims `public.data` so it can reach `.env`, which macOS types as
/// plain data because a leading dot name has no extension it recognises. That
/// claim also catches every other extension-less file, so the kind has to be
/// worked out here rather than trusted from the content type.
enum PreviewKind {
    case markdown
    case dotenv
    case json
    case epub
    case plainText
    /// Not text at all. Rendering it would produce a screen of mojibake.
    case binary
}

extension PreviewKind {

    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "qmd", "rmd",
    ]

    private static let jsonExtensions: Set<String> = [
        "json", "geojson", "jsonc", "webmanifest",
    ]

    /// Decides how to render a file from its name and a sample of its bytes.
    static func detect(fileName: String, sample: Data) -> PreviewKind {
        let name = fileName.lowercased()
        let fileExtension = (name as NSString).pathExtension

        // An EPUB is a ZIP, so it has to be recognised before the binary sniff,
        // which would otherwise reject it out of hand. A file claiming to be one
        // that is not a ZIP still routes here, and the parser reports why.
        if fileExtension == "epub" { return .epub }

        if isBinary(sample) { return .binary }

        if markdownExtensions.contains(fileExtension) { return .markdown }
        if jsonExtensions.contains(fileExtension) { return .json }
        if isDotEnv(name) { return .dotenv }
        return .plainText
    }

    /// Matches `.env`, `.env.local`, `.env.production.local`, `production.env`
    /// and `env.example`, without swallowing unrelated names like `environment`.
    static func isDotEnv(_ name: String) -> Bool {
        if name == ".env" || name == "env" { return true }
        if name.hasPrefix(".env.") || name.hasPrefix("env.") { return true }
        if name.hasSuffix(".env") { return true }
        return false
    }

    /// A NUL byte is the classic text/binary tell, and anything that will not
    /// decode as UTF-8 would render as mojibake anyway.
    private static func isBinary(_ sample: Data) -> Bool {
        guard !sample.isEmpty else { return false }
        if sample.contains(0) { return true }
        return String(data: sample, encoding: .utf8) == nil
            && String(data: sample, encoding: .isoLatin1) == nil
    }
}

/// A file loaded and classified, ready to render.
struct PreviewSource {
    let kind: PreviewKind
    /// Decoded text. Empty for .epub and .binary, which are not text.
    let text: String
    /// Raw bytes, carried only for .epub, whose renderer needs the archive.
    let data: Data?
    let fileName: String

    /// Bytes sampled to decide text versus binary. Enough to catch a header.
    private static let sampleSize = 8 * 1024

    static func load(contentsOf url: URL) throws -> PreviewSource {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fileName = url.lastPathComponent
        let kind = PreviewKind.detect(
            fileName: fileName,
            sample: data.prefix(sampleSize)
        )

        switch kind {
        case .binary:
            return PreviewSource(kind: .binary, text: "", data: nil, fileName: fileName)
        case .epub:
            return PreviewSource(kind: .epub, text: "", data: data, fileName: fileName)
        default:
            return PreviewSource(
                kind: kind,
                text: try MarkdownDocument.decodeText(data, at: url),
                data: nil,
                fileName: fileName
            )
        }
    }
}

// MARK: - Plain text

enum PlainTextRenderer {

    /// Files longer than this are cut off. A preview is a glance, and a web view
    /// holding a hundred thousand line elements is slow enough to time out.
    static let maximumLines = 5_000

    static func html(_ text: String, fileName: String) -> String {
        var lines = text.components(separatedBy: .newlines)

        // A trailing newline yields a final empty component that is not a line.
        if lines.last?.isEmpty == true { lines.removeLast() }

        let truncated = lines.count > maximumLines
        if truncated { lines = Array(lines.prefix(maximumLines)) }

        var rendered = ""
        rendered.reserveCapacity(text.count + lines.count * 24)
        for line in lines {
            // An empty span collapses, so keep a zero width space for height.
            let content = line.isEmpty ? "\u{200B}" : HTMLRenderer.escape(line)
            rendered += "<span class=\"ln\">\(content)</span>"
        }

        var out = header(fileName: fileName, detail: "\(lines.count) lines")
        out += "<pre class=\"plain\">\(rendered)</pre>\n"

        if truncated {
            out += """
            <p class="truncation-note">Showing the first \(maximumLines) lines.</p>

            """
        }
        return out
    }

    static func header(fileName: String, detail: String) -> String {
        """
        <div class="text-header">\
        <span class="text-header-name">\(HTMLRenderer.escape(fileName))</span>\
        <span class="text-header-detail">\(HTMLRenderer.escape(detail))</span>\
        </div>

        """
    }
}

// MARK: - dotenv

enum DotEnvRenderer {

    /// One parsed line of a `.env` file.
    enum Entry {
        case comment(String)
        case variable(key: String, value: String, exported: Bool, trailingComment: String?)
        case blank
        /// A line that is neither a comment nor `KEY=VALUE`.
        case other(String)
    }

    static func html(_ text: String, fileName: String) -> String {
        let entries = parse(text)
        let count = entries.reduce(into: 0) { total, entry in
            if case .variable = entry { total += 1 }
        }

        var rows = ""
        for entry in entries {
            switch entry {
            case .blank:
                rows += "<div class=\"env-blank\"></div>"

            case .comment(let comment):
                rows += "<div class=\"env-comment\">\(HTMLRenderer.escape(comment))</div>"

            case .other(let line):
                rows += "<div class=\"env-other\">\(HTMLRenderer.escape(line))</div>"

            case .variable(let key, let value, let exported, let trailingComment):
                let prefix = exported
                    ? "<span class=\"env-export\">export</span> "
                    : ""
                let renderedValue = value.isEmpty
                    ? "<span class=\"env-empty\">empty</span>"
                    : HTMLRenderer.escape(value)
                let comment = trailingComment.map {
                    "<span class=\"env-inline-comment\">\(HTMLRenderer.escape($0))</span>"
                } ?? ""

                rows += """
                <div class="env-row">\
                <span class="env-key">\(prefix)\(HTMLRenderer.escape(key))</span>\
                <span class="env-value">\(renderedValue)\(comment)</span>\
                </div>
                """
            }
        }

        let detail = count == 1 ? "1 variable" : "\(count) variables"
        return PlainTextRenderer.header(fileName: fileName, detail: detail)
            + "<div class=\"env\">\(rows)</div>\n"
    }

    static func parse(_ text: String) -> [Entry] {
        text.components(separatedBy: .newlines).map(parseLine)
    }

    private static func parseLine(_ rawLine: String) -> Entry {
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        if line.isEmpty { return .blank }
        if line.hasPrefix("#") { return .comment(line) }

        // `export KEY=value` is common in files meant to be sourced by a shell.
        var body = Substring(line)
        var exported = false
        if body.hasPrefix("export ") {
            body = body.dropFirst("export ".count).drop(while: { $0 == " " })
            exported = true
        }

        guard let separator = body.firstIndex(of: "=") else {
            return .other(line)
        }

        let key = body[body.startIndex..<separator].trimmingCharacters(in: .whitespaces)
        guard isValidKey(key) else { return .other(line) }

        let rawValue = body[body.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        let (value, comment) = splitValue(rawValue)

        return .variable(key: key, value: value, exported: exported, trailingComment: comment)
    }

    /// Environment variable names are conventionally letters, digits and
    /// underscores. Anything else is more likely a stray line than a variable.
    private static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, let first = key.first, !first.isNumber else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    /// Strips surrounding quotes, and splits off a trailing `# comment` when the
    /// value is unquoted. A `#` inside quotes belongs to the value.
    private static func splitValue(_ raw: String) -> (String, String?) {
        guard let first = raw.first else { return ("", nil) }

        if first == "\"" || first == "'" {
            // Find the closing quote, honouring a backslash escape.
            var index = raw.index(after: raw.startIndex)
            var previousWasEscape = false
            while index < raw.endIndex {
                let character = raw[index]
                if character == first && !previousWasEscape { break }
                previousWasEscape = (character == "\\" && !previousWasEscape)
                index = raw.index(after: index)
            }

            guard index < raw.endIndex else {
                // Unterminated quote: treat the remainder as the value.
                return (String(raw.dropFirst()), nil)
            }

            let value = String(raw[raw.index(after: raw.startIndex)..<index])
            let rest = raw[raw.index(after: index)...].trimmingCharacters(in: .whitespaces)
            return (value, rest.hasPrefix("#") ? rest : nil)
        }

        if let hash = raw.range(of: " #") {
            let value = String(raw[raw.startIndex..<hash.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let comment = String(raw[hash.lowerBound...]).trimmingCharacters(in: .whitespaces)
            return (value, comment)
        }

        return (raw, nil)
    }
}
