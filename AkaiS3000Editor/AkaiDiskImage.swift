import Foundation

// MARK: - Akai S3000 Disk Format Constants
// The Akai S3000 uses a proprietary filesystem on 1.44MB HD floppy disks
// Sector size: 512 bytes
// Tracks: 80, Sides: 2, Sectors per track: 18 (for HD)
// Volume header at sector 0
// Directory starts at sector 1

struct AkaiDiskFormat {
    static let sectorSize = 512
    static let sectorsPerTrack = 18
    static let tracksPerSide = 80
    static let sides = 2
    static let totalSectors = sectorsPerTrack * tracksPerSide * sides // 2880
    static let diskSize = totalSectors * sectorSize // 1,474,560 bytes

    // Akai uses a flat file system. The directory occupies the first few sectors.
    static let directorySectorStart = 1
    static let directoryEntrySize = 24
    static let maxDirectoryEntries = 512
    static let directorySectors = (maxDirectoryEntries * directoryEntrySize) / sectorSize

    // File types
    static let fileTypeVolume: UInt8 = 0x00
    static let fileTypeSample: UInt8 = 0x46   // 'F' for sample/wave
    static let fileTypeProgram: UInt8 = 0x50  // 'P' for program
    static let fileTypeMultiSample: UInt8 = 0x45 // extended

    // Sample header fields
    static let sampleHeaderSize = 150  // bytes before audio data begins in a sample file
}

// MARK: - Data Model

struct AkaiDirectoryEntry {
    var name: String           // 12 chars, padded with 0 or space
    var fileType: UInt8
    var startBlock: UInt16
    var length: UInt32         // in bytes for sample data
    var rawEntry: Data

    var isValid: Bool {
        return fileType == AkaiDiskFormat.fileTypeSample ||
               fileType == AkaiDiskFormat.fileTypeProgram
    }

    var displayType: String {
        switch fileType {
        case AkaiDiskFormat.fileTypeSample: return "Sample"
        case AkaiDiskFormat.fileTypeProgram: return "Program"
        default: return String(format: "0x%02X", fileType)
        }
    }
}

struct AkaiSampleHeader {
    // Parsed from the first ~150 bytes of a sample file
    var name: String
    var sampleRate: UInt32     // Hz
    var loopStart: UInt32      // in samples
    var loopEnd: UInt32        // in samples
    var numSamples: UInt32
    var midiRootNote: UInt8    // MIDI note number (0-127)
    var loopEnabled: Bool
    var bitDepth: Int          // 12-bit internal, expanded to 16-bit on export
    var numChannels: Int       // S3000 is mono per sample layer
    var fineTune: Int8         // cents -50 to +50
    var loudness: UInt8        // 0-99
    var rawHeader: Data
}

struct AkaiProgramKeyzone {
    var sampleName: String
    var lowKey: UInt8      // MIDI note
    var highKey: UInt8     // MIDI note
    var rootNote: UInt8    // MIDI note for pitch reference
    var tuneOffset: Int8   // semitones
    var fineTune: Int8     // cents
    var volume: UInt8
    var pan: Int8          // -50 to +50
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
    var audioData: Data        // raw 12-bit packed audio, interleaved words
    var offset: Int            // byte offset in disk image
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
    @Published var totalBlocks: Int = 0

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
        // Sector 0: Volume header
        // Bytes 0-11: Volume name
        // Byte 12: Volume type (should be 0)
        // Various allocation info follows

        let sector0 = data.subdata(in: 0..<AkaiDiskFormat.sectorSize)

        // Extract volume name (bytes 0..11, Akai ASCII)
        diskName = akaiString(from: sector0, offset: 0, length: 12)

        // Parse block allocation table (FAT-like) from sector 0 bytes 16 onward
        // Each block = 1024 bytes (2 sectors). Disk has 1440 blocks.
        // Allocation stored as 12-bit entries packed in the first sector(s).
        totalBlocks = 1583  // S3000 usable blocks
        freeBlocks = parseFreeBlocks(data: data)

        // Parse directory entries
        try parseDirectory(data: data)

