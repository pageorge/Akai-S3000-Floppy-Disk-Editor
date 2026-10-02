import Foundation

// MARK: - E-mu ESI-32 / ESI-2000 / ESI-4000 (and Emulator IIIX) bank reader
//
// Reads an E-mu "Series III" bank from either:
//   • a FLOPPY SET — one or more raw 1.44 MB HD images (1,474,560 bytes each),
//     as saved by an ESI-4000 / ESI-32 / EIIIX onto its own floppies, or
//   • a BANK FILE — the same bank as a single file (.esi / .e3x), e.g. pulled
//     off a CD-ROM or a FAT-formatted disk by E-mu's tools.
//
// FORMAT SOURCE: ConvertWithMoss documentation/design/EIII_FORMAT.md and
// Emulator3FloppySet.java (Jürgen Moßgraber, LGPLv3), which in turn derive from
// emu3bm (David García Goñi) and were verified against the E-mu EIIIX /
// ESI-4000 library CD-ROMs and the E-mu + Sweetwater floppy libraries. Nothing
// here has been verified on our own hardware yet — same discipline as the Akai
// side: treat as provisional until checked against real disks.
//
// FLOPPY LAYOUT (everything BIG-endian — it's a 68k memory dump):
//   Each disk: 512-byte disk header, then payload. Payloads of disks 1…N are
//   concatenated in disk order into one "stream".
//   Disk header: 0x00 identifier[16], 0x10 bank name[16], 0x24 u32 = 1,
//                0x28 u32 disk number (1-based), 0x2C u32 total disks.
//   Stream = three 512-aligned regions:
//     1. bank record (bank-file offset B lives at stream offset B − 0x4C),
//        holding the preset/sample address tables (BE memory addresses) and
//        the presets themselves (byte-identical to a bank file EXCEPT each
//        zone's flag byte is bit-mirrored).
//     2./3. ESI order:   sample-header table (1000 × 92 B), then PCM data.
//           EIIIX order: PCM data, then sample-header table.
//   PCM is 16-bit BIG-endian, channels stored separately (not interleaved).
//
// BANK FILE LAYOUT: same structures, LITTLE-endian, sample headers sit in
// front of each sample's PCM. See parseBankFile.

// MARK: - Model

enum EmuBankVariant: String {
    case emulator3X = "Emulator IIIX"
    case esi        = "ESI-32/2000/4000"

    /// The 15-char identifier at offset 0 of a bank file / disk header.
    static func from(identifier: String) -> EmuBankVariant? {
        if identifier.hasPrefix("EMU SI-32")   { return .esi }
        if identifier.hasPrefix("EMULATOR 3X") { return .emulator3X }
        return nil
    }
}

/// One sample of the bank, already converted to 16-bit LITTLE-endian mono
/// buffers (one per channel) — i.e. ready for AkaiDiskImage.addImportedSample.
struct EmuSample: Identifiable {
    /// 1-based sample number within the bank (what zones reference).
    let id: Int
    let name: String
    let sampleRate: Int
    let left: Data?
    let right: Data?
    /// Loop start in frames, or nil if the sample doesn't loop.
    let loopStart: Int?
    /// Loop end in frames, EXCLUSIVE (one past the last looped frame).
    let loopEnd: Int?
    /// ESI "loop in release": keep looping through the release stage.
    let loopInRelease: Bool

    var isStereo: Bool { left != nil && right != nil }
    var channelCount: Int { isStereo ? 2 : 1 }
    var frameCount: Int { ((left ?? right)?.count ?? 0) / 2 }
    var isLooped: Bool { loopStart != nil && loopEnd != nil }
}

/// One zone (a sample assignment plus its voice parameters) of a preset layer.
struct EmuZone {
    /// MIDI note at which the sample plays at its recorded pitch.
    let originalKey: Int
    /// 1-based sample number, 0 = none.
    let sampleNumber: Int
    /// Amplifier envelope: attack, hold, decay, sustain, release (table indices 0–127).
    let ampEnvelope: [UInt8]
    /// Amplifier level 0–127.
    let level: Int
    /// Fine tuning in cents (−100…+100).
    let tuningCents: Int
    /// Pan 0 = hard left, 64 = centre, 127 = hard right.
    let pan: Int
    /// Zone flags in BANK-FILE bit order (floppy bytes are un-mirrored on read).
    let flags: UInt8

