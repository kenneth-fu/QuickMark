import Foundation
import Markdown

/// Renders a Markdown file to standalone HTML using the same code path the
/// Quick Look extension uses. Handy for iterating on style.css without
/// rebuilding and reinstalling the app on every tweak.
///
///     ./Tools/render.sh Samples/kitchen-sink.md /tmp/preview.html
///     ./Tools/render.sh --tree Samples/kitchen-sink.md
@main
struct Render {
    static func main() {
        var arguments = CommandLine.arguments

        // --tree prints the parsed tree with source locations, which is the
        // fastest way to see why a block rendered the way it did.
        var dumpTree = false
        if let index = arguments.firstIndex(of: "--tree") {
            arguments.remove(at: index)
            dumpTree = true
        }

        guard arguments.count >= 2 else {
            fail("usage: qm-render [--tree] <input.md> [output.html]", code: 2)
        }

        let inputURL = URL(fileURLWithPath: arguments[1])

        if dumpTree {
            do {
                let document = try MarkdownDocument.load(contentsOf: inputURL)
                print(document.parsed.debugDescription(options: .printSourceLocations))
                return
            } catch {
                fail("error: \(error.localizedDescription)", code: 1)
            }
        }

        let outputURL = arguments.count >= 3
            ? URL(fileURLWithPath: arguments[2])
            : inputURL.deletingPathExtension().appendingPathExtension("html")

        do {
            let source = try PreviewSource.load(contentsOf: inputURL)
            let html: String

            switch source.kind {
            case .markdown:
                html = HTMLPage.render(
                    MarkdownDocument(text: source.text),
                    fileName: source.fileName,
                    baseURL: inputURL.deletingLastPathComponent(),
                    stylesheet: stylesheet()
                )
            case .epub:
                html = HTMLPage.render(
                    epubData: source.data ?? Data(),
                    fileName: source.fileName,
                    stylesheet: stylesheet()
                )
            case .dotenv, .json, .plainText:
                html = HTMLPage.render(
                    text: source.text,
                    kind: source.kind,
                    fileName: source.fileName,
                    stylesheet: stylesheet()
                )
            case .binary:
                html = HTMLPage.errorPage(
                    message: "\(source.fileName) is not a text file.",
                    stylesheet: stylesheet()
                )
            }
            try html.write(to: outputURL, atomically: true, encoding: .utf8)
            print(outputURL.path)
        } catch {
            fail("error: \(error.localizedDescription)", code: 1)
        }
    }

    /// The extension reads its stylesheet from its own bundle. Here it sits next
    /// to the sources, so locate it relative to this file's own path.
    private static func stylesheet() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PreviewExtension/Resources/style.css")

        return (try? String(contentsOf: url, encoding: .utf8)) ?? HTMLPage.bundledStylesheet
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
