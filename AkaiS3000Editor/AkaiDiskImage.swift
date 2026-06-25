import Foundation

// MARK: - Akai S3000 Disk Format Constants
// Verified against (a) the akaiutil / akai-fs source structs and (b) a real
// Greaseweazle-read S3000 HD floppy, byte-for-byte.
//
// Physical format:  80 cylinders × 2 heads × 10 sectors × 1024 bytes = 1,638,400 bytes
//                   (akai_flhhead: AKAI_FL_BLOCKSIZE 0x400, AKAI_FLH_SIZE 0x640 = 1600 blocks)
// Audio encoding:   16-bit signed little-endian PCM (same as WAV — no conversion needed)
// Character set:    0-9=digits, 10=space, 11-36=A-Z, 37=#, 38=+, 39=-, 40=.
//
// HD floppy HEADER (struct akai_flhhead_s, blocks 0-4, 5 blocks total):
//   0x0000: file[64]        — 64 voldir entries × 24 bytes (the FLOPPY-HEADER copy).
//                             On S3000 floppies this is NOT the live directory; slot 0
//                             holds the 0xFF S3000 volume flag (name 'VVVVVVVVVVVV',
//                             AKAI_EMPTY1000_FNAME), the rest are empty. DO NOT touch block 0.
//   0x0600: fatblk[1600][2] — FAT, 2 bytes LE per block (next-block or special code)
//   0x0D80: label           — akai_flvol_label_s (volume name + osver + params)
//
// LIVE VOLUME DIRECTORY (struct akai_voldir3000fl_s): starts at BLOCK 5
//   (AKAI_VOLDIR3000FLH_BSTART = 5), 510 entries × 24 bytes, spans 12 blocks.
//   This is the real directory we read and write.
//
// Directory entry (struct akai_voldir_entry_s, 24 bytes):
//   [0-11]  name (12 bytes, Akai encoding)
//   [12-15] tag[4]   (S3000 free tag = 0x00; S1000 default = 0x20)
//   [16]    type     (0xF3 = sample 's'+0x80, 0xF0 = program 'p'+0x80, 0x00 = free)
//   [17-19] size     (24-bit LE, total bytes incl. 252-byte header)
//   [20-21] start    (16-bit LE, start block within partition)
//   [22-23] osver    (16-bit LE; real samples = 0x0000, programs = 0x1100 = v17.00)
//
// FAT codes (AKAI_FAT_CODE_*):
//   0x0000 = free block       0x2000 = bad block
//   0x4000 = system block     0xC000 = end of file chain (FILEEND)
//   other  = next block number (16-bit LE)
//
// Sample header (struct akai_sample3000_s = akai_sample1000_s (0x96) + 42 pad,
// = 0xC0 = 192 bytes). VERIFIED against the real S3000XL: a 256-sample SINE has
// directory size 704 = 0xC0 header + 512 audio bytes (256 frames). Audio begins
// at 0xC0, NOT 0xFC.
//   0x00 blockid=0x03   0x01 bandw   0x02 rkey   0x03 name[12]
//   0x10 lnum  0x11 lfirst  0x13 pmode (0=loop,2=noloop)  0x14 ctune  0x15 stune
//   0x16 locat[4] (sampler-managed)
//   0x1A slen[4] (number of samples)   0x1E start[4]   0x22 end[4]
//   0x26 loop[0]: at[4] @0x26, flen[2] @0x2A, len[4] @0x2C, time[2] @0x30
//   (loop array is 8 × 0x0C = 0x60, spanning 0x26..0x85)
//   0x86 dummy3[2]   0x88 stpaira[2]   0x8A srate[2]   0x8C hltoff
//   then dummy4[9] → 0x96, then 42 pad → 0xC0
//   0xC0 audio data begins

struct AkaiDiskFormat {
    static let blockSize            = 1024
    static let blocksPerTrack       = 10
    static let tracks               = 80
    static let sides                = 2
    static let totalBlocks          = blocksPerTrack * tracks * sides   // 1600

    static let dirEntryCount        = 64
    static let dirEntrySize         = 24
    static let fatOffset            = dirEntryCount * dirEntrySize      // 1536 = 0x600

    static let volDirStartBlock     = 5
    static let volDirEntryCount     = 510

    static let ftypeSample: UInt8   = 0xF3
    static let ftypeProgram: UInt8  = 0xF0

    static let fatFree: UInt16      = 0x0000
    static let fatSystem: UInt16    = 0x4000
    static let fatEnd: UInt16       = 0xC000

    static let sampleHeaderSize     = 0xC0    // akai_sample3000_s = 192 bytes; audio starts here

    // Single canonical offsets from akai_sample1000_s — no scanning, no fallback.
    static let hdrNameOffset        = 0x03    // name[12]
    static let hdrSampleCountOffset = 0x1A    // slen[4]  (number of samples)
    static let hdrLoopAtOffset      = 0x26    // loop[0].at[4]
    static let hdrLoopFineOffset    = 0x2A    // loop[0].flen[2] (1/65536 sample)
    static let hdrLoopLenOffset     = 0x2C    // loop[0].len[4]
    static let hdrStPairOffset      = 0x88    // stpaira[2]
    static let hdrSampleRateOffset  = 0x8A    // srate[2]
}

// MARK: - Data Model

struct AkaiDirectoryEntry {
    var name: String
    var fileType: UInt8
    var startBlock: UInt16
    var size: UInt32
    var rawEntry: Data
    /// Byte offset of this 24-byte entry within the disk image (volume directory region).
    /// Used so we can blank/delete the correct on-disk slot later.
    var diskOffset: Int = -1

    var isSample:  Bool { fileType == AkaiDiskFormat.ftypeSample }
    var isProgram: Bool { fileType == AkaiDiskFormat.ftypeProgram }

    var displayType: String {
        switch fileType {
        case AkaiDiskFormat.ftypeSample:  return "Sample"
        case AkaiDiskFormat.ftypeProgram: return "Program"
        default: return String(format: "0x%02X", fileType)
        }
    }
}

struct AkaiSampleHeader {
    var name: String
    var sampleRate: UInt32
    var loopStart: UInt32
    var loopEnd: UInt32
    var numSamples: UInt32
    var midiRootNote: UInt8
    var loopEnabled: Bool
    var bitDepth: Int
    var numChannels: Int
    var fineTune: Int8        // ctune: cents tune (0x14), signed
    var semitoneTune: Int8    // stune: semitone tune (0x15), signed
    var loudness: UInt8
    var rawHeader: Data
}

struct AkaiProgramKeyzone {
    var sampleName: String
    var lowKey: UInt8
    var highKey: UInt8
    var rootNote: UInt8
    var tuneOffset: Int8
    var fineTune: Int8
    var volume: UInt8
    var pan: Int8
    var loopEnabled: Bool
    var velocityLow: UInt8
    var velocityHigh: UInt8
}

struct AkaiProgram {
    var name: String
    var keyzones: [AkaiProgramKeyzone]
    var midiChannel: UInt8
    var polyphony: UInt8
    var bendRange: UInt8
    var rawData: Data
}

struct AkaiSample: Identifiable {
    var id = UUID()
    var directoryEntry: AkaiDirectoryEntry
    var header: AkaiSampleHeader
    var audioData: Data
    var offset: Int
    var additionalEntries: [AkaiDirectoryEntry] = []
}

struct AkaiProgramFile: Identifiable {
    var id = UUID()
    var directoryEntry: AkaiDirectoryEntry
    var program: AkaiProgram
    var offset: Int
}

// MARK: - Disk Image

class AkaiDiskImage: ObservableObject {
    @Published var isLoaded    = false
    @Published var diskName    = ""
    @Published var samples:  [AkaiSample]      = []
    @Published var programs: [AkaiProgramFile] = []
    @Published var freeBlocks  = 0
    @Published var totalBlocks = AkaiDiskFormat.totalBlocks
    /// True whenever there are edits (sample/program changes, deletions) that
    /// haven't been written to the .img file yet. Detail views set this when
    /// they mark themselves dirty, and writeSampleToImage/updateProgramInImage/
    /// saveImageToDisk/deleteSample clear or set it appropriately.
    @Published var hasUnsavedChanges = false

    /// True while a text field (e.g. the sample-rename field) has focus. Global
    /// NSEvent key monitors (delete-to-remove-sample, space-to-play) check this
    /// and bow out so keystrokes reach the field instead of triggering shortcuts.
    @Published var isEditingText = false

