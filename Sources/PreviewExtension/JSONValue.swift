import Foundation

/// A parsed JSON document.
///
/// Deliberately not `JSONSerialization`: that returns dictionaries, which lose
/// key order, and a preview should show the file as it was written. Numbers and
/// strings keep their original source text for the same reason, so `1.50` does
/// not come back as `1.5` and an escape stays exactly as the author typed it.
indirect enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    /// Raw source text between the quotes, escapes and all.
    case string(String)
    /// Raw source text, so precision and formatting survive.
    case number(String)
    case bool(Bool)
    case null

    /// Total number of values in the tree, used to decide how much to expand.
    var nodeCount: Int {
        switch self {
        case .object(let members):
            return 1 + members.reduce(0) { $0 + $1.value.nodeCount }
        case .array(let elements):
            return 1 + elements.reduce(0) { $0 + $1.nodeCount }
        default:
            return 1
        }
    }

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }
}

/// A hand written JSON parser that preserves member order and reports where a
/// document went wrong, so a malformed file gets a useful message rather than
/// just failing to preview.
struct JSONParser {

    struct ParseError: LocalizedError {
        let message: String
        let line: Int
        let column: Int

        var errorDescription: String? {
            "\(message) at line \(line), column \(column)"
        }
    }

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var line = 1
    private var column = 1

    private init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(text)
        parser.skipByteOrderMark()
        parser.skipWhitespace()

        let value = try parser.parseValue()

        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw parser.error("Unexpected text after the top level value")
        }
        return value
    }

    // MARK: - Scanning

    private var isAtEnd: Bool { index >= scalars.count }

    private var current: Unicode.Scalar? { isAtEnd ? nil : scalars[index] }

    private mutating func advance() {
        guard !isAtEnd else { return }
        if scalars[index] == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index += 1
    }

    private mutating func skipByteOrderMark() {
        if current == "\u{FEFF}" { advance() }
    }

    private mutating func skipWhitespace() {
        while let scalar = current,
              scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            advance()
        }
    }

    private func error(_ message: String) -> ParseError {
        ParseError(message: message, line: line, column: column)
    }

    private mutating func expect(_ expected: Unicode.Scalar) throws {
        guard current == expected else {
            throw error("Expected '\(expected)'")
        }
        advance()
    }

    // MARK: - Values

    private mutating func parseValue() throws -> JSONValue {
        guard let scalar = current else {
            throw error("Unexpected end of file")
        }

        switch scalar {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t": try parseLiteral("true"); return .bool(true)
        case "f": try parseLiteral("false"); return .bool(false)
        case "n": try parseLiteral("null"); return .null
        default:
            if scalar == "-" || (scalar.value >= 48 && scalar.value <= 57) {
                return .number(try parseNumber())
            }
            throw error("Unexpected character '\(scalar)'")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try expect("{")
        var members: [(key: String, value: JSONValue)] = []

        skipWhitespace()
        if current == "}" {
            advance()
            return .object(members)
        }

        while true {
            skipWhitespace()
            guard current == "\"" else { throw error("Expected a key in double quotes") }

            let key = try parseString()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            members.append((key: key, value: try parseValue()))
            skipWhitespace()

            switch current {
            case ",":
                advance()
                skipWhitespace()
                // A trailing comma before the closing brace is invalid JSON, and
                // saying so beats a vaguer complaint about the next token.
                if current == "}" { throw error("Trailing comma in object") }
            case "}":
                advance()
                return .object(members)
            default:
                throw error("Expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try expect("[")
        var elements: [JSONValue] = []

        skipWhitespace()
        if current == "]" {
            advance()
            return .array(elements)
        }

        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()

            switch current {
            case ",":
                advance()
                skipWhitespace()
                if current == "]" { throw error("Trailing comma in array") }
            case "]":
                advance()
                return .array(elements)
            default:
                throw error("Expected ',' or ']'")
            }
        }
    }

    /// Returns the raw text between the quotes, without interpreting escapes.
    private mutating func parseString() throws -> String {
        try expect("\"")
        var raw = String.UnicodeScalarView()

        while true {
            guard let scalar = current else {
                throw error("Unterminated string")
            }

            if scalar == "\"" {
                advance()
                return String(raw)
            }

            if scalar == "\\" {
                raw.append(scalar)
                advance()
                guard let escaped = current else { throw error("Unterminated escape") }
                guard "\"\\/bfnrtu".unicodeScalars.contains(escaped) else {
                    throw error("Invalid escape '\\\(escaped)'")
                }
                raw.append(escaped)
                advance()

                if escaped == "u" {
                    for _ in 0..<4 {
                        guard let digit = current, digit.isHexDigit else {
                            throw error("Invalid \\u escape")
                        }
                        raw.append(digit)
                        advance()
                    }
                }
                continue
            }

            // Literal control characters are not allowed inside a JSON string.
            if scalar.value < 0x20 {
                throw error("Unescaped control character in string")
            }

            raw.append(scalar)
            advance()
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = index

        if current == "-" { advance() }

        guard let first = current, first.value >= 48, first.value <= 57 else {
            throw error("Expected a digit")
        }
        while let scalar = current, scalar.value >= 48, scalar.value <= 57 { advance() }

        if current == "." {
            advance()
            guard let digit = current, digit.value >= 48, digit.value <= 57 else {
                throw error("Expected a digit after the decimal point")
            }
            while let scalar = current, scalar.value >= 48, scalar.value <= 57 { advance() }
        }

        if current == "e" || current == "E" {
            advance()
            if current == "+" || current == "-" { advance() }
            guard let digit = current, digit.value >= 48, digit.value <= 57 else {
                throw error("Expected a digit in the exponent")
            }
            while let scalar = current, scalar.value >= 48, scalar.value <= 57 { advance() }
        }

        return String(String.UnicodeScalarView(scalars[start..<index]))
    }

    private mutating func parseLiteral(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard current == expected else { throw error("Expected '\(literal)'") }
            advance()
        }
    }
}

private extension Unicode.Scalar {
    var isHexDigit: Bool {
        (value >= 48 && value <= 57)
            || (value >= 97 && value <= 102)
            || (value >= 65 && value <= 70)
    }
}
