import Foundation

// MARK: - E-mu ESI → Akai S3000 conversion
//
// Turns selected presets of an EmuBank into Akai programs + samples on the
// currently loaded disk, using only the app's existing, hardware-validated
// write paths (addImportedSample / applySampleEdits / createProgram /
// applyProgramEdits) — nothing here writes raw bytes itself.
//
// Mapping:
//   ESI sample            → Akai sample (stereo → "-L"/"-R" pair, like WAV import)
//   ESI loop              → loop points; loop-in-release → "Loop In Release",
//                           otherwise "Loop Until Release"; none → "No Loop"
//   zone original key     → sample root note (rkey). If another zone plays the
//                           same sample from a different original key, the
//                           difference goes into that keygroup's tune.
//   key-map run           → keygroup (low/high key)
//   primary layer         → keygroup with the preset's primary velocity range
//   secondary layer       → a second, overlapping keygroup with the secondary
//                           velocity range (S3000 plays overlapping keygroups)
//   zone tuning (cents)   → keygroup semitone + fine tune
//   zone level / pan      → keygroup loudness / pan (stereo pairs: hard L/R)
//   non-transpose flag    → pitch CONST
//   loop-disable flag     → keygroup playback "No Loop"
//   amp envelope          → ENV1, LINEARLY rescaled 0–127 → 0–99 (APPROXIMATE:
//                           both are lookup tables we haven't measured against
//                           each other — expect envelope times to need tweaking)
//
// Not carried over (no Akai equivalent in this app yet): filter settings,
// LFO/aux envelope routings, preset links (layered preset chains), velocity
// curves, the ESI's crossfade/switch note-zone options.

struct EmuImportOptions {
    /// Halve the space by resampling anything above 22.05 kHz down to 22.05 kHz.
    var downsampleTo22k = false
    /// Import the secondary layer as extra overlapping, velocity-split keygroups.
    var includeSecondaryLayer = true
    /// Rescale the ESI amp envelope onto ENV1. Off = Akai keygroup defaults.
    var convertEnvelopes = true
}

struct EmuImportSummary {
    var programNames: [String] = []
    var sampleCount = 0
    var warnings: [String] = []

    var message: String {
        let p = programNames.count, s = sampleCount
        var m = "Imported \(p) program\(p == 1 ? "" : "s") and \(s) sample\(s == 1 ? "" : "s")"
        if !warnings.isEmpty { m += " (\(warnings.count) warning\(warnings.count == 1 ? "" : "s"))" }
        return m
    }
}

enum EmuToAkai {
    static let maxKeygroups = 99
    static let lofiRate = 22050

    static func blocks(forBytes n: Int) -> Int {
        (n + AkaiDiskFormat.blockSize - 1) / AkaiDiskFormat.blockSize
    }

    /// Frames a sample will have on the Akai disk after optional downsampling.
    static func importedFrames(_ s: EmuSample, options: EmuImportOptions) -> Int {
        guard options.downsampleTo22k, s.sampleRate > lofiRate else { return s.frameCount }
        return Int((Double(s.frameCount) * Double(lofiRate) / Double(s.sampleRate)).rounded(.up)) + 1
    }

    static func blocks(for s: EmuSample, options: EmuImportOptions) -> Int {
        let perChannel = blocks(forBytes: AkaiDiskFormat.sampleHeaderSize + importedFrames(s, options: options) * 2)
        return perChannel * s.channelCount
    }

    /// Keygroups the preset will need on the Akai (before the 99 cap).
    static func keygroupCount(_ p: EmuPreset, options: EmuImportOptions) -> Int {
        p.keyRanges.reduce(0) { n, r in
            n + (r.primary != nil ? 1 : 0) + (options.includeSecondaryLayer && r.secondary != nil ? 1 : 0)
        }
    }

    static func programBlocks(_ p: EmuPreset, options: EmuImportOptions) -> Int {
        let kg = min(maxKeygroups, keygroupCount(p, options: options))
        return blocks(forBytes: 0xC0 + kg * 0xC0)
    }

    /// Total Akai disk blocks needed to import `presets` (shared samples counted once).
    static func estimatedBlocks(_ presets: [EmuPreset], bank: EmuBank, options: EmuImportOptions) -> Int {
        var numbers = Set<Int>()
        var total = 0
        for p in presets {
            total += programBlocks(p, options: options)
            numbers.formUnion(p.sampleNumbers(includeSecondary: options.includeSecondaryLayer))
        }
        for n in numbers {
            if let s = bank.samples[n] { total += blocks(for: s, options: options) }
        }
        return total
    }