    var imageData: Data?
    var imageURL:  URL?

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= AkaiDiskFormat.blockSize * 5 else {
            throw AkaiError.invalidImage("File too small")
        }
        imageData = data
        imageURL  = url
        hasUnsavedChanges = false
        try parseImage(data: data)
    }

    /// Close the current disk image and return to the unloaded (welcome) state.
    /// Clears all in-memory data and the unsaved-changes flag. Does NOT write to
    /// disk — callers should resolve unsaved changes (save/discard) first.
    func closeImage() {
        imageData = nil
        imageURL = nil
        samples = []
        programs = []
        diskName = ""
        freeBlocks = 0
        totalBlocks = AkaiDiskFormat.totalBlocks
        hasUnsavedChanges = false
        isEditingText = false
        isLoaded = false
    }

    private func parseImage(data: Data) throws {
        // Volume label (akai_flvol_label_s.name) lives at ABSOLUTE offset 0xD80
        // within the header (blocks 0-4), per akai_flhhead_s — NOT 4*blockSize
        // (0x1000), which was the previous, wrong offset and meant the disk name
        // was always read from the wrong bytes (typically blank/garbage).
        let labelOffset = 0xD80
        diskName = labelOffset + 12 <= data.count
            ? akaiString(from: data, offset: labelOffset, length: 12)
            : ""
        freeBlocks = countFreeBlocks(data: data)
        let (parsedSamples, parsedPrograms) = try parseDirectory(data: data)
        DispatchQueue.main.async {
            self.samples  = parsedSamples
            self.programs = parsedPrograms
            self.isLoaded = true
        }
    }

    private func countFreeBlocks(data: Data) -> Int {
        var free = 0
        for block in 0..<AkaiDiskFormat.totalBlocks {
            if fatValue(block: block, data: data) == AkaiDiskFormat.fatFree { free += 1 }
        }
        return free
    }

    // MARK: - FAT

    private func fatValue(block: Int, data: Data) -> UInt16 {
        let offset = AkaiDiskFormat.fatOffset + block * 2
        guard offset + 2 <= data.count else { return AkaiDiskFormat.fatEnd }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func setFatValue(block: Int, value: UInt16, data: inout Data) {
        let offset = AkaiDiskFormat.fatOffset + block * 2
        guard offset + 2 <= data.count else { return }
        data[offset]     = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func fatChain(from startBlock: Int, data: Data) -> [Int] {
        var chain = [startBlock]
        var seen  = Set([startBlock])
        var block = startBlock
        for _ in 0..<2000 {
            let val = fatValue(block: block, data: data)
            if val >= AkaiDiskFormat.fatEnd || val == AkaiDiskFormat.fatFree { break }
            let next = Int(val)
            if seen.contains(next) { break }
            chain.append(next)
            seen.insert(next)
            block = next
        }
        return chain
    }

    /// Mark every block in the chain starting at startBlock as free (0x0000) in the FAT.
    private func freeChain(from startBlock: Int, data: inout Data) {
        let chain = fatChain(from: startBlock, data: data)
        for block in chain {
            setFatValue(block: block, value: AkaiDiskFormat.fatFree, data: &data)
        }
    }

    private func readFromChain(_ chain: [Int], fileOffset: Int, length: Int, data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(length)
        let bs = AkaiDiskFormat.blockSize
        for (i, block) in chain.enumerated() {
            let blockStart = i * bs
            let readStart  = max(0, fileOffset - blockStart)
            let readEnd    = min(bs, fileOffset + length - blockStart)
            guard readStart < readEnd else { continue }
            let diskOffset = block * bs + readStart
            let diskEnd    = block * bs + readEnd
            guard diskEnd <= data.count else { break }
            result.append(data[diskOffset..<diskEnd])
            if result.count >= length { break }
        }
        return result
    }

    // MARK: - Directory

    private func parseDirectory(data: Data) throws -> ([AkaiSample], [AkaiProgramFile]) {
        let dirStart   = AkaiDiskFormat.volDirStartBlock * AkaiDiskFormat.blockSize
        let entrySize  = AkaiDiskFormat.dirEntrySize
        let maxEntries = AkaiDiskFormat.volDirEntryCount

        var entries: [AkaiDirectoryEntry] = []
        for i in 0..<maxEntries {
            let base = dirStart + i * entrySize
            guard base + entrySize <= data.count else { break }
            let ftype = data[base + 16]
            // The hardware treats the directory as a fixed array of slots: an
            // empty slot (type 0x00) is skipped, NOT a terminator. Deleting a
            // file in the middle leaves a hole, and later files must still be
            // read. So we continue scanning rather than breaking here.
            guard ftype == AkaiDiskFormat.ftypeSample || ftype == AkaiDiskFormat.ftypeProgram else { continue }
            let name  = akaiString(from: data, offset: base, length: 12)
            let size  = UInt32(data[base+17]) | (UInt32(data[base+18]) << 8) | (UInt32(data[base+19]) << 16)
            let start = UInt16(data[base+20]) | (UInt16(data[base+21]) << 8)
            entries.append(AkaiDirectoryEntry(name: name, fileType: ftype, startBlock: start, size: size,
                                              rawEntry: Data(data[base..<base+entrySize]),
                                              diskOffset: base))
        }

        var parsedSamples:  [AkaiSample]      = []
        var parsedPrograms: [AkaiProgramFile] = []
        var processedNames = Set<String>()

        for entry in entries {
            if entry.isProgram {
                if let prog = try? parseProgram(entry: entry, data: data) { parsedPrograms.append(prog) }
            } else if entry.isSample {
                if processedNames.contains(entry.name) { continue }
                processedNames.insert(entry.name)
                let parts = entries.filter { $0.isSample && $0.name == entry.name }
                    .sorted { $0.startBlock < $1.startBlock }
                if let sample = try? parseSample(parts: parts, data: data) { parsedSamples.append(sample) }
            }
        }

        return (parsedSamples, parsedPrograms)
    }

    // MARK: - Sample Parsing

    private func parseSample(parts: [AkaiDirectoryEntry], data: Data) throws -> AkaiSample {
        guard let first = parts.first else { throw AkaiError.dataError("Empty sample parts") }
        let startBlock = Int(first.startBlock)
        let headerSize = AkaiDiskFormat.sampleHeaderSize
        let chain0     = fatChain(from: startBlock, data: data)
        let headerData = readFromChain(chain0, fileOffset: 0, length: headerSize, data: data)
        guard headerData.count >= headerSize else {
            throw AkaiError.dataError("Sample header too short: \(first.name)")
        }

        let name = akaiString(from: headerData, offset: AkaiDiskFormat.hdrNameOffset, length: 12)

        // Sample rate: srate[2] @ 0x8A. Single canonical offset (akai_sample1000_s).
        let sampleRate = UInt32(headerData[AkaiDiskFormat.hdrSampleRateOffset]) |
                         (UInt32(headerData[AkaiDiskFormat.hdrSampleRateOffset + 1]) << 8)

        // Number of samples: slen[4] @ 0x1A. This is THE count the Akai reports
        // (verified: SINE slen = 256 = Akai "size: 256"). Source of truth.
        let numSamples = UInt32(headerData[AkaiDiskFormat.hdrSampleCountOffset]) |
                         (UInt32(headerData[AkaiDiskFormat.hdrSampleCountOffset + 1]) << 8) |
                         (UInt32(headerData[AkaiDiskFormat.hdrSampleCountOffset + 2]) << 16) |
                         (UInt32(headerData[AkaiDiskFormat.hdrSampleCountOffset + 3]) << 24)

        // Read the audio that follows the 0xC0 header across the FAT chain(s).
        var audioData = Data()
        for part in parts {
            let chain     = fatChain(from: Int(part.startBlock), data: data)
            let audioSize = Int(part.size) - headerSize
            guard audioSize > 0 else { continue }
            audioData.append(readFromChain(chain, fileOffset: headerSize, length: audioSize, data: data))
        }

        // pmode @ 0x13: 0=loop, 1=loop-until-release, 2=no loop, 3=play-to-end.
        let loopEnabled = headerData[0x13] != 0x02

        // loop[0]: at[4] @ 0x26 (return-to point), len[4] @ 0x2C (loop length in
        // samples). The real loop region is [at, at+len) — verified by hardware
        // testing: at=48,len=48 produces a 48-sample loop (48→96), NOT a loop to
        // the buffer end. The end can never exceed numSamples (there's no audio
        // past it), so it's clamped to the buffer's real size — not a fallback,
        // just respecting that the data physically ends there. The factory SINE
        // (at=192,len=168) gives min(360,256)=256, which happens to reach the
        // buffer end — a coincidence of that particular sample, not the rule.
        let loopStart = UInt32(headerData[AkaiDiskFormat.hdrLoopAtOffset]) |
                        (UInt32(headerData[AkaiDiskFormat.hdrLoopAtOffset + 1]) << 8) |
                        (UInt32(headerData[AkaiDiskFormat.hdrLoopAtOffset + 2]) << 16) |
                        (UInt32(headerData[AkaiDiskFormat.hdrLoopAtOffset + 3]) << 24)
        let loopLen = UInt32(headerData[AkaiDiskFormat.hdrLoopLenOffset]) |
                      (UInt32(headerData[AkaiDiskFormat.hdrLoopLenOffset + 1]) << 8) |
                      (UInt32(headerData[AkaiDiskFormat.hdrLoopLenOffset + 2]) << 16) |
                      (UInt32(headerData[AkaiDiskFormat.hdrLoopLenOffset + 3]) << 24)
        let loopEnd = min(loopStart + loopLen, numSamples)
        let midiRootNote = headerData[0x02]
        let fineTune = Int8(bitPattern: headerData[0x14])
        let semitoneTune = Int8(bitPattern: headerData[0x15])

        let header = AkaiSampleHeader(
            name: name.isEmpty ? first.name : name,
            sampleRate: sampleRate,
            loopStart: loopStart,
            loopEnd: loopEnd,
            numSamples: numSamples,
            midiRootNote: midiRootNote,
            loopEnabled: loopEnabled,
            bitDepth: 16, numChannels: 1,
            fineTune: fineTune,
            semitoneTune: semitoneTune,
            loudness: 99,
            rawHeader: headerData
        )
        return AkaiSample(directoryEntry: first, header: header, audioData: audioData,
                          offset: startBlock * AkaiDiskFormat.blockSize,
                          additionalEntries: Array(parts.dropFirst()))
    }

    // MARK: - Program Parsing

    /// Parse an S3000 program file. Offsets verified against akaiutil's
    /// akai_program1000_s / akai_program3000kg_s structs and a real gw disk.
    ///   Program header (0xC0): 0x00 blockid=0x01, 0x03 name[12], 0x10 midich1
    ///   (0xff=OMNI), 0x13 keylo, 0x14 keyhi, 0x15 oct, 0x2A kgnum.
    ///   Keygroups follow at 0xC0, each 0xC0 bytes: 0x00 blockid=0x02, 0x03 keylo,
    ///   0x04 keyhi, then 4 velocity zones at +0x22 (each 0x18): sname[12],
    ///   0x0C vello, 0x0D velhi, 0x0E ctune, 0x0F stune, 0x10 loud, 0x12 pan, 0x13 pmode.
    private func parseProgram(entry: AkaiDirectoryEntry, data: Data) throws -> AkaiProgramFile {
        let startBlock = Int(entry.startBlock)
        let chain      = fatChain(from: startBlock, data: data)
        let fileData   = readFromChain(chain, fileOffset: 0, length: Int(entry.size), data: data)

        let name = fileData.count >= 0x0F
            ? akaiString(from: fileData, offset: 0x03, length: 12) : entry.name
        // midich1 @ 0x10: on-disk 0xFF = Omni, 0...15 = MIDI channel (0-indexed).
        // The UI uses 0 = Omni, 1...16 = channel (1-indexed display), so translate
        // here rather than storing the raw on-disk byte directly into the model.
        let rawMidi = fileData.count > 0x10 ? fileData[0x10] : 0xff
        let midiChannel: UInt8 = rawMidi == 0xff ? 0 : rawMidi &+ 1
        let keygroupCount = fileData.count > 0x2A ? fileData[0x2A] : 0
        let octave = fileData.count > 0x15 ? fileData[0x15] : 0

        // Walk keygroups: first at 0xC0, each 0xC0 bytes; kgnum tells us how many.
        var keyzones: [AkaiProgramKeyzone] = []
        let kgSize = 0xC0
        let kgBase = 0xC0
        for kgi in 0..<Int(keygroupCount) {
            let kg = kgBase + kgi * kgSize
            guard kg + kgSize <= fileData.count else { break }
            let kgKeylo = fileData[kg + 0x03]
            let kgKeyhi = fileData[kg + 0x04]
            // Velocity zone 1 holds the primary sample assignment.
            let vz = kg + 0x22
            guard vz + 0x18 <= fileData.count else { break }
            let sname = akaiString(from: fileData, offset: vz, length: 12)
            keyzones.append(AkaiProgramKeyzone(
                sampleName: sname,
                lowKey: kgKeylo, highKey: kgKeyhi,
                rootNote: 60,
                tuneOffset: Int8(bitPattern: fileData[vz + 0x0F]),   // stune
                fineTune:   Int8(bitPattern: fileData[vz + 0x0E]),   // ctune
                volume: fileData[vz + 0x10],                          // loud
                pan: Int8(bitPattern: fileData[vz + 0x12]),           // pan
                loopEnabled: fileData[vz + 0x13] != 0x03,             // pmode 0x03=NOLOOP
                velocityLow:  fileData[vz + 0x0C],
                velocityHigh: fileData[vz + 0x0D]))
        }

        let program = AkaiProgram(name: name, keyzones: keyzones,
                                  midiChannel: midiChannel, polyphony: 16, bendRange: octave,
                                  rawData: fileData)
        return AkaiProgramFile(directoryEntry: entry, program: program,
                               offset: startBlock * AkaiDiskFormat.blockSize)
    }

    /// Generate a unique 12-char program name, avoiding existing program names.
    private func uniqueProgramName(basedOn base: String) -> String {
        let existing = Set(programs.map { $0.program.name })
        let cleanBase = Self.sanitizeName(base.isEmpty ? "NEW PROGRAM" : base)
        if !existing.contains(cleanBase) { return cleanBase }
        for n in 2...999 {
            let suffix = " \(n)"
            let candidate = Self.sanitizeName(String(cleanBase.prefix(12 - suffix.count)) + suffix)
            if !existing.contains(candidate) { return candidate }
        }
        return cleanBase
    }

    /// Create a new, empty but VALID S3000 program (one keygroup spanning the full
    /// keyboard, no sample assigned) and add it to the disk. Layout verified
    /// against akaiutil's akai_program3000_s / akai_program3000kg_s and a real gw
    /// disk. Does not write to disk immediately — persist via Save.
    @discardableResult
    func createProgram(name rawName: String = "NEW PROGRAM") throws -> AkaiProgramFile {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        let name = uniqueProgramName(basedOn: rawName)

        // Build the 0xC0-byte file: program header only, no keygroups yet.
        let progSize = 0xC0
        var file = Data(repeating: 0, count: progSize)

        // --- Program header (akai_program1000_s + S3000 pad) ---
        file[0x00] = 0x01                       // blockid
        // kg1a (0x01..0x02) stays 0 — sampler-managed.
        let nameBytes = akaiBytes(from: name, length: 12)
        for (i, b) in nameBytes.enumerated() { file[0x03 + i] = b }
        file[0x10] = 0xFF                        // midich1 = OMNI
        file[0x13] = 24                         // keylo (matches hardware default)
        file[0x14] = 127                        // keyhi
        file[0x15] = 0                          // oct
        file[0x16] = 0xFF                        // auxch1 = OFF
        file[0x29] = 0                          // kgxf
        file[0x2A] = 0                          // kgnum = 0

        // No keygroups — the user will add them manually or via the drum preset tool.

        // Allocate one block (384 bytes < 1024) and a directory slot.
        let bs = AkaiDiskFormat.blockSize
        let blocksNeeded = (progSize + bs - 1) / bs
        guard let blocks = findFreeBlocks(count: blocksNeeded, data: data) else {
            throw AkaiError.diskFull("Not enough space on the disk to create a program.")
        }
        guard let dirSlot = findFreeDirectorySlot(data: data) else {
            throw AkaiError.dataError("Disk directory is full")
        }

        // Chain blocks (last = end-of-chain) and write the file data.
        for i in 0..<blocks.count {
            let value: UInt16 = (i == blocks.count - 1) ? AkaiDiskFormat.fatEnd : UInt16(blocks[i + 1])
            setFatValue(block: blocks[i], value: value, data: &data)
        }
        for (i, block) in blocks.enumerated() {
            let srcStart = i * bs
            let srcEnd = min(srcStart + bs, file.count)
            let dstStart = block * bs
            guard dstStart + bs <= data.count else { throw AkaiError.dataError("Block out of range") }
            let chunk = file[srcStart..<srcEnd]
            let padded = chunk + Data(repeating: 0, count: bs - (srcEnd - srcStart))
            data.replaceSubrange(dstStart..<dstStart + bs, with: padded)
        }

        // Directory entry: type 0xF0 (program), osver 0x1100 like real S3000 programs.
        let startBlock = blocks[0]
        let totalSize = UInt32(progSize)
        var entryBytes = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
        for (i, b) in nameBytes.enumerated() { entryBytes[i] = b }
        entryBytes[16] = AkaiDiskFormat.ftypeProgram
        entryBytes[17] = UInt8(totalSize & 0xFF)
        entryBytes[18] = UInt8((totalSize >> 8) & 0xFF)
        entryBytes[19] = UInt8((totalSize >> 16) & 0xFF)
        entryBytes[20] = UInt8(startBlock & 0xFF)
        entryBytes[21] = UInt8((startBlock >> 8) & 0xFF)
        entryBytes[22] = 0x00; entryBytes[23] = 0x11   // osver 0x1100 (v17.00)
        data.replaceSubrange(dirSlot..<dirSlot + AkaiDiskFormat.dirEntrySize, with: entryBytes)

        // Commit to in-memory image + model.
        imageData = data
        freeBlocks = countFreeBlocks(data: data)

        let dirEntry = AkaiDirectoryEntry(
            name: name, fileType: AkaiDiskFormat.ftypeProgram,
            startBlock: UInt16(startBlock), size: totalSize,
            rawEntry: entryBytes, diskOffset: dirSlot)
        let program = AkaiProgram(name: name, keyzones: [],
            midiChannel: 0, polyphony: 16, bendRange: 0, rawData: file)
        let progFile = AkaiProgramFile(directoryEntry: dirEntry, program: program,
                                       offset: startBlock * bs)
        programs.append(progFile)
        hasUnsavedChanges = true
        return progFile
    }

    // MARK: - WAV Export

    func exportSampleAsWAV(sample: AkaiSample) throws -> Data {
        return buildWAV(pcmData: sample.audioData, sampleRate: sample.header.sampleRate,
                        numChannels: UInt16(max(1, sample.header.numChannels)), bitsPerSample: 16)
    }

    private func buildWAV(pcmData: Data, sampleRate: UInt32, numChannels: UInt16, bitsPerSample: UInt16) -> Data {
        var wav = Data()
        let byteRate   = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize   = UInt32(pcmData.count)
        wav.append(contentsOf: "RIFF".utf8); wav.appendLE32(36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); wav.appendLE32(16)
        wav.appendLE16(1); wav.appendLE16(numChannels)
        wav.appendLE32(sampleRate); wav.appendLE32(byteRate)
        wav.appendLE16(blockAlign); wav.appendLE16(bitsPerSample)
        wav.append(contentsOf: "data".utf8); wav.appendLE32(dataSize)
        wav.append(pcmData)
        return wav
    }

    // MARK: - WAV Import

    /// Parse an audio file and add it to the disk with real block allocation and
    /// a directory entry (so it persists on Save). Stereo files are split into two
    /// mono samples named "<base>-L" and "<base>-R", matching how the S3000
    /// hardware stores stereo (as a pair of mono samples). Returns the first
    /// sample added (the -L part for stereo, or the single sample for mono).
    @discardableResult
    func importAndAddSample(from url: URL) throws -> AkaiSample {
        let wavData = try Data(contentsOf: url)
        let (pcmData, sampleRate, numChannels, _) = try parseWAV(wavData)
        let baseName = Self.sanitizeName(url.deletingPathExtension().lastPathComponent)

        // Pre-check total space so we don't half-import a stereo pair (or fail
        // after partially writing). 1 block = 1 KB on the Akai HD floppy.
        let bs = AkaiDiskFormat.blockSize
        let headerSize = AkaiDiskFormat.sampleHeaderSize
        func blocksFor(_ audioBytes: Int) -> Int { (headerSize + audioBytes + bs - 1) / bs }
        let perChannelBytes = pcmData.count / max(1, numChannels)
        let blocksRequired = numChannels >= 2
            ? 2 * blocksFor(perChannelBytes)        // -L and -R
            : blocksFor(pcmData.count)
        if blocksRequired > freeBlockCount {
            throw AkaiError.diskFull("Not enough space on the disk! This sample needs \(blocksRequired) KB but only \(freeBlockCount) KB is free.")
        }

        if numChannels >= 2 {
            // De-interleave to two mono channels (use channels 0 and 1).
            let (left, right) = Self.deinterleaveStereo(pcmData, channels: numChannels)
            // Base clamped to 10 chars so the -L/-R suffix fits within 12.
            let stem = String(baseName.prefix(10))
            let l = try addImportedSample(name: "\(stem)-L", sampleRate: UInt32(sampleRate),
                                          numChannels: 1, pcmData: left)
            _ = try addImportedSample(name: "\(stem)-R", sampleRate: UInt32(sampleRate),
                                      numChannels: 1, pcmData: right)
            return l
        }

        return try addImportedSample(name: baseName, sampleRate: UInt32(sampleRate),
                                     numChannels: 1, pcmData: pcmData)
    }

    /// Split interleaved 16-bit PCM into two mono 16-bit buffers (left, right).
    /// Only the first two channels are used; any extra channels are ignored.
    static func deinterleaveStereo(_ pcm: Data, channels: Int) -> (Data, Data) {
        let bytesPerSample = 2
        let frameBytes = channels * bytesPerSample
        guard frameBytes > 0 else { return (Data(), Data()) }
        let frames = pcm.count / frameBytes
        var left  = Data(capacity: frames * bytesPerSample)
        var right = Data(capacity: frames * bytesPerSample)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for f in 0..<frames {
                let base = f * frameBytes
                // Left = channel 0, Right = channel 1.
                left.append(raw[base]);     left.append(raw[base + 1])
                right.append(raw[base + 2]); right.append(raw[base + 3])
            }
        }
        return (left, right)
    }

    // MARK: - Add Imported Sample (allocate + write-back)

    /// Find `count` free blocks in the FAT. Free-space search starts after the
    /// system/directory region. Returns block numbers, or nil if insufficient.
    private func findFreeBlocks(count: Int, data: Data) -> [Int]? {
        guard count > 0 else { return [] }
        var found: [Int] = []
        for block in AkaiDiskFormat.volDirStartBlock..<AkaiDiskFormat.totalBlocks {
            if fatValue(block: block, data: data) == AkaiDiskFormat.fatFree {
                found.append(block)
                if found.count == count { return found }
            }
        }
        return nil
    }

    /// Find a free 24-byte slot in the volume directory (first slot whose type
    /// byte is 0x00). Returns its byte offset, or nil if the directory is full.
    private func findFreeDirectorySlot(data: Data) -> Int? {
        let dirStart  = AkaiDiskFormat.volDirStartBlock * AkaiDiskFormat.blockSize
        let entrySize = AkaiDiskFormat.dirEntrySize
        for i in 0..<AkaiDiskFormat.volDirEntryCount {
            let base = dirStart + i * entrySize
            guard base + entrySize <= data.count else { return nil }
            if data[base + 16] == 0x00 { return base }
        }
        return nil
    }

    /// Build a 0xC0 (192-byte) S3000 sample header from scratch, matching the
    /// canonical akai_sample3000_s layout exactly (no gw-compat mirrors).
    ///
    /// IMPORTANT: we never clone an existing sample's header. Cloning drags in
    /// sampler-managed fields — locat (0x16) and the stereo-partner pointer
    /// stpaira (0x88) — that point at the WRONG sample and make the hardware
    /// start loading, show the name, then stop. Hand-building every time
    /// produces a byte-perfect header with no stale state.
    private func buildSampleHeader(name: String, sampleRate: UInt32, numSamples: UInt32,
                                   rootNote: UInt8) -> Data {
        var hdr = Data(repeating: 0, count: AkaiDiskFormat.sampleHeaderSize)  // 0xC0

        hdr[0x00] = 0x03            // blockid (SAMPLE1000_BLOCKID)
        hdr[0x01] = 0x01            // bandw = 20kHz
        hdr[0x02] = rootNote        // rkey
        let nameBytes = akaiBytes(from: name, length: 12)
        for (i, b) in nameBytes.enumerated() { hdr[AkaiDiskFormat.hdrNameOffset + i] = b }
        hdr[0x0F] = 0x80            // dummy1 (canonical constant)
        hdr[0x10] = 0x00           // lnum = 0 loops
        hdr[0x13] = 0x02           // pmode = NOLOOP by default
        hdr[0x14] = 0x00           // ctune
        hdr[0x15] = 0x00           // stune

        // slen[4] @ 0x1A — number of samples (THE count the Akai reads).
        hdr[0x1A] = UInt8(numSamples & 0xFF)
        hdr[0x1B] = UInt8((numSamples >> 8) & 0xFF)
        hdr[0x1C] = UInt8((numSamples >> 16) & 0xFF)
        hdr[0x1D] = UInt8((numSamples >> 24) & 0xFF)
        // start[4] @ 0x1E = 0, end[4] @ 0x22 = numSamples-1 (last sample index).
        let endMarker = numSamples > 0 ? numSamples - 1 : 0
        hdr[0x22] = UInt8(endMarker & 0xFF)
        hdr[0x23] = UInt8((endMarker >> 8) & 0xFF)
        hdr[0x24] = UInt8((endMarker >> 16) & 0xFF)
        hdr[0x25] = UInt8((endMarker >> 24) & 0xFF)

        // stpaira[2] @ 0x88 = 0xFFFF (none) — canonical AKAI_SAMPLE1000_STPAIRA_NONE.
        hdr[AkaiDiskFormat.hdrStPairOffset]     = 0xFF
        hdr[AkaiDiskFormat.hdrStPairOffset + 1] = 0xFF
        // srate[2] @ 0x8A.
        let sr16 = UInt16(min(sampleRate, 65535))
        hdr[AkaiDiskFormat.hdrSampleRateOffset]     = UInt8(sr16 & 0xFF)
        hdr[AkaiDiskFormat.hdrSampleRateOffset + 1] = UInt8(sr16 >> 8)

        // locat (0x16) and the loop array (0x26..0x85) stay zero — sampler-managed
        // / no loop. pad to 0xC0 stays zero.
        return hdr
    }

    /// Allocate space and write a freshly imported sample into the disk image:
    /// builds a valid header, finds free FAT blocks, chains them, writes
    /// header+audio, and creates a directory entry. Updates in-memory image and
    /// model and sets hasUnsavedChanges (persist via Save).
    @discardableResult
    func addImportedSample(name rawName: String, sampleRate: UInt32,
                           numChannels: Int, pcmData: Data) throws -> AkaiSample {
        guard var data = imageData else { throw AkaiError.noImageLoaded }

        let name = Self.sanitizeName(rawName.isEmpty ? "NEW SAMPLE" : rawName)
        let numSamples = UInt32(pcmData.count) / UInt32(max(1, numChannels)) / 2
        let header = buildSampleHeader(name: name, sampleRate: sampleRate,
                                       numSamples: numSamples, rootNote: 60)

        let fileBytes = header.count + pcmData.count
        let bs = AkaiDiskFormat.blockSize
        let blocksNeeded = (fileBytes + bs - 1) / bs

        guard let blocks = findFreeBlocks(count: blocksNeeded, data: data) else {
            throw AkaiError.dataError("Not enough free space on disk for this sample")
        }
        guard let dirSlot = findFreeDirectorySlot(data: data) else {
            throw AkaiError.dataError("Disk directory is full")
        }

        // 1. Chain allocated blocks in the FAT (last = end-of-chain).
        for i in 0..<blocks.count {
            let value: UInt16 = (i == blocks.count - 1)
                ? AkaiDiskFormat.fatEnd
                : UInt16(blocks[i + 1])
            setFatValue(block: blocks[i], value: value, data: &data)
        }

        // 2. Write header+audio across the chain, zero-padding the last block.
        let fileData = header + pcmData
        for (i, block) in blocks.enumerated() {
            let srcStart = i * bs
            let srcEnd   = min(srcStart + bs, fileData.count)
            let dstStart = block * bs
            guard dstStart + bs <= data.count else {
                throw AkaiError.dataError("Block out of range while writing sample")
            }
            let chunk = fileData[srcStart..<srcEnd]
            let padded = chunk + Data(repeating: 0, count: bs - (srcEnd - srcStart))
            data.replaceSubrange(dstStart..<dstStart + bs, with: padded)
        }

        // 3. Write the 24-byte directory entry.
        let startBlock = blocks[0]
        let totalSize  = UInt32(fileBytes)
        var entryBytes = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
        let nameBytes = akaiBytes(from: name, length: 12)
        for (i, b) in nameBytes.enumerated() { entryBytes[i] = b }
        entryBytes[16] = AkaiDiskFormat.ftypeSample
        entryBytes[17] = UInt8(totalSize & 0xFF)
        entryBytes[18] = UInt8((totalSize >> 8) & 0xFF)
        entryBytes[19] = UInt8((totalSize >> 16) & 0xFF)
        entryBytes[20] = UInt8(startBlock & 0xFF)
        entryBytes[21] = UInt8((startBlock >> 8) & 0xFF)
        data.replaceSubrange(dirSlot..<dirSlot + AkaiDiskFormat.dirEntrySize, with: entryBytes)

        // 4. Commit to in-memory image + model.
        imageData = data
        freeBlocks = countFreeBlocks(data: data)

        let dirEntry = AkaiDirectoryEntry(
            name: name, fileType: AkaiDiskFormat.ftypeSample,
            startBlock: UInt16(startBlock), size: totalSize,
            rawEntry: entryBytes, diskOffset: dirSlot)
        let hdrModel = AkaiSampleHeader(
            name: name, sampleRate: sampleRate, loopStart: 0,
            loopEnd: numSamples > 0 ? numSamples - 1 : 0, numSamples: numSamples,
            midiRootNote: 60, loopEnabled: false, bitDepth: 16,
            numChannels: numChannels, fineTune: 0, semitoneTune: 0, loudness: 99, rawHeader: header)
        let sample = AkaiSample(
            directoryEntry: dirEntry, header: hdrModel, audioData: pcmData,
            offset: startBlock * bs)

        samples.append(sample)
        hasUnsavedChanges = true
        return sample
    }

    /// Number of free (unallocated) blocks currently available on the disk.
    var freeBlockCount: Int {
        guard let data = imageData else { return 0 }
        return countFreeBlocks(data: data)
    }

    // MARK: - Block Map (Disk Info visualization)

    enum DiskBlockKind: Equatable {
        case system
        case free
        case sample(name: String)
        case program(name: String)
    }

    /// Build a complete map of what owns every block on the disk, for the Disk
    /// Info "map" visualization. Walks the REAL FAT chain for every sample and
    /// program (not just startBlock + size), so fragmentation shows accurately —
    /// a sample's blocks may not be contiguous if space was reused after a delete.
    func blockMap() -> [DiskBlockKind] {
        guard let data = imageData else { return [] }
        var map = [DiskBlockKind](repeating: .free, count: AkaiDiskFormat.totalBlocks)

        // System region: 5 header blocks + 12 volume-directory blocks = 17.
        let systemBlocks = AkaiDiskFormat.volDirStartBlock
            + (AkaiDiskFormat.volDirEntryCount * AkaiDiskFormat.dirEntrySize + AkaiDiskFormat.blockSize - 1)
            / AkaiDiskFormat.blockSize
        for b in 0..<min(systemBlocks, map.count) { map[b] = .system }

        for sample in samples {
            let name = sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name
            let allEntries = [sample.directoryEntry] + sample.additionalEntries
            for entry in allEntries {
                let chain = fatChain(from: Int(entry.startBlock), data: data)
                for b in chain where b >= 0 && b < map.count { map[b] = .sample(name: name) }
            }
        }
        for prog in programs {
            let name = prog.program.name.isEmpty ? prog.directoryEntry.name : prog.program.name
            let chain = fatChain(from: Int(prog.directoryEntry.startBlock), data: data)
            for b in chain where b >= 0 && b < map.count { map[b] = .program(name: name) }
        }
        return map
    }

    /// How many blocks a sample occupies (header + audio), i.e. how many a clone
    /// of it would need.
    func blocksNeeded(for sample: AkaiSample) -> Int {
        let bytes = AkaiDiskFormat.sampleHeaderSize + sample.audioData.count
        return (bytes + AkaiDiskFormat.blockSize - 1) / AkaiDiskFormat.blockSize
    }

    /// Generate a unique 12-char Akai sample name based on `base`, avoiding any
    /// name already present in the directory. Tries "<base> 2", "<base> 3", …,
    /// trimming the base so the suffix fits within 12 characters.
    private func uniqueSampleName(basedOn base: String) -> String {
        let existing = Set(samples.map { $0.header.name })
        let cleanBase = Self.sanitizeName(base)
        for n in 2...999 {
            let suffix = " \(n)"
            let room = 12 - suffix.count
            let candidate = Self.sanitizeName(String(cleanBase.prefix(room)) + suffix)
            if !existing.contains(candidate) { return candidate }
        }
        return Self.sanitizeName(String(cleanBase.prefix(10)) + " X")
    }

    /// Duplicate an existing sample into a new sample on the disk, carrying over
    /// all of its settings (root note, fine/semitone tune, loop). The clone gets
    /// fresh blocks, a fresh directory entry, and a unique name. Does not write to
    /// disk immediately — persist via Save. Returns the new sample.
    @discardableResult
    func cloneSample(id: UUID) throws -> AkaiSample {
        guard let src = samples.first(where: { $0.id == id }) else {
            throw AkaiError.dataError("Sample to clone not found")
        }
        let newName = uniqueSampleName(basedOn: src.header.name)

        // Allocate + write a new mono sample with the source's audio and rate.
        var clone = try addImportedSample(name: newName,
                                          sampleRate: src.header.sampleRate,
                                          numChannels: 1,
                                          pcmData: src.audioData)

        // Carry over the editable settings, then commit them to the new header.
        clone.header.midiRootNote = src.header.midiRootNote
        clone.header.fineTune     = src.header.fineTune
        clone.header.semitoneTune = src.header.semitoneTune
        clone.header.loopEnabled  = src.header.loopEnabled
        clone.header.loopStart    = src.header.loopStart
        clone.header.loopEnd      = src.header.loopEnd
        applySampleEdits(clone)

        // applySampleEdits updated the stored copy; return the current version.
        return samples.first(where: { $0.id == clone.id }) ?? clone
    }

    private func parseWAV(_ data: Data) throws -> (Data, Int, Int, Int) {
        guard data.count > 44, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw AkaiError.dataError("Not a valid WAV file")
        }
        var offset = 12, sampleRate = 44100, numChannels = 1, bitsPerSample = 16
        var pcmData = Data()
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(data.readLE32(at: offset + 4))
            offset += 8
            if id == "fmt " {
                numChannels = Int(data.readLE16(at: offset + 2))
                sampleRate  = Int(data.readLE32(at: offset + 4))
                bitsPerSample = Int(data.readLE16(at: offset + 14))
            } else if id == "data" {
                pcmData = data.subdata(in: offset..<min(offset + size, data.count))
            }
            offset += size + (size % 2)
        }
        guard !pcmData.isEmpty else { throw AkaiError.dataError("No audio data in WAV") }
        return (pcmData, sampleRate, numChannels, bitsPerSample)
    }

    // MARK: - Delete

    /// Remove a sample both from the in-memory list AND from the disk image:
    /// blanks its directory entry/entries (so it no longer shows up on a real Akai)
    /// and frees every block in its FAT chain(s) so the space can be reused.
    /// Does not write to disk immediately — call saveImageToDisk() (or the global
    /// Save button) afterwards to persist this to the .img file.
    func deleteSample(id: UUID) {
        guard let sample = samples.first(where: { $0.id == id }) else { return }
        guard var data = imageData else {
            samples.removeAll { $0.id == id }
            return
        }

        let allEntries = [sample.directoryEntry] + sample.additionalEntries
        for entry in allEntries {
            // Free the FAT chain for this part
            freeChain(from: Int(entry.startBlock), data: &data)

            // Blank the directory entry on disk so it's no longer recognised as a file.
            // Zero the whole 24-byte slot (name + type + size + start + osver).
            if entry.diskOffset >= 0,
               entry.diskOffset + AkaiDiskFormat.dirEntrySize <= data.count {
                let blank = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
                data.replaceSubrange(entry.diskOffset..<entry.diskOffset + AkaiDiskFormat.dirEntrySize, with: blank)
            }
        }

        imageData = data
        freeBlocks = countFreeBlocks(data: data)
        samples.removeAll { $0.id == id }
        hasUnsavedChanges = true
    }

    /// Delete several samples at once. Frees each sample's FAT chain(s) and blanks
    /// its directory entry/entries, then removes them from the in-memory list.
    /// Does not write to disk — call saveImageToDisk() afterwards to persist.
    func deleteSamples(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        guard var data = imageData else {
            samples.removeAll { ids.contains($0.id) }
            return
        }
        let targets = samples.filter { ids.contains($0.id) }
        for sample in targets {
            let allEntries = [sample.directoryEntry] + sample.additionalEntries
            for entry in allEntries {
                freeChain(from: Int(entry.startBlock), data: &data)
                if entry.diskOffset >= 0,
                   entry.diskOffset + AkaiDiskFormat.dirEntrySize <= data.count {
                    let blank = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
                    data.replaceSubrange(entry.diskOffset..<entry.diskOffset + AkaiDiskFormat.dirEntrySize, with: blank)
                }
            }
        }
        imageData = data
        freeBlocks = countFreeBlocks(data: data)
        samples.removeAll { ids.contains($0.id) }
        hasUnsavedChanges = true
    }

    /// Remove a program both from the in-memory list AND from the disk image:
    /// blanks its directory entry and frees every block in its FAT chain so the
    /// space can be reused. Does not write to disk immediately — call
    /// saveImageToDisk() (or the global Save button) afterwards to persist.
    func deleteProgram(id: UUID) {
        guard let program = programs.first(where: { $0.id == id }) else { return }
        guard var data = imageData else {
            programs.removeAll { $0.id == id }
            return
        }
        freeChain(from: Int(program.directoryEntry.startBlock), data: &data)
        let entry = program.directoryEntry
        if entry.diskOffset >= 0, entry.diskOffset + AkaiDiskFormat.dirEntrySize <= data.count {
            let blank = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
            data.replaceSubrange(entry.diskOffset..<entry.diskOffset + AkaiDiskFormat.dirEntrySize, with: blank)
        }
        imageData = data
        freeBlocks = countFreeBlocks(data: data)
        programs.removeAll { $0.id == id }
        hasUnsavedChanges = true
    }

    /// Delete several programs at once, mirroring deleteSamples. Does not write
    /// to disk — call saveImageToDisk() afterwards to persist.
    func deletePrograms(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        guard var data = imageData else {
            programs.removeAll { ids.contains($0.id) }
            return
        }
        let targets = programs.filter { ids.contains($0.id) }
        for program in targets {
            freeChain(from: Int(program.directoryEntry.startBlock), data: &data)
            let entry = program.directoryEntry
            if entry.diskOffset >= 0, entry.diskOffset + AkaiDiskFormat.dirEntrySize <= data.count {
                let blank = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
                data.replaceSubrange(entry.diskOffset..<entry.diskOffset + AkaiDiskFormat.dirEntrySize, with: blank)
            }
        }
        imageData = data
        freeBlocks = countFreeBlocks(data: data)
        programs.removeAll { ids.contains($0.id) }
        hasUnsavedChanges = true
    }

    /// Build a blank but VALID Akai S3000 HD floppy image (1600 blocks) and load
    /// it. Structure verified byte-for-byte against a real Greaseweazle-formatted
    /// disk: floppy-header file[64] with the 0xFF volume flag in slot 0, FAT with
    /// the 17 system blocks (header + 12 voldir blocks) marked 0x4000 and the rest
    /// free, an empty volume directory at block 5, and an optional volume label.
    /// Writes the file to `url`, then loads it as the active image.
    func createBlankImage(at url: URL, volumeName: String = "VOLUME") throws {
        let bs = AkaiDiskFormat.blockSize
        let total = AkaiDiskFormat.totalBlocks * bs
        var data = Data(repeating: 0, count: total)

        // --- Floppy header file[64] (block 0) ---
        // Each 24-byte entry: 12 spaces + tag(0000040b) + type + 6 zero + osver(0011).
        // Slot 0 carries the S3000 volume flag (type 0xFF); slots 1..63 are 0x00.
        let spaces: [UInt8] = Array(repeating: 0x20, count: 12)
        for i in 0..<AkaiDiskFormat.dirEntryCount {
            let base = i * AkaiDiskFormat.dirEntrySize
            for (j, b) in spaces.enumerated() { data[base + j] = b }
            data[base + 12] = 0x00; data[base + 13] = 0x00
            data[base + 14] = 0x04; data[base + 15] = 0x0b   // tag
            data[base + 16] = (i == 0) ? 0xFF : 0x00          // type: volume flag in slot 0
            // bytes 17..21 stay zero
            data[base + 22] = 0x00; data[base + 23] = 0x11    // osver 0x1100
        }

        // --- FAT (at 0x600): system blocks 0..16 = 0x4000, rest = 0x0000 (free) ---
        // 17 system blocks = 5 header blocks + 12 volume-directory blocks.
        let systemBlocks = AkaiDiskFormat.volDirStartBlock
            + (AkaiDiskFormat.volDirEntryCount * AkaiDiskFormat.dirEntrySize + bs - 1) / bs  // 5 + 12 = 17
        for block in 0..<systemBlocks {
            setFatValue(block: block, value: AkaiDiskFormat.fatSystem, data: &data)
        }
        // Remaining blocks already 0x0000 (free).

        // --- Volume label (akai_flvol_label_s name field at 0xD80) ---
        let labelBytes = akaiBytes(from: Self.sanitizeName(volumeName), length: 12)
        let labelOffset = 0xD80
        if labelOffset + 12 <= data.count {
            for (i, b) in labelBytes.enumerated() { data[labelOffset + i] = b }
        }

        // Volume directory at block 5 is already all-zero (empty slots).

        try data.write(to: url, options: .atomic)
        try load(from: url)
    }

    func saveImageToDisk() throws {
        guard let data = imageData, let url = imageURL else {
            throw AkaiError.noImageLoaded
        }
        try data.write(to: url, options: .atomic)
        hasUnsavedChanges = false
    }

    /// Rename the disk's volume label (akai_flvol_label_s.name @ absolute 0xD80).
    /// Patches the in-memory image only — persist via Save, matching every other
    /// edit in the app. Used by the sidebar's click-to-edit volume name.
    @discardableResult
    func renameVolume(to newName: String) throws -> String {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        let clean = Self.sanitizeName(newName)
        let labelOffset = 0xD80
        guard labelOffset + 12 <= data.count else {
            throw AkaiError.dataError("Disk image too small for a volume label")
        }
        let labelBytes = akaiBytes(from: clean, length: 12)
        data.replaceSubrange(labelOffset..<labelOffset + 12, with: labelBytes)
        imageData = data
        diskName = clean
        hasUnsavedChanges = true
        return clean
    }

    // MARK: - Write Back

    /// Patch a sample's header into the in-memory image (imageData) WITHOUT
    /// writing the file. Used so edits are reflected in imageData immediately and
    /// picked up by a later Save All (saveImageToDisk). Updates the samples model
    /// too. Returns silently if no image is loaded.
    func applySampleEdits(_ sample: AkaiSample) {
        guard var data = imageData else { return }
        var hdr = sample.header.rawHeader
        guard hdr.count >= AkaiDiskFormat.sampleHeaderSize else { return }
        hdr[0x02] = sample.header.midiRootNote
        hdr[0x13] = sample.header.loopEnabled ? 0x00 : 0x02
        hdr[0x14] = UInt8(bitPattern: sample.header.fineTune)
        hdr[0x15] = UInt8(bitPattern: sample.header.semitoneTune)
        let ls = sample.header.loopStart
        hdr[0x26] = UInt8(ls & 0xFF); hdr[0x27] = UInt8((ls >> 8) & 0xFF)
        hdr[0x28] = UInt8((ls >> 16) & 0xFF); hdr[0x29] = UInt8((ls >> 24) & 0xFF)
        let loopLen = sample.header.loopEnd > sample.header.loopStart
            ? sample.header.loopEnd - sample.header.loopStart : 0
        hdr[0x2C] = UInt8(loopLen & 0xFF); hdr[0x2D] = UInt8((loopLen >> 8) & 0xFF)
        hdr[0x2E] = UInt8((loopLen >> 16) & 0xFF); hdr[0x2F] = UInt8((loopLen >> 24) & 0xFF)

        let chain = fatChain(from: sample.offset / AkaiDiskFormat.blockSize, data: data)
        let bs = AkaiDiskFormat.blockSize
        let headerSize = AkaiDiskFormat.sampleHeaderSize
        // Only the header region needs patching (audio is unchanged).
        for (i, block) in chain.enumerated() {
            let blockStart = i * bs
            guard blockStart < headerSize else { break }
            let copyEnd = min(blockStart + bs, headerSize)
            let dstStart = block * bs
            let slice = hdr[blockStart..<copyEnd]
            guard dstStart + slice.count <= data.count else { break }
            data.replaceSubrange(dstStart..<dstStart + slice.count, with: slice)
        }
        imageData = data

        var updated = sample
        updated.header.rawHeader = hdr
        if let index = samples.firstIndex(where: { $0.id == sample.id }) {
            samples[index] = updated
        }
        hasUnsavedChanges = true
    }

    /// Patch a raw sample header with correct S1000/S3000 offsets and write to disk.
    /// Struct: akai_sample1000_s (from akaiutil_file.h)
    ///   0x02: rkey (root MIDI note)
    ///   0x13: pmode (0=loop, 2=noloop)
    ///   0x14: ctune (cents tune, signed)
    ///   0x15: stune (semitone tune, signed)
    ///   0x26: loop[0].at (loop start, 32-bit LE)
    ///   0x2C: loop[0].len (loop length = end - start, 32-bit LE)
    func writeSampleToImage(sample: AkaiSample) throws {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        var hdr = sample.header.rawHeader
        guard hdr.count >= AkaiDiskFormat.sampleHeaderSize else {
            throw AkaiError.dataError("Header too short to patch")
        }
        // Root key
        hdr[0x02] = sample.header.midiRootNote
        // Playback mode: 0=loop, 2=noloop
        hdr[0x13] = sample.header.loopEnabled ? 0x00 : 0x02
        // Cents tune (signed)
        hdr[0x14] = UInt8(bitPattern: sample.header.fineTune)
        // Semitone tune (signed)
        hdr[0x15] = UInt8(bitPattern: sample.header.semitoneTune)
        // Loop start (loop[0].at) — 32-bit LE at 0x26
        let ls = sample.header.loopStart
        hdr[0x26] = UInt8(ls & 0xFF)
        hdr[0x27] = UInt8((ls >> 8) & 0xFF)
        hdr[0x28] = UInt8((ls >> 16) & 0xFF)
        hdr[0x29] = UInt8((ls >> 24) & 0xFF)
        // Loop length = end - start (loop[0].len) — 32-bit LE at 0x2C
        let loopLen = sample.header.loopEnd > sample.header.loopStart
            ? sample.header.loopEnd - sample.header.loopStart : 0
        hdr[0x2C] = UInt8(loopLen & 0xFF)
        hdr[0x2D] = UInt8((loopLen >> 8) & 0xFF)
        hdr[0x2E] = UInt8((loopLen >> 16) & 0xFF)
        hdr[0x2F] = UInt8((loopLen >> 24) & 0xFF)
        // Loudness is per-keygroup in S3000, not in sample header — skip for now

        let chain = fatChain(from: sample.offset / AkaiDiskFormat.blockSize, data: data)
        let fileData = hdr + sample.audioData
        let bs = AkaiDiskFormat.blockSize
        for (i, block) in chain.enumerated() {
            let srcStart = i * bs; guard srcStart < fileData.count else { break }
            let srcEnd = min(srcStart + bs, fileData.count)
            let dstStart = block * bs
            data.replaceSubrange(dstStart..<dstStart+bs,
                                 with: fileData[srcStart..<srcEnd] + Data(repeating: 0, count: bs-(srcEnd-srcStart)))
        }
        imageData = data

        // Reflect the patched header back into the in-memory model so the UI and
        // any later save use the up-to-date loop/root/tune values (not the stale
        // pre-edit header).
        var updated = sample
        updated.header.rawHeader = hdr
        if let index = samples.firstIndex(where: { $0.id == sample.id }) {
            samples[index] = updated
        }

        guard let url = imageURL else { throw AkaiError.noImageLoaded }
        try data.write(to: url, options: .atomic)
        hasUnsavedChanges = false
    }

    func updateProgramInImage(programFile: AkaiProgramFile) throws {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        var fileData = programFile.program.rawData
        let nameBytes = akaiBytes(from: programFile.program.name, length: 12)
        for (i, b) in nameBytes.enumerated() { fileData[i] = b }
        if fileData.count > 0x0C { fileData[0x0C] = programFile.program.midiChannel }
        if fileData.count > 0x0D { fileData[0x0D] = programFile.program.polyphony }
        if fileData.count > 0x0E { fileData[0x0E] = programFile.program.bendRange }
        let chain = fatChain(from: programFile.offset / AkaiDiskFormat.blockSize, data: data)
        let bs = AkaiDiskFormat.blockSize
        for (i, block) in chain.enumerated() {
            let srcStart = i * bs; guard srcStart < fileData.count else { break }
            let srcEnd = min(srcStart + bs, fileData.count)
            let dstStart = block * bs
            data.replaceSubrange(dstStart..<dstStart+bs,
                                 with: fileData[srcStart..<srcEnd] + Data(repeating: 0, count: bs-(srcEnd-srcStart)))
        }
        imageData = data
        if let url = imageURL { try data.write(to: url) }
        hasUnsavedChanges = false
    }

    // MARK: - Akai Character Encoding
    // Confirmed S1000/S3000 encoding from akaiutil source (github.com/Midi-In/akaiutil):
    //   0-9   → '0'-'9'
    //   10    → ' ' (space)
    //   11-36 → 'A'-'Z'
    //   37    → '#', 38 → '+', 39 → '-', 40 → '.'

    private func akaiString(from data: Data, offset: Int, length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let str = data[offset..<offset+length].compactMap { byte -> Character? in
            switch byte {
            case 0:       return nil
            case 1...9:   return Character(UnicodeScalar(UInt32("0".unicodeScalars.first!.value) + UInt32(byte))!)
            case 10:      return " "
            case 11...36: return Character(UnicodeScalar(UInt32("A".unicodeScalars.first!.value) + UInt32(byte) - 11)!)
            case 37:      return "#"
            case 38:      return "+"
            case 39:      return "-"
            case 40:      return "."
            default:      return nil
            }
        }
        return String(str).trimmingCharacters(in: .whitespaces)
    }

    /// Encode a string into Akai S1000/S3000 character codes (inverse of akaiString).
    /// Unsupported characters are converted to space (10). Pads to `length` with
    /// the Akai space code (10), NOT ASCII 0x20.
    func akaiBytes(from string: String, length: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for ch in string.uppercased() {
            if bytes.count >= length { break }
            bytes.append(Self.akaiCode(for: ch))
        }
        while bytes.count < length { bytes.append(10) }  // Akai space
        return bytes
    }

    /// Map a single character to its Akai code. Returns 10 (space) for anything
    /// not representable in the Akai character set.
    static func akaiCode(for ch: Character) -> UInt8 {
        switch ch {
        case "0"..."9":
            return UInt8(ch.asciiValue! - Character("0").asciiValue!)
        case "A"..."Z":
            return UInt8(ch.asciiValue! - Character("A").asciiValue!) + 11
        case " ": return 10
        case "#": return 37
        case "+": return 38
        case "-": return 39
        case ".": return 40
        default:  return 10
        }
    }

    /// The set of characters an Akai name can contain, for UI validation/filtering.
    static let allowedNameCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 #+-.")

    /// Sanitize a user-entered name: uppercase, keep only representable characters,
    /// clamp to 12 characters.
    static func sanitizeName(_ raw: String) -> String {
        let upper = raw.uppercased()
        let filtered = upper.filter { allowedNameCharacters.contains($0) }
        return String(filtered.prefix(12))
    }

    // MARK: - Program Edits

    /// Build a complete S3000 program file from scratch: the 0xC0 header
    /// followed by exactly max(1, keyzones.count) 0xC0 keygroups, with kgnum
    /// (0x2A) always set to match the real keygroup count. A real S3000 reports
    /// "bad disk program" if kgnum disagrees with what's actually stored, or if
    /// fields are written outside their real struct offsets — so this always
    /// rebuilds the whole file rather than patching bytes in place.
    private func buildProgramFileData(name: String, midiChannel: UInt8, bendRange: UInt8,
                                      keyzones: [AkaiProgramKeyzone]) -> Data {
        let kgCount = keyzones.count
        let progSize = 0xC0 + kgCount * 0xC0
        var file = Data(repeating: 0, count: progSize)

        file[0x00] = 0x01                         // blockid
        let nameBytes = akaiBytes(from: name, length: 12)
        for (i, b) in nameBytes.enumerated() { file[0x03 + i] = b }
        // midich1 @ 0x10: on-disk 0xFF = Omni, 0...15 = channel (0-indexed).
        // UI is 0 = Omni, 1...16 = channel (1-indexed) — translate, don't store raw.
        file[0x10] = midiChannel == 0 ? 0xFF : midiChannel - 1
        file[0x13] = 0                            // program-level keylo
        file[0x14] = 127                          // program-level keyhi
        file[0x15] = bendRange                    // oct
        file[0x16] = 0xFF                          // auxch1 = OFF
        file[0x29] = 0                            // kgxf
        file[0x2A] = UInt8(min(255, kgCount))     // kgnum — MUST match real keygroup count

        let kgBase = 0xC0
        let emptyName = akaiBytes(from: "", length: 12)
        for kgi in 0..<kgCount {
            let kg = kgBase + kgi * 0xC0
            file[kg + 0x00] = 0x02                // blockid
            let kz: AkaiProgramKeyzone? = kgi < keyzones.count ? keyzones[kgi] : nil
            file[kg + 0x03] = kz?.lowKey ?? 0
            file[kg + 0x04] = kz?.highKey ?? 127

            for z in 0..<4 {
                let vz = kg + 0x22 + z * 0x18
                if z == 0, let kz = kz {
                    // Velocity zone 1 carries the real keyzone's sample + settings.
                    let snameBytes = akaiBytes(from: kz.sampleName, length: 12)
                    for (i, b) in snameBytes.enumerated() { file[vz + i] = b }
                    file[vz + 0x0C] = kz.velocityLow
                    file[vz + 0x0D] = kz.velocityHigh
                    file[vz + 0x0E] = UInt8(bitPattern: kz.fineTune)    // ctune
                    file[vz + 0x0F] = UInt8(bitPattern: kz.tuneOffset) // stune
                    file[vz + 0x10] = kz.volume                         // loud
                    file[vz + 0x12] = UInt8(bitPattern: kz.pan)
                    file[vz + 0x13] = kz.loopEnabled ? 0x00 : 0x03      // pmode
                    file[vz + 0x16] = 0xFF; file[vz + 0x17] = 0xFF       // shdra = none
                } else {
                    for (i, b) in emptyName.enumerated() { file[vz + i] = b }
                    file[vz + 0x0C] = 0
                    file[vz + 0x0D] = 127
                    file[vz + 0x13] = 0x03
                    file[vz + 0x16] = 0xFF; file[vz + 0x17] = 0xFF
                }
            }
        }
        return file
    }

    /// Rebuild a program's entire file (header + every keygroup) into the
    /// in-memory image WITHOUT writing the file, reallocating FAT blocks (and
    /// updating the directory entry's start/size) if the keygroup count changed
    /// the file's size — the program-detail counterpart to applySampleEdits.
    /// Picked up by a later Save All (saveImageToDisk).
    func applyProgramEdits(_ programFile: AkaiProgramFile) {
        guard var data = imageData else { return }
        let fileData = buildProgramFileData(
            name: programFile.program.name,
            midiChannel: programFile.program.midiChannel,
            bendRange: programFile.program.bendRange,
            keyzones: programFile.program.keyzones)

        let bs = AkaiDiskFormat.blockSize
        let requiredBlocks = (fileData.count + bs - 1) / bs
        let oldStartBlock = programFile.offset / bs
        let oldChain = fatChain(from: oldStartBlock, data: data)

        var startBlock = oldStartBlock
        func writeFile(across chain: [Int]) {
            for (i, block) in chain.enumerated() {
                let srcStart = i * bs
                let dstStart = block * bs
                guard dstStart + bs <= data.count else { break }
                let srcEnd = min(srcStart + bs, fileData.count)
                let chunk = srcStart < fileData.count ? fileData[srcStart..<srcEnd] : Data()
                let padded = chunk + Data(repeating: 0, count: bs - chunk.count)
                data.replaceSubrange(dstStart..<dstStart + bs, with: padded)
            }
        }

        if requiredBlocks == oldChain.count {
            // Same size — reuse the existing chain in place.
            writeFile(across: oldChain)
        } else {
            // The keygroup count changed the file's size — free the old chain
            // and allocate a fresh one of the right length, then update the
            // directory entry's start block + size to match.
            freeChain(from: oldStartBlock, data: &data)
            guard let newBlocks = findFreeBlocks(count: requiredBlocks, data: data) else {
                // Not enough room to grow — leave the disk untouched rather than
                // half-write a corrupt program. The in-memory model still has the
                // attempted edit; it just won't persist until there's space.
                return
            }
            for i in 0..<newBlocks.count {
                let value: UInt16 = (i == newBlocks.count - 1) ? AkaiDiskFormat.fatEnd : UInt16(newBlocks[i + 1])
                setFatValue(block: newBlocks[i], value: value, data: &data)
            }
            writeFile(across: newBlocks)
            startBlock = newBlocks[0]

            let entry = programFile.directoryEntry
            if entry.diskOffset >= 0, entry.diskOffset + AkaiDiskFormat.dirEntrySize <= data.count {
                let totalSize = UInt32(fileData.count)
                data[entry.diskOffset + 17] = UInt8(totalSize & 0xFF)
                data[entry.diskOffset + 18] = UInt8((totalSize >> 8) & 0xFF)
                data[entry.diskOffset + 19] = UInt8((totalSize >> 16) & 0xFF)
                data[entry.diskOffset + 20] = UInt8(startBlock & 0xFF)
                data[entry.diskOffset + 21] = UInt8((startBlock >> 8) & 0xFF)
            }
            freeBlocks = countFreeBlocks(data: data)
        }

        imageData = data

        var updated = programFile
        updated.program.rawData = fileData
        updated.offset = startBlock * bs
        var updatedEntry = programFile.directoryEntry
        updatedEntry.startBlock = UInt16(startBlock)
        updatedEntry.size = UInt32(fileData.count)
        updated.directoryEntry = updatedEntry
        if let index = programs.firstIndex(where: { $0.id == programFile.id }) {
            programs[index] = updated
        }
        hasUnsavedChanges = true
    }

    // MARK: - Rename

    /// Rename a sample everywhere it appears: the sample header (offset 0x03) and
    /// every directory entry that belongs to it (main entry + additionalEntries,
    /// which share the name for multi-part samples). Updates in-memory state and
    /// writes the image to disk. Returns the updated sample.
    @discardableResult
    func renameSample(id: UUID, to newRawName: String) throws -> AkaiSample {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        guard let index = samples.firstIndex(where: { $0.id == id }) else {
            throw AkaiError.dataError("Sample not found")
        }
        let cleanName = Self.sanitizeName(newRawName)
        guard !cleanName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AkaiError.dataError("Name cannot be empty")
        }

        var sample = samples[index]
        let nameBytes = akaiBytes(from: cleanName, length: 12)

        // 1. Patch the 12-byte name in the sample header (header name is at 0x03).
        var hdr = sample.header.rawHeader
        if hdr.count >= AkaiDiskFormat.hdrNameOffset + 12 {
            for (i, b) in nameBytes.enumerated() {
                hdr[AkaiDiskFormat.hdrNameOffset + i] = b
            }
        }
        sample.header.rawHeader = hdr
        sample.header.name = cleanName

        // 2. Write the patched header back into the first block(s) of the sample's chain.
        let chain = fatChain(from: sample.offset / AkaiDiskFormat.blockSize, data: data)
        let bs = AkaiDiskFormat.blockSize
        let headerSize = AkaiDiskFormat.sampleHeaderSize
        for (i, block) in chain.enumerated() {
            let blockStart = i * bs
            // Only the region overlapping the header needs patching.
            guard blockStart < headerSize else { break }
            let copyStart = blockStart
            let copyEnd = min(blockStart + bs, headerSize)
            let dstStart = block * bs + (copyStart - blockStart)
            let slice = hdr[copyStart..<copyEnd]
            guard dstStart + slice.count <= data.count else { break }
            data.replaceSubrange(dstStart..<dstStart + slice.count, with: slice)
        }

        // 3. Blank+rewrite the name field (first 12 bytes) of each directory entry
        //    belonging to this sample.
        var updatedMain = sample.directoryEntry
        var updatedAdditional = sample.additionalEntries
        func patchEntryName(_ entry: inout AkaiDirectoryEntry) {
            guard entry.diskOffset >= 0, entry.diskOffset + 12 <= data.count else { return }
            for (i, b) in nameBytes.enumerated() { data[entry.diskOffset + i] = b }
            entry.name = cleanName
        }
        patchEntryName(&updatedMain)
        for i in updatedAdditional.indices { patchEntryName(&updatedAdditional[i]) }
        sample.directoryEntry = updatedMain
        sample.additionalEntries = updatedAdditional

        // 4. Commit.
        imageData = data
        samples[index] = sample
        if let url = imageURL { try data.write(to: url, options: .atomic) }
        hasUnsavedChanges = false
        return sample
    }

    /// Rename a program: patches the 12-byte name field at the start of its raw
    /// file data (offset 0x03, mirroring the sample header layout) and the
    /// directory entry's name field. Writes to disk immediately, matching
    /// renameSample's behaviour.
    @discardableResult
    func renameProgram(id: UUID, to newRawName: String) throws -> AkaiProgramFile {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        guard let index = programs.firstIndex(where: { $0.id == id }) else {
            throw AkaiError.dataError("Program not found")
        }
        let cleanName = Self.sanitizeName(newRawName)
        guard !cleanName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AkaiError.dataError("Name cannot be empty")
        }

        var progFile = programs[index]
        let nameBytes = akaiBytes(from: cleanName, length: 12)

        // 1. Patch the 12-byte name in the program's raw data (name @ 0x03).
        var fileData = progFile.program.rawData
        if fileData.count >= 0x03 + 12 {
            for (i, b) in nameBytes.enumerated() { fileData[0x03 + i] = b }
        }
        progFile.program.rawData = fileData
        progFile.program.name = cleanName

        // 2. Write the patched data back across the program's FAT chain.
        let chain = fatChain(from: progFile.offset / AkaiDiskFormat.blockSize, data: data)
        let bs = AkaiDiskFormat.blockSize
        for (i, block) in chain.enumerated() {
            let srcStart = i * bs
            guard srcStart < fileData.count else { break }
            let srcEnd = min(srcStart + bs, fileData.count)
            let dstStart = block * bs
            guard dstStart + bs <= data.count else { break }
            data.replaceSubrange(dstStart..<dstStart + bs,
                                 with: fileData[srcStart..<srcEnd] + Data(repeating: 0, count: bs - (srcEnd - srcStart)))
        }

        // 3. Rewrite the directory entry's name field.
        var entry = progFile.directoryEntry
        if entry.diskOffset >= 0, entry.diskOffset + 12 <= data.count {
            for (i, b) in nameBytes.enumerated() { data[entry.diskOffset + i] = b }
            entry.name = cleanName
        }
        progFile.directoryEntry = entry

        // 4. Commit.
        imageData = data
        programs[index] = progFile
        if let url = imageURL { try data.write(to: url, options: .atomic) }
        hasUnsavedChanges = false
        return progFile
    }

    /// Duplicate an existing program into a new program on the disk, carrying
    /// over every setting (MIDI channel, polyphony, bend range, keyzones). The
    /// clone gets fresh blocks, a fresh directory entry, and a unique name. Does
    /// not write to disk immediately — persist via Save. Returns the new program.
    @discardableResult
    func cloneProgram(id: UUID) throws -> AkaiProgramFile {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        guard let src = programs.first(where: { $0.id == id }) else {
            throw AkaiError.dataError("Program to clone not found")
        }
        let newName = uniqueProgramName(basedOn: src.program.name)
        let nameBytes = akaiBytes(from: newName, length: 12)

        // Copy the source's raw file bytes verbatim, then patch in the new name.
        var fileData = src.program.rawData
        if fileData.count >= 0x03 + 12 {
            for (i, b) in nameBytes.enumerated() { fileData[0x03 + i] = b }
        }

        let bs = AkaiDiskFormat.blockSize
        let blocksNeeded = (fileData.count + bs - 1) / bs
        guard let blocks = findFreeBlocks(count: blocksNeeded, data: data) else {
            throw AkaiError.diskFull("Not enough space on the disk to clone this program.")
        }
        guard let dirSlot = findFreeDirectorySlot(data: data) else {
            throw AkaiError.dataError("Disk directory is full")
        }

        // Chain blocks (last = end-of-chain) and write the file data.
        for i in 0..<blocks.count {
            let value: UInt16 = (i == blocks.count - 1) ? AkaiDiskFormat.fatEnd : UInt16(blocks[i + 1])
            setFatValue(block: blocks[i], value: value, data: &data)
        }
        for (i, block) in blocks.enumerated() {
            let srcStart = i * bs
            let srcEnd = min(srcStart + bs, fileData.count)
            let dstStart = block * bs
            guard dstStart + bs <= data.count else { throw AkaiError.dataError("Block out of range") }
            let chunk = fileData[srcStart..<srcEnd]
            let padded = chunk + Data(repeating: 0, count: bs - (srcEnd - srcStart))
            data.replaceSubrange(dstStart..<dstStart + bs, with: padded)
        }

        // Directory entry: type 0xF0 (program), osver 0x1100 like real S3000 programs.
        let startBlock = blocks[0]
        let totalSize = UInt32(fileData.count)
        var entryBytes = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
        for (i, b) in nameBytes.enumerated() { entryBytes[i] = b }
        entryBytes[16] = AkaiDiskFormat.ftypeProgram
        entryBytes[17] = UInt8(totalSize & 0xFF)
        entryBytes[18] = UInt8((totalSize >> 8) & 0xFF)
        entryBytes[19] = UInt8((totalSize >> 16) & 0xFF)
        entryBytes[20] = UInt8(startBlock & 0xFF)
        entryBytes[21] = UInt8((startBlock >> 8) & 0xFF)
        entryBytes[22] = 0x00; entryBytes[23] = 0x11   // osver 0x1100 (v17.00)
        data.replaceSubrange(dirSlot..<dirSlot + AkaiDiskFormat.dirEntrySize, with: entryBytes)

        // Commit to in-memory image + model.
        imageData = data
        freeBlocks = countFreeBlocks(data: data)

        let dirEntry = AkaiDirectoryEntry(
            name: newName, fileType: AkaiDiskFormat.ftypeProgram,
            startBlock: UInt16(startBlock), size: totalSize,
            rawEntry: entryBytes, diskOffset: dirSlot)
        var clonedProgram = src.program
        clonedProgram.name = newName
        clonedProgram.rawData = fileData
        let progFile = AkaiProgramFile(directoryEntry: dirEntry, program: clonedProgram,
                                       offset: startBlock * bs)
        programs.append(progFile)
        hasUnsavedChanges = true
        return progFile
    }
}

// MARK: - Errors

enum AkaiError: LocalizedError {
    case invalidImage(String), dataError(String), noImageLoaded, diskFull(String)
    var errorDescription: String? {
        switch self {
        case .invalidImage(let s): return "Invalid image: \(s)"
        case .dataError(let s):    return "Data error: \(s)"
        case .noImageLoaded:       return "No disk image loaded"
        case .diskFull(let s):     return s
        }
    }
}

// MARK: - Data Extensions

extension Data {
    mutating func appendLE16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
    func readLE16(at i: Int) -> UInt16 {
        guard i+1 < count else { return 0 }
        return UInt16(self[i]) | (UInt16(self[i+1]) << 8)
    }
    func readLE32(at i: Int) -> UInt32 {
        guard i+3 < count else { return 0 }
        return UInt32(self[i]) | (UInt32(self[i+1]) << 8) |
               (UInt32(self[i+2]) << 16) | (UInt32(self[i+3]) << 24)
    }
}
