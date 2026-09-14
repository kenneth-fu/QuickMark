import Foundation

/// An EPUB opened from a ZIP archive: its metadata, reading order and contents.
///
/// Parsing follows the chain the format defines. `META-INF/container.xml` names
/// the package document, the package document carries the metadata, the
/// manifest of every file, and the spine that puts them in reading order, and
/// the table of contents lives either in an EPUB 3 nav document or an EPUB 2
/// NCX. Both are handled, because real libraries contain both.
struct EPUBDocument {

    struct Metadata {
        var title: String?
        var creators: [String] = []
        var language: String?
        var publisher: String?
        var date: String?
        var description: String?
        var identifier: String?
    }

    struct ManifestItem {
        let id: String
        /// Archive path, already resolved against the package document.
        let path: String
        let mediaType: String
        let properties: String
    }

    struct TOCEntry {
        let title: String
        let path: String?
        let depth: Int
    }

    let archive: ZIPArchive
    let metadata: Metadata
    /// Documents in reading order.
    let spine: [ManifestItem]
    let toc: [TOCEntry]
    let coverPath: String?
    /// Directory holding the package document; every href resolves against it.
    let packageDirectory: String

    enum EPUBError: LocalizedError {
        case missingContainer
        case missingPackage
        case unreadablePackage

        var errorDescription: String? {
            switch self {
            case .missingContainer: return "The EPUB has no META-INF/container.xml"
            case .missingPackage: return "The EPUB container names no package document"
            case .unreadablePackage: return "The EPUB package document could not be parsed"
            }
        }
    }

    // MARK: - Loading