    static func scale127to99(_ v: Int) -> UInt8 {
        UInt8(max(0, min(99, Int((Double(min(127, max(0, v))) * 99.0 / 127.0).rounded()))))
    }
}

extension AkaiDiskImage {

    /// Import `presets` from `bank` as new programs + samples on this disk.
    /// Must be called on the main thread (it mutates @Published model state
    /// synchronously so each step sees the previous one's samples/programs).
    @discardableResult
    func importEmuPresets(_ presets: [EmuPreset], from bank: EmuBank,
                          options: EmuImportOptions) throws -> EmuImportSummary {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isLoaded else { throw AkaiError.noImageLoaded }

        let needed = EmuToAkai.estimatedBlocks(presets, bank: bank, options: options)
        let free = freeBlockCount
        guard needed <= free else {
            throw AkaiError.diskFull("These presets need \(needed) KB but only \(free) KB is free on the disk. Deselect some presets or turn on 22 kHz downsampling.")
        }

        var summary = EmuImportSummary()
        let includeSecondary = options.includeSecondaryLayer

        // 1. Choose each sample's root note: the original key of the first zone
        //    (in preset order) that plays it.
        var rootFor: [Int: Int] = [:]
        for p in presets {
            for r in p.keyRanges {
                for z in [r.primary, includeSecondary ? r.secondary : nil].compactMap({ $0 })
                where z.sampleNumber > 0 && rootFor[z.sampleNumber] == nil {
                    rootFor[z.sampleNumber] = z.originalKey
                }
            }
        }

        // 2. Import every referenced sample once.
        struct Imported { let left: String; let right: String; let root: Int }
        var imported: [Int: Imported] = [:]
        var usedNames = Set(samples.map { $0.header.name })
        var missing = Set<Int>()

        for number in rootFor.keys.sorted() {
            guard let s = bank.samples[number] else { missing.insert(number); continue }
            let root = UInt8(max(0, min(127, rootFor[number] ?? 60)))
            let rawName = s.name.isEmpty ? "EMU \(number)" : s.name

            // Optional downsample (same converter as WAV "low quality" import).
            var channels = [s.left, s.right].compactMap { $0 }
            var rate = UInt32(s.sampleRate)
            var loopStart = s.loopStart, loopEnd = s.loopEnd
            if options.downsampleTo22k, s.sampleRate > EmuToAkai.lofiRate {
                let inFrames = s.frameCount
                channels = channels.map { AkaiDiskImage.applyLoFi(pcm: $0, fromRate: s.sampleRate).0 }
                let outFrames = channels.map { $0.count / 2 }.min() ?? 0
                channels = channels.map { $0.prefix(outFrames * 2) }
                rate = UInt32(EmuToAkai.lofiRate)
                if inFrames > 0, let ls = loopStart, let le = loopEnd {
                    let k = Double(outFrames) / Double(inFrames)
                    loopStart = Int((Double(ls) * k).rounded())
                    loopEnd = min(outFrames, Int((Double(le) * k).rounded()))
                }
            }

            let names: [String]
            if channels.count == 2 {
                let base = uniqueSampleBaseName(AkaiDiskImage.sanitizeNamePreservingEnd(rawName, maxLen: 10))
                names = [base + "-L", base + "-R"]
                usedNames.formUnion(names)
            } else {
                names = [AkaiDiskImage.disambiguateSampleName(AkaiDiskImage.sanitizeName(rawName),
                                                              usedNames: &usedNames)]
            }

            for (pcm, name) in zip(channels, names) {
                var sample = try addImportedSample(name: name, sampleRate: rate, numChannels: 1,
                                                   pcmData: pcm, forceName: true)
                let frames = UInt32(pcm.count / 2)
                sample.header.midiRootNote = root
                if let ls = loopStart, let le = loopEnd, le > ls, UInt32(le) <= frames {
                    sample.header.loopStart = UInt32(ls)
                    sample.header.loopEnd = UInt32(le)
                    sample.header.playbackMode = s.loopInRelease ? .loop : .loopNotRel
                } else {
                    sample.header.loopStart = 0
                    sample.header.loopEnd = frames > 0 ? frames - 1 : 0
                    sample.header.playbackMode = .noLoop
                }
                applySampleEdits(sample)
                summary.sampleCount += 1
            }
            imported[number] = Imported(left: names[0], right: names.count > 1 ? names[1] : "",
                                        root: Int(root))
        }
        if !missing.isEmpty {
            summary.warnings.append("\(missing.count) sample slot(s) referenced by these presets are empty in the bank; those keys will be silent.")
        }

        // 3. One program per preset.
        for p in presets {
            // A preset's velocity ranges only split the layers when it really has
            // both. Presets often declare primary 0-63 / secondary 64-127 with
            // no secondary zones at all (every preset on a real ESI-4000 bank
            // tested) — applying the window there would leave everything above
            // velocity 63 silent. Same rule as ConvertWithMoss.
            let hasPrimary = p.keyRanges.contains { $0.primary != nil }
            let hasSecondary = includeSecondary && p.keyRanges.contains { $0.secondary != nil }
            let splitVelocity = hasPrimary && hasSecondary
            let primaryVel = splitVelocity ? p.primaryVelocity : 0...127
            let secondaryVel = splitVelocity ? p.secondaryVelocity : 0...127

            var keyzones: [AkaiProgramKeyzone] = []
            for r in p.keyRanges {
                var layers: [(EmuZone, ClosedRange<Int>)] = []
                if let z = r.primary { layers.append((z, primaryVel)) }
                if includeSecondary, let z = r.secondary { layers.append((z, secondaryVel)) }
                for (z, vel) in layers {
                    guard let smp = imported[z.sampleNumber] else { continue }
                    keyzones.append(makeKeyzone(range: r, zone: z, sample: smp.left,
                                                right: smp.right, sampleRoot: smp.root,
                                                velocity: vel, options: options))
                }
            }
            if keyzones.count > EmuToAkai.maxKeygroups {
                summary.warnings.append("“\(p.name)” has \(keyzones.count) keygroups; only the first \(EmuToAkai.maxKeygroups) were kept.")
                keyzones = Array(keyzones.prefix(EmuToAkai.maxKeygroups))
            }
            if p.link != 0 {
                summary.warnings.append("“\(p.name)” is linked to another preset (layered chain); links aren't imported.")
            }

            var programFile = try createProgram(name: p.name.isEmpty ? "EMU \(p.id + 1)" : p.name)
            programFile.program.keyzones = keyzones
            programFile.program.bendRange = UInt8(max(0, min(12, p.bendRange)))
            applyProgramEdits(programFile)
            summary.programNames.append(programFile.program.name)
        }
        return summary
    }