        DispatchQueue.main.async {
            self.isLoaded = true
        }
    }

    private func parseFreeBlocks(data: Data) -> Int {
        // The S3000 stores a free block count at offset 0x12 in sector 0 as a 16-bit LE word
        guard data.count > 0x14 else { return 0 }
        let free = UInt16(data[0x12]) | (UInt16(data[0x13]) << 8)
        return Int(free)
    }

    // MARK: - Directory Parsing

    private func parseDirectory(data: Data) throws {
        // Directory starts at sector 1, each entry is 24 bytes
        // Entry format (Akai S3000):
        //   Bytes 0-11:  filename (Akai ASCII, 12 chars)
        //   Byte  12:    file type (0x46=sample, 0x50=program)
        //   Bytes 13:    unknown/reserved
        //   Bytes 14-15: start block (16-bit LE)
        //   Bytes 16-19: file length in bytes (32-bit LE)
        //   Bytes 20-23: unknown/reserved

        let dirStart = AkaiDiskFormat.sectorSize * AkaiDiskFormat.directorySectorStart
        let dirEnd = min(dirStart + AkaiDiskFormat.directoryEntrySize * AkaiDiskFormat.maxDirectoryEntries, data.count)

        var offset = dirStart
        var parsedSamples: [AkaiSample] = []
        var parsedPrograms: [AkaiProgramFile] = []

        while offset + AkaiDiskFormat.directoryEntrySize <= dirEnd {
            let entryData = data.subdata(in: offset..<(offset + AkaiDiskFormat.directoryEntrySize))

            // First byte of filename being 0 = end of directory
            if entryData[0] == 0x00 { break }

            let fileType = entryData[12]
            let name = akaiString(from: entryData, offset: 0, length: 12)
            let startBlock = UInt16(entryData[14]) | (UInt16(entryData[15]) << 8)
            let fileLength = UInt32(entryData[16]) |
                             (UInt32(entryData[17]) << 8) |
                             (UInt32(entryData[18]) << 16) |
                             (UInt32(entryData[19]) << 24)

            let entry = AkaiDirectoryEntry(
                name: name,
                fileType: fileType,
                startBlock: startBlock,
                length: fileLength,
                rawEntry: entryData
            )

            if fileType == AkaiDiskFormat.fileTypeSample {
                if let sample = try? parseSample(data: data, entry: entry) {
                    parsedSamples.append(sample)
                }
            } else if fileType == AkaiDiskFormat.fileTypeProgram {
                if let prog = try? parseProgram(data: data, entry: entry) {
                    parsedPrograms.append(prog)
                }
            }

            offset += AkaiDiskFormat.directoryEntrySize
        }

        DispatchQueue.main.async {
            self.samples = parsedSamples
            self.programs = parsedPrograms
        }
    }

    // MARK: - Sample Parsing

    private func parseSample(data: Data, entry: AkaiDirectoryEntry) throws -> AkaiSample {
        // Block to byte offset: block 0 starts at byte 0, each block = 1024 bytes
        let fileOffset = Int(entry.startBlock) * 1024

        guard fileOffset + AkaiDiskFormat.sampleHeaderSize < data.count else {
            throw AkaiError.dataError("Sample \(entry.name) is out of bounds")
        }

        let fileData = data.subdata(in: fileOffset..<min(fileOffset + Int(entry.length), data.count))

        // S3000 Sample Header layout (confirmed by reverse engineering real disks):
        // 0x00: File type (0x03 = sample)
        // 0x01: Version byte
        // 0x02: Sub-type
        // 0x03-0x0E: Name (12 bytes, Akai ASCII encoding)
        // 0x0F: Attribute flags (0x80 = mono, etc.)
        // 0x18: Number of channels (1=mono, 2=stereo)
        // 0x1A-0x1B: Sample rate (16-bit LE, e.g. 0xAC44 = 44100)
        // 0x58-0x5B: Number of samples (32-bit LE)
        // Audio data follows after 0x96 (150 bytes)

        let name = akaiString(from: fileData, offset: 0x03, length: 12)

        // Sample rate at 0x1A (16-bit LE)
        let sampleRate: UInt32
        if fileData.count > 0x1B {
            sampleRate = UInt32(fileData[0x1A]) | (UInt32(fileData[0x1B]) << 8)
        } else {
            sampleRate = 44100
        }

        // Number of channels at 0x18
        let numChannels = fileData.count > 0x18 ? Int(fileData[0x18]) : 1

        // Root note — not confirmed yet, use default
        let rootNote: UInt8 = fileData.count > 0x0F ? fileData[0x0F] : 60

        // Number of samples at 0x58 (32-bit LE)
        let numSamples: UInt32
        if fileData.count > 0x5B {
            numSamples = UInt32(fileData[0x58]) |
                         (UInt32(fileData[0x59]) << 8) |
                         (UInt32(fileData[0x5A]) << 16) |
                         (UInt32(fileData[0x5B]) << 24)
        } else {
            numSamples = UInt32(max(0, Int(entry.length) - AkaiDiskFormat.sampleHeaderSize)) / 2
        }

        // Loop info — offsets not yet confirmed, use placeholders
        let loopStart: UInt32 = 0
        let loopEnd: UInt32 = numSamples > 0 ? numSamples - 1 : 0
        let loopEnabled = false
        let fineTune: Int8 = 0
        let loudness: UInt8 = 99

        let header = AkaiSampleHeader(
            name: name,
            sampleRate: sampleRate > 0 ? sampleRate : 44100,
            loopStart: loopStart,
            loopEnd: loopEnd,
            numSamples: numSamples,
            midiRootNote: rootNote,
            loopEnabled: loopEnabled,
            bitDepth: 16,
            numChannels: numChannels,
            fineTune: fineTune,
            loudness: loudness,
            rawHeader: fileData.count >= AkaiDiskFormat.sampleHeaderSize
                ? fileData.subdata(in: 0..<AkaiDiskFormat.sampleHeaderSize)
                : fileData
        )

        let audioStart = AkaiDiskFormat.sampleHeaderSize
        let audioData: Data
        if fileData.count > audioStart {
            audioData = fileData.subdata(in: audioStart..<fileData.count)
        } else {
            audioData = Data()
        }

        return AkaiSample(
            directoryEntry: entry,
            header: header,
            audioData: audioData,
            offset: fileOffset
        )
    }

    // MARK: - Program Parsing

    private func parseProgram(data: Data, entry: AkaiDirectoryEntry) throws -> AkaiProgramFile {
        let fileOffset = Int(entry.startBlock) * 1024
        guard fileOffset < data.count else {
            throw AkaiError.dataError("Program \(entry.name) out of bounds")
        }

        let fileData = data.subdata(in: fileOffset..<min(fileOffset + Int(entry.length), data.count))

        // S3000 Program header:
        // 0x00: Name (12 bytes)
        // 0x0C: MIDI channel
        // 0x0D: Polyphony
        // 0x0E: Bend range (semitones)
        // Keyzone data starts at 0x14, each keyzone is 22 bytes
        // Keyzone entry:
        //   0x00-0x0B: Sample name (12 bytes)
        //   0x0C: Low key (MIDI)
        //   0x0D: High key (MIDI)
        //   0x0E: Root note (MIDI)
        //   0x0F: Tune offset (signed byte, semitones)
        //   0x10: Fine tune (signed byte, cents)
        //   0x11: Volume
        //   0x12: Pan (signed byte)
        //   0x13: Loop flag
        //   0x14: Velocity low
        //   0x15: Velocity high

        let name = akaiString(from: fileData, offset: 0x00, length: 12)
        let midiChannel = fileData.count > 0x0C ? fileData[0x0C] : 0
        let polyphony = fileData.count > 0x0D ? fileData[0x0D] : 16
        let bendRange = fileData.count > 0x0E ? fileData[0x0E] : 2

        var keyzones: [AkaiProgramKeyzone] = []
        let keyzoneStart = 0x14
        let keyzoneSize = 22

        var kzOffset = keyzoneStart
        while kzOffset + keyzoneSize <= fileData.count {
            if fileData[kzOffset] == 0x00 { break }

            let kzSampleName = akaiString(from: fileData, offset: kzOffset, length: 12)
            let lowKey = fileData[kzOffset + 0x0C]
            let highKey = fileData[kzOffset + 0x0D]
            let rootNote = fileData[kzOffset + 0x0E]
            let tuneOffset = Int8(bitPattern: fileData[kzOffset + 0x0F])
            let fineTune = Int8(bitPattern: fileData[kzOffset + 0x10])
            let volume = fileData[kzOffset + 0x11]
            let pan = fileData.count > kzOffset + 0x12 ? Int8(bitPattern: fileData[kzOffset + 0x12]) : 0
            let loop = fileData.count > kzOffset + 0x13 ? fileData[kzOffset + 0x13] != 0 : false
            let velLow = fileData.count > kzOffset + 0x14 ? fileData[kzOffset + 0x14] : 0
            let velHigh = fileData.count > kzOffset + 0x15 ? fileData[kzOffset + 0x15] : 127

            keyzones.append(AkaiProgramKeyzone(
                sampleName: kzSampleName,
                lowKey: lowKey,
                highKey: highKey,
                rootNote: rootNote,
                tuneOffset: tuneOffset,
                fineTune: fineTune,
                volume: volume,
                pan: pan,
                loopEnabled: loop,
                velocityLow: velLow,
                velocityHigh: velHigh
            ))

            kzOffset += keyzoneSize
        }

        let program = AkaiProgram(
            name: name,
            keyzones: keyzones,
            midiChannel: midiChannel,
            polyphony: polyphony,
            bendRange: bendRange,
            rawData: fileData
        )

        return AkaiProgramFile(
            directoryEntry: entry,
            program: program,
            offset: fileOffset
        )
    }

    // MARK: - WAV Export

    /// Export an Akai sample as a 16-bit WAV file
    func exportSampleAsWAV(sample: AkaiSample) throws -> Data {
        // S3000 stores 16-bit signed little-endian PCM — same as WAV, no conversion needed
        let pcmData = convertAkaiAudioToPCM(sample.audioData)

        return buildWAVFile(
            pcmData: pcmData,
            sampleRate: sample.header.sampleRate,
            numChannels: UInt16(sample.header.numChannels),
            bitsPerSample: 16
        )
    }

    private func convertAkaiAudioToPCM(_ audioData: Data) -> Data {
        // S3000 audio is 16-bit signed little-endian — same as WAV PCM.
        // No byte swap needed; return as-is.
        return audioData
    }

    private func buildWAVFile(pcmData: Data, sampleRate: UInt32, numChannels: UInt16, bitsPerSample: UInt16) -> Data {
        var wav = Data()

        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = UInt32(pcmData.count)
        let riffSize = 36 + dataSize

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE32(riffSize)
        wav.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLE32(16)          // chunk size
        wav.appendLE16(1)           // PCM format
        wav.appendLE16(numChannels)
        wav.appendLE32(sampleRate)
        wav.appendLE32(byteRate)
        wav.appendLE16(blockAlign)
        wav.appendLE16(bitsPerSample)

        // data chunk
        wav.append(contentsOf: "data".utf8)
        wav.appendLE32(dataSize)
        wav.append(pcmData)

        return wav
    }

    // MARK: - WAV Import

    /// Import a WAV file and add/replace a sample in the disk image
    func importWAVAsSample(wavURL: URL, targetSampleName: String? = nil) throws -> AkaiSample {
        let wavData = try Data(contentsOf: wavURL)
        let (pcmData, sampleRate, numChannels, bitsPerSample) = try parseWAVFile(wavData)

        // Convert PCM (LE) back to Akai format (BE)
        let akaiAudio = convertPCMToAkaiAudio(pcmData, bitsPerSample: bitsPerSample)

        let name = targetSampleName ?? wavURL.deletingPathExtension().lastPathComponent
            .prefix(12).uppercased()

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
            rawHeader: buildAkaiSampleHeader(name: String(name.prefix(12)),
                                             sampleRate: UInt32(sampleRate),
                                             numSamples: numSamples,
                                             rootNote: 60)
        )

        let entry = AkaiDirectoryEntry(
            name: String(name.prefix(12)),
            fileType: AkaiDiskFormat.fileTypeSample,
            startBlock: 0,
            length: UInt32(AkaiDiskFormat.sampleHeaderSize + akaiAudio.count),
            rawEntry: Data(repeating: 0, count: 24)
        )

        return AkaiSample(
            directoryEntry: entry,
            header: header,
            audioData: akaiAudio,
            offset: 0
        )
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
            let chunkID = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize = Int(data.readLE32(at: offset + 4))
            offset += 8

            if chunkID == "fmt " {
                numChannels = Int(data.readLE16(at: offset + 2))
                sampleRate = Int(data.readLE32(at: offset + 4))
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

    private func convertPCMToAkaiAudio(_ pcmData: Data, bitsPerSample: Int) -> Data {
        // S3000 is 16-bit little-endian, same as standard WAV PCM — no conversion needed.
        return pcmData
    }

    private func buildAkaiSampleHeader(name: String, sampleRate: UInt32, numSamples: UInt32, rootNote: UInt8) -> Data {
        var h = Data(repeating: 0, count: AkaiDiskFormat.sampleHeaderSize)
        let nameBytes = akaiBytes(from: name, length: 12)
        for (i, b) in nameBytes.enumerated() { h[i] = b }

        let bw: UInt8
        switch sampleRate {
        case 44100...: bw = 2
        case 22050...: bw = 1
        default: bw = 0
        }
        h[0x0C] = bw
        h[0x0D] = rootNote

        h[0x18] = UInt8(numSamples & 0xFF)
        h[0x19] = UInt8((numSamples >> 8) & 0xFF)
        h[0x1A] = UInt8((numSamples >> 16) & 0xFF)
        h[0x1B] = UInt8((numSamples >> 24) & 0xFF)

        return h
    }

    // MARK: - Write Back to Disk Image

    func writeSampleToImage(sample: AkaiSample) throws {
        guard var data = imageData else { throw AkaiError.noImageLoaded }

        let fileData = sample.header.rawHeader + sample.audioData

        guard sample.offset + fileData.count <= data.count else {
            throw AkaiError.dataError("Sample too large to fit in current location")
        }

        data.replaceSubrange(sample.offset..<sample.offset + fileData.count, with: fileData)
        imageData = data

        if let url = imageURL {
            try data.write(to: url)
        }
    }

    func updateProgramInImage(programFile: AkaiProgramFile) throws {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        let prog = programFile.program
        var fileData = programFile.program.rawData

        // Update name
        let nameBytes = akaiBytes(from: prog.name, length: 12)
        for (i, b) in nameBytes.enumerated() { fileData[i] = b }
        if fileData.count > 0x0C { fileData[0x0C] = prog.midiChannel }
        if fileData.count > 0x0D { fileData[0x0D] = prog.polyphony }
        if fileData.count > 0x0E { fileData[0x0E] = prog.bendRange }

        let keyzoneStart = 0x14
        let keyzoneSize = 22
        for (idx, kz) in prog.keyzones.enumerated() {
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

    private func akaiString(from data: Data, offset: Int, length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let bytes = data[offset..<(offset + length)]
        // Confirmed S3000 character set: 0=space, 1=A, 2=B...26=Z, 27=0...36=9, 37=-, 38=+
        let akaiChars: [Character] = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-+")
        let str = bytes.compactMap { byte -> Character? in
            if byte == 0 { return nil }
            if Int(byte) < akaiChars.count { return akaiChars[Int(byte)] }
            // Fall back to ASCII for bytes >= 0x20
            if byte >= 0x20, let scalar = Unicode.Scalar(byte) { return Character(scalar) }
            return nil
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
    case invalidImage(String)
    case dataError(String)
    case noImageLoaded

    var errorDescription: String? {
        switch self {
        case .invalidImage(let s): return "Invalid image: \(s)"
        case .dataError(let s): return "Data error: \(s)"
        case .noImageLoaded: return "No disk image is loaded"
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
