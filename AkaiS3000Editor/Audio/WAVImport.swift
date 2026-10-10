import Foundation

/// Shared WAV import helpers.
///
/// The app imports .wav audio from several entry points (drag onto the keyzone
/// editor, drag onto the Programs panel, "Browse…" pickers, folder drops). Each
/// used to parse the RIFF/`fmt `/`data` chunks and repack 24-bit PCM by hand,
/// and the copies had drifted — some forgot the 24-bit repack entirely and fed
/// the raw 3-byte stream in as if it were 16-bit, turning 24-bit files into
/// hiss. This type is the single source of truth so every path behaves the same.
enum WAVImport {

    /// The decoded result of parsing a WAV file.
    ///
    /// `pcm` is ALWAYS 16-bit little-endian interleaved PCM: 8-bit input is not
    /// supported (rare for these tools), 16-bit is passed through, and 24-bit is
    /// repacked down to 16-bit (keeping the two high bytes of each sample). The
    /// rest of the pipeline — `deinterleaveStereo`, `applyLoFi`,
    /// `addImportedSample` — assumes 16-bit, so callers can use `pcm` directly.
    struct Decoded {
        let pcm: Data
        let sampleRate: Int
        let channels: Int
        /// Bit depth of the ORIGINAL file (16 or 24). `pcm` is always 16-bit
        /// regardless; this is here only for callers that want to report it.
        let sourceBitsPerSample: Int
    }

    enum WAVError: LocalizedError {
        case notAWAV
        case noAudioData
        var errorDescription: String? {
            switch self {
            case .notAWAV:      return "Not a valid WAV or AIFF file"
            case .noAudioData:  return "No audio data in WAV"
            }
        }
    }

    /// Parse WAV or AIFF bytes into 16-bit interleaved PCM plus format info.
    /// Throws `WAVError` if the data isn't a supported audio file or has no samples.
    static func decode(_ data: Data) throws -> Decoded {
        // Route AIFF/AIFC by magic before attempting WAV parse.
        if data.count > 12,
           data[data.startIndex..<data.startIndex+4] == Data("FORM".utf8),
           data[data.startIndex+8..<data.startIndex+12] == Data("AIFF".utf8) ||
           data[data.startIndex+8..<data.startIndex+12] == Data("AIFC".utf8) {
            return try decodeAIFF(data)
        }
        guard data.count > 44,
              data[data.startIndex..<data.startIndex+4] == Data("RIFF".utf8),
              data[data.startIndex+8..<data.startIndex+12] == Data("WAVE".utf8) else {
            throw WAVError.notAWAV
        }

        var offset = 12
        var sampleRate = 44100
        var numChannels = 1
        var bitsPerSample = 16
        var pcmData = Data()

        // Walk the chunk list, reading `fmt ` for the format and `data` for the
        // samples. Chunks are word-aligned, so odd sizes get a pad byte.
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(data.readLE32(at: offset + 4))
            offset += 8
            if id == "fmt " {
                numChannels   = Int(data.readLE16(at: offset + 2))
                sampleRate    = Int(data.readLE32(at: offset + 4))
                bitsPerSample = Int(data.readLE16(at: offset + 14))
            } else if id == "data" {
                pcmData = data.subdata(in: offset..<min(offset + size, data.count))
            }
            offset += size + (size % 2)
        }

        guard !pcmData.isEmpty else { throw WAVError.noAudioData }