    static func load(data: Data) throws -> EPUBDocument {
        let archive = try ZIPArchive(data: data)

        guard let containerXML = try archive.text(for: "META-INF/container.xml") else {
            throw EPUBError.missingContainer
        }
        guard let packagePath = try packagePath(fromContainer: containerXML) else {
            throw EPUBError.missingPackage
        }
        guard let packageXML = try archive.text(for: packagePath)
            ?? archive.text(for: packagePath.removingPercentEncoding ?? packagePath) else {
            throw EPUBError.missingPackage
        }

        let directory = (packagePath as NSString).deletingLastPathComponent
        guard let package = try? XMLDocument(data: Data(packageXML.utf8), options: []) else {
            throw EPUBError.unreadablePackage
        }

        let manifest = manifestItems(in: package, packageDirectory: directory)
        let byID = Dictionary(manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return EPUBDocument(
            archive: archive,
            metadata: metadata(in: package),
            spine: spineItems(in: package, manifest: byID),
            toc: tableOfContents(
                in: package,
                manifest: manifest,
                byID: byID,
                archive: archive,
                packageDirectory: directory
            ),
            coverPath: coverPath(in: package, manifest: manifest, byID: byID),
            packageDirectory: directory
        )
    }

    // MARK: - Container

    private static func packagePath(fromContainer xml: String) throws -> String? {
        guard let document = try? XMLDocument(data: Data(xml.utf8), options: []) else {
            return nil
        }
        let rootfiles = (try? document.nodes(forXPath: "//*[local-name()='rootfile']")) ?? []
        for node in rootfiles {
            if let path = (node as? XMLElement)?.attribute(forName: "full-path")?.stringValue,
               !path.isEmpty {
                return path
            }
        }
        return nil
    }

    // MARK: - Package document

    private static func metadata(in package: XMLDocument) -> Metadata {
        var metadata = Metadata()

        func values(_ name: String) -> [String] {
            let nodes = (try? package.nodes(forXPath: "//*[local-name()='\(name)']")) ?? []
            return nodes.compactMap {
                $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }

        metadata.title = values("title").first
        metadata.creators = values("creator")
        metadata.language = values("language").first
        metadata.publisher = values("publisher").first
        metadata.date = values("date").first
        metadata.description = values("description").first
        metadata.identifier = values("identifier").first
        return metadata
    }

    private static func manifestItems(
        in package: XMLDocument,
        packageDirectory: String
    ) -> [ManifestItem] {
        let nodes = (try? package.nodes(
            forXPath: "//*[local-name()='manifest']/*[local-name()='item']"
        )) ?? []

        return nodes.compactMap { node in
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue
            else { return nil }

            return ManifestItem(
                id: id,
                path: resolve(href, against: packageDirectory),
                mediaType: element.attribute(forName: "media-type")?.stringValue ?? "",
                properties: element.attribute(forName: "properties")?.stringValue ?? ""
            )
        }
    }

    private static func spineItems(
        in package: XMLDocument,
        manifest: [String: ManifestItem]
    ) -> [ManifestItem] {
        let nodes = (try? package.nodes(
            forXPath: "//*[local-name()='spine']/*[local-name()='itemref']"
        )) ?? []

        return nodes.compactMap { node in
            guard let element = node as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue
            else { return nil }

            // linear="no" marks material outside the main reading order, such as
            // pop-up footnotes. A preview follows the main order only.
            if element.attribute(forName: "linear")?.stringValue == "no" { return nil }
            return manifest[idref]
        }
    }

    private static func coverPath(
        in package: XMLDocument,
        manifest: [ManifestItem],
        byID: [String: ManifestItem]
    ) -> String? {
        // EPUB 3 marks the cover in the manifest.
        if let item = manifest.first(where: { $0.properties.contains("cover-image") }) {
            return item.path
        }

        // EPUB 2 uses <meta name="cover" content="manifest-id">.
        let metas = (try? package.nodes(forXPath: "//*[local-name()='meta']")) ?? []
        for node in metas {
            guard let element = node as? XMLElement,
                  element.attribute(forName: "name")?.stringValue == "cover",
                  let id = element.attribute(forName: "content")?.stringValue
            else { continue }
            if let item = byID[id] { return item.path }
        }

        // Last resort: an image in the manifest whose name says cover.
        return manifest.first {
            $0.mediaType.hasPrefix("image/") && $0.path.lowercased().contains("cover")
        }?.path
    }

    // MARK: - Table of contents

    private static func tableOfContents(
        in package: XMLDocument,
        manifest: [ManifestItem],
        byID: [String: ManifestItem],
        archive: ZIPArchive,
        packageDirectory: String
    ) -> [TOCEntry] {
        // EPUB 3: a manifest item with properties="nav".
        if let nav = manifest.first(where: { $0.properties.contains("nav") }),
           let xml = try? archive.text(for: nav.path),
           let entries = navigationEntries(
               fromNav: xml,
               directory: (nav.path as NSString).deletingLastPathComponent
           ),
           !entries.isEmpty {
            return entries
        }

        // EPUB 2: the spine's toc attribute names an NCX in the manifest.
        let spines = (try? package.nodes(forXPath: "//*[local-name()='spine']")) ?? []
        let tocID = (spines.first as? XMLElement)?.attribute(forName: "toc")?.stringValue
        let ncx = tocID.flatMap { byID[$0] }
            ?? manifest.first { $0.mediaType == "application/x-dtbncx+xml" }

        if let ncx, let xml = try? archive.text(for: ncx.path) {
            return navigationEntries(
                fromNCX: xml,
                directory: (ncx.path as NSString).deletingLastPathComponent
            )
        }
        return []
    }

    private static func navigationEntries(fromNav xml: String, directory: String) -> [TOCEntry]? {
        guard let document = try? XMLDocument(data: Data(xml.utf8), options: .documentTidyXML) else {
            return nil
        }

        // Prefer the nav element that declares itself the table of contents.
        let navs = (try? document.nodes(forXPath: "//*[local-name()='nav']")) ?? []
        let toc = navs.first {
            ($0 as? XMLElement)?.attribute(forName: "type")?.stringValue == "toc"
                || ($0 as? XMLElement)?.attribute(forName: "epub:type")?.stringValue == "toc"
        } ?? navs.first

        guard let root = toc as? XMLElement else { return nil }

        var entries: [TOCEntry] = []
        collectListEntries(in: root, directory: directory, depth: 0, into: &entries)
        return entries
    }

    private static func collectListEntries(
        in element: XMLElement,
        directory: String,
        depth: Int,
        into entries: inout [TOCEntry]
    ) {
        guard depth < 6 else { return }

        for child in element.children ?? [] {
            guard let item = child as? XMLElement else { continue }

            if item.name?.lowercased() == "li" {
                let anchors = item.elements(forName: "a")
                if let anchor = anchors.first {
                    let title = (anchor.stringValue ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let href = anchor.attribute(forName: "href")?.stringValue
                    if !title.isEmpty {
                        entries.append(
                            TOCEntry(
                                title: title,
                                path: href.map { resolve(stripFragment($0), against: directory) },
                                depth: depth
                            )
                        )
                    }
                }
                for nested in item.elements(forName: "ol") + item.elements(forName: "ul") {
                    collectListEntries(in: nested, directory: directory, depth: depth + 1, into: &entries)
                }
            } else {
                collectListEntries(in: item, directory: directory, depth: depth, into: &entries)
            }
        }
    }

    private static func navigationEntries(fromNCX xml: String, directory: String) -> [TOCEntry] {
        guard let document = try? XMLDocument(data: Data(xml.utf8), options: []) else {
            return []
        }
        let maps = (try? document.nodes(forXPath: "//*[local-name()='navMap']")) ?? []
        guard let root = maps.first as? XMLElement else { return [] }

        var entries: [TOCEntry] = []
        collectNavPoints(in: root, directory: directory, depth: 0, into: &entries)
        return entries
    }

    private static func collectNavPoints(
        in element: XMLElement,
        directory: String,
        depth: Int,
        into entries: inout [TOCEntry]
    ) {
        guard depth < 6 else { return }

        for child in element.children ?? [] {
            guard let point = child as? XMLElement,
                  point.name?.lowercased().hasSuffix("navpoint") == true else { continue }

            let labels = (try? point.nodes(forXPath: "./*[local-name()='navLabel']/*[local-name()='text']")) ?? []
            let title = (labels.first?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let contents = (try? point.nodes(forXPath: "./*[local-name()='content']")) ?? []
            let src = (contents.first as? XMLElement)?.attribute(forName: "src")?.stringValue

            if !title.isEmpty {
                entries.append(
                    TOCEntry(
                        title: title,
                        path: src.map { resolve(stripFragment($0), against: directory) },
                        depth: depth
                    )
                )
            }
            collectNavPoints(in: point, directory: directory, depth: depth + 1, into: &entries)
        }
    }

    // MARK: - Paths

    static func stripFragment(_ href: String) -> String {
        href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
    }

    /// Resolves an href against a directory inside the archive, collapsing the
    /// `..` segments that EPUBs use to reach out of an OEBPS folder.
    static func resolve(_ href: String, against directory: String) -> String {
        let target = stripFragment(href)
        if target.hasPrefix("/") { return String(target.dropFirst()) }

        var components = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for segment in target.split(separator: "/").map(String.init) {
            switch segment {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(segment)
            }
        }
        return components.joined(separator: "/")
    }

    /// Archive lookups have to tolerate percent encoded hrefs, since the zip
    /// entry is stored under the decoded name.
    func data(atArchivePath path: String) -> Data? {
        if let bytes = try? archive.data(for: path), bytes != nil { return bytes }
        if let decoded = path.removingPercentEncoding,
           let bytes = try? archive.data(for: decoded) {
            return bytes
        }
        return nil
    }

    func text(atArchivePath path: String) -> String? {
        data(atArchivePath: path).map { ZIPArchive.decodeText($0) }
    }
}
