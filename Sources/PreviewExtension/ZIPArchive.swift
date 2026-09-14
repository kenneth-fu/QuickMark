import Compression
import Foundation

/// A minimal, read only ZIP reader that works entirely in memory.
///
/// Nothing is written to disk. That is deliberate: the extension is sandboxed
/// and unpacking to a temporary directory would be one more thing that can be
/// denied, and one more thing to clean up. An EPUB is small enough to hold in
/// memory for the moment it takes to render a preview.
///
/// Only what EPUB actually uses is implemented: stored and deflate entries,
/// read through the central directory. Zip64 and encrypted entries are
/// reported as unsupported rather than silently mis-read.
struct ZIPArchive {

    struct Entry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        /// Offset of the local file header, not of the data itself: the local
        /// header repeats the name and extra field with its own lengths, which
        /// can differ from the central directory's, so the data offset can only
        /// be computed once the local header is read.
        let localHeaderOffset: Int
    }

    enum ArchiveError: LocalizedError {
        case notAZIP
        case truncated
        case unsupportedCompression(UInt16)
        case zip64Unsupported
        case encrypted
        case decompressionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAZIP: return "Not a ZIP archive"
            case .truncated: return "The archive is truncated"
            case .unsupportedCompression(let method):
                return "Unsupported compression method \(method)"
            case .zip64Unsupported: return "Zip64 archives are not supported"
            case .encrypted: return "The archive is encrypted"
            case .decompressionFailed(let path): return "Could not decompress \(path)"
            }
        }
    }

    private let data: Data
    private let entriesByPath: [String: Entry]

    /// Paths in central directory order, which for an EPUB is roughly authoring
    /// order and is only used for diagnostics.
    let paths: [String]

    // MARK: - Reading the directory

    init(data: Data) throws {
        self.data = data

        let directoryStart = try Self.findCentralDirectory(in: data)
        var entries: [Entry] = []
        var cursor = directoryStart

        while cursor + 46 <= data.count,
              data.readUInt32(at: cursor) == 0x0201_4b50 {
            let flags = data.readUInt16(at: cursor + 8)
            let method = data.readUInt16(at: cursor + 10)
            let compressed = Int(data.readUInt32(at: cursor + 20))
            let uncompressed = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localOffset = Int(data.readUInt32(at: cursor + 42))

            // Bit 0 of the general purpose flags marks an encrypted entry.
            guard flags & 1 == 0 else { throw ArchiveError.encrypted }

            guard cursor + 46 + nameLength <= data.count else {
                throw ArchiveError.truncated
            }
            let nameRange = (cursor + 46)..<(cursor + 46 + nameLength)
            let path = String(decoding: data[nameRange], as: UTF8.self)

            // 0xFFFFFFFF in any size field means the real value lives in a
            // Zip64 extra field, which this reader does not decode.
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF
                || localOffset == 0xFFFF_FFFF {
                throw ArchiveError.zip64Unsupported
            }

            entries.append(
                Entry(
                    path: path,
                    compressionMethod: method,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localHeaderOffset: localOffset
                )
            )

            cursor += 46 + nameLength + extraLength + commentLength
        }

        guard !entries.isEmpty else { throw ArchiveError.notAZIP }

        paths = entries.map(\.path)
        entriesByPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Scans backwards for the End of Central Directory record. It sits at the
    /// very end unless the archive carries a trailing comment, which can be up
    /// to 64 KB, so that is how far back the search goes.
    private static func findCentralDirectory(in data: Data) throws -> Int {
        let minimumRecord = 22
        guard data.count >= minimumRecord else { throw ArchiveError.notAZIP }

        let earliest = max(0, data.count - minimumRecord - 65_535)
        var index = data.count - minimumRecord

        while index >= earliest {
            if data.readUInt32(at: index) == 0x0605_4b50 {
                let entryCount = data.readUInt16(at: index + 10)
                let offset = Int(data.readUInt32(at: index + 16))

                if entryCount == 0xFFFF || offset == 0xFFFF_FFFF {
                    throw ArchiveError.zip64Unsupported
                }
                guard offset < data.count else { throw ArchiveError.truncated }
                return offset
            }
            index -= 1
        }
        throw ArchiveError.notAZIP
    }

    // MARK: - Reading entries

    func contains(_ path: String) -> Bool { entriesByPath[path] != nil }

    /// Returns the decompressed bytes for a path, or nil when it is not present.
    func data(for path: String) throws -> Data? {
        guard let entry = entriesByPath[path] else { return nil }
        return try read(entry)
    }

    func text(for path: String) throws -> String? {
        guard let bytes = try data(for: path) else { return nil }
        return Self.decodeText(bytes)
    }

    private func read(_ entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count,
              data.readUInt32(at: header) == 0x0403_4b50 else {
            throw ArchiveError.truncated
        }

        // The local header's own name and extra lengths are authoritative here.
        let nameLength = Int(data.readUInt16(at: header + 26))
        let extraLength = Int(data.readUInt16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize

        guard end <= data.count else { throw ArchiveError.truncated }
        let payload = data.subdata(in: start..<end)

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            guard let inflated = Self.inflate(payload, expectedSize: entry.uncompressedSize) else {
                throw ArchiveError.decompressionFailed(entry.path)
            }
            return inflated
        default:
            throw ArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }

    /// Raw DEFLATE, which is what ZIP stores. Apple's COMPRESSION_ZLIB is raw
    /// deflate with no zlib wrapper, so it is the right algorithm here despite
    /// the name.
    private static func inflate(_ payload: Data, expectedSize: Int) -> Data? {
        guard !payload.isEmpty else { return Data() }

        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return payload.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase, expectedSize,
                    sourceBase, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written == expectedSize else { return nil }
        return output
    }

    /// EPUB content is XML and therefore UTF-8 or UTF-16 by declaration, but
    /// real files stray, so fall back the same way the rest of QuickMark does.
    static func decodeText(_ bytes: Data) -> String {
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: bytes, encoding: .utf16) { return utf16 }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - Little endian reads

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }
}
