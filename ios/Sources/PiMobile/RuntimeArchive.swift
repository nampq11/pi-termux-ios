import Foundation

/// Minimal zip extraction for the runtime payload. External unzip libraries
/// link system zlib, which breaks the iOS-on-Linux link in xtool, and Apple's
/// Compression framework has no raw-DEFLATE mode — so the payload is produced
/// STORED (uncompressed) by scripts/prepare-runtime-ios.py and this reader
/// only walks the central directory and copies bytes (no encryption, no data
/// descriptors, no zip64 in that producer).
enum RuntimeArchive {

    enum ArchiveError: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            if case .malformed(let detail) = self { return "malformed archive: \(detail)" }
            return "malformed archive"
        }
    }

    /// Extracts every entry of `archiveURL` under `destination`.
    static func extract(archiveURL: URL, into destination: URL) throws {
        let bytes = [UInt8](try Data(contentsOf: archiveURL, options: .mappedIfSafe))
        let end = try locateCentralDirectory(bytes)

        let fm = FileManager.default
        var offset = Int(end.directoryOffset)
        for _ in 0..<end.entryCount {
            guard u32(bytes, offset) == 0x02014b50 else {
                throw ArchiveError.malformed("bad central directory entry")
            }
            let method = Int(u16(bytes, offset + 10))
            let size = Int(u32(bytes, offset + 24))
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let localOffset = Int(u32(bytes, offset + 42))

            guard let name = String(bytes: bytes[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8),
                  isSafeEntryName(name) else {
                throw ArchiveError.malformed("bad entry name")
            }
            defer { offset += 46 + nameLength + extraLength + commentLength }

            // local header: data follows the fixed part + its own name/extra fields
            guard u32(bytes, localOffset) == 0x04034b50 else {
                throw ArchiveError.malformed("bad local header for \(name)")
            }
            let dataStart = localOffset + 30 + Int(u16(bytes, localOffset + 26)) + Int(u16(bytes, localOffset + 28))

            let target = destination.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard method == 0, dataStart + size <= bytes.count else {
                throw ArchiveError.malformed("unsupported entry \(name) (method \(method))")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes[dataStart..<(dataStart + size)]).write(to: target, options: .atomic)
        }
    }

    private static func locateCentralDirectory(_ bytes: [UInt8]) throws -> (entryCount: Int, directoryOffset: UInt32) {
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06] // end of central directory
        let searchStart = Swift.max(0, bytes.count - 65_560) // EOCD + max comment
        var eocd = -1
        var i = bytes.count - 4
        while i >= searchStart {
            if bytes[i] == signature[0], Array(bytes[i..<(i + 4)]) == signature {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.malformed("end of central directory not found") }
        return (Int(u16(bytes, eocd + 10)), u32(bytes, eocd + 16))
    }

    private static func isSafeEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.contains("../")
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
