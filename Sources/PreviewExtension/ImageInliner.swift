import Foundation

/// Turns local image references into `data:` URIs.
///
/// The preview runs inside the App Sandbox, and Quick Look only grants access
/// to the previewed file, so a `file://` subresource fetched by the web view is
/// not reliable. Reading the bytes in Swift and embedding them sidesteps the
/// question: whatever the extension can read, the preview can display.
struct ImageInliner {

    /// Directory the document lives in, used to resolve relative references.
    let baseURL: URL?

    /// Individual files above this are skipped rather than embedded.
    static let maximumFileSize = 8 * 1024 * 1024

    /// Total budget across one document, to keep the HTML a sane size.
    static let totalBudget = 24 * 1024 * 1024

    private(set) var bytesUsed = 0

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    /// Returns a `src` value for the given Markdown image source, or nil when
    /// the image cannot be embedded and should be dropped.
    mutating func source(for reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Remote and already-inlined images pass straight through.
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme != "file" {
            return ["http", "https", "data"].contains(scheme) ? trimmed : nil
        }

        guard let fileURL = resolve(trimmed) else { return nil }
        return inline(fileURL)
    }

    /// Resolves a reference against the document's directory. Markdown sources
    /// are often percent-encoded, so try the decoded form too.
    private func resolve(_ reference: String) -> URL? {
        if reference.hasPrefix("file://") {
            return URL(string: reference)
        }

        guard let baseURL else { return nil }

        let candidates = [reference.removingPercentEncoding, reference].compactMap { $0 }
        for candidate in candidates {
            // Strip any #fragment or ?query a reference may carry.
            let path = candidate
                .split(separator: "#", maxSplits: 1).first
                .map(String.init) ?? candidate
            let cleaned = path
                .split(separator: "?", maxSplits: 1).first
                .map(String.init) ?? path

            let url = cleaned.hasPrefix("/")
                ? URL(fileURLWithPath: cleaned)
                : baseURL.appendingPathComponent(cleaned)

            if FileManager.default.isReadableFile(atPath: url.path) {
                return url.standardizedFileURL
            }
        }
        return nil
    }

    private mutating func inline(_ url: URL) -> String? {
        guard let mimeType = Self.mimeType(for: url.pathExtension) else { return nil }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size > 0,
              size <= Self.maximumFileSize,
              bytesUsed + size <= Self.totalBudget,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }

        bytesUsed += size
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    static func mimeType(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "ico": return "image/x-icon"
        default: return nil
        }
    }
}
