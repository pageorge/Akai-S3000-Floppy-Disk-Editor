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
//   0x1280: label           — akai_flvol_label_s (volume name + osver + params)
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

/// Hardware-confirmed default values for a freshly created keygroup on a real
/// S3000XL, established by byte-diff testing against TEST PROGRAM captures.
/// Use these everywhere defaults are needed: new keyzones, reset buttons,
/// fallback values in parseProgram.
struct AkaiKeyzoneDefaults {
    // ENV1 — confirmed from saw-sine-example.img (TEST PROGRAM on real hardware)
    static let env1Attack:  UInt8 = 25
    static let env1Decay:   UInt8 = 50
    static let env1Sustain: UInt8 = 99
    static let env1Release: UInt8 = 45
    // ENV2 — confirmed from env2-r1-99.img et al. (11 byte-diff captures)
    static let env2R1: UInt8 = 0
    static let env2L1: UInt8 = 99
    static let env2R2: UInt8 = 50
    static let env2L2: UInt8 = 99
    static let env2R3: UInt8 = 50
    static let env2L3: UInt8 = 99
    static let env2R4: UInt8 = 45
    static let env2L4: UInt8 = 0
}

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
    /// AKAI_MULTI3000_FTYPE ('m'+0x80) — akaiutil only documents the file-type
    /// byte and default name for this type ("MULTI FILE"); it has NO struct at
    /// all for the internal layout. This app recognizes real multi files on
    /// disk (so they're visible/renameable/deletable) but does not decode or
    /// edit their actual content — see AkaiMultiFile's doc comment.
    static let ftypeMulti: UInt8    = 0xED

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
    var isMulti:   Bool { fileType == AkaiDiskFormat.ftypeMulti }

    var displayType: String {
        switch fileType {
        case AkaiDiskFormat.ftypeSample:  return "Sample"
        case AkaiDiskFormat.ftypeProgram: return "Program"
        case AkaiDiskFormat.ftypeMulti:   return "Multi"
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
    var playbackMode: AkaiSamplePlaybackMode
    var bitDepth: Int
    var numChannels: Int
    var fineTune: Int8        // ctune: cents tune (0x14), signed
    var semitoneTune: Int8    // stune: semitone tune (0x15), signed
    var loudness: UInt8
    var rawHeader: Data
}

/// Sample-level playback mode (`pmode` @ 0x13 in `akai_sample1000_s`). Same idea
/// as AkaiPlaybackMode for keyzones, but this is THE actual loop behavior a
/// sample carries — what a keyzone's `.sample` playback mode defers to.
/// Matches `SAMPLE1000_PMODE_*` in akaiutil_file.h. Note there is no "inherit"
/// option here (unlike the keyzone enum) since this IS the source of truth;
/// also note the format only ever has ONE active loop region per sample for our
/// purposes (loop[0]) even though the struct technically has 8 slots — see the
/// `loop[8]` / `lnum` note where loopStart/loopEnd are read.
enum AkaiSamplePlaybackMode: UInt8, CaseIterable, Identifiable {
    case loop       = 0x00   // SAMPLE1000_PMODE_LOOP
    case loopNotRel = 0x01   // SAMPLE1000_PMODE_LOOPNOTREL: loop, but no release tail on key-up
    case noLoop     = 0x02   // SAMPLE1000_PMODE_NOLOOP
    case toEnd      = 0x03   // SAMPLE1000_PMODE_TOEND: play to end regardless of key-up or loop points

    var id: UInt8 { rawValue }

    var displayName: String {
        switch self {
        case .loop:       return "Loop"
        case .loopNotRel: return "Loop Until Release"
        case .noLoop:     return "No Loop"
        case .toEnd:      return "Play to End"
        }
    }

    /// User-facing explanation shown under the Playback Mode picker in Sample Edit.
    var explanation: String {
        switch self {
        case .loop:
            return "This sample will loop between the start/end points below for as long as the key is held."
        case .loopNotRel:
            return "This sample will loop between the start/end points below, but will NOT play a release tail when the key is lifted — it just stops."
        case .noLoop:
            return "This sample will play straight through once and stop. The start/end points below are ignored during playback (but kept here so you can switch back to a loop mode without losing them)."
        case .toEnd:
            return "This sample will always play out to the very end — ignoring both the loop points and key-up — even if the key is released early."
        }
    }
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
    /// Per-velocity-zone filter cutoff fine-tune, signed, range ±50 —
    /// `filter` @ +0x11 in `akai_program1000kgvelzone_s`. Confirmed against the
    /// real S3000XL Operator's Manual (SMP2 page, p.93): "This parameter allows
    /// you to fine tune the filter cutoff slightly to maintain a consistent tone
    /// between keygroups." This is layered ON TOP of `filterCutoff` below.
    var filterOffset: Int8
    /// Keygroup-level filter cutoff, 0–99 — `filter` @ kg+0x07 in
    /// `akai_program1000kg_s`. CONFIRMED BY REAL HARDWARE BYTE-DIFF (not just
    /// struct field naming): a single-variable test on a real S3000XL —
    /// Frequency 99→50, every other FILT-page control held at baseline —
    /// produced exactly ONE changed byte in the saved program file, at kg+0x07,
    /// going 0x63 (99) → 0x32 (50). Raw byte = the literal 0–99 value, no
    /// scaling or sign bit. So despite akaiutil's struct calling this single
    /// byte just `filter`, it is literally the Frequency/cutoff control itself,
    /// not an offset (the offset is the per-zone `filterOffset` above).
    var filterCutoff: UInt8
    /// Keygroup-level filter key-follow, signed — `dummy1[0]`/kg+0x08 in
    /// `akai_program1000kg_s` (the first byte of akaiutil's undocumented 22-byte
    /// dummy region). CONFIRMED BY REAL HARDWARE BYTE-DIFF: a test changing ONLY
    /// Key Follow 12→0 (Frequency left at a known, already-confirmed value)
    /// produced exactly that single additional byte change at kg+0x08, going
    /// 0x0c(12)→0x00(0) — raw byte, no scaling. The manual (p.97) describes +12
    /// (octave-for-octave tracking) as "the default," but a real, never-touched
    /// keygroup (a fresh KG on a copy of TEST PROGRAM, never edited) was
    /// photographed showing key follow: +00 — so the TRUE factory/blank default
    /// is 0 (no key tracking at all), not +12. +12 is better described as the
    /// manual's recommended starting point for normal tonal playing, not what a
    /// fresh keygroup actually contains. Negative values not yet hardware-tested,
    /// so sign encoding (two's complement assumed) is unconfirmed for that range.
    var filterKeyFollow: Int8
    /// Keygroup-level filter resonance, 0–15 — `kg+0x95`, WELL PAST the end of
    /// akaiutil's documented `akai_program1000kg_s` struct (which only maps out
    /// to relative offset 0x82, the end of the 4th velocity zone) — genuinely
    /// new territory, not in any source we'd referenced before. CONFIRMED BY
    /// REAL HARDWARE BYTE-DIFF: a save with ONLY Resonance changed 0→15
    /// (relative to the prior reference capture) differed in exactly that one
    /// byte: `kg+0x95` went `0x00`→`0x0f`(15) — direct, unscaled. Boosts
    /// harmonics around the cutoff; high settings give the classic synth
    /// "weeow" sound (manual, p.97).
    var filterResonance: UInt8
    /// Keygroup-level filter modulation depth #1 (default source: Velocity→Freq),
    /// signed, range ±50 — `kg+0x97`. CONFIRMED BY REAL HARDWARE BYTE-DIFF:
    /// isolated test changing ONLY this depth 0→50 produced exactly one changed
    /// byte, `kg+0x97` 0x00→0x32(50) — direct, unscaled. This also retroactively
    /// explained an earlier ambiguous combined-change capture that showed
    /// kg+0x95/0x97/0x98/0x99 all non-zero at once (Resonance + the 3 mod depths,
    /// strongly suggesting they're adjacent in memory with kg+0x96 unused/padding
    /// between Resonance and this group) — but ONLY this one (kg+0x97) has
    /// actually been independently isolated; mod depths #2/#3 are deliberately
    /// NOT yet modeled here, pending their own isolated tests, to avoid writing
    /// to bytes we haven't individually confirmed (same discipline as everywhere
    /// else in this format). Source selector (Modwheel/Bend/Pressure/External/
    /// Key/Lfo1/Env1/Velocity/Lfo2/Env2 + "!" variants) not yet located either.
    var filterModDepth1: Int8
    /// Keygroup-level filter modulation depth #2 (default source: Lfo2→Freq),
    /// signed, range ±50 — `kg+0x98`. CONFIRMED BY REAL HARDWARE BYTE-DIFF:
    /// isolated test changing ONLY this depth 0→50 produced exactly one changed
    /// byte, `kg+0x98` 0x00→0x32(50) — direct, unscaled, confirming the adjacency
    /// pattern predicted from depth #1. Source selector not yet located.
    var filterModDepth2: Int8
    /// Keygroup-level filter modulation depth #3 (default source: Env2→Freq),
    /// signed, range ±50 — `kg+0x99`. CONFIRMED BY REAL HARDWARE BYTE-DIFF:
    /// isolated test changing ONLY this depth 0→50 produced exactly one changed
    /// byte, `kg+0x99` 0x00→0x32(50) — direct, unscaled. Completes the 3-byte
    /// adjacency run (0x97/0x98/0x99) predicted from depth #1, now confirmed
    /// three-for-three by isolated single-variable tests. Source selector not
    /// yet located for any of the three depths.
    var filterModDepth3: Int8
    /// Zone 2: the RIGHT channel of a stereo sample pair, assigned alongside
    /// `sampleName` (the LEFT channel, in zone 1) within this SAME keygroup —
    /// confirmed as the real hardware convention by the S3000XL Operator's
    /// Manual (p.51-52): "the left and right samples are assigned to their own
    /// zones (1 and 2 respectively) in ONE keygroup and each zone is panned hard
    /// left and hard right," and explicitly NOT two separate keygroups — "a
    /// stereo program with 5 keygroups would typically show 10 samples (5 x L
    /// and R)." Empty string = mono keygroup, no zone 2. When non-empty, zone 2
    /// mirrors zone 1's velocity range/tune/filter-trim/playback mode (they're
    /// meant to trigger together) — only the sample name and pan genuinely
    /// differ between the two zones.
    var rightSampleName: String
    /// Zone 2's pan, signed ±50. Real hardware convention is hard right (+50)
    /// to pair with zone 1 panned hard left (−50) — the app sets both
    /// automatically the first time a right-channel sample is assigned, but
    /// either can be adjusted afterward.
    var rightPan: Int8
    var playbackMode: AkaiPlaybackMode
    var velocityLow: UInt8
    var velocityHigh: UInt8
    // ENV1 (amplitude envelope) — confirmed by real hardware byte-diff.
    // Simple ADSR: A=0 = instant attack, D=50, S=99, R=45 are hardware defaults.
    // kg+0x0C = Attack, kg+0x0D = Decay, kg+0x0E = Sustain, kg+0x0F = Release.
    var env1Attack: UInt8 = AkaiKeyzoneDefaults.env1Attack
    var env1Decay: UInt8 = AkaiKeyzoneDefaults.env1Decay
    var env1Sustain: UInt8 = AkaiKeyzoneDefaults.env1Sustain
    var env1Release: UInt8 = AkaiKeyzoneDefaults.env1Release
    // ENV2 (filter envelope) — 4-stage Rate/Level envelope. Confirmed by real
    // hardware byte-diff (11 captures). Layout is NON-LINEAR — rates and levels
    // are split across two separate regions:
    //   Rates:  kg+0x14=R1, kg+0x15=R3, kg+0x16=L3(sustain level), kg+0x17=R4
    //   Levels: kg+0x9C=L1, kg+0x9D=R2, kg+0x9E=L2, kg+0x9F=L4
    // Hardware defaults: R1=0, R2=50, R3=50, R4=45, L1=99, L2=99, L3=99, L4=0
    var env2R1: UInt8 = AkaiKeyzoneDefaults.env2R1
    var env2L1: UInt8 = AkaiKeyzoneDefaults.env2L1
    var env2R2: UInt8 = AkaiKeyzoneDefaults.env2R2
    var env2L2: UInt8 = AkaiKeyzoneDefaults.env2L2
    var env2R3: UInt8 = AkaiKeyzoneDefaults.env2R3
    var env2L3: UInt8 = AkaiKeyzoneDefaults.env2L3
    var env2R4: UInt8 = AkaiKeyzoneDefaults.env2R4
    var env2L4: UInt8 = AkaiKeyzoneDefaults.env2L4
}

/// The full set of modulation sources selectable for any of the 3 filter
/// mod-depth slots, captured directly off a real S3000XL's FILT page (cycling
/// through every option via the DATA wheel) — not inferred from the manual.
/// Raw values are the CONFIRMED on-disk index (0–13), matching the hardware's
/// own cycle order exactly: a real-hardware byte-diff test (No Source →
/// Modwheel for slot 1) produced exactly one changed byte, going `0x00`→`0x01`
/// — i.e. a direct cycle-position index, not a separate bit-flag or code.
/// Three sources (Modwheel, Bend, External) have a second "!" note-on-only
/// variant; the others (Pressure, Velocity, Key, Lfo1, Lfo2, Env1, Env2) do
/// not — confirmed by cycling the full list on real hardware, not assumed for
/// symmetry.
enum AkaiFilterModSource: UInt8, CaseIterable, Identifiable, Codable {
    case noSource        = 0
    case modwheel        = 1
    case bend            = 2
    case pressure        = 3
    case external        = 4
    case velocity        = 5
    case key             = 6
    case lfo1            = 7
    case lfo2            = 8
    case env1            = 9
    case env2            = 10
    case modwheelNoteOn  = 11
    case bendNoteOn      = 12
    case externalNoteOn  = 13

    var id: UInt8 { rawValue }

    var helpText: String {
        switch self {
        case .noSource:       return "No modulation source assigned to this slot."
        case .modwheel:       return "Moving the modwheel opens and closes the filter cutoff. Useful for phrasing brass parts or synth filter effects."
        case .bend:           return "The pitchbend wheel opens and closes the filter. Effective when bending up into a note as the filter opens and sounds brighter."
        case .pressure:       return "Aftertouch (key pressure) controls the filter. Good for expressive swells, particularly on brass sounds."
        case .external:       return "External controller (footpedal, volume, or breath) controls the filter cutoff."
        case .velocity:       return "Note velocity controls the filter — louder notes yield brighter sounds. Default mod source for tonal dynamics on acoustic instruments."
        case .key:            return "Keyboard position modulates the filter, though this largely overlaps with the Key Follow parameter."
        case .lfo1:           return "LFO 1 sweeps the filter. Small amounts emulate natural tremolo on flutes, woodwind, and brass. Large amounts give classic synth filter sweeps."
        case .lfo2:           return "LFO 2 sweeps the filter. Default second mod source — useful for filter sweep effects."
        case .env1:           return "Amplitude envelope (ENV1) also shapes the filter, matching tonal and amplitude dynamics without needing to copy the envelope."
        case .env2:           return "Filter envelope (ENV2) shapes tonal dynamics and restores harmonic movement lost through looping. Default third mod source."
        case .modwheelNoteOn: return "Modwheel position at the moment of note-on sets the filter opening. Has no effect if the modwheel moves after the note is pressed."
        case .bendNoteOn:     return "Pitchbend position at note-on sets the filter opening. Has no effect if bend changes after the note is pressed."
        case .externalNoteOn: return "External controller position at note-on sets the filter opening. Has no effect if the controller changes after the note is pressed."
        }
    }

    var displayName: String {
        switch self {
        case .noSource:       return "No Source"
        case .modwheel:       return "Modwheel"
        case .bend:           return "Bend"
        case .pressure:       return "Pressure"
        case .external:       return "External"
        case .velocity:       return "Velocity"
        case .key:            return "Key"
        case .lfo1:           return "Lfo1"
        case .lfo2:           return "Lfo2"
        case .env1:           return "Env1"
        case .env2:           return "Env2"
        case .modwheelNoteOn: return "!Modwheel"
        case .bendNoteOn:     return "!Bend"
        case .externalNoteOn: return "!External"
        }
    }
}

/// Velocity-zone playback mode (`pmode` @ +0x13 in `akai_program1000kgvelzone_s`).
/// This is NOT just a loop on/off switch — it's the full set of options a real
/// S3000 offers per keyzone/velocity-zone, matching `PROGRAM1000_PMODE_*` in
/// akaiutil_file.h. `.sample` (raw 0x00) is both "inherit the sample's own loop
/// setting" AND the natural zero-value default — i.e. it's what a freshly
/// created keygroup gets if nothing overrides it, which is why new keyzones in
/// this app default to it (mimicking real hardware) rather than to `.noLoop`.
enum AkaiPlaybackMode: UInt8, CaseIterable, Identifiable {
    case sample      = 0x00   // PROGRAM1000_PMODE_SAMPLE: use the sample's own loop setting
    case loop        = 0x01   // PROGRAM1000_PMODE_LOOP: force loop
    case loopNotRel  = 0x02   // PROGRAM1000_PMODE_LOOPNOTREL: force loop, don't release into the tail on key-up
    case noLoop      = 0x03   // PROGRAM1000_PMODE_NOLOOP: force no loop, overriding the sample
    case toEnd       = 0x04   // PROGRAM1000_PMODE_TOEND: play to end regardless of key-up or loop points

    var id: UInt8 { rawValue }

    var displayName: String {
        switch self {
        case .sample:     return "Sample's Setting"
        case .loop:       return "Loop"
        case .loopNotRel: return "Loop Until Release"
        case .noLoop:     return "No Loop"
        case .toEnd:      return "Play to End"
        }
    }

    /// User-facing explanation shown under the Playback Mode picker. Spells out
    /// what will actually happen on playback, since "pmode" naming alone (even
    /// translated to e.g. "Loop Until Release") doesn't make the behavior obvious
    /// — and critically, makes clear that the loop POINTS always come from the
    /// sample itself (set in Sample Edit), never from the keyzone.
    var explanation: String {
        switch self {
        case .sample:
            return "Playback will use this sample's own loop setting from Sample Edit — if the sample loops, this keyzone loops; if not, it won't."
        case .loop:
            return "Playback will loop using the start/end points set on the sample in Sample Edit, for as long as the key is held."
        case .loopNotRel:
            return "Playback will loop (using the sample's loop points) but will NOT play any release tail when the key is lifted — it just stops."
        case .noLoop:
            return "Playback will ignore the sample's loop points entirely and just play through once, stopping at the end (or on key-up)."
        case .toEnd:
            return "Playback will ignore both the loop points and key-up — the whole sample plays out to the end no matter what."
        }
    }
}

/// Voice priority when polyphony limit is reached — hdr+0x12.
/// LOW=0, NORM=1, HIGH=2. Hardware-confirmed by byte-diff.
enum AkaiProgramPriority: UInt8, CaseIterable, Identifiable {
    case low  = 0
    case norm = 1
    case high = 2
    case hold = 3
    var id: UInt8 { rawValue }
    var displayName: String {
        switch self { case .low: return "LOW"; case .norm: return "NORM"; case .high: return "HIGH"; case .hold: return "HOLD" }
    }
}

/// Voice reassignment mode when all voices are in use — hdr+0x3D.
/// OLDEST=0, QUIETEST=1. Hardware-confirmed by byte-diff.
enum AkaiProgramReassignment: UInt8, CaseIterable, Identifiable {
    case oldest   = 0
    case quietest = 1
    var id: UInt8 { rawValue }
    var displayName: String {
        switch self { case .oldest: return "OLDEST"; case .quietest: return "QUIETEST" }
    }
}

struct AkaiProgram {
    var name: String
    var keyzones: [AkaiProgramKeyzone]
    var midiChannel: UInt8
    var polyphony: UInt8          // hdr+0x11, 0-indexed (value = voices - 1), range 0–31
    var priority: AkaiProgramPriority       // hdr+0x12, hardware-confirmed
    var reassignment: AkaiProgramReassignment   // hdr+0x3D, hardware-confirmed
    var bendRange: UInt8
    /// Master "stereo level" — program header offset `0x17`, 0–99. The OUTPUT
    /// LEVELS page's level of the program at the main L/R stereo outs (manual,
    /// p.66): "By setting this field to 00, you may use this parameter to mix a
    /// program out of the L/R mix completely." CONFIRMED BY REAL HARDWARE
    /// BYTE-DIFF: an isolated test changing ONLY this field 0→99 produced that
    /// exact byte change (`0x17`: `0x00`→`0x63`), found while diagnosing a
    /// real "no audio at all" bug — this app previously always wrote 0 here
    /// (akaiutil leaves this whole region as undocumented dummy bytes), which is
    /// the real silence, since 0 mixes the program out of the L/R bus entirely.
    var stereoLevel: UInt8
    /// "Basic loudness" — program header offset `0x19`, 0–99. Same OUTPUT LEVELS
    /// page, LOUDNESS CONTROL column: the base loudness every note starts from
    /// before velocity sensitivity (`velocity > loud`) is applied — manual:
    /// "at a setting of 99, the program is at maximum level but you will not
    /// have any velocity sensitivity." CONFIRMED BY REAL HARDWARE BYTE-DIFF:
    /// isolated test 0→80 produced exactly one changed byte (`0x19`:
    /// `0x00`→`0x50`). A real factory TEST PROGRAM shows this at 80 by default;
    /// this app previously always wrote 0, contributing to the same silence bug
    /// as stereoLevel above.
    var basicLoudness: UInt8
    /// Modulation SOURCE for filter mod-depth slot #1/#2/#3 — program header
    /// offsets `0x54`/`0x55`/`0x56`. CONFIRMED BY REAL HARDWARE BYTE-DIFF: a
    /// sequence of isolated single-variable tests, each changing exactly ONE
    /// slot's source from "No Source" to "Modwheel" (leaving the others and all
    /// depth amounts untouched), produced exactly one new changed byte each
    /// time: `0x54`→`0x01`, then `0x55`→`0x01`, then `0x56`→`0x01` — a direct
    /// index into the 14-option list (see AkaiFilterModSource), one byte per
    /// slot, three consecutive bytes.
    ///
    /// IMPORTANT: despite being shown per-keygroup on the real FILT page, these
    /// are PROGRAM-LEVEL bytes (within the 0xC0-byte header, not any keygroup's
    /// own 0xC0-byte region) — i.e. one shared source routing per slot for the
    /// WHOLE program, not per keygroup. Only the depth AMOUNTS
    /// (filterModDepth1/2/3 on AkaiProgramKeyzone) are genuinely per-keygroup;
    /// the source choice applies to every keygroup in the program at once. This
    /// was discovered by accident: an early test diffing two keygroups in the
    /// same program showed the change landing in the header region rather than
    /// either keygroup's body.
    var filterModSource1: AkaiFilterModSource
    var filterModSource2: AkaiFilterModSource
    var filterModSource3: AkaiFilterModSource
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

/// One "part" (1–16) of a MULTI — the MIX page's per-part settings, as shown
/// on the real S3000XL screen: program assignment, MIDI channel, level, pan,
/// FX bus + send.
///
/// ALL 16 PARTS ARE NOW CONFIRMED BY REAL HARDWARE BYTE-DIFF (see
/// AkaiMultiFile's doc comment for the full method). Part 1's fields were
/// isolated first (7 captures), then one more test — assigning ONLY Part 2's
/// program — revealed the per-part STRIDE: Part 2's record landed at absolute
/// `0x4C0`, exactly `0xC0` (192) bytes after Part 1's `0x400`. Confirmed beyond
/// doubt: `header(0x400) + 16 × 0xC0 = 0x1000 (4096)` exactly matches every
/// multi file's real size.
///
/// So Part N's record starts at absolute `0x400 + (N-1) × 0xC0`
/// (`AkaiMultiFormat.partBase`), and within that record, relative to the
/// part's own base:
///   - `+0x00`: constant `0x01` (record marker, unconfirmed purpose)
///   - `+0x01`–`+0x02`: 2-byte program link pointer, sampler-managed (like
///     kg1a/shdra elsewhere) — changes whenever the program assignment
///     changes, but isn't something we compute ourselves
///   - `+0x03`–`+0x0E`: **program name**, 12 bytes Akai-encoded (confirmed on
///     both Part 1 and Part 2: `TEST PROGRAM` → `TEST PROG 2`/`TEST PROG 1`
///     byte-for-byte at the predicted relative position both times)
///   - `+0x0F`: separator/padding, unconfirmed
///   - `+0x10`: **channel**, 0-indexed (confirmed: `0x00`→`0x01` for ch.1→ch.2)
///   - `+0x11`–`+0x16`: unconfirmed gap (6 bytes)
///   - `+0x17`: **level**, 0–99 direct (confirmed: default `99`→`56`)
///   - `+0x18`: **pan**, signed (confirmed: default `0`→`2`)
///   - `+0x19`–`+0x70`: unconfirmed gap (88 bytes)
///   - `+0x71`: **fx bus**, index into OFF/FX1/FX2/RV3/RV4 (confirmed: `0`→`1`
///     for OFF→FX1; FX2/RV3/RV4 = 2/3/4 inferred from cycle order, NOT
///     independently tested)
///   - `+0x72`: **send**, 0–99 direct (confirmed: default `25`→`60`)
///   - `+0xBE`–`+0xBF`: a second 2-byte sampler-managed pointer (confirmed on
///     both Part 1 and Part 2; resolves from `0xFFFF`/none to a real value once
///     a program is assigned — same convention as a velocity zone's `shdra`).
///     Not written by this app.
///
/// This app reads/writes ALL 16 parts of a real MULTI file using these
/// offsets (see `applyMultiPartEdit`). The two small gaps within each part's
/// own record (`+0x11`–`+0x16`, `+0x19`–`+0x70`) remain unconfirmed and are
/// preserved byte-for-byte, never written.
struct AkaiMultiPart {
    /// Empty = no program assigned (shown as "?" on the real hardware screen).
    var programName: String = ""
    /// 1-indexed (1...16) in this model; on-disk is 0-indexed — translated at
    /// the read/write boundary, matching AkaiProgram.midiChannel's convention.
    var channel: UInt8 = 1
    var level: UInt8 = 99
    var pan: Int8 = 0
    var fxBus: AkaiFxBus = .off
    var fxSend: UInt8 = 25
}

/// FX bus assignment for a multi part's effects send (manual, p.38: "FX1, FX2,
/// RV3, RV4"), and separately for a program's own FX bus (OUTPUT LEVELS page).
enum AkaiFxBus: String, CaseIterable, Identifiable {
    case off = "OFF"
    case fx1 = "FX1"
    case fx2 = "FX2"
    case rv3 = "RV3"
    case rv4 = "RV4"
    var id: String { rawValue }

    /// On-disk index at Part 1's `+0x71`. OFF=0 and FX1=1 are CONFIRMED by
    /// real-hardware byte-diff; FX2=2/RV3=3/RV4=4 are inferred from the cycle
    /// order shown on screen, not independently isolated yet.
    var byteValue: UInt8 {
        switch self {
        case .off: return 0
        case .fx1: return 1
        case .fx2: return 2
        case .rv3: return 3
        case .rv4: return 4
        }
    }

    init(byteValue: UInt8) {
        self = AkaiFxBus.allCases.first { $0.byteValue == byteValue } ?? .off
    }
}

/// A MULTI: up to 16 parts, each layering a program on its own MIDI channel
/// with its own level/pan/FX send — the manual's "MIX" page. See
/// AkaiMultiFile's doc comment for what is and isn't real here yet.
struct AkaiMulti {
    var name: String
    var parts: [AkaiMultiPart]

    static func blank(name: String = "NEW MULTI") -> AkaiMulti {
        AkaiMulti(name: name, parts: (1...16).map { i in
            var p = AkaiMultiPart()
            p.channel = UInt8(min(i, 16))
            return p
        })
    }
}

/// A MULTI file found on (or staged for) disk.
///
/// Unlike every other file type in this app: akaiutil has NO struct at all for
/// MULTI files, only the bare file-type byte and default name
/// (`AKAI_MULTI3000_FTYPE`/`AKAI_MULTI3000_FNAME`). Every other format in this
/// app started from at least a partial struct skeleton that hardware testing
/// then confirmed/corrected; MULTI started from nothing, and was reverse-
/// engineered entirely from scratch via isolated hardware byte-diff tests —
/// same method as the filter section, just with no prior art to start from.
///
/// CONFIRMED (real-hardware byte-diff, 8 captures total: a baseline, one
/// isolated change per field on Part 1, plus one more isolating the per-part
/// stride via Part 2):
///   - Multi-level header spans the first `0x400` (1024) bytes of the file.
///     Its own internal layout (the multi's own name field, etc.) is NOT yet
///     investigated.
///   - Every part's full field layout, ALL 16 of them — see AkaiMultiPart's
///     doc comment for the complete offset table and the stride confirmation.
///
/// NOT yet confirmed:
///   - The two small unconfirmed gaps within each part's own record.
///   - The multi-level header's internal layout (bytes `0x000`–`0x3FF`),
///     including wherever the multi's own name is stored — renaming currently
///     only patches the directory entry's name, not any internal field.
///
/// Practical effect on this app's behavior:
///   - `isContentReal: true` (a real file on disk) — ALL 16 parts' confirmed
///     fields are decoded from real bytes and safe to edit/save (see
///     `applyMultiPartEdit`). Only the two small per-part gaps and the
///     multi-level header are left untouched.
///   - `isContentReal: false` — a fresh in-app "preview" multi, entirely
///     in-memory, never written anywhere. Still useful for planning a multi
///     before it has a backing file on disk to save into.
struct AkaiMultiFile: Identifiable {
    var id = UUID()
    var directoryEntry: AkaiDirectoryEntry?
    var multi: AkaiMulti
    var isContentReal: Bool
}

/// Confirmed absolute byte offsets for a real MULTI file's part records —
/// see AkaiMultiPart's doc comment for the full evidence/method. `partIndex`
/// is 0-based (0...15) for Parts 1...16.
struct AkaiMultiFormat {
    static let firstPartBase       = 0x400
    static let partStride          = 0xC0   // confirmed via Part 2's program-assignment test
    static let relNameOffset       = 0x03   // 12 bytes, Akai-encoded
    static let relChannelOffset    = 0x10   // 0-indexed
    static let relLevelOffset      = 0x17   // 0-99 direct
    static let relPanOffset        = 0x18   // signed
    static let relFxBusOffset      = 0x71   // index, see AkaiFxBus.byteValue
    static let relSendOffset       = 0x72   // 0-99 direct

    static func partBase(_ partIndex: Int) -> Int { firstPartBase + partIndex * partStride }
    /// Minimum file size for `partIndex`'s confirmed fields to be safely
    /// readable/writable.
    static func minSizeForPart(_ partIndex: Int) -> Int { partBase(partIndex) + relSendOffset + 1 }
}

// MARK: - Disk Image

class AkaiDiskImage: ObservableObject {
    @Published var isLoaded    = false
    @Published var diskName    = ""
    @Published var samples:  [AkaiSample]      = []
    @Published var programs: [AkaiProgramFile] = []
    /// Real MULTI files found on disk. See AkaiMultiFile's doc comment —
    /// all 16 parts' confirmed fields are decoded from real bytes and safe to
    /// edit/save; only two small per-part gaps and the multi-level header
    /// remain undecoded.
    @Published var multis: [AkaiMultiFile] = []
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
        multis = []
        diskName = ""
        freeBlocks = 0
        totalBlocks = AkaiDiskFormat.totalBlocks
        hasUnsavedChanges = false
        isEditingText = false
        isLoaded = false
    }

    private func parseImage(data: Data) throws {
        // Volume label (akai_flvol_label_s.name) lives at ABSOLUTE offset 0x1280
        // within the header (blocks 0-4), per akai_flhhead_s:
        //   file[64] (64*24 = 0x600) + fatblk[1600][2] (1600*2 = 0xC80) = 0x1280.
        // A previous offset of 0xD80 was wrong — that's only (0xD80-0x600)/2 = 960
        // entries into the FAT table, i.e. the FAT entry for block 960, not the
        // label. That meant we were reading a FAT value as the volume name while
        // the real (zero-filled) label sat untouched — which a real S3000 renders
        // as "000000000000" (Akai char code 0x00 = digit '0').
        let labelOffset = 0x1280
        diskName = labelOffset + 12 <= data.count
            ? akaiString(from: data, offset: labelOffset, length: 12)
            : ""
        freeBlocks = countFreeBlocks(data: data)
        let (parsedSamples, parsedPrograms, parsedMultis) = try parseDirectory(data: data)
        DispatchQueue.main.async {
            self.samples  = parsedSamples
            self.programs = parsedPrograms
            self.multis   = parsedMultis
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

    private func parseDirectory(data: Data) throws -> ([AkaiSample], [AkaiProgramFile], [AkaiMultiFile]) {
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
            guard ftype == AkaiDiskFormat.ftypeSample || ftype == AkaiDiskFormat.ftypeProgram
                || ftype == AkaiDiskFormat.ftypeMulti else { continue }
            let name  = akaiString(from: data, offset: base, length: 12)
            let size  = UInt32(data[base+17]) | (UInt32(data[base+18]) << 8) | (UInt32(data[base+19]) << 16)
            let start = UInt16(data[base+20]) | (UInt16(data[base+21]) << 8)
            entries.append(AkaiDirectoryEntry(name: name, fileType: ftype, startBlock: start, size: size,
                                              rawEntry: Data(data[base..<base+entrySize]),
                                              diskOffset: base))
        }

        var parsedSamples:  [AkaiSample]      = []
        var parsedPrograms: [AkaiProgramFile] = []
        var parsedMultis:   [AkaiMultiFile]   = []
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
            } else if entry.isMulti {
                // Most of the content is NOT decoded (the multi-level header and
                // two small per-part gaps — no struct exists for those) — but
                // ALL 16 parts' confirmed fields ARE decoded (see AkaiMultiPart's
                // doc comment for the confirmed stride/offsets).
                let chain = fatChain(from: Int(entry.startBlock), data: data)
                let fileData = readFromChain(chain, fileOffset: 0, length: Int(entry.size), data: data)
                var parts = [AkaiMultiPart](repeating: AkaiMultiPart(), count: 16)
                for partIndex in 0..<16 {
                    guard fileData.count >= AkaiMultiFormat.minSizeForPart(partIndex) else { continue }
                    let base = AkaiMultiFormat.partBase(partIndex)
                    var p = AkaiMultiPart()
                    p.programName = akaiString(from: fileData, offset: base + AkaiMultiFormat.relNameOffset, length: 12)
                    p.channel = fileData[base + AkaiMultiFormat.relChannelOffset] &+ 1   // disk 0-indexed -> model 1-indexed
                    p.level = fileData[base + AkaiMultiFormat.relLevelOffset]
                    p.pan = Int8(bitPattern: fileData[base + AkaiMultiFormat.relPanOffset])
                    p.fxBus = AkaiFxBus(byteValue: fileData[base + AkaiMultiFormat.relFxBusOffset])
                    p.fxSend = fileData[base + AkaiMultiFormat.relSendOffset]
                    parts[partIndex] = p
                }
                parsedMultis.append(AkaiMultiFile(
                    directoryEntry: entry,
                    multi: AkaiMulti(name: entry.name, parts: parts),
                    isContentReal: true))
            }
        }

        return (parsedSamples, parsedPrograms, parsedMultis)
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

        // pmode @ 0x13: full 4-state byte (see AkaiSamplePlaybackMode). Fall
        // back to .noLoop for any unrecognized byte value.
        let playbackMode = AkaiSamplePlaybackMode(rawValue: headerData[0x13]) ?? .noLoop

        // loop[0]: at[4] @ 0x26, flen[2] @ 0x2A (fine length, 1/65536 sample),
        // len[4] @ 0x2C. CORRECTED (found while investigating a real loop-point
        // mismatch against actual Akai hardware): `at` is the loop's RIGHT-HAND
        // boundary (the return-to point), NOT the left/start as we'd previously
        // assumed — the real region is `[at - len, at)`, not `[at, at+len)`.
        //
        // Proof, from a real factory SAWTOOTH sample (S3000XL hardware screens +
        // this exact file's bytes cross-referenced): TRIM page shows
        // start=22/end=255; LOOP page shows at=192, lng=168.562 (displaying
        // `len + flen/65536` as a single fractional value: 168 + 36831/65536 =
        // 168.562, confirming flen is real and must be included). The OLD
        // (forward) interpretation gives `[192, 360.6)` — past the end of the
        // 256-frame buffer entirely, which is impossible. The NEW (backward)
        // interpretation gives `[192-168.56, 192)` ≈ `[23.4, 192)`, matching the
        // real TRIM start (22) almost exactly. The previous code comment here
        // claiming "verified by hardware testing: at=48,len=48 produces a
        // 48-sample loop (48→96)" was apparently never actually confirmed
        // against real hardware playback — this cross-reference is the first
        // genuine confirmation either direction has had.
        let loopAt = UInt32(headerData[AkaiDiskFormat.hdrLoopAtOffset]) |
                        (UInt32(headerData[AkaiDiskFormat.hdrLoopAtOffset + 1]) << 8) |
                        (UInt32(headerData[AkaiDiskFormat.hdrLoopAtOffset + 2]) << 16) |
                        (UInt32(headerData[AkaiDiskFormat.hdrLoopAtOffset + 3]) << 24)
        let loopLenInt = UInt32(headerData[AkaiDiskFormat.hdrLoopLenOffset]) |
                      (UInt32(headerData[AkaiDiskFormat.hdrLoopLenOffset + 1]) << 8) |
                      (UInt32(headerData[AkaiDiskFormat.hdrLoopLenOffset + 2]) << 16) |
                      (UInt32(headerData[AkaiDiskFormat.hdrLoopLenOffset + 3]) << 24)
        // flen is sub-sample fine length (1/65536ths) — we don't model fractional
        // positions in the UI (sliders are whole-sample), so round to the
        // nearest whole sample for display/editing purposes. This loses the same
        // sub-sample precision a basic "drag a slider to a sample number" editor
        // would lose regardless.
        let loopFlen = UInt32(headerData[AkaiDiskFormat.hdrLoopFineOffset]) |
                       (UInt32(headerData[AkaiDiskFormat.hdrLoopFineOffset + 1]) << 8)
        let loopLenTotal = loopLenInt + (loopFlen >= 32768 ? 1 : 0)   // round, don't truncate
        let loopEnd = min(loopAt, numSamples)
        let loopStart = loopEnd > loopLenTotal ? loopEnd - loopLenTotal : 0
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
            playbackMode: playbackMode,
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
        // Polyphony @ hdr+0x11: 0-indexed (0=1 voice, 31=32 voices). Default 32 voices.
        let rawPoly = fileData.count > 0x11 ? fileData[0x11] : 31
        let polyphony: UInt8 = rawPoly &+ 1
        // Priority @ hdr+0x12: LOW=0, NORM=1, HIGH=2. Hardware-confirmed.
        let priority = fileData.count > 0x12 ? (AkaiProgramPriority(rawValue: fileData[0x12]) ?? .norm) : .norm
        // Reassignment @ hdr+0x3D: OLDEST=0, QUIETEST=1. Hardware-confirmed.
        let reassignment = fileData.count > 0x3D ? (AkaiProgramReassignment(rawValue: fileData[0x3D]) ?? .oldest) : .oldest
        // Master output level and base loudness — confirmed offsets, see
        // AkaiProgram.stereoLevel/basicLoudness. Default to 99 (not 0) when the
        // file is too short to contain them, matching real factory defaults
        // rather than the silent value.
        let stereoLevel = fileData.count > 0x17 ? fileData[0x17] : 99
        let basicLoudness = fileData.count > 0x19 ? fileData[0x19] : 99
        // Filter mod-depth sources — confirmed program-level offsets, see
        // AkaiProgram.filterModSource1/2/3. Fall back to real hardware defaults
        // (Velocity/Lfo2/Env2) for any byte value outside the known 0-13 range.
        let modSource1 = fileData.count > 0x54 ? (AkaiFilterModSource(rawValue: fileData[0x54]) ?? .velocity) : .velocity
        let modSource2 = fileData.count > 0x55 ? (AkaiFilterModSource(rawValue: fileData[0x55]) ?? .lfo2) : .lfo2
        let modSource3 = fileData.count > 0x56 ? (AkaiFilterModSource(rawValue: fileData[0x56]) ?? .env2) : .env2

        // Walk keygroups: first at 0xC0, each 0xC0 bytes; kgnum tells us how many.
        var keyzones: [AkaiProgramKeyzone] = []
        let kgSize = 0xC0
        let kgBase = 0xC0
        for kgi in 0..<Int(keygroupCount) {
            let kg = kgBase + kgi * kgSize
            guard kg + kgSize <= fileData.count else { break }
            let kgKeylo = fileData[kg + 0x03]
            let kgKeyhi = fileData[kg + 0x04]
            // Filter cutoff (Frequency), 0–99, and Key Follow, signed —
            // confirmed real-hardware offsets, see AkaiProgramKeyzone.
            let kgFilterCutoff = fileData[kg + 0x07]
            let kgFilterKeyFollow = Int8(bitPattern: fileData[kg + 0x08])
            let kgFilterResonance = fileData[kg + 0x95]
            let kgFilterModDepth1 = Int8(bitPattern: fileData[kg + 0x97])
            let kgFilterModDepth2 = Int8(bitPattern: fileData[kg + 0x98])
            let kgFilterModDepth3 = Int8(bitPattern: fileData[kg + 0x99])
            // Velocity zone 1 holds the primary sample assignment.
            let vz = kg + 0x22
            guard vz + 0x18 <= fileData.count else { break }
            let sname = akaiString(from: fileData, offset: vz, length: 12)
            // Velocity zone 2: the stereo RIGHT channel, if assigned (see
            // AkaiProgramKeyzone.rightSampleName doc comment for the real
            // hardware convention this reflects — one keygroup, two zones).
            var rightName = ""
            var rightPan: Int8 = 50
            let vz2 = kg + 0x22 + 0x18
            if vz2 + 0x18 <= fileData.count {
                let s2 = akaiString(from: fileData, offset: vz2, length: 12)
                if !s2.trimmingCharacters(in: .whitespaces).isEmpty {
                    rightName = s2
                    rightPan = Int8(bitPattern: fileData[vz2 + 0x12])
                }
            }
            keyzones.append(AkaiProgramKeyzone(
                sampleName: sname,
                lowKey: kgKeylo, highKey: kgKeyhi,
                rootNote: 60,
                tuneOffset: Int8(bitPattern: fileData[vz + 0x0F]),   // stune
                fineTune:   Int8(bitPattern: fileData[vz + 0x0E]),   // ctune
                volume: fileData[vz + 0x10],                          // loud
                pan: Int8(bitPattern: fileData[vz + 0x12]),           // pan
                filterOffset: Int8(bitPattern: fileData[vz + 0x11]),  // filter (fine-tune)
                filterCutoff: kgFilterCutoff,
                filterKeyFollow: kgFilterKeyFollow,
                filterResonance: kgFilterResonance,
                filterModDepth1: kgFilterModDepth1,
                filterModDepth2: kgFilterModDepth2,
                filterModDepth3: kgFilterModDepth3,
                rightSampleName: rightName,
                rightPan: rightPan,
                playbackMode: AkaiPlaybackMode(rawValue: fileData[vz + 0x13]) ?? .sample,
                velocityLow:  fileData[vz + 0x0C],
                velocityHigh: fileData[vz + 0x0D],
                env1Attack:   kg + 0x0C < fileData.count ? fileData[kg + 0x0C] : AkaiKeyzoneDefaults.env1Attack,
                env1Decay:    kg + 0x0D < fileData.count ? fileData[kg + 0x0D] : AkaiKeyzoneDefaults.env1Decay,
                env1Sustain:  kg + 0x0E < fileData.count ? fileData[kg + 0x0E] : AkaiKeyzoneDefaults.env1Sustain,
                env1Release:  kg + 0x0F < fileData.count ? fileData[kg + 0x0F] : AkaiKeyzoneDefaults.env1Release,
                env2R1:       kg + 0x14 < fileData.count ? fileData[kg + 0x14] : AkaiKeyzoneDefaults.env2R1,
                env2L1:       kg + 0x9C < fileData.count ? fileData[kg + 0x9C] : AkaiKeyzoneDefaults.env2L1,
                env2R2:       kg + 0x9D < fileData.count ? fileData[kg + 0x9D] : AkaiKeyzoneDefaults.env2R2,
                env2L2:       kg + 0x9E < fileData.count ? fileData[kg + 0x9E] : AkaiKeyzoneDefaults.env2L2,
                env2R3:       kg + 0x15 < fileData.count ? fileData[kg + 0x15] : AkaiKeyzoneDefaults.env2R3,
                env2L3:       kg + 0x16 < fileData.count ? fileData[kg + 0x16] : AkaiKeyzoneDefaults.env2L3,
                env2R4:       kg + 0x17 < fileData.count ? fileData[kg + 0x17] : AkaiKeyzoneDefaults.env2R4,
                env2L4:       kg + 0x9F < fileData.count ? fileData[kg + 0x9F] : AkaiKeyzoneDefaults.env2L4))
        }

        let program = AkaiProgram(name: name, keyzones: keyzones,
                                  midiChannel: midiChannel, polyphony: polyphony,
                                  priority: priority, reassignment: reassignment,
                                  bendRange: octave,
                                  stereoLevel: stereoLevel, basicLoudness: basicLoudness,
                                  filterModSource1: modSource1, filterModSource2: modSource2, filterModSource3: modSource3,
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
        file[0x15] = 2                          // oct (bend range) — hardware default is 2 semitones
        file[0x16] = 0xFF                        // auxch1 = OFF
        file[0x17] = 99                         // stereo level (OUTPUT LEVELS page) — confirmed offset; 0 = silent!
        file[0x19] = 99                         // basic loudness (OUTPUT LEVELS page) — confirmed offset; real factory default is 80, but 99 matches "to 99 for both" request
        file[0x54] = AkaiFilterModSource.velocity.rawValue   // filter mod source #1 — confirmed program-level offset
        file[0x55] = AkaiFilterModSource.lfo2.rawValue       // filter mod source #2 — confirmed program-level offset
        file[0x56] = AkaiFilterModSource.env2.rawValue       // filter mod source #3 — confirmed program-level offset
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
            midiChannel: 0, polyphony: 32, priority: .norm, reassignment: .oldest,
            bendRange: 2,
            stereoLevel: 99, basicLoudness: 99,
            filterModSource1: .velocity, filterModSource2: .lfo2, filterModSource3: .env2,
            rawData: file)
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
        hdr[0x13] = AkaiSamplePlaybackMode.noLoop.rawValue   // pmode = NOLOOP by default
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

        // loop[0]: `at` is the loop's RIGHT-HAND boundary (return-to point),
        // not the start — see parseSample's doc comment for the hardware
        // cross-reference that corrected this. To default to "loop the whole
        // sample" ([0, numSamples-1)), that means at=numSamples-1 (the end
        // boundary) and len=numSamples-1 (so start = at-len = 0) — NOT at=0 as
        // this used to say before the at/len direction was corrected. flen
        // (fine length) stays 0; this app's sliders don't model sub-sample
        // precision. pmode above stays NOLOOP, so this has no audible effect
        // until the user actually enables looping — but it means the on-disk
        // bytes already agree with the model from creation, instead of silently
        // reading back as a zero-length loop the next time this header is
        // parsed (e.g. after Save + reload), which is what happened before this
        // fix: the model's "loop the whole sample" default never made it to disk
        // unless the user happened to touch a loop slider first.
        hdr[0x26] = UInt8(endMarker & 0xFF)
        hdr[0x27] = UInt8((endMarker >> 8) & 0xFF)
        hdr[0x28] = UInt8((endMarker >> 16) & 0xFF)
        hdr[0x29] = UInt8((endMarker >> 24) & 0xFF)              // loop[0].at = numSamples-1 (end boundary)
        hdr[0x2A] = 0; hdr[0x2B] = 0                              // loop[0].flen = 0 (no fine offset)
        hdr[0x2C] = UInt8(endMarker & 0xFF)
        hdr[0x2D] = UInt8((endMarker >> 8) & 0xFF)
        hdr[0x2E] = UInt8((endMarker >> 16) & 0xFF)
        hdr[0x2F] = UInt8((endMarker >> 24) & 0xFF)               // loop[0].len = numSamples-1

        // stpaira[2] @ 0x88 = 0xFFFF (none) — canonical AKAI_SAMPLE1000_STPAIRA_NONE.
        hdr[AkaiDiskFormat.hdrStPairOffset]     = 0xFF
        hdr[AkaiDiskFormat.hdrStPairOffset + 1] = 0xFF
        // srate[2] @ 0x8A.
        let sr16 = UInt16(min(sampleRate, 65535))
        hdr[AkaiDiskFormat.hdrSampleRateOffset]     = UInt8(sr16 & 0xFF)
        hdr[AkaiDiskFormat.hdrSampleRateOffset + 1] = UInt8(sr16 >> 8)

        // locat (0x16) stays zero — sampler-managed. pad to 0xC0 stays zero.
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
            midiRootNote: 60, playbackMode: .noLoop, bitDepth: 16,
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
        case multi(name: String)
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
        for multiFile in multis {
            guard let entry = multiFile.directoryEntry else { continue }
            let name = multiFile.multi.name.isEmpty ? entry.name : multiFile.multi.name
            let chain = fatChain(from: Int(entry.startBlock), data: data)
            for b in chain where b >= 0 && b < map.count { map[b] = .multi(name: name) }
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
        clone.header.playbackMode = src.header.playbackMode
        clone.header.loopStart    = src.header.loopStart
        clone.header.loopEnd      = src.header.loopEnd
        applySampleEdits(clone)

        // applySampleEdits updated the stored copy; return the current version.
        return samples.first(where: { $0.id == clone.id }) ?? clone
    }

    private func parseWAV(_ data: Data) throws -> (Data, Int, Int, Int) {
        // Route by file magic: RIFF/WAVE → WAV, FORM/AIFF or FORM/AIFC → AIFF.
        if data.count > 12,
           data[0..<4] == Data("FORM".utf8),
           (data[8..<12] == Data("AIFF".utf8) || data[8..<12] == Data("AIFC".utf8)) {
            return try parseAIFF(data)
        }
        guard data.count > 44,
              data[0..<4] == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else {
            throw AkaiError.dataError("Not a valid WAV or AIFF file")
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

    /// Parse an AIFF or AIFF-C file. Extracts raw 16-bit signed PCM.
    /// AIFF stores audio big-endian; we byte-swap to little-endian for the Akai.
    /// AIFF-C (AIFC) with 'sowt' (little-endian) compression needs no swap.
    private func parseAIFF(_ data: Data) throws -> (Data, Int, Int, Int) {
        // FORM chunk: bytes 0-3 = "FORM", 4-7 = size (BE), 8-11 = "AIFF"/"AIFC"
        let isAIFC = data[8..<12] == Data("AIFC".utf8)
        var offset = 12
        var sampleRate = 44100
        var numChannels = 1
        var bitsPerSample = 16
        var soundDataOffset = -1
        var soundDataSize = 0
        var offset2sound = 8   // AIFF SSND chunk has an 8-byte header before audio
        var isSowt = false     // AIFC 'sowt' = already little-endian

        // Read big-endian 32-bit int
        func readBE32(at i: Int) -> Int {
            guard i + 3 < data.count else { return 0 }
            return Int(data[i]) << 24 | Int(data[i+1]) << 16 | Int(data[i+2]) << 8 | Int(data[i+3])
        }
        func readBE16(at i: Int) -> Int {
            guard i + 1 < data.count else { return 0 }
            return Int(data[i]) << 8 | Int(data[i+1])
        }
        // 80-bit IEEE 754 extended → Int (sample rate field in AIFF COMM chunk)
        func readExtended(at i: Int) -> Int {
            guard i + 9 < data.count else { return 44100 }
            let exp = (Int(data[i] & 0x7F) << 8) | Int(data[i+1])
            let mantHi = UInt32(data[i+2]) << 24 | UInt32(data[i+3]) << 16 |
                         UInt32(data[i+4]) << 8  | UInt32(data[i+5])
            let shift = 63 - exp
            if shift < 0 || shift > 32 { return 44100 }
            return Int(mantHi >> UInt32(shift))
        }

        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = readBE32(at: offset + 4)
            offset += 8
            switch id {
            case "COMM":
                numChannels   = readBE16(at: offset)
                // numSampleFrames at offset+2 (4 bytes) — not needed
                bitsPerSample = readBE16(at: offset + 6)
                sampleRate    = readExtended(at: offset + 8)
                if isAIFC, offset + 18 + 4 <= data.count {
                    // compression type: 4-byte OSType at offset+18
                    let comp = String(bytes: data[(offset+18)..<(offset+22)], encoding: .ascii) ?? ""
                    isSowt = (comp == "sowt")   // little-endian PCM — no swap needed
                }
            case "SSND":
                // SSND: offset(4) + blockSize(4) + audio data
                offset2sound = readBE32(at: offset) + 8   // skip offset+blockSize fields
                soundDataOffset = offset + offset2sound
                soundDataSize   = max(0, size - offset2sound)
            default:
                break
            }
            offset += size + (size % 2)
        }

        guard soundDataOffset >= 0, soundDataOffset + soundDataSize <= data.count else {
            throw AkaiError.dataError("No audio data found in AIFF file")
        }

        var pcmData = data.subdata(in: soundDataOffset..<soundDataOffset + soundDataSize)

        // AIFF is big-endian 16-bit; swap bytes to little-endian for the Akai.
        // AIFC 'sowt' is already little-endian — skip the swap.
        if bitsPerSample == 16 && !isSowt {
            pcmData.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
                var i = 0
                while i + 1 < buf.count {
                    let hi = buf[i]; buf[i] = buf[i+1]; buf[i+1] = hi
                    i += 2
                }
            }
        }

        guard !pcmData.isEmpty else { throw AkaiError.dataError("No audio data in AIFF file") }
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

    /// Delete a real MULTI file: frees its FAT chain and blanks its directory
    /// entry, same mechanics as deleteProgram. Safe even though we don't decode
    /// the content — deletion only ever needs the directory entry + FAT chain,
    /// both of which are fully understood regardless of file type.
    func deleteMulti(id: UUID) {
        guard let multiFile = multis.first(where: { $0.id == id }) else { return }
        guard let entry = multiFile.directoryEntry else {
            multis.removeAll { $0.id == id }
            return
        }
        guard var data = imageData else {
            multis.removeAll { $0.id == id }
            return
        }
        freeChain(from: Int(entry.startBlock), data: &data)
        if entry.diskOffset >= 0, entry.diskOffset + AkaiDiskFormat.dirEntrySize <= data.count {
            let blank = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
            data.replaceSubrange(entry.diskOffset..<entry.diskOffset + AkaiDiskFormat.dirEntrySize, with: blank)
        }
        imageData = data
        freeBlocks = countFreeBlocks(data: data)
        multis.removeAll { $0.id == id }
        hasUnsavedChanges = true
    }

    /// Generate a unique 12-char multi name, avoiding existing multi names on
    /// disk — mirrors uniqueProgramName/uniqueSampleName.
    private func uniqueMultiName(basedOn base: String) -> String {
        let existing = Set(multis.map { $0.multi.name })
        let cleanBase = Self.sanitizeName(base.isEmpty ? "NEW MULTI" : base)
        if !existing.contains(cleanBase) { return cleanBase }
        for n in 2...999 {
            let suffix = " \(n)"
            let candidate = Self.sanitizeName(String(cleanBase.prefix(12 - suffix.count)) + suffix)
            if !existing.contains(candidate) { return candidate }
        }
        return cleanBase
    }

    /// Duplicate an existing REAL multi file into a new multi file on disk,
    /// byte-for-byte (preserving the multi-level header and both per-part
    /// unconfirmed gaps exactly, mirroring cloneProgram/cloneSample), then
    /// patches only the DIRECTORY ENTRY's name — the multi-level header's own
    /// internal name field, if any, is unconfirmed and left untouched (same
    /// caveat as renameMulti). Does not write to disk immediately — persist via
    /// Save. Returns the new multi file.
    @discardableResult
    func cloneMulti(id: UUID) throws -> AkaiMultiFile {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        guard let src = multis.first(where: { $0.id == id }) else {
            throw AkaiError.dataError("Multi to clone not found")
        }
        guard let srcEntry = src.directoryEntry else {
            throw AkaiError.dataError("This multi has no on-disk content to clone")
        }
        let newName = uniqueMultiName(basedOn: src.multi.name)
        let nameBytes = akaiBytes(from: newName, length: 12)

        // Read the source file's real bytes verbatim, then patch the internal
        // name at +0x03 so the Akai shows the correct name when this clone is
        // loaded — same fix as renameMulti, confirmed from leftfield-stab.img.
        let chain = fatChain(from: Int(srcEntry.startBlock), data: data)
        var fileData = readFromChain(chain, fileOffset: 0, length: Int(srcEntry.size), data: data)
        if fileData.count >= 0x03 + 12 {
            for (i, b) in nameBytes.enumerated() { fileData[0x03 + i] = b }
        }

        let bs = AkaiDiskFormat.blockSize
        let blocksNeeded = (fileData.count + bs - 1) / bs
        guard let blocks = findFreeBlocks(count: blocksNeeded, data: data) else {
            throw AkaiError.diskFull("Not enough space on the disk to clone this multi.")
        }
        guard let dirSlot = findFreeDirectorySlot(data: data) else {
            throw AkaiError.dataError("Disk directory is full")
        }

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

        let startBlock = blocks[0]
        let totalSize = UInt32(fileData.count)
        var entryBytes = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
        for (i, b) in nameBytes.enumerated() { entryBytes[i] = b }
        entryBytes[16] = AkaiDiskFormat.ftypeMulti
        entryBytes[17] = UInt8(totalSize & 0xFF)
        entryBytes[18] = UInt8((totalSize >> 8) & 0xFF)
        entryBytes[19] = UInt8((totalSize >> 16) & 0xFF)
        entryBytes[20] = UInt8(startBlock & 0xFF)
        entryBytes[21] = UInt8((startBlock >> 8) & 0xFF)
        data.replaceSubrange(dirSlot..<dirSlot + AkaiDiskFormat.dirEntrySize, with: entryBytes)

        imageData = data
        freeBlocks = countFreeBlocks(data: data)

        let dirEntry = AkaiDirectoryEntry(
            name: newName, fileType: AkaiDiskFormat.ftypeMulti,
            startBlock: UInt16(startBlock), size: totalSize,
            rawEntry: entryBytes, diskOffset: dirSlot)

        // Decode the cloned parts back from the fresh bytes — the name patch
        // above only touched the directory entry, so these mirror the source
        // multi's parts exactly.
        var parts = [AkaiMultiPart](repeating: AkaiMultiPart(), count: 16)
        for partIndex in 0..<16 {
            guard fileData.count >= AkaiMultiFormat.minSizeForPart(partIndex) else { continue }
            let base = AkaiMultiFormat.partBase(partIndex)
            var p = AkaiMultiPart()
            p.programName = akaiString(from: fileData, offset: base + AkaiMultiFormat.relNameOffset, length: 12)
            p.channel = fileData[base + AkaiMultiFormat.relChannelOffset] &+ 1
            p.level = fileData[base + AkaiMultiFormat.relLevelOffset]
            p.pan = Int8(bitPattern: fileData[base + AkaiMultiFormat.relPanOffset])
            p.fxBus = AkaiFxBus(byteValue: fileData[base + AkaiMultiFormat.relFxBusOffset])
            p.fxSend = fileData[base + AkaiMultiFormat.relSendOffset]
            parts[partIndex] = p
        }

        let cloned = AkaiMultiFile(directoryEntry: dirEntry,
                                   multi: AkaiMulti(name: newName, parts: parts),
                                   isContentReal: true)
        multis.append(cloned)
        hasUnsavedChanges = true
        return cloned
    }

    // MARK: - Create Multi

    /// Build and write a brand-new MULTI file to disk.
    /// Structure confirmed by byte-diff: +0x000 preamble (3 bytes 0x00),
    /// +0x003 name (12 bytes Akai-encoded), +0x00F..+0x3FF zeros,
    /// then 16 × 0xC0 part records at +0x400. Total: 4096 bytes.
    /// Sampler recalculates link pointers on load — we write zeros.
    @discardableResult
    func createMulti(name rawName: String = "NEW MULTI") throws -> AkaiMultiFile {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        let name = Self.sanitizeName(rawName.isEmpty ? "NEW MULTI" : rawName)
        let fileSize = 0x1000
        var file = Data(repeating: 0, count: fileSize)
        let nameBytes = akaiBytes(from: name, length: 12)
        for (i, b) in nameBytes.enumerated() { file[0x003 + i] = b }
        let emptyName = [UInt8](repeating: 10, count: 12)
        for partIndex in 0..<16 {
            let base = AkaiMultiFormat.partBase(partIndex)
            file[base + 0x00] = 0x01
            for (i, b) in emptyName.enumerated() { file[base + AkaiMultiFormat.relNameOffset + i] = b }
            file[base + AkaiMultiFormat.relChannelOffset] = UInt8(partIndex)
            file[base + AkaiMultiFormat.relLevelOffset]   = 99
            file[base + AkaiMultiFormat.relPanOffset]     = 0
            file[base + AkaiMultiFormat.relFxBusOffset]   = AkaiFxBus.off.byteValue
            file[base + AkaiMultiFormat.relSendOffset]    = 25
            // +0xBE/+0xBF: end link pointer — 0xFFFF = none (unassigned).
            // Hardware writes 0xFFFF for empty parts; 0x0000 may be interpreted
            // as a valid pointer, causing the Akai to always load the wrong multi.
            file[base + 0xBE] = 0xFF
            file[base + 0xBF] = 0xFF
        }
        let bs = AkaiDiskFormat.blockSize
        let blocksNeeded = (fileSize + bs - 1) / bs
        guard let blocks = findFreeBlocks(count: blocksNeeded, data: data) else {
            throw AkaiError.diskFull("Not enough space on the disk to create a multi.")
        }
        guard let dirSlot = findFreeDirectorySlot(data: data) else {
            throw AkaiError.dataError("Disk directory is full")
        }
        for i in 0..<blocks.count {
            let value: UInt16 = (i == blocks.count - 1) ? AkaiDiskFormat.fatEnd : UInt16(blocks[i + 1])
            setFatValue(block: blocks[i], value: value, data: &data)
        }
        for (i, block) in blocks.enumerated() {
            let srcStart = i * bs
            let srcEnd   = min(srcStart + bs, file.count)
            let dstStart = block * bs
            guard dstStart + bs <= data.count else { throw AkaiError.dataError("Block out of range") }
            let chunk = file[srcStart..<srcEnd]
            data.replaceSubrange(dstStart..<dstStart + bs, with: chunk + Data(repeating: 0, count: bs - chunk.count))
        }
        let startBlock = blocks[0]
        let totalSize  = UInt32(fileSize)
        var entryBytes = Data(repeating: 0, count: AkaiDiskFormat.dirEntrySize)
        for (i, b) in nameBytes.enumerated() { entryBytes[i] = b }
        entryBytes[16] = AkaiDiskFormat.ftypeMulti
        entryBytes[17] = UInt8(totalSize & 0xFF)
        entryBytes[18] = UInt8((totalSize >> 8) & 0xFF)
        entryBytes[19] = UInt8((totalSize >> 16) & 0xFF)
        entryBytes[20] = UInt8(startBlock & 0xFF)
        entryBytes[21] = UInt8((startBlock >> 8) & 0xFF)
        data.replaceSubrange(dirSlot..<dirSlot + AkaiDiskFormat.dirEntrySize, with: entryBytes)
        imageData = data
        freeBlocks = countFreeBlocks(data: data)
        let dirEntry = AkaiDirectoryEntry(
            name: name, fileType: AkaiDiskFormat.ftypeMulti,
            startBlock: UInt16(startBlock), size: totalSize,
            rawEntry: entryBytes, diskOffset: dirSlot)
        let parts: [AkaiMultiPart] = (0..<16).map { i in
            var p = AkaiMultiPart()
            p.channel = UInt8(i + 1); p.level = 99; p.pan = 0; p.fxBus = .off; p.fxSend = 25
            return p
        }
        let multiFile = AkaiMultiFile(
            directoryEntry: dirEntry,
            multi: AkaiMulti(name: name, parts: parts),
            isContentReal: true)
        multis.append(multiFile)
        hasUnsavedChanges = true
        return multiFile
    }

    /// Rename a real MULTI file's directory entry name. Does NOT touch the
    /// file's content (any internal "multi name" field, if one exists at a
    /// different offset, is left alone — we don't know where it'd be).
    @discardableResult
    func renameMulti(id: UUID, to newRawName: String) throws -> AkaiMultiFile {
        guard let index = multis.firstIndex(where: { $0.id == id }) else {
            throw AkaiError.dataError("Multi not found")
        }
        guard var entry = multis[index].directoryEntry else {
            throw AkaiError.dataError("This multi has no on-disk entry to rename")
        }
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        let cleanName = Self.sanitizeName(newRawName)
        guard !cleanName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AkaiError.dataError("Name cannot be empty")
        }
        let nameBytes = akaiBytes(from: cleanName, length: 12)

        // 1. Patch the internal name at +0x03 in the file content — confirmed
        //    from leftfield-stab.img: both multis had 'NEW MULTI' at file+0x03
        //    while the directory entry already showed 'LEFTFIELD'/'LEFTFIELD 2'.
        //    The Akai reads the internal name once a multi is loaded into memory,
        //    so without this patch it always showed 'New Multi' regardless of
        //    which file was selected. Same offset/method as renameProgram.
        let chain = fatChain(from: Int(entry.startBlock), data: data)
        var fileData = readFromChain(chain, fileOffset: 0, length: Int(entry.size), data: data)
        if fileData.count >= 0x03 + 12 {
            for (i, b) in nameBytes.enumerated() { fileData[0x03 + i] = b }
        }
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

        // 2. Patch the directory entry name.
        if entry.diskOffset >= 0, entry.diskOffset + 12 <= data.count {
            for (i, b) in nameBytes.enumerated() { data[entry.diskOffset + i] = b }
        }
        entry.name = cleanName
        imageData = data
        multis[index].directoryEntry = entry
        multis[index].multi.name = cleanName
        if let url = imageURL { try data.write(to: url, options: .atomic) }
        hasUnsavedChanges = false
        return multis[index]
    }

    /// Patch one part's confirmed fields (program name, channel, level, pan, fx
    /// bus, send) into a REAL multi file's bytes on disk — see AkaiMultiPart's
    /// doc comment for the confirmed offsets/method/stride. `partIndex` is
    /// 0-based (0...15) for Parts 1...16. Deliberately does NOT touch anything
    /// else: each part's 2-byte program link pointer and second pointer
    /// (sampler-managed, like kg1a/shdra elsewhere), the two unconfirmed gaps
    /// within each part's own record, the multi-level header (bytes
    /// `0x000`-`0x3FF`), or any other part — all of those are preserved exactly
    /// as they were. Patches the in-memory image only; persist via Save, same
    /// as every other edit in this app.
    func applyMultiPartEdit(id: UUID, partIndex: Int, part: AkaiMultiPart) throws {
        guard partIndex >= 0 && partIndex < 16 else {
            throw AkaiError.dataError("Part index out of range")
        }
        guard let index = multis.firstIndex(where: { $0.id == id }) else {
            throw AkaiError.dataError("Multi not found")
        }
        guard let entry = multis[index].directoryEntry else {
            throw AkaiError.dataError("This multi has no on-disk entry to edit")
        }
        guard var data = imageData else { throw AkaiError.noImageLoaded }

        let chain = fatChain(from: Int(entry.startBlock), data: data)
        var fileData = readFromChain(chain, fileOffset: 0, length: Int(entry.size), data: data)
        guard fileData.count >= AkaiMultiFormat.minSizeForPart(partIndex) else {
            throw AkaiError.dataError("This multi file is too small to contain Part \(partIndex + 1)'s confirmed fields")
        }

        let base = AkaiMultiFormat.partBase(partIndex)
        let nameBytes = akaiBytes(from: part.programName, length: 12)
        for (i, b) in nameBytes.enumerated() { fileData[base + AkaiMultiFormat.relNameOffset + i] = b }
        fileData[base + AkaiMultiFormat.relChannelOffset] = part.channel > 0 ? part.channel - 1 : 0  // model 1-indexed -> disk 0-indexed
        fileData[base + AkaiMultiFormat.relLevelOffset] = part.level
        fileData[base + AkaiMultiFormat.relPanOffset] = UInt8(bitPattern: part.pan)
        fileData[base + AkaiMultiFormat.relFxBusOffset] = part.fxBus.byteValue
        fileData[base + AkaiMultiFormat.relSendOffset] = part.fxSend

        // Write the patched bytes back across the existing chain — file size
        // never changes (we only ever patch fields, never grow/shrink), so
        // there's no FAT reallocation needed, just an in-place rewrite.
        let bs = AkaiDiskFormat.blockSize
        for (i, block) in chain.enumerated() {
            let srcStart = i * bs
            guard srcStart < fileData.count else { break }
            let srcEnd = min(srcStart + bs, fileData.count)
            let dstStart = block * bs
            guard dstStart + bs <= data.count else { break }
            let chunk = fileData[srcStart..<srcEnd]
            let padded = chunk + Data(repeating: 0, count: bs - chunk.count)
            data.replaceSubrange(dstStart..<dstStart + bs, with: padded)
        }

        imageData = data
        multis[index].multi.parts[partIndex] = part
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

        // --- Volume label (akai_flvol_label_s name field at 0x1280) ---
        let labelBytes = akaiBytes(from: Self.sanitizeName(volumeName), length: 12)
        let labelOffset = 0x1280
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

    /// Rename the disk's volume label (akai_flvol_label_s.name @ absolute 0x1280).
    /// Patches the in-memory image only — persist via Save, matching every other
    /// edit in the app. Used by the sidebar's click-to-edit volume name.
    @discardableResult
    func renameVolume(to newName: String) throws -> String {
        guard var data = imageData else { throw AkaiError.noImageLoaded }
        let clean = Self.sanitizeName(newName)
        let labelOffset = 0x1280
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
        hdr[0x13] = sample.header.playbackMode.rawValue
        hdr[0x14] = UInt8(bitPattern: sample.header.fineTune)
        hdr[0x15] = UInt8(bitPattern: sample.header.semitoneTune)
        // loop[0]: `at` is the loop's RIGHT-HAND boundary (the return-to point),
        // not the start — see the doc comment in parseSample for the hardware
        // cross-reference that corrected this. So `at` = loopEnd, `len` =
        // loopEnd-loopStart. flen (fine/sub-sample length) is written as 0 since
        // this app's sliders only edit whole-sample positions — any fine offset
        // that was on disk before is lost on save (same precision loss any
        // whole-sample loop editor would have).
        let le = sample.header.loopEnd
        hdr[0x26] = UInt8(le & 0xFF); hdr[0x27] = UInt8((le >> 8) & 0xFF)
        hdr[0x28] = UInt8((le >> 16) & 0xFF); hdr[0x29] = UInt8((le >> 24) & 0xFF)
        hdr[AkaiDiskFormat.hdrLoopFineOffset] = 0; hdr[AkaiDiskFormat.hdrLoopFineOffset + 1] = 0
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
    ///   0x13: pmode (see AkaiSamplePlaybackMode: 0=loop,1=loopNotRel,2=noLoop,3=toEnd)
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
        // Playback mode
        hdr[0x13] = sample.header.playbackMode.rawValue
        // Cents tune (signed)
        hdr[0x14] = UInt8(bitPattern: sample.header.fineTune)
        // Semitone tune (signed)
        hdr[0x15] = UInt8(bitPattern: sample.header.semitoneTune)
        // Loop: `at` is the loop's RIGHT-HAND boundary (return-to point), not
        // the start — see parseSample's doc comment for the hardware
        // cross-reference that corrected this. at = loopEnd, len = end-start.
        // flen (fine/sub-sample length) written as 0 — not modeled by this app's
        // whole-sample sliders.
        let le = sample.header.loopEnd
        hdr[0x26] = UInt8(le & 0xFF)
        hdr[0x27] = UInt8((le >> 8) & 0xFF)
        hdr[0x28] = UInt8((le >> 16) & 0xFF)
        hdr[0x29] = UInt8((le >> 24) & 0xFF)
        hdr[AkaiDiskFormat.hdrLoopFineOffset] = 0
        hdr[AkaiDiskFormat.hdrLoopFineOffset + 1] = 0
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
            case 0...9:   return Character(UnicodeScalar(UInt32("0".unicodeScalars.first!.value) + UInt32(byte))!)
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
                                      stereoLevel: UInt8, basicLoudness: UInt8,
                                      polyphony: UInt8, priority: AkaiProgramPriority, reassignment: AkaiProgramReassignment,
                                      filterModSource1: AkaiFilterModSource, filterModSource2: AkaiFilterModSource, filterModSource3: AkaiFilterModSource,
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
        // Polyphony @ 0x11: 0-indexed (0=1 voice, 31=32 voices). Hardware-confirmed.
        file[0x11] = polyphony > 0 ? polyphony - 1 : 31
        // Priority @ 0x12: LOW=0, NORM=1, HIGH=2. Hardware-confirmed.
        file[0x12] = priority.rawValue
        file[0x13] = 0                            // program-level keylo
        file[0x14] = 127                          // program-level keyhi
        // Bend range — up @ hdr+0x27, down @ hdr+0x15. Hardware-confirmed.
        // Single UI control writes both simultaneously.
        file[0x15] = bendRange   // bend down
        file[0x27] = bendRange   // bend up
        file[0x16] = 0xFF                          // auxch1 = OFF
        file[0x17] = stereoLevel                  // OUTPUT LEVELS "stereo level" — confirmed offset; 0 = total silence on main outs
        file[0x19] = basicLoudness                 // OUTPUT LEVELS "basic loudness" — confirmed offset; 0 = total silence regardless of velocity
        file[0x54] = filterModSource1.rawValue     // filter mod source #1 — confirmed program-level offset (shared by all keygroups)
        file[0x55] = filterModSource2.rawValue     // filter mod source #2 — confirmed program-level offset (shared by all keygroups)
        file[0x56] = filterModSource3.rawValue     // filter mod source #3 — confirmed program-level offset (shared by all keygroups)
        file[0x29] = 0                            // kgxf
        file[0x2A] = UInt8(min(255, kgCount))     // kgnum — MUST match real keygroup count
        // Reassignment @ 0x3D: OLDEST=0, QUIETEST=1. Hardware-confirmed.
        file[0x3D] = reassignment.rawValue

        let kgBase = 0xC0
        let emptyName = akaiBytes(from: "", length: 12)
        for kgi in 0..<kgCount {
            let kg = kgBase + kgi * 0xC0
            file[kg + 0x00] = 0x02                // blockid
            let kz: AkaiProgramKeyzone? = kgi < keyzones.count ? keyzones[kgi] : nil
            file[kg + 0x03] = kz?.lowKey ?? 0
            file[kg + 0x04] = kz?.highKey ?? 127
            file[kg + 0x07] = kz?.filterCutoff ?? 99
            file[kg + 0x08] = UInt8(bitPattern: kz?.filterKeyFollow ?? 0)
            file[kg + 0x0C] = kz?.env1Attack ?? 0    // ENV1 Attack   — hardware-confirmed kg+0x0C
            file[kg + 0x0D] = kz?.env1Decay ?? 0     // ENV1 Decay    — hardware-confirmed kg+0x0D
            file[kg + 0x0E] = kz?.env1Sustain ?? 99   // ENV1 Sustain  — hardware-confirmed kg+0x0E
            file[kg + 0x0F] = kz?.env1Release ?? 0   // ENV1 Release  — hardware-confirmed kg+0x0F
            file[kg + 0x14] = kz?.env2R1 ?? 0         // ENV2 Rate 1   — hardware-confirmed kg+0x14
            file[kg + 0x15] = kz?.env2R3 ?? 50        // ENV2 Rate 3   — hardware-confirmed kg+0x15
            file[kg + 0x16] = kz?.env2L3 ?? 99        // ENV2 Level 3  — hardware-confirmed kg+0x16
            file[kg + 0x17] = kz?.env2R4 ?? 45        // ENV2 Rate 4   — hardware-confirmed kg+0x17
            file[kg + 0x9C] = kz?.env2L1 ?? 99        // ENV2 Level 1  — hardware-confirmed kg+0x9C
            file[kg + 0x9D] = kz?.env2R2 ?? 50        // ENV2 Rate 2   — hardware-confirmed kg+0x9D
            file[kg + 0x9E] = kz?.env2L2 ?? 99        // ENV2 Level 2  — hardware-confirmed kg+0x9E
            file[kg + 0x9F] = kz?.env2L4 ?? 0         // ENV2 Level 4  — hardware-confirmed kg+0x9F
            file[kg + 0x95] = kz?.filterResonance ?? 0
            file[kg + 0x97] = UInt8(bitPattern: kz?.filterModDepth1 ?? 0)  // Mod depth #1 (Velocity→Freq) — confirmed offset
            file[kg + 0x98] = UInt8(bitPattern: kz?.filterModDepth2 ?? 0)  // Mod depth #2 (Lfo2→Freq) — confirmed offset
            file[kg + 0x99] = UInt8(bitPattern: kz?.filterModDepth3 ?? 0)  // Mod depth #3 (Env2→Freq) — confirmed offset

            // kg+0x20/0x21: shdra of the implicit zone-0 slot — hardware expects
            // 0xFFFF here (confirmed from working programs on real hardware).
            file[kg + 0x20] = 0xFF; file[kg + 0x21] = 0xFF
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
                    file[vz + 0x11] = UInt8(bitPattern: kz.filterOffset) // filter (fine-tune)
                    file[vz + 0x12] = UInt8(bitPattern: kz.pan)
                    file[vz + 0x13] = kz.playbackMode.rawValue          // pmode
                    file[vz + 0x16] = 0xFF; file[vz + 0x17] = 0xFF       // shdra = none
                } else if z == 1, let kz = kz, !kz.rightSampleName.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Velocity zone 2: the stereo RIGHT channel (real hardware
                    // convention — see AkaiProgramKeyzone.rightSampleName doc
                    // comment). Mirrors zone 1's velocity/tune/filter-trim/
                    // playback mode (they trigger together); only the sample
                    // name and pan genuinely differ.
                    let snameBytes = akaiBytes(from: kz.rightSampleName, length: 12)
                    for (i, b) in snameBytes.enumerated() { file[vz + i] = b }
                    file[vz + 0x0C] = kz.velocityLow
                    file[vz + 0x0D] = kz.velocityHigh
                    file[vz + 0x0E] = UInt8(bitPattern: kz.fineTune)
                    file[vz + 0x0F] = UInt8(bitPattern: kz.tuneOffset)
                    file[vz + 0x10] = kz.volume
                    file[vz + 0x11] = UInt8(bitPattern: kz.filterOffset)
                    file[vz + 0x12] = UInt8(bitPattern: kz.rightPan)
                    file[vz + 0x13] = kz.playbackMode.rawValue
                    file[vz + 0x16] = 0xFF; file[vz + 0x17] = 0xFF
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
            stereoLevel: programFile.program.stereoLevel,
            basicLoudness: programFile.program.basicLoudness,
            polyphony: programFile.program.polyphony,
            priority: programFile.program.priority,
            reassignment: programFile.program.reassignment,
            filterModSource1: programFile.program.filterModSource1,
            filterModSource2: programFile.program.filterModSource2,
            filterModSource3: programFile.program.filterModSource3,
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
            // Same number of BLOCKS — reuse the existing chain in place. The
            // ACTUAL FILE SIZE can still have changed even when the block count
            // hasn't (e.g. 0 keygroups → 1 keygroup is 192 → 384 bytes, both of
            // which fit in a single 1024-byte block) — so the directory entry's
            // size field still needs updating below, unconditionally.
            writeFile(across: oldChain)
        } else {
            // The keygroup count changed the file's BLOCK COUNT — free the old
            // chain and allocate a fresh one of the right length, updating the
            // directory entry's start block (size is handled below either way).
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
            data[programFile.directoryEntry.diskOffset + 20] = UInt8(startBlock & 0xFF)
            data[programFile.directoryEntry.diskOffset + 21] = UInt8((startBlock >> 8) & 0xFF)
            freeBlocks = countFreeBlocks(data: data)
        }

        // ALWAYS patch the directory entry's size field to match the real file
        // size, regardless of which branch above ran — this was the actual bug:
        // it used to only happen in the realloc branch, so any edit that changed
        // the file's byte count WITHOUT crossing a 1024-byte block boundary (e.g.
        // the very first keyzone added to a brand-new 0-keygroup program: 192 →
        // 384 bytes, both 1 block) left the on-disk directory entry reporting the
        // OLD size. On reload, parseProgram only reads that many bytes from the
        // chain — silently truncating the file and losing every keygroup, since
        // they live right after the 0xC0-byte header.
        let entry = programFile.directoryEntry
        if entry.diskOffset >= 0, entry.diskOffset + AkaiDiskFormat.dirEntrySize <= data.count {
            let totalSize = UInt32(fileData.count)
            data[entry.diskOffset + 17] = UInt8(totalSize & 0xFF)
            data[entry.diskOffset + 18] = UInt8((totalSize >> 8) & 0xFF)
            data[entry.diskOffset + 19] = UInt8((totalSize >> 16) & 0xFF)
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
