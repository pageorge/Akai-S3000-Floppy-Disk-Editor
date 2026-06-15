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

    var imageData: Data?
    var imageURL:  URL?

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= AkaiDiskFormat.blockSize * 5 else {
            throw AkaiError.invalidImage("File too small")
        }
        imageData = data
        imageURL  = url
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
            guard ftype != 0x00 else { break }
            guard ftype == AkaiDiskFormat.ftypeSample || ftype == AkaiDiskFormat.ftypeProgram else { continue }
            let name  = akaiString(from: data, offset: base, length: 12)
            let size  = UInt32(data[base+17]) | (UInt32(data[base+18]) << 8) | (UInt32(data[base+19]) << 16)
            let start = UInt16(data[base+20]) | (UInt16(data[base+21]) << 8)
            entries.append(AkaiDirectoryEntry(name: name, fileType: ftype, startBlock: start, size: size,
                                              rawEntry: Data(data[base..<base+entrySize])))
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

        return (parsedSamples.sorted { $0.header.name < $1.header.name },
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

        let header = AkaiSampleHeader(
            name: name.isEmpty ? first.name : name,
            sampleRate: sampleRate,
            loopStart: 0, loopEnd: numSamples > 0 ? numSamples - 1 : 0,
            numSamples: numSamples, midiRootNote: 60, loopEnabled: false,
            bitDepth: 16, numChannels: 1, fineTune: 0, loudness: 99,
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

    func importWAVAsSample(wavURL: URL, targetSampleName: String? = nil) throws -> AkaiSample {
        let wavData = try Data(contentsOf: wavURL)
        let (pcmData, sampleRate, numChannels, _) = try parseWAV(wavData)
        let name = targetSampleName ??
            String(wavURL.deletingPathExtension().lastPathComponent.prefix(12).uppercased())
        let numSamples = UInt32(pcmData.count) / UInt32(numChannels) / 2
        let header = AkaiSampleHeader(
            name: String(name.prefix(12)), sampleRate: UInt32(sampleRate),
            loopStart: 0, loopEnd: numSamples > 0 ? numSamples - 1 : 0,
            numSamples: numSamples, midiRootNote: 60, loopEnabled: false,
            bitDepth: 16, numChannels: numChannels, fineTune: 0, loudness: 99,
            rawHeader: Data(repeating: 0, count: AkaiDiskFormat.sampleHeaderSize))
        let entry = AkaiDirectoryEntry(
            name: String(name.prefix(12)), fileType: AkaiDiskFormat.ftypeSample,
            startBlock: 0, size: UInt32(AkaiDiskFormat.sampleHeaderSize + pcmData.count),
            rawEntry: Data(repeating: 0, count: 24))
        return AkaiSample(directoryEntry: entry, header: header, audioData: pcmData, offset: 0)
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

    func deleteSample(id: UUID) {
        samples.removeAll { $0.id == id }
    }

    // MARK: - Write Back

    func writeSampleToImage(sample: AkaiSample) throws {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        let chain = fatChain(from: sample.offset / AkaiDiskFormat.blockSize, data: data)
        let fileData = sample.header.rawHeader + sample.audioData
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

    private func akaiBytes(from string: String, length: Int) -> [UInt8] {
        var bytes = Array(string.uppercased().utf8.prefix(length))
        while bytes.count < length { bytes.append(0x20) }
        return bytes
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
