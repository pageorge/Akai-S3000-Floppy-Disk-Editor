import Foundation
import AppKit

/// Central audio import pipeline.
///
/// Every import path in the app (drag-and-drop, Browse picker, folder drop,
/// EMU import) should go through `AudioImportPipeline.process(...)` rather
/// than duplicating the decode → resample-check → loFi chain inline. This
/// keeps the behaviour identical at every entry point and makes future
/// changes (e.g. different target rates, new prompt wording) a one-line fix.
enum AudioImportPipeline {

    // MARK: - Result

    /// A single import-ready audio channel.
    struct Channel {
        /// Suggested name for `addImportedSample`. Already sanitised to 12 chars.
        let name: String
        /// 16-bit mono little-endian PCM ready for `addImportedSample`.
        let pcm: Data
        /// Akai-legal sample rate (22050 or 44100).
        let sampleRate: UInt32
        /// True for the right channel of a stereo file; false for everything else.
        let isRight: Bool
    }

    /// Remembers the resample answer (Resample or Cancel) across a batch import
    /// so the user is asked once per batch rather than once per file. Pass the
    /// same instance to every call in the batch. Thread-safe: if several files
    /// in a batch reach the prompt at once, the first one asks and the rest wait
    /// for (and reuse) its answer.
    final class ResampleConsent {
        fileprivate let lock = NSLock()
        fileprivate var answer: Bool?          // nil = not asked yet
        let id = String(UUID().uuidString.prefix(4))
        init(_ origin: String = #function) {
            NSLog("[IMPORT] consent %@ created by %@", id, origin)
        }
    }

    // MARK: - Main entry point

    /// Decode an audio file and prepare it for import.
    ///
    /// - Parameters:
    ///   - url: The audio file URL (WAV or AIFF).
    ///   - baseName: Name to use for the sample (before sanitisation). If nil,
    ///     derived from the file name.
    ///   - loFi: Apply 22 kHz lo-fi downsampling (user preference).
    ///   - stereo: How to handle a stereo file.
    ///     - `.monoLeft` (default) — extract the left channel only.
    ///     - `.stereoLR` — return both channels as separate `Channel` values.
    ///   - disk: The disk the samples will go on — names are chosen (and
    ///     reserved) against it using the import naming rule.
    ///   - consent: Optional batch-wide resample answer (see `ResampleConsent`).
    ///
    /// - Returns: One `Channel` for mono files; one or two for stereo.
    ///   Returns an empty array if the user cancelled the resample prompt.
    ///
    /// - Throws: `WAVImport.WAVError` if the file cannot be decoded,
    ///   or `AkaiError.cancelled` if the user dismissed the resample prompt.
    ///
    /// This function **must** be called from a background thread; it will hop
    /// to the main thread briefly if a resample prompt is needed.
    static func process(
        url: URL,
        baseName: String? = nil,
        loFi: Bool,
        stereo: StereoMode = .monoLeft,
        names disk: AkaiDiskImage,
        consent: ResampleConsent? = nil
    ) throws -> [Channel] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        NSLog("[IMPORT] pipeline.process %@ loFi=%d consent=%@",
              url.lastPathComponent, loFi ? 1 : 0, consent?.id ?? "none")

