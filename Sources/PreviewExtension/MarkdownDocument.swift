import Foundation
import Markdown

/// A Markdown file loaded from disk, split into optional front matter and body.
struct MarkdownDocument {
    /// Raw YAML front matter, without the delimiter lines. Nil when absent.
    let frontMatter: String?
    /// The Markdown body, front matter removed.
    let body: String

    // MARK: - Loading

    enum LoadError: LocalizedError {
        case unreadableText(URL)

        var errorDescription: String? {
            switch self {
            case .unreadableText(let url):
                return "QuickMark could not read \(url.lastPathComponent) as text."
            }
        }
    }

    static func load(contentsOf url: URL) throws -> MarkdownDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return MarkdownDocument(text: try decodeText(data, at: url))
    }

    /// Decodes file bytes as text, preferring UTF-8 and falling back to whatever
    /// encoding the system can detect. Some Markdown in the wild is Latin-1.
    /// Shared with the plain text and dotenv previews.
    static func decodeText(_ data: Data, at url: URL) throws -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }

        var encoding = String.Encoding.utf8
        if let detected = try? String(contentsOf: url, usedEncoding: &encoding) {
            return detected
        }

        // Last resort: decode as Latin-1 rather than failing the preview outright.
        guard let lossy = String(data: data, encoding: .isoLatin1) else {
            throw LoadError.unreadableText(url)
        }
        return lossy
    }

    // MARK: - Front matter

    init(text: String) {
        let (frontMatter, body) = Self.splitFrontMatter(text)
        self.frontMatter = frontMatter
        self.body = body
    }

    /// Pulls a leading `---` fenced YAML block off the top of the document.
    /// Without this, cmark reads the opening delimiter as a thematic break and
    /// the first key as a setext heading, which looks broken.
    private static func splitFrontMatter(_ text: String) -> (String?, String) {
        // Tolerate a UTF-8 BOM and leading blank lines.
        var scanner = Substring(text)
        if scanner.hasPrefix("\u{FEFF}") { scanner = scanner.dropFirst() }

        let lines = scanner.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, String(scanner))
        }

        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed == "---" || trimmed == "..." else { continue }

            let matter = lines[1..<index].joined(separator: "\n")
            let remainder = lines[(index + 1)...].joined(separator: "\n")
            return (matter, remainder)
        }

        // Opening delimiter with no close: treat the whole thing as body.
        return (nil, String(scanner))
    }

    /// Front matter parsed just far enough to show top level `key: value` pairs.
    /// This is deliberately not a YAML parser; nested structures are skipped.
    var frontMatterPairs: [(key: String, value: String)] {
        guard let frontMatter else { return [] }

        var pairs: [(String, String)] = []
        for line in frontMatter.split(separator: "\n", omittingEmptySubsequences: true) {
            // Skip list items and nested keys, which need real YAML to make sense of.
            guard let first = line.first, first != " ", first != "\t", first != "-" else { continue }
            guard let separator = line.firstIndex(of: ":") else { continue }

            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }

            guard !key.isEmpty, !value.isEmpty else { continue }
            pairs.append((key, value))
        }
        return pairs
    }

    /// The document body as a parsed Markdown tree.
    var parsed: Document {
        Document(parsing: body)
    }
}