    var isNonTranspose: Bool { flags & 0x02 != 0 }
    var loopDisabled:   Bool { flags & 0x20 != 0 }
    var leftDisabled:   Bool { flags & 0x40 != 0 }
    var rightDisabled:  Bool { flags & 0x80 != 0 }
}

/// A contiguous run of keys sharing one note zone (= one Akai keygroup).
struct EmuKeyRange {
    let lowKey: Int    // MIDI
    let highKey: Int   // MIDI
    let primary: EmuZone?
    let secondary: EmuZone?
}

struct EmuPreset: Identifiable {
    /// 0-based preset slot in the bank.
    let id: Int
    let name: String
    let bendRange: Int
    let primaryVelocity: ClosedRange<Int>
    let secondaryVelocity: ClosedRange<Int>
    /// 1-based preset slot layered on top of this one, 0 = none. Not imported
    /// (Akai has no preset linking) — reported so the UI can mention it.
    let link: Int
    let keyRanges: [EmuKeyRange]

    /// Sample numbers used by this preset, optionally including the secondary layer.
    func sampleNumbers(includeSecondary: Bool) -> Set<Int> {
        var s = Set<Int>()
        for r in keyRanges {
            if let p = r.primary, p.sampleNumber > 0 { s.insert(p.sampleNumber) }
            if includeSecondary, let z = r.secondary, z.sampleNumber > 0 { s.insert(z.sampleNumber) }
        }
        return s
    }
}

struct EmuBank {
    let variant: EmuBankVariant
    let name: String
    let presets: [EmuPreset]
    let samples: [Int: EmuSample]
    /// Number of floppies the set spanned (0 for a bank file).
    let diskCount: Int
    var warnings: [String]
}

enum EmuESIError: LocalizedError {
    case notEmuData
    case unsupportedVariant(String)
    case incompleteSet(bankName: String, have: [Int], total: Int)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notEmuData:
            return "These files don't look like E-mu ESI / EIIIX disks or bank files."
        case .unsupportedVariant(let id):
            return "Unsupported E-mu bank type “\(id)”. Only ESI-32/2000/4000 and Emulator IIIX banks can be read (original Emulator III floppies use an undocumented layout)."
        case .incompleteSet(let name, let have, let total):
            let missing = (1...max(1, total)).filter { !have.contains($0) }
            let list = missing.map(String.init).joined(separator: ", ")
            return "“\(name)” is a \(total)-disk set but disk(s) \(list) weren't found. Select all disks of the set (or keep them in the same folder)."
        case .corrupt(let why):
            return "The E-mu data couldn't be read: \(why)"
        }
    }
}

// MARK: - Parser

enum EmuESIParser {

    static let floppySize       = 1_474_560
    static let diskHeaderSize   = 0x200
    static let blockSize        = 512

    // Bank-file offsets (identical for the EIIIX and ESI variants).
    static let presetTableOffset = 0x17CA
    static let sampleTableOffset = 0x1BD2
    static let presetAreaOffset  = 0x2B72
    static let maxPresets        = 256
    static let maxSamples        = 999

    /// Floppy payload offset = bank-file offset − recordShift.
    static let recordShift       = 0x4C
    static let sampleAddressBias = 0x400000
    /// Bit 26 flags the sampler's second memory bank on floppy addresses.
    static let floppyAddressMask = 0x3FF_FFFF
    /// 1000 slots × 92 bytes, rounded up to whole 512-byte blocks.
    static let headerTableSize   = (92 * 1000 + 511) / 512 * 512

    static let presetSize        = 142
    static let noteZoneSize      = 4
    static let zoneSize          = 48
    static let sampleHeaderSize  = 92
    static let numKeys           = 88
    static let firstKeyMIDI      = 21

