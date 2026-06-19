import Foundation

// MARK: - Akai S3000 Disk Format Constants
// All confirmed by reverse engineering real S3000 HD floppy disks and cross-referencing
// with the akaiutil open-source project (github.com/Midi-In/akaiutil).
//
// Physical format:  80 cylinders × 2 heads × 10 sectors × 1024 bytes = 1,638,400 bytes
// Audio encoding:   16-bit signed little-endian PCM (same as WAV — no conversion needed)
// Character set:    0-9=digits, 10=space, 11-36=A-Z, 37=#, 38=+, 39=-, 40=.
//
// HD floppy header layout (akai_flhhead_s):
//   Offset 0x000:  file[64]   — 64 directory entries × 24 bytes = 1536 bytes
//   Offset 0x600:  fatblk[1600][2] — FAT, 2 bytes LE per block = 3200 bytes
//   Offset 0xD80:  label (64 bytes)
//   Total: 5 blocks (5120 bytes)
//
// S3000 volume directory:  starts at block 5, 510 entries × 24 bytes
//
// Directory entry format (akai_voldir_entry_s, 24 bytes):
//   [0-11]  name (12 bytes, Akai encoding)
//   [12-15] tag[4]
//   [16]    type  (0xF0=program, 0xF3=sample)
//   [17-19] size  (24-bit LE, bytes)
//   [20-21] start (16-bit LE, block number)
//   [22-23] osver (16-bit LE)
//
// FAT codes:
//   0x0000 = free block
//   0x4000 = system block
//   0xC000 = end of chain (AKAI_FAT_CODE_FILEEND)
//   other  = next block number (16-bit LE)
//
// Sample header (252 bytes = 0xFC):
//   [0x03-0x0E]  name (12 bytes, Akai encoding)
//   [0x22-0x23]  sample rate (16-bit LE) — unreliable on some samples, also check 0x8A
//   [0x58-0x5B]  sample count (32-bit LE)
//   [0x8A-0x8B]  sample rate (16-bit LE) — more reliable location
//   [0xFC]       audio data begins

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

    static let sampleHeaderSize     = 0xFC

    static let hdrNameOffset        = 0x03
    static let hdrSampleCountOffset = 0x58
    // Sample rate scan order — 0x8A is most reliable, 0x22 is the documented location
    static let hdrSampleRateOffsets = [0x8A, 0x22, 0x1A, 0x1C, 0x20, 0x24]
    static let validSampleRates: Set<UInt32> = [11025, 22050, 44100]
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
    var fineTune: Int8
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

    private func parseImage(data: Data) throws {
        let labelOffset = 4 * AkaiDiskFormat.blockSize
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

        return (parsedSamples,
                parsedPrograms.sorted { $0.program.name < $1.program.name })
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

        // Scan known offsets in priority order for a valid sample rate.
        // 0x8A is the most reliable location; 0x22 is documented but unreliable on some samples.
        var sampleRate: UInt32 = 44100
        for off in AkaiDiskFormat.hdrSampleRateOffsets {
            if off + 1 < headerData.count {
                let val = UInt32(headerData[off]) | (UInt32(headerData[off+1]) << 8)
                if AkaiDiskFormat.validSampleRates.contains(val) { sampleRate = val; break }
            }
        }

        let numSamples = UInt32(headerData[AkaiDiskFormat.hdrSampleCountOffset]) |
                         (UInt32(headerData[AkaiDiskFormat.hdrSampleCountOffset+1]) << 8) |
                         (UInt32(headerData[AkaiDiskFormat.hdrSampleCountOffset+2]) << 16) |
                         (UInt32(headerData[AkaiDiskFormat.hdrSampleCountOffset+3]) << 24)

        var audioData = Data()
        for part in parts {
            let chain     = fatChain(from: Int(part.startBlock), data: data)
            let audioSize = Int(part.size) - headerSize
            guard audioSize > 0 else { continue }
            audioData.append(readFromChain(chain, fileOffset: headerSize, length: audioSize, data: data))
        }

        let loopEnabled = headerData[0x13] != 0x02  // pmode: 2 = no loop; any other value loops
        let loopStart = UInt32(headerData[0x26]) | (UInt32(headerData[0x27]) << 8) |
                        (UInt32(headerData[0x28]) << 16) | (UInt32(headerData[0x29]) << 24)
        let loopLen   = UInt32(headerData[0x2C]) | (UInt32(headerData[0x2D]) << 8) |
                        (UInt32(headerData[0x2E]) << 16) | (UInt32(headerData[0x2F]) << 24)
        let loopEnd   = loopLen > 0 ? loopStart + loopLen : (numSamples > 0 ? numSamples - 1 : 0)
        let midiRootNote = headerData[0x02]
        let fineTune = Int8(bitPattern: headerData[0x14])

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
            loudness: 99,
            rawHeader: headerData
        )
        return AkaiSample(directoryEntry: first, header: header, audioData: audioData,
                          offset: startBlock * AkaiDiskFormat.blockSize,
                          additionalEntries: Array(parts.dropFirst()))
    }

    // MARK: - Program Parsing

    private func parseProgram(entry: AkaiDirectoryEntry, data: Data) throws -> AkaiProgramFile {
        let startBlock = Int(entry.startBlock)
        let chain      = fatChain(from: startBlock, data: data)
        let fileData   = readFromChain(chain, fileOffset: 0, length: Int(entry.size), data: data)
        let midiChannel = fileData.count > 0x0C ? fileData[0x0C] : 0
        let polyphony   = fileData.count > 0x0D ? fileData[0x0D] : 16
        let bendRange   = fileData.count > 0x0E ? fileData[0x0E] : 2
        var keyzones: [AkaiProgramKeyzone] = []
        var kzOff = 0x14
        while kzOff + 22 <= fileData.count {
            if fileData[kzOff] == 0x00 { break }
            let kzName = akaiString(from: fileData, offset: kzOff, length: 12)
            keyzones.append(AkaiProgramKeyzone(
                sampleName: kzName, lowKey: fileData[kzOff+0x0C], highKey: fileData[kzOff+0x0D],
                rootNote: fileData[kzOff+0x0E], tuneOffset: Int8(bitPattern: fileData[kzOff+0x0F]),
                fineTune: Int8(bitPattern: fileData[kzOff+0x10]), volume: fileData[kzOff+0x11],
                pan: fileData.count > kzOff+0x12 ? Int8(bitPattern: fileData[kzOff+0x12]) : 0,
                loopEnabled: fileData.count > kzOff+0x13 ? fileData[kzOff+0x13] != 0 : false,
                velocityLow: fileData.count > kzOff+0x14 ? fileData[kzOff+0x14] : 0,
                velocityHigh: fileData.count > kzOff+0x15 ? fileData[kzOff+0x15] : 127))
            kzOff += 22
        }
        let program = AkaiProgram(name: entry.name, keyzones: keyzones,
                                  midiChannel: midiChannel, polyphony: polyphony, bendRange: bendRange,
                                  rawData: fileData)
        return AkaiProgramFile(directoryEntry: entry, program: program,
                               offset: startBlock * AkaiDiskFormat.blockSize)
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
    /// a directory entry (so it persists on Save).
    @discardableResult
    func importAndAddSample(from url: URL) throws -> AkaiSample {
        let wavData = try Data(contentsOf: url)
        let (pcmData, sampleRate, numChannels, _) = try parseWAV(wavData)
        let baseName = Self.sanitizeName(url.deletingPathExtension().lastPathComponent)
        return try addImportedSample(name: baseName, sampleRate: UInt32(sampleRate),
                                     numChannels: numChannels, pcmData: pcmData)
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

    /// Build a 252-byte S3000 sample header. Prefer cloning an existing sample's
    /// raw header (so fixed/obscure bytes are correct) and patching variable
    /// fields; fall back to a minimal hand-built header otherwise.
    private func buildSampleHeader(name: String, sampleRate: UInt32, numSamples: UInt32,
                                   rootNote: UInt8) -> Data {
        let size = AkaiDiskFormat.sampleHeaderSize
        var hdr: Data
        if let template = samples.first(where: { $0.header.rawHeader.count >= size })?.header.rawHeader {
            hdr = Data(template.prefix(size))
        } else {
            hdr = Data(repeating: 0, count: size)
            hdr[0x00] = 0x03   // block id (sample)
            hdr[0x01] = 0x01   // format marker (commonly 0x01)
            hdr[0x12] = 0x01   // active loops / sustain marker
        }
        hdr[0x02] = rootNote
        let nameBytes = akaiBytes(from: name, length: 12)
        for (i, b) in nameBytes.enumerated() { hdr[AkaiDiskFormat.hdrNameOffset + i] = b }
        hdr[0x13] = 0x02   // pmode: noloop by default
        hdr[0x14] = 0      // ctune
        hdr[0x15] = 0      // stune
        hdr[0x58] = UInt8(numSamples & 0xFF)
        hdr[0x59] = UInt8((numSamples >> 8) & 0xFF)
        hdr[0x5A] = UInt8((numSamples >> 16) & 0xFF)
        hdr[0x5B] = UInt8((numSamples >> 24) & 0xFF)
        let sr16 = UInt16(min(sampleRate, 65535))
        hdr[0x22] = UInt8(sr16 & 0xFF);  hdr[0x23] = UInt8(sr16 >> 8)
        hdr[0x8A] = UInt8(sr16 & 0xFF);  hdr[0x8B] = UInt8(sr16 >> 8)
        for off in [0x26, 0x27, 0x28, 0x29, 0x2C, 0x2D, 0x2E, 0x2F] { hdr[off] = 0 }
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
            numChannels: numChannels, fineTune: 0, loudness: 99, rawHeader: header)
        let sample = AkaiSample(
            directoryEntry: dirEntry, header: hdrModel, audioData: pcmData,
            offset: startBlock * bs)

        samples.append(sample)
        hasUnsavedChanges = true
        return sample
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

    func saveImageToDisk() throws {
        guard let data = imageData, let url = imageURL else {
            throw AkaiError.noImageLoaded
        }
        try data.write(to: url, options: .atomic)
        hasUnsavedChanges = false
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
}

// MARK: - Errors

enum AkaiError: LocalizedError {
    case invalidImage(String), dataError(String), noImageLoaded
    var errorDescription: String? {
        switch self {
        case .invalidImage(let s): return "Invalid image: \(s)"
        case .dataError(let s):    return "Data error: \(s)"
        case .noImageLoaded:       return "No disk image loaded"
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
