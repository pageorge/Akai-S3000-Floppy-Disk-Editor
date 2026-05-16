import Foundation

// MARK: - Akai S3000 Disk Format Constants
// Confirmed by reverse engineering real S3000 disks:
// - 80 cylinders, 2 heads, 10 sectors/track, 1024 bytes/sector
// - Total: 1,638,400 bytes (1600 blocks of 1024 bytes)
// - Audio: 16-bit signed little-endian PCM
// - Character encoding: 0=space, 1=A...26=Z, 27=0...36=9, 37=-, 38=+

struct AkaiDiskFormat {
    static let sectorSize = 1024        // confirmed: 1024-byte sectors
    static let sectorsPerTrack = 10     // confirmed: 10 sectors per track
    static let tracksPerSide = 80
    static let sides = 2
    static let totalBlocks = sectorsPerTrack * tracksPerSide * sides // 1600
    static let diskSize = totalBlocks * sectorSize // 1,638,400 bytes

    // File types (first byte of each file)
    static let fileTypeProgram: UInt8 = 0x01
    static let fileTypeSample: UInt8  = 0x03

    // Sample header: 150 bytes (0x96), audio data follows immediately after
    static let sampleHeaderSize = 0x96
}

// MARK: - Data Model

struct AkaiDirectoryEntry {
    var name: String
    var fileType: UInt8
    var startBlock: UInt16
    var length: UInt32
    var rawEntry: Data

    var isValid: Bool {
        return fileType == AkaiDiskFormat.fileTypeSample ||
               fileType == AkaiDiskFormat.fileTypeProgram
    }