    private func makeKeyzone(range r: EmuKeyRange, zone z: EmuZone, sample: String, right: String,
                             sampleRoot: Int, velocity: ClosedRange<Int>,
                             options: EmuImportOptions) -> AkaiProgramKeyzone {
        // Pitch: sample root is set from the first zone that used it; any other
        // original key + the zone's own fine tune become keygroup tuning.
        let cents = z.tuningCents + 100 * (sampleRoot - z.originalKey)
        let semis = Int((Double(cents) / 100.0).rounded())
        let fine = max(-50, min(50, cents - semis * 100))

        // Stereo pair unless the zone mutes one side.
        var left = sample, rightName = right
        if !right.isEmpty {
            if z.rightDisabled { rightName = "" }
            else if z.leftDisabled { left = right; rightName = "" }
        }
        let isPair = !rightName.isEmpty
        let pan = isPair ? -50 : max(-50, min(50, (z.pan - 64) * 50 / 63))

        let env = z.ampEnvelope
        let useEnv = options.convertEnvelopes && env.count == 5
        return AkaiProgramKeyzone(
            sampleName: left,
            lowKey: UInt8(max(0, min(127, r.lowKey))),
            highKey: UInt8(max(0, min(127, r.highKey))),
            rootNote: UInt8(max(0, min(127, sampleRoot))),
            tuneOffset: Int8(max(-36, min(36, semis))),
            fineTune: Int8(fine),
            volume: EmuToAkai.scale127to99(z.level),
            pan: Int8(pan),
            filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
            filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
            rightSampleName: rightName,
            rightPan: 50,
            playbackMode: z.loopDisabled ? .noLoop : .sample,
            velocityLow: UInt8(velocity.lowerBound),
            velocityHigh: UInt8(velocity.upperBound),
            env1Attack:  useEnv ? EmuToAkai.scale127to99(Int(env[0])) : AkaiKeyzoneDefaults.env1Attack,
            env1Decay:   useEnv ? EmuToAkai.scale127to99(Int(env[2])) : AkaiKeyzoneDefaults.env1Decay,
            env1Sustain: useEnv ? EmuToAkai.scale127to99(Int(env[3])) : AkaiKeyzoneDefaults.env1Sustain,
            env1Release: useEnv ? EmuToAkai.scale127to99(Int(env[4])) : AkaiKeyzoneDefaults.env1Release,
            pitchMode: z.isNonTranspose ? 1 : 0)
    }
}
