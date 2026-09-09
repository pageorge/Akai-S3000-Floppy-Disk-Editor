import Foundation

// MARK: - Data little-endian read/write

/// Generic little-endian byte helpers on `Data` — not specific to any file
/// format. Used wherever the app packs or unpacks fixed-width integers from a
/// byte buffer (Akai disk structures, WAV chunk headers, etc.).
///
/// Note on indexing: these use offsets measured from the buffer's own
/// `startIndex`, so they behave  correctly even on a `Data` slice whose
/// `startIndex` isn't 0 (e.g. the result of `subdata`/range subscripting).
extension Data {
    mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }

    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }

    func readLE16(at i: Int) -> UInt16 {
        let base = startIndex + i
        guard base + 1 < endIndex else { return 0 }
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readLE32(at i: Int) -> UInt32 {
        let base = startIndex + i
        guard base + 3 < endIndex else { return 0 }
        return UInt32(self[base]) | (UInt32(self[base + 1]) << 8) |
               (UInt32(self[base + 2]) << 16) | (UInt32(self[base + 3]) << 24)
    }
}