    var displayType: String {
        switch fileType {
        case AkaiDiskFormat.fileTypeSample:  return "Sample"
        case AkaiDiskFormat.fileTypeProgram: return "Program"
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
}

struct AkaiProgramFile: Identifiable {
    var id = UUID()
    var directoryEntry: AkaiDirectoryEntry
    var program: AkaiProgram
    var offset: Int
}

// MARK: - Disk Image Parser

class AkaiDiskImage: ObservableObject {
    @Published var isLoaded = false
    @Published var diskName: String = ""
    @Published var samples: [AkaiSample] = []
    @Published var programs: [AkaiProgramFile] = []
    @Published var errorMessage: String? = nil
    @Published var freeBlocks: Int = 0
    @Published var totalBlocks: Int = AkaiDiskFormat.totalBlocks

    var imageData: Data?
    var imageURL: URL?

    // MARK: - Loading

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= AkaiDiskFormat.sectorSize else {
            throw AkaiError.invalidImage("File too small to be a disk image")
        }
        imageData = data
        imageURL = url
        try parseVolume(data: data)
    }

    private func parseVolume(data: Data) throws {
        diskName = akaiString(from: data, offset: 0x03, length: 12)
        freeBlocks = parseFreeBlocks(data: data)
        try parseDirectory(data: data)
        DispatchQueue.main.async { self.isLoaded = true }
    }

    private func parseFreeBlocks(data: Data) -> Int {
        guard data.count > 0x14 else { return 0 }
        let free = UInt16(data[0x12]) | (UInt16(data[0x13]) << 8)
        return Int(free)
    }

    // MARK: - Directory Parsing
    // The S3000 directory is found by scanning blocks for file type markers.
    // File type 0x01 = program, 0x03 = sample (first byte of each file block).

    private func parseDirectory(data: Data) throws {
        var parsedSamples: [AkaiSample] = []
        var parsedPrograms: [AkaiProgramFile] = []
        let blockSize = AkaiDiskFormat.sectorSize
        let totalBlocks = data.count / blockSize

        for blockNum in 0..<totalBlocks {
            let offset = blockNum * blockSize
            guard offset + 16 <= data.count else { break }

            let fileType = data[offset]
            guard fileType == AkaiDiskFormat.fileTypeSample ||
                  fileType == AkaiDiskFormat.fileTypeProgram else { continue }

            // Validate: name bytes 0x03-0x0E must all be valid Akai chars (< 39)
            let nameBytes = data[offset+3..<offset+15]
            guard nameBytes.allSatisfy({ $0 < 39 }),
                  nameBytes.contains(where: { $0 > 0 }) else { continue }

            let name = akaiString(from: data, offset: offset + 3, length: 12)

            let entry = AkaiDirectoryEntry(
                name: name,
                fileType: fileType,
                startBlock: UInt16(blockNum),
                length: 0,
                rawEntry: Data(data[offset..<min(offset+24, data.count)])
            )

            if fileType == AkaiDiskFormat.fileTypeSample {
                if let sample = try? parseSample(data: data, entry: entry, blockOffset: offset) {
                    parsedSamples.append(sample)
                }
            } else if fileType == AkaiDiskFormat.fileTypeProgram {
                if let prog = try? parseProgram(data: data, entry: entry, blockOffset: offset) {
                    parsedPrograms.append(prog)
                }
            }
        }

        DispatchQueue.main.async {
            self.samples = parsedSamples
            self.programs = parsedPrograms
        }
    }

    // MARK: - Sample Parsing
    //
    // Confirmed S3000 sample header layout (offset from file start):
    //   0x00: File type (0x03 = sample)
    //   0x01: Version
    //   0x02: Sub-type
    //   0x03-0x0E: Name (12 bytes, Akai encoding)
    //   0x0F: Attribute flags
    //   0x18: Number of channels (1=mono, 2=stereo)
    //   0x1A-0x1B: Sample rate (16-bit LE, e.g. 0xAC44 = 44100)
    //   0x58-0x5B: Number of samples (32-bit LE)
    //   0x96: Audio data begins (16-bit signed LE PCM)

    private func parseSample(data: Data, entry: AkaiDirectoryEntry, blockOffset: Int) throws -> AkaiSample {
        guard blockOffset + AkaiDiskFormat.sampleHeaderSize < data.count else {
            throw AkaiError.dataError("Sample \(entry.name) is out of bounds")
        }

        let hdr = data

        let sampleRate: UInt32
        if blockOffset + 0x1C <= data.count {
            sampleRate = UInt32(hdr[blockOffset + 0x1A]) | (UInt32(hdr[blockOffset + 0x1B]) << 8)
        } else {
            sampleRate = 44100
        }

        let numChannels = blockOffset + 0x19 <= data.count ? Int(hdr[blockOffset + 0x18]) : 1
        let rootNote: UInt8 = blockOffset + 0x10 <= data.count ? hdr[blockOffset + 0x0F] : 60

        let numSamples: UInt32
        if blockOffset + 0x5C <= data.count {
            numSamples = UInt32(hdr[blockOffset + 0x58]) |
                         (UInt32(hdr[blockOffset + 0x59]) << 8) |
                         (UInt32(hdr[blockOffset + 0x5A]) << 16) |
                         (UInt32(hdr[blockOffset + 0x5B]) << 24)
        } else {
            numSamples = 0
        }

        let header = AkaiSampleHeader(
            name: entry.name,
            sampleRate: sampleRate > 0 ? sampleRate : 44100,
            loopStart: 0,
            loopEnd: numSamples > 0 ? numSamples - 1 : 0,
            numSamples: numSamples,
            midiRootNote: rootNote,
            loopEnabled: false,
            bitDepth: 16,
            numChannels: max(1, numChannels),
            fineTune: 0,
            loudness: 99,
            rawHeader: Data(data[blockOffset..<min(blockOffset + AkaiDiskFormat.sampleHeaderSize, data.count)])
        )

        let audioStart = blockOffset + AkaiDiskFormat.sampleHeaderSize
        let audioEnd = min(audioStart + Int(numSamples) * (numChannels > 1 ? 2 : 1) * 2, data.count)
        let audioData = audioStart < data.count ? Data(data[audioStart..<audioEnd]) : Data()

        return AkaiSample(
            directoryEntry: entry,
            header: header,
            audioData: audioData,
            offset: blockOffset
        )
    }

    // MARK: - Program Parsing

    private func parseProgram(data: Data, entry: AkaiDirectoryEntry, blockOffset: Int) throws -> AkaiProgramFile {
        guard blockOffset < data.count else {
            throw AkaiError.dataError("Program \(entry.name) out of bounds")
        }

        let end = min(blockOffset + AkaiDiskFormat.sectorSize, data.count)
        let fileData = data.subdata(in: blockOffset..<end)

        let midiChannel = fileData.count > 0x0C ? fileData[0x0C] : 0
        let polyphony   = fileData.count > 0x0D ? fileData[0x0D] : 16
        let bendRange   = fileData.count > 0x0E ? fileData[0x0E] : 2

        var keyzones: [AkaiProgramKeyzone] = []
        let keyzoneStart = 0x14
        let keyzoneSize  = 22

        var kzOffset = keyzoneStart
        while kzOffset + keyzoneSize <= fileData.count {
            if fileData[kzOffset] == 0x00 { break }
            let kzName = akaiString(from: fileData, offset: kzOffset, length: 12)
            keyzones.append(AkaiProgramKeyzone(
                sampleName: kzName,
                lowKey:      fileData[kzOffset + 0x0C],
                highKey:     fileData[kzOffset + 0x0D],
                rootNote:    fileData[kzOffset + 0x0E],
                tuneOffset:  Int8(bitPattern: fileData[kzOffset + 0x0F]),
                fineTune:    Int8(bitPattern: fileData[kzOffset + 0x10]),
                volume:      fileData[kzOffset + 0x11],
                pan:         fileData.count > kzOffset + 0x12 ? Int8(bitPattern: fileData[kzOffset + 0x12]) : 0,
                loopEnabled: fileData.count > kzOffset + 0x13 ? fileData[kzOffset + 0x13] != 0 : false,
                velocityLow: fileData.count > kzOffset + 0x14 ? fileData[kzOffset + 0x14] : 0,
                velocityHigh: fileData.count > kzOffset + 0x15 ? fileData[kzOffset + 0x15] : 127
            ))
            kzOffset += keyzoneSize
        }

        let program = AkaiProgram(
            name: entry.name,
            keyzones: keyzones,
            midiChannel: midiChannel,
            polyphony: polyphony,
            bendRange: bendRange,
            rawData: fileData
        )

        return AkaiProgramFile(directoryEntry: entry, program: program, offset: blockOffset)
    }

    // MARK: - WAV Export

    func exportSampleAsWAV(sample: AkaiSample) throws -> Data {
        // S3000 audio is 16-bit signed little-endian PCM — same as WAV, no conversion needed
        return buildWAVFile(
            pcmData: sample.audioData,
            sampleRate: sample.header.sampleRate,
            numChannels: UInt16(sample.header.numChannels),
            bitsPerSample: 16
        )
    }

    private func buildWAVFile(pcmData: Data, sampleRate: UInt32, numChannels: UInt16, bitsPerSample: UInt16) -> Data {
        var wav = Data()
        let byteRate   = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize   = UInt32(pcmData.count)

        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE32(36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLE32(16)
        wav.appendLE16(1)
        wav.appendLE16(numChannels)
        wav.appendLE32(sampleRate)
        wav.appendLE32(byteRate)
        wav.appendLE16(blockAlign)
        wav.appendLE16(bitsPerSample)
        wav.append(contentsOf: "data".utf8)
        wav.appendLE32(dataSize)
        wav.append(pcmData)
        return wav
    }

    // MARK: - WAV Import

    func importWAVAsSample(wavURL: URL, targetSampleName: String? = nil) throws -> AkaiSample {
        let wavData = try Data(contentsOf: wavURL)
        let (pcmData, sampleRate, numChannels, bitsPerSample) = try parseWAVFile(wavData)
        let name = targetSampleName ?? String(wavURL.deletingPathExtension().lastPathComponent.prefix(12).uppercased())
        let numSamples = UInt32(pcmData.count) / (UInt32(bitsPerSample) / 8 * UInt32(numChannels))

        let header = AkaiSampleHeader(
            name: String(name.prefix(12)),
            sampleRate: UInt32(sampleRate),
            loopStart: 0,
            loopEnd: numSamples > 0 ? numSamples - 1 : 0,
            numSamples: numSamples,
            midiRootNote: 60,
            loopEnabled: false,
            bitDepth: 16,
            numChannels: Int(numChannels),
            fineTune: 0,
            loudness: 99,
            rawHeader: Data(repeating: 0, count: AkaiDiskFormat.sampleHeaderSize)
        )
        let entry = AkaiDirectoryEntry(
            name: String(name.prefix(12)),
            fileType: AkaiDiskFormat.fileTypeSample,
            startBlock: 0,
            length: UInt32(AkaiDiskFormat.sampleHeaderSize + pcmData.count),
            rawEntry: Data(repeating: 0, count: 24)
        )
        return AkaiSample(directoryEntry: entry, header: header, audioData: pcmData, offset: 0)
    }

    private func parseWAVFile(_ data: Data) throws -> (Data, Int, Int, Int) {
        guard data.count > 44 else { throw AkaiError.dataError("WAV too small") }
        guard data[0..<4] == Data("RIFF".utf8) else { throw AkaiError.dataError("Not a RIFF file") }
        guard data[8..<12] == Data("WAVE".utf8) else { throw AkaiError.dataError("Not a WAVE file") }

        var offset = 12
        var sampleRate = 44100
        var numChannels = 1
        var bitsPerSample = 16
        var pcmData = Data()

        while offset + 8 <= data.count {
            let chunkID   = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize = Int(data.readLE32(at: offset + 4))
            offset += 8
            if chunkID == "fmt " {
                numChannels   = Int(data.readLE16(at: offset + 2))
                sampleRate    = Int(data.readLE32(at: offset + 4))
                bitsPerSample = Int(data.readLE16(at: offset + 14))
            } else if chunkID == "data" {
                pcmData = data.subdata(in: offset..<min(offset + chunkSize, data.count))
            }
            offset += chunkSize
            if chunkSize % 2 != 0 { offset += 1 }
        }
        guard !pcmData.isEmpty else { throw AkaiError.dataError("No audio data in WAV") }
        return (pcmData, sampleRate, numChannels, bitsPerSample)
    }

    // MARK: - Write Back

    func writeSampleToImage(sample: AkaiSample) throws {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        let fileData = sample.header.rawHeader + sample.audioData
        guard sample.offset + fileData.count <= data.count else {
            throw AkaiError.dataError("Sample too large to fit in current location")
        }
        data.replaceSubrange(sample.offset..<sample.offset + fileData.count, with: fileData)
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
        let keyzoneStart = 0x14
        let keyzoneSize  = 22
        for (idx, kz) in programFile.program.keyzones.enumerated() {
            let kzOffset = keyzoneStart + idx * keyzoneSize
            guard kzOffset + keyzoneSize <= fileData.count else { break }
            let kzNameBytes = akaiBytes(from: kz.sampleName, length: 12)
            for (i, b) in kzNameBytes.enumerated() { fileData[kzOffset + i] = b }
            fileData[kzOffset + 0x0C] = kz.lowKey
            fileData[kzOffset + 0x0D] = kz.highKey
            fileData[kzOffset + 0x0E] = kz.rootNote
            fileData[kzOffset + 0x0F] = UInt8(bitPattern: kz.tuneOffset)
            fileData[kzOffset + 0x10] = UInt8(bitPattern: kz.fineTune)
            fileData[kzOffset + 0x11] = kz.volume
            if fileData.count > kzOffset + 0x12 { fileData[kzOffset + 0x12] = UInt8(bitPattern: kz.pan) }
            if fileData.count > kzOffset + 0x13 { fileData[kzOffset + 0x13] = kz.loopEnabled ? 1 : 0 }
            if fileData.count > kzOffset + 0x14 { fileData[kzOffset + 0x14] = kz.velocityLow }
            if fileData.count > kzOffset + 0x15 { fileData[kzOffset + 0x15] = kz.velocityHigh }
        }
        guard programFile.offset + fileData.count <= data.count else {
            throw AkaiError.dataError("Program data out of bounds")
        }
        data.replaceSubrange(programFile.offset..<programFile.offset + fileData.count, with: fileData)
        imageData = data
        if let url = imageURL { try data.write(to: url) }
    }

    // MARK: - Akai String Encoding
    // Confirmed S3000 character set:
    // 0x00=space, 0x01=A...0x1A=Z, 0x1B=0...0x24=9, 0x25=-, 0x26=+

    private func akaiString(from data: Data, offset: Int, length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let akaiChars: [Character] = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-+")
        let str = data[offset..<(offset + length)].compactMap { byte -> Character? in
            if byte == 0 { return nil }
            if Int(byte) < akaiChars.count { return akaiChars[Int(byte)] }
            if byte >= 0x20, let scalar = Unicode.Scalar(byte) { return Character(scalar) }
            return nil
        }
        return String(str).trimmingCharacters(in: .whitespaces)
    }

    private func akaiString(from data: Data, offset: Int, length: Int) -> String {
        akaiString(from: data as Data, offset: offset, length: length)
    }

    private func akaiBytes(from string: String, length: Int) -> [UInt8] {
        var bytes = Array(string.uppercased().utf8.prefix(length))
        while bytes.count < length { bytes.append(0x20) }
        return bytes
    }
}

// MARK: - Errors

enum AkaiError: LocalizedError {
    case invalidImage(String)
    case dataError(String)
    case noImageLoaded

    var errorDescription: String? {
        switch self {
        case .invalidImage(let s): return "Invalid image: \(s)"
        case .dataError(let s):    return "Data error: \(s)"
        case .noImageLoaded:       return "No disk image is loaded"
        }
    }
}

// MARK: - Data Extensions

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
    func readLE16(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset+1]) << 8)
    }
    func readLE32(at offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        return UInt32(self[offset]) | (UInt32(self[offset+1]) << 8) |
               (UInt32(self[offset+2]) << 16) | (UInt32(self[offset+3]) << 24)
    }
}