    // MARK: Detection

    struct DiskInfo {
        let url: URL?
        let bytes: [UInt8]
        let identifier: String
        let bankName: String
        let number: Int
        let total: Int
        /// Identifier + bank name (first 32 bytes) — what ties the disks of a set together.
        var setKey: [UInt8] { Array(bytes[0..<32]) }
    }

    /// Recognise one disk of an EIIIX/ESI floppy set from its raw bytes.
    static func diskInfo(_ bytes: [UInt8], url: URL? = nil) -> DiskInfo? {
        guard bytes.count == floppySize else { return nil }
        let number = be32(bytes, 0x28), total = be32(bytes, 0x2C)
        // A bank file stores little-endian 1s here; sane big-endian disk
        // numbers are what tell a floppy apart from a 1.44 MB bank file.
        guard be32(bytes, 0x24) == 1, number >= 1, number <= total, total <= 99 else { return nil }
        return DiskInfo(url: url, bytes: bytes,
                        identifier: ascii(bytes, 0, 16),
                        bankName: ascii(bytes, 0x10, 16),
                        number: number, total: total)
    }

    /// Where the bank starts inside a bank file, or nil if it isn't one.
    /// Usually 0, but some tools save banks behind a 512-byte wrapper of their
    /// own (seen on a real ESI-4000 .esi: bank name + a few bytes + "EiB0",
    /// then the real bank at 0x200) — so 512-byte steps are tried too. A real
    /// bank has a known identifier and little-endian 1s at +0x24.
    static func bankFileStart(_ bytes: [UInt8]) -> Int? {
        guard diskInfo(bytes) == nil else { return nil }
        for start in stride(from: 0, through: 0x2000, by: 0x200) {
            guard bytes.count > start + presetAreaOffset else { break }
            if EmuBankVariant.from(identifier: ascii(bytes, start, 16)) != nil,
               le32(bytes, start + 0x24) == 1 {
                return start
            }
        }
        return nil
    }

    static func isBankFile(_ bytes: [UInt8]) -> Bool { bankFileStart(bytes) != nil }

    // MARK: Loading from files

    /// Load a bank from user-selected files. Accepts either one bank file, or
    /// any subset of a floppy set — missing disks are looked for among the
    /// other 1.44 MB files in the same folder(s) (file names can't be trusted;
    /// the disk headers are matched instead).
    static func load(urls: [URL]) throws -> EmuBank {
        var disks: [DiskInfo] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let bytes = [UInt8](data)
            if let info = diskInfo(bytes, url: url) {
                disks.append(info)
            } else if let start = bankFileStart(bytes) {
                return try parseBankFile(start == 0 ? bytes : Array(bytes[start...]))
            }
        }
        guard let first = disks.first else {
            // Distinguish an empty/truncated file from a genuinely foreign one.
            if urls.count == 1,
               let size = try? urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size < presetAreaOffset {
                throw EmuESIError.corrupt("“\(urls[0].lastPathComponent)” is only \(size) bytes — too small to be an E-mu bank (is it still downloading, or an iCloud placeholder?)")
            }
            throw EmuESIError.notEmuData
        }