        let wavData = try Data(contentsOf: url)
        let decoded = try WAVImport.decode(wavData)
        return try process(
            decoded: decoded,
            url: url,
            baseName: baseName,
            loFi: loFi,
            stereo: stereo,
            names: disk,
            consent: consent
        )
    }

    /// Overload for callers that have already decoded the file.
    static func process(
        decoded: WAVImport.Decoded,
        url: URL,
        baseName: String? = nil,
        loFi: Bool,
        stereo: StereoMode = .monoLeft,
        names disk: AkaiDiskImage,
        consent: ResampleConsent? = nil
    ) throws -> [Channel] {
        let rawName = baseName ?? url.deletingPathExtension().lastPathComponent

        // Split stereo → left/right before rate conversion so each channel is
        // resampled individually (avoids re-interleaving).
        let (leftPCM, rightPCM): (Data, Data?)
        if decoded.channels >= 2 {
            let (l, r) = AkaiDiskImage.deinterleaveStereo(decoded.pcm, channels: decoded.channels)
            leftPCM = l
            rightPCM = stereo == .stereoLR ? r : nil
        } else {
            leftPCM  = decoded.pcm
            rightPCM = nil
        }

        // Determine the final sample rate.
        let finalRate: UInt32
        if loFi {
            // applyLoFi always targets 22050.
            finalRate = 22050
        } else {
            finalRate = try confirmedAkaiRate(fromRate: decoded.sampleRate, consent: consent)
        }

        // Apply rate conversion.
        let convertedLeft  = convert(leftPCM,  fromRate: decoded.sampleRate, toRate: Int(finalRate), loFi: loFi)
        let convertedRight = rightPCM.map { convert($0, fromRate: decoded.sampleRate, toRate: Int(finalRate), loFi: loFi) }

        // Build name(s).
        if let right = convertedRight {
            // Stereo pair — "<base>-L" / "<base>-R", same number on both.
            let picked = disk.reserveImportNames(for: rawName, stereo: true)
            let leftName  = picked.left
            let rightName = picked.right ?? picked.left
            return [
                Channel(name: leftName,  pcm: convertedLeft, sampleRate: finalRate, isRight: false),
                Channel(name: rightName, pcm: right,         sampleRate: finalRate, isRight: true),
            ]
        } else {
            // Mono (or left-only).
            let name = disk.reserveImportNames(for: rawName, stereo: decoded.channels >= 2,
                                               rightToo: false).left
            return [Channel(name: name, pcm: convertedLeft, sampleRate: finalRate, isRight: false)]
        }
    }

    // MARK: - Stereo mode

    enum StereoMode {
        /// Extract only the left channel (or the only channel for mono files).
        case monoLeft
        /// Return both left and right as separate `Channel` values.
        case stereoLR
    }

    // MARK: - Private helpers

    /// Return the nearest Akai-legal rate (22050 or 44100), prompting the user
    /// if the source rate is not already one of those.
    ///
    /// Runs the alert on the main thread; callers must be on a background thread.
    /// Throws `AkaiError.cancelled` if the user dismisses.
    static func confirmedAkaiRate(fromRate: Int,
                                  consent: ResampleConsent? = nil,
                                  caller: String = #function,
                                  file: String = #fileID,
                                  line: Int = #line) throws -> UInt32 {
        let who = "\(file):\(line) \(caller)"
        guard fromRate != 22050, fromRate != 44100 else {
            NSLog("[IMPORT] confirmedAkaiRate %dHz already legal — no prompt (from %@)", fromRate, who)
            return UInt32(fromRate)
        }
        let target = nearestAkaiRate(fromRate)
        guard let consent else {
            NSLog("[IMPORT] confirmedAkaiRate %dHz NO consent → prompting (from %@)", fromRate, who)
            guard askToResample(fromRate: fromRate) else { throw AkaiError.cancelled }
            return target
        }
        consent.lock.lock(); defer { consent.lock.unlock() }
        if let answer = consent.answer {
            NSLog("[IMPORT] confirmedAkaiRate %dHz consent %@ reused answer=%@ (from %@)",
                  fromRate, consent.id, answer ? "resample" : "cancel", who)
        } else {
            NSLog("[IMPORT] confirmedAkaiRate %dHz consent %@ first ask → prompting (from %@)",
                  fromRate, consent.id, who)
            consent.answer = askToResample(fromRate: fromRate)
        }
        guard consent.answer == true else { throw AkaiError.cancelled }
        return target
    }

    /// Show the resample alert on the main thread. Returns true for Resample.
    private static func askToResample(fromRate: Int) -> Bool {
        let targetRate = Int(nearestAkaiRate(fromRate))
        let rateStr    = fromRate >= 1000 ? "\(fromRate / 1000)kHz" : "\(fromRate)Hz"
        let targetStr  = targetRate == 44100 ? "44.1kHz" : "22kHz"

        var confirmed = false
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = "Resample to \(targetStr)?"
            alert.informativeText =
                "This sample is \(rateStr). The Akai S3000XL only supports " +
                "22kHz and 44.1kHz — importing as-is will cause hiss and wrong pitch."
            alert.addButton(withTitle: "Resample to \(targetStr)")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        NSLog("[IMPORT] prompt answered: %@", confirmed ? "resample" : "cancel")
        return confirmed
    }

    /// The Akai-legal rate (44100 or 22050) closest to `rate`.
    static func nearestAkaiRate(_ rate: Int) -> UInt32 {
        abs(rate - 44100) <= abs(rate - 22050) ? 44100 : 22050
    }

    /// Apply the appropriate rate conversion to a mono 16-bit PCM buffer.
    private static func convert(_ pcm: Data, fromRate: Int, toRate: Int, loFi: Bool) -> Data {
        if loFi {
            return AkaiDiskImage.applyLoFi(pcm: pcm, fromRate: fromRate).0
        } else if fromRate != toRate {
            return AkaiDiskImage.resampleToAkaiRate(pcm: pcm, fromRate: fromRate).0
        } else {
            return pcm
        }
    }
}