        let pcm16 = repack24to16IfNeeded(pcmData, bitsPerSample: bitsPerSample, channels: numChannels)
        return Decoded(pcm: pcm16, sampleRate: sampleRate, channels: numChannels,
                       sourceBitsPerSample: bitsPerSample)
    }

    /// If `bitsPerSample` is 24, repack to 16-bit by keeping the two high
    /// (most-significant) bytes of each little-endian sample; otherwise return
    /// the data unchanged. Without this, 24-bit audio read as 16-bit is
    /// byte-misaligned on every sample and plays back as noise.
    static func repack24to16IfNeeded(_ pcm: Data, bitsPerSample: Int, channels: Int) -> Data {
        guard bitsPerSample == 24 else { return pcm }
        let bytesPerFrame = 3 * channels
        guard bytesPerFrame > 0 else { return pcm }
        var out = Data()
        out.reserveCapacity((pcm.count / bytesPerFrame) * 2 * channels)
        var i = pcm.startIndex
        while i + bytesPerFrame <= pcm.endIndex {
            for ch in 0..<channels {
                out.append(pcm[i + ch*3 + 1])
                out.append(pcm[i + ch*3 + 2])
            }
            i += bytesPerFrame
        }
        return out
    }

    /// Parse AIFF/AIFC bytes into 16-bit little-endian PCM.
    /// AIFF is big-endian; `sowt` AIFC is already little-endian.
    private static func decodeAIFF(_ data: Data) throws -> Decoded {
        let isAIFC = data[data.startIndex+8..<data.startIndex+12] == Data("AIFC".utf8)
        var offset = 12

        func readBE32(at i: Int) -> UInt32 {
            (UInt32(data[i]) << 24) | (UInt32(data[i+1]) << 16) |
            (UInt32(data[i+2]) << 8)  |  UInt32(data[i+3])
        }
        func readBE16(at i: Int) -> UInt16 {
            (UInt16(data[i]) << 8) | UInt16(data[i+1])
        }
        func readExtended(at i: Int) -> Double {
            let exp  = Int(readBE16(at: i)) & 0x7FFF
            let mant = (UInt64(readBE32(at: i+2)) << 32) | UInt64(readBE32(at: i+6))
            guard exp != 0 else { return 0 }
            let frac = Double(mant) / pow(2.0, 63.0)
            return frac * pow(2.0, Double(exp - 16383))
        }

        var sampleRate = 44100, numChannels = 1, bitsPerSample = 16
        var soundData = Data(), isSowt = false

        while offset + 8 <= data.count {
            let id   = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(readBE32(at: offset + 4))
            let body = offset + 8
            offset += 8

            if id == "COMM" {
                numChannels   = Int(readBE16(at: body))
                bitsPerSample = Int(readBE16(at: body + 6))
                sampleRate    = Int(readExtended(at: body + 8))
                if isAIFC, size >= 26 {
                    let codec = String(bytes: data[body+18..<body+22], encoding: .ascii) ?? ""
                    isSowt = (codec == "sowt")
                }
            } else if id == "SSND" {
                let ssndOff = Int(readBE32(at: body))
                let start   = body + 8 + ssndOff
                let end     = min(body + size, data.count)
                if start < end { soundData = data.subdata(in: start..<end) }
            }
            offset += size + (size % 2)
        }

        guard !soundData.isEmpty else { throw WAVError.noAudioData }

        let pcm16: Data
        if bitsPerSample == 24 {
            var out = Data(); out.reserveCapacity(soundData.count / 3 * 2)
            var i = soundData.startIndex
            while i + 3 * numChannels <= soundData.endIndex {
                for _ in 0..<numChannels {
                    // AIFF 24-bit is big-endian [MSB, mid, LSB]. Keep the top
                    // two bytes and emit little-endian: low = mid, high = MSB.
                    out.append(soundData[i + 1])
                    out.append(soundData[i])
                    i += 3
                }
            }
            pcm16 = out
        } else if isSowt {
            pcm16 = soundData
        } else {
            var out = Data(); out.reserveCapacity(soundData.count)
            var i = soundData.startIndex
            while i + 2 <= soundData.endIndex {
                out.append(soundData[i + 1])
                out.append(soundData[i])
                i += 2
            }
            pcm16 = out
        }

        return Decoded(pcm: pcm16, sampleRate: sampleRate, channels: numChannels,
                       sourceBitsPerSample: bitsPerSample)
    }


}