        var bank = try assembleSet(first: first, candidates: disks)
        let otherSets = Set(disks.filter { $0.setKey != first.setKey }.map { $0.bankName })
        if !otherSets.isEmpty {
            bank.warnings.append("Other disk sets were selected and ignored: \(otherSets.sorted().joined(separator: ", ")). Import them separately.")
        }
        return bank
    }

    private static func assembleSet(first: DiskInfo, candidates: [DiskInfo]) throws -> EmuBank {
        var byNumber: [Int: DiskInfo] = [:]
        for d in candidates where d.setKey == first.setKey && d.total == first.total {
            byNumber[d.number] = byNumber[d.number] ?? d
        }

        // Look for the missing disks next to the ones that were selected.
        if byNumber.count < first.total {
            let folders = Set(candidates.compactMap { $0.url?.deletingLastPathComponent() })
            let selected = Set(candidates.compactMap { $0.url?.standardizedFileURL })
            for folder in folders {
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles])) ?? []
                for item in items where !selected.contains(item.standardizedFileURL) {
                    guard byNumber.count < first.total,
                          let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size == floppySize,
                          let data = try? Data(contentsOf: item),
                          let d = diskInfo([UInt8](data), url: item),
                          d.setKey == first.setKey, d.total == first.total,
                          byNumber[d.number] == nil else { continue }
                    byNumber[d.number] = d
                }
            }
        }

        guard byNumber.count == first.total else {
            throw EmuESIError.incompleteSet(bankName: first.bankName,
                                            have: byNumber.keys.sorted(), total: first.total)
        }
        let ordered = (1...first.total).compactMap { byNumber[$0]?.bytes }
        return try parseFloppySet(ordered)
    }

    // MARK: Floppy set

    /// Parse the disks of one set, already ordered by disk number.
    static func parseFloppySet(_ disks: [[UInt8]]) throws -> EmuBank {
        guard let firstDisk = disks.first, let info = diskInfo(firstDisk) else {
            throw EmuESIError.notEmuData
        }
        guard let variant = EmuBankVariant.from(identifier: info.identifier) else {
            throw EmuESIError.unsupportedVariant(info.identifier)
        }

        // Concatenate the payloads behind the 512-byte disk headers.
        var s = [UInt8]()
        s.reserveCapacity(disks.count * (floppySize - diskHeaderSize))
        for d in disks { s.append(contentsOf: d[diskHeaderSize..<d.count]) }

        let presetTable = presetTableOffset - recordShift
        let presetArea  = presetAreaOffset  - recordShift
        let sampleTable = sampleTableOffset - recordShift

        // Preset table: BE memory addresses. Subtracting entry 0 (the address
        // of the preset area) turns them into preset-area offsets.
        var presetEntries = [Int](repeating: 0, count: maxPresets + 1)
        for i in 0...maxPresets {
            presetEntries[i] = be32(s, presetTable + i * 4)
            if i > 0, presetEntries[i] < presetEntries[i - 1] {
                throw EmuESIError.corrupt("preset address table is not ascending")
            }
        }
        let presetAreaSize = presetEntries[maxPresets] - presetEntries[0]
        guard presetArea + presetAreaSize + 1 <= s.count else {
            throw EmuESIError.corrupt("preset area runs past the end of the disks")
        }
        let presetOffsets: [Int?] = (0..<maxPresets).map { i in
            presetEntries[i] == presetEntries[i + 1] ? nil : presetArea + presetEntries[i] - presetEntries[0]
        }
        let presets = parsePresets(s, offsets: presetOffsets,
                                   areaEnd: presetArea + presetAreaSize, mirrorFlags: true)

        // Sample table: an entry of 0 = empty slot (deleted sample).
        var sampleEntries = [Int](repeating: 0, count: maxSamples + 1)
        for i in 0...maxSamples { sampleEntries[i] = be32(s, sampleTable + i * 4) }
        let pcmSize = sampleEntries[maxSamples] & floppyAddressMask

        let recordEnd = blockAligned(presetArea + presetAreaSize + 1)
        let esiOrder   = (headers: recordEnd, pcm: recordEnd + headerTableSize)
        let eiiixOrder = (headers: recordEnd + blockAligned(pcmSize), pcm: recordEnd)
        // The ESI puts the header table first, the EIIIX the PCM. Try the
        // expected order first; fall back to the other if it reads worse (a
        // safety net in case an ESI ever saves with the 3X identifier).
        let orders = variant == .esi ? [esiOrder, eiiixOrder] : [eiiixOrder, esiOrder]

        var best: (samples: [Int: EmuSample], bad: [Int])? = nil
        for order in orders {
            let attempt = readFloppySamples(s, entries: sampleEntries,
                                            headerTable: order.headers, pcm: order.pcm)
            if best == nil || attempt.samples.count > best!.samples.count { best = attempt }
            if attempt.bad.isEmpty { break }
        }
        var warnings: [String] = []
        if let bad = best?.bad, !bad.isEmpty {
            warnings.append("Skipped \(bad.count) unreadable sample(s): #\(bad.prefix(10).map(String.init).joined(separator: ", #"))\(bad.count > 10 ? "…" : "").")
        }

        return EmuBank(variant: variant, name: info.bankName, presets: presets,
                       samples: best?.samples ?? [:], diskCount: disks.count, warnings: warnings)
    }

    private static func readFloppySamples(_ s: [UInt8], entries: [Int], headerTable: Int, pcm: Int)
        -> (samples: [Int: EmuSample], bad: [Int]) {
        var samples: [Int: EmuSample] = [:]
        var bad: [Int] = []
        guard headerTable >= 0, headerTable + (maxSamples + 1) * sampleHeaderSize <= s.count else {
            return ([:], Array(1...maxSamples).filter { entries[$0 - 1] != 0 })
        }
        for n in 1...maxSamples where entries[n - 1] != 0 {
            let h = headerTable + n * sampleHeaderSize
            // Floppy option flags (high byte of the BE options word):
            // 0x02 left, 0x04 right, 0x08 loop in release, 0x40 looped.
            let flags = s[h + 0x3A]
            let hasL = flags & 0x02 != 0, hasR = flags & 0x04 != 0
            guard hasL || hasR else { bad.append(n); continue }
            let stereo = hasL && hasR
            let field = hasL ? 0 : 4   // use the right-hand fields for right-only samples

            // On a floppy the positions are byte offsets from the channel's own
            // data start: the "end" field is the channel size in bytes.
            var size = be32(s, h + 0x1C + field)
            if stereo { size = min(size, be32(s, h + 0x20)) }
            size = size / 2 * 2
            let rate = be32(s, h + 0x34)
            let lOff = pcm + (be32(s, h + 0x3C) & floppyAddressMask)
            let rOff = pcm + (be32(s, h + 0x40) & floppyAddressMask)
            let primary = hasL ? lOff : rOff
            guard size > 0, rate > 0, rate <= 100_000,
                  primary + size <= s.count,
                  !stereo || rOff + size <= s.count else { bad.append(n); continue }

            var loopStart: Int? = nil, loopEnd: Int? = nil
            if flags & 0x40 != 0 {
                let ls = be32(s, h + 0x24 + field)
                let le = be32(s, h + 0x2C + field)   // floppy: points BEHIND the last loop frame
                if ls < le, le <= size { loopStart = ls / 2; loopEnd = le / 2 }
            }
            samples[n] = EmuSample(
                id: n, name: ascii(s, h, 16), sampleRate: rate,
                left:  hasL ? swapped16(s, lOff, size) : nil,
                right: hasR ? swapped16(s, rOff, size) : nil,
                loopStart: loopStart, loopEnd: loopEnd,
                loopInRelease: flags & 0x08 != 0)
        }
        return (samples, bad)
    }

    // MARK: Bank file

    static func parseBankFile(_ b: [UInt8]) throws -> EmuBank {
        let identifier = ascii(b, 0, 16)
        guard let variant = EmuBankVariant.from(identifier: identifier) else {
            throw EmuESIError.unsupportedVariant(identifier)
        }
        guard b.count > presetAreaOffset else { throw EmuESIError.corrupt("file too short") }

        var presetEntries = [Int](repeating: 0, count: maxPresets + 1)
        for i in 0...maxPresets { presetEntries[i] = le32(b, presetTableOffset + i * 4) }
        let presetAreaSize = presetEntries[maxPresets]
        guard presetAreaOffset + presetAreaSize < b.count else {
            throw EmuESIError.corrupt("preset area runs past the end of the file")
        }
        let presetOffsets: [Int?] = (0..<maxPresets).map { i in
            presetEntries[i] == presetEntries[i + 1] ? nil : presetAreaOffset + presetEntries[i]
        }
        let presets = parsePresets(b, offsets: presetOffsets,
                                   areaEnd: presetAreaOffset + presetAreaSize, mirrorFlags: false)

        let sampleArea = presetAreaOffset + 1 + presetAreaSize
        var samples: [Int: EmuSample] = [:]
        var bad: [Int] = []
        for i in 0..<maxSamples {
            let entry = le32(b, sampleTableOffset + i * 4)
            guard entry != 0 else { continue }
            let n = i + 1
            let h = sampleArea + entry - sampleAddressBias
            guard h >= sampleArea, h + sampleHeaderSize <= b.count,
                  let sample = readBankSample(b, header: h, number: n) else { bad.append(n); continue }
            samples[n] = sample
        }

        var warnings: [String] = []
        if !bad.isEmpty {
            warnings.append("Skipped \(bad.count) unreadable sample(s).")
        }
        return EmuBank(variant: variant, name: ascii(b, 0x10, 16), presets: presets,
                       samples: samples, diskCount: 0, warnings: warnings)
    }

    private static func readBankSample(_ b: [UInt8], header h: Int, number n: Int) -> EmuSample? {
        // Bank-file options: 0x0003 loop type, 0x0008 loop in release,
        // 0x0020 left channel, 0x0040 right channel.
        let options = le16(b, h + 0x3A)
        let hasL = options & 0x20 != 0, hasR = options & 0x40 != 0
        guard hasL || hasR else { return nil }

        // Positions are byte offsets from the start of this 92-byte header;
        // "end" is the offset of the channel's LAST frame. Channels can be
        // stored in either order, so each uses its own start/end.
        func channel(_ startField: Int, _ endField: Int) -> (start: Int, data: Data)? {
            let start = le32(b, h + startField), end = le32(b, h + endField)
            let bytes = (end + 2 - start) / 2 * 2
            guard start >= sampleHeaderSize, bytes > 0, h + start + bytes <= b.count else { return nil }
            return (start, Data(b[(h + start)..<(h + start + bytes)]))
        }
        let left  = hasL ? channel(0x14, 0x1C) : nil
        let right = hasR ? channel(0x18, 0x20) : nil
        guard let primary = left ?? right else { return nil }
        let rate = le32(b, h + 0x34)
        guard rate > 0, rate <= 100_000 else { return nil }

        var loopStart: Int? = nil, loopEnd: Int? = nil
        if options & 0x0003 != 0 {
            let fieldOffset = left != nil ? 0 : 4
            let ls = le32(b, h + 0x24 + fieldOffset)
            let le = le32(b, h + 0x2C + fieldOffset)   // bank file: the loop's LAST frame
            let frames = primary.data.count / 2
            let s = (ls - primary.start) / 2
            let e = (le - primary.start) / 2 + 1     // → exclusive
            if s >= 0, s < e, e <= frames { loopStart = s; loopEnd = e }
        }

        // A stereo sample's channels must be the same length for Akai's L/R pair.
        var l = left?.data, r = right?.data
        if let lc = l, let rc = r, lc.count != rc.count {
            let n = min(lc.count, rc.count)
            l = lc.prefix(n); r = rc.prefix(n)
        }
        return EmuSample(id: n, name: ascii(b, h, 16), sampleRate: rate,
                         left: l, right: r, loopStart: loopStart, loopEnd: loopEnd,
                         loopInRelease: options & 0x0008 != 0)
    }

    // MARK: Presets (shared by floppy and bank file)

    private static func parsePresets(_ b: [UInt8], offsets: [Int?], areaEnd: Int,
                                     mirrorFlags: Bool) -> [EmuPreset] {
        var presets: [EmuPreset] = []
        for (slot, off) in offsets.enumerated() {
            guard let off, let p = parsePreset(b, at: off, slot: slot, end: min(areaEnd, b.count),
                                              mirrorFlags: mirrorFlags) else { continue }
            // Skip presets that map no key at all (empty "Untitled Preset"
            // slots, CD-ROM label stubs) — they'd import as empty programs.
            guard !p.keyRanges.isEmpty else { continue }
            presets.append(p)
        }
        return presets
    }

    private static func parsePreset(_ b: [UInt8], at off: Int, slot: Int, end: Int,
                                    mirrorFlags: Bool) -> EmuPreset? {
        guard off >= 0, off + presetSize <= end else { return nil }

        func velocity(_ lo: UInt8, _ hi: UInt8) -> ClosedRange<Int> {
            // A high value of 0 means the layer isn't velocity-restricted.
            hi == 0 ? 0...127 : Int(min(lo, hi))...Int(min(hi, 127))
        }

        let noteZoneCount = Int(b[off + 53])
        let noteZoneBase = off + presetSize
        let zoneBase = noteZoneBase + noteZoneCount * noteZoneSize
        guard zoneBase <= end else { return nil }

        func zone(_ index: UInt8) -> EmuZone? {
            guard index != 0xFF else { return nil }
            let z = zoneBase + Int(index) * zoneSize
            guard z + zoneSize <= end else { return nil }
            var flags = b[z + 47]
            // On a floppy the zone flag byte is stored bit-mirrored.
            if mirrorFlags { flags = reverseBits(flags) }
            return EmuZone(
                originalKey: Int(b[z]) + firstKeyMIDI,
                sampleNumber: (Int(b[z + 1]) | Int(b[z + 2]) << 8) & 0x3FFF,
                ampEnvelope: Array(b[(z + 4)..<(z + 9)]),
                level: Int(b[z + 40] & 0x7F),
                tuningCents: Int(Int8(bitPattern: b[z + 41])) * 100 / 64,
                pan: Int(b[z + 44] & 0x7F),
                flags: flags)
        }

        // Key map: one note-zone index per key. Contiguous runs of the same
        // index become one key range (= one Akai keygroup).
        var ranges: [EmuKeyRange] = []
        var key = 0
        while key < numKeys {
            let nz = b[off + 54 + key]
            var last = key
            while last + 1 < numKeys && b[off + 54 + last + 1] == nz { last += 1 }
            if nz != 0xFF, Int(nz) < noteZoneCount {
                let nzOff = noteZoneBase + Int(nz) * noteZoneSize
                let primary = zone(b[nzOff + 2]), secondary = zone(b[nzOff + 3])
                if primary != nil || secondary != nil {
                    ranges.append(EmuKeyRange(lowKey: key + firstKeyMIDI, highKey: last + firstKeyMIDI,
                                              primary: primary, secondary: secondary))
                }
            }
            key = last + 1
        }

        return EmuPreset(
            id: slot, name: ascii(b, off, 16), bendRange: Int(b[off + 44]),
            primaryVelocity: velocity(b[off + 45], b[off + 46]),
            secondaryVelocity: velocity(b[off + 47], b[off + 48]),
            link: Int(b[off + 49]), keyRanges: ranges)
    }

    // MARK: Byte helpers (bounds-safe: out-of-range reads return 0)

    static func be32(_ b: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }
    static func le32(_ b: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
    static func le16(_ b: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o + 2 <= b.count else { return 0 }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }
    static func ascii(_ b: [UInt8], _ o: Int, _ len: Int) -> String {
        guard o >= 0, o + len <= b.count else { return "" }
        let chars = b[o..<(o + len)].map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : " " }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
    /// Copy 16-bit big-endian PCM out as little-endian.
    static func swapped16(_ b: [UInt8], _ o: Int, _ len: Int) -> Data {
        var out = [UInt8](repeating: 0, count: len)
        var i = 0
        while i + 1 < len {
            out[i] = b[o + i + 1]
            out[i + 1] = b[o + i]
            i += 2
        }
        return Data(out)
    }
    static func reverseBits(_ x: UInt8) -> UInt8 {
        var v = x, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }
    static func blockAligned(_ n: Int) -> Int { (n + blockSize - 1) / blockSize * blockSize }
}
