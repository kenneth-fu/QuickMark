import Foundation

/// Renders a parsed JSON document as a collapsible, syntax coloured tree.
///
/// Collapsing uses native `<details>` and `<summary>` elements, so the
/// disclosure triangles work with JavaScript switched off, which it is
/// everywhere in this preview.
enum JSONRenderer {

    /// Beyond this many values the deeper levels start out collapsed, so a big
    /// document opens on something readable rather than a wall of text.
    static let expandEverythingBelow = 400

    /// Levels kept open in a large document.
    static let defaultOpenDepth = 2

    /// Hard ceiling on rendered values. A megabyte of JSON is millions of DOM
    /// nodes otherwise, which is slow enough to hit the preview timeout.
    static let maximumNodes = 20_000

    static func html(_ value: JSONValue, fileName: String) -> String {
        let total = value.nodeCount
        var state = RenderState(
            expandAll: total <= expandEverythingBelow,
            remaining: maximumNodes
        )

        let tree = render(value, depth: 0, isLast: true, state: &state)
        let detail = total == 1 ? "1 value" : "\(total) values"

        var out = PlainTextRenderer.header(fileName: fileName, detail: detail)
        out += "<div class=\"json\">\(tree)</div>\n"

        if state.truncated {
            out += """
            <p class="truncation-note">Showing the first \(maximumNodes) values.</p>

            """
        }
        return out
    }

    /// Shown when the document does not parse. The text still gets rendered
    /// underneath so the file stays readable and the error can be found by eye.
    static func errorHTML(_ error: Error, text: String, fileName: String) -> String {
        let message = (error as? JSONParser.ParseError)?.errorDescription
            ?? error.localizedDescription

        return """
        <div class="json-error">\
        <span class="json-error-label">Invalid JSON</span>\
        <span class="json-error-message">\(HTMLRenderer.escape(message))</span>\
        </div>

        """ + PlainTextRenderer.html(text, fileName: fileName)
    }

    // MARK: - Rendering

    private struct RenderState {
        let expandAll: Bool
        var remaining: Int
        var truncated = false

        mutating func consume() -> Bool {
            guard remaining > 0 else {
                truncated = true
                return false
            }
            remaining -= 1
            return true
        }
    }

    private static func render(
        _ value: JSONValue,
        depth: Int,
        isLast: Bool,
        state: inout RenderState,
        key: String? = nil,
        index: Int? = nil
    ) -> String {
        guard state.consume() else { return "" }

        let label: String
        if let key {
            label = "<span class=\"json-key\">&quot;\(HTMLRenderer.escape(key))&quot;</span>"
                + "<span class=\"json-punct\">: </span>"
        } else if let index, value.isContainer {
            // Numbering array elements only pays off when they are objects or
            // arrays, where a collapsed row would otherwise read "{ 3 keys }"
            // two hundred times over. A list of plain strings stays clean.
            label = "<span class=\"json-index\">\(index)</span>"
                + "<span class=\"json-punct\">: </span>"
        } else {
            label = ""
        }
        let comma = isLast ? "" : "<span class=\"json-punct\">,</span>"

        switch value {
        case .object(let members):
            return container(
                open: "{",
                close: "}",
                countLabel: members.count == 1 ? "1 key" : "\(members.count) keys",
                isEmpty: members.isEmpty,
                label: label,
                comma: comma,
                depth: depth,
                state: &state
            ) { innerState in
                var rows = ""
                for (offset, member) in members.enumerated() {
                    rows += render(
                        member.value,
                        depth: depth + 1,
                        isLast: offset == members.count - 1,
                        state: &innerState,
                        key: member.key
                    )
                }
                return rows
            }

        case .array(let elements):
            return container(
                open: "[",
                close: "]",
                countLabel: elements.count == 1 ? "1 item" : "\(elements.count) items",
                isEmpty: elements.isEmpty,
                label: label,
                comma: comma,
                depth: depth,
                state: &state
            ) { innerState in
                var rows = ""
                for (offset, element) in elements.enumerated() {
                    rows += render(
                        element,
                        depth: depth + 1,
                        isLast: offset == elements.count - 1,
                        state: &innerState,
                        index: offset
                    )
                }
                return rows
            }

        case .string(let raw):
            return row(label + "<span class=\"json-string\">&quot;\(HTMLRenderer.escape(raw))&quot;</span>" + comma)

        case .number(let raw):
            return row(label + "<span class=\"json-number\">\(HTMLRenderer.escape(raw))</span>" + comma)

        case .bool(let flag):
            return row(label + "<span class=\"json-bool\">\(flag)</span>" + comma)

        case .null:
            return row(label + "<span class=\"json-null\">null</span>" + comma)
        }
    }

    private static func row(_ content: String) -> String {
        "<div class=\"json-row\">\(content)</div>"
    }

    private static func container(
        open: String,
        close: String,
        countLabel: String,
        isEmpty: Bool,
        label: String,
        comma: String,
        depth: Int,
        state: inout RenderState,
        children: (inout RenderState) -> String
    ) -> String {
        // An empty object or array has nothing to disclose, so render it flat.
        guard !isEmpty else {
            return row(label + "<span class=\"json-punct\">\(open)\(close)</span>" + comma)
        }

        let isOpen = state.expandAll || depth < defaultOpenDepth
        let rows = children(&state)

        return """
        <details class="json-node"\(isOpen ? " open" : "")>\
        <summary>\(label)<span class="json-punct">\(open)</span>\
        <span class="json-collapsed"> \(countLabel) \(close)\(comma.isEmpty ? "" : ",")</span>\
        </summary>\
        <div class="json-children">\(rows)</div>\
        <div class="json-row json-close"><span class="json-punct">\(close)</span>\(comma)</div>\
        </details>
        """
    }
}
