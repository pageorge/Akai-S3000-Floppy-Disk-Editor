# Akai S3000 Floppy Disk Editor

![Akai S3000 Editor Logo](AkaiS3000Editor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png)

A personal macOS project for reading and editing **Akai S3000 floppy disk images** (.img) created with [GreaseWeazle](https://github.com/keirf/greaseweazle). Built with SwiftUI — no dependencies, just plug in your floppy drive and go.

**[View on GitHub](https://github.com/pageorge/Akai-S3000-Floppy-Disk-Editor)**

---

## Download

**[⬇️ Download latest build](https://github.com/pageorge/Akai-S3000-Floppy-Disk-Editor/releases/latest)**

1. Download `AkaiS3000Editor.zip` from the link above
2. Unzip and drag `AkaiS3000Editor.app` to your Applications folder
3. On first launch, right-click the app and choose **Open** to bypass Gatekeeper (the app is unsigned)

The app is built automatically from the latest commit on `main` — no Xcode required.

---

## What it does

- 📂 **Open .img disk images** — drag & drop or File → Open
- 🎵 **Browse and preview samples** — waveform display, spacebar to play
- 📤 **Export samples as WAV** — standard 16-bit PCM, ready for any DAW
- 📥 **Import WAV files** — add new samples to a disk image
- ✏️ **Edit sample parameters** — root note, fine tune, loudness, loop points
- 🎹 **Browse and edit programs** — view keyzone mappings on a piano keyboard
- 🥁 **Drum preset tool** — drag multiple WAV files to auto-map each to a single key
- 🖱️ **Drag on the keyboard** — set low key, high key and root note by dragging
- 💾 **Save changes** back to the .img file
- ℹ️ **Disk info** — free blocks, file counts, disk map

---

## Reading a floppy with GreaseWeazle

```bash
gw read --format=akai.1600 my_disk.img --drive=B
```

Then open `my_disk.img` in this app.

---

## Requirements

- **macOS 14 Sonoma** or later
- No third-party dependencies

To build from source: **Xcode 15** or later.

---

## Building from source

1. Clone this repo
2. Open `AkaiS3000Editor.xcodeproj` in Xcode
3. Set your Development Team in Signing & Capabilities
4. Press **⌘R**

---

## Technical Reference: Akai S3000 Disk Format

This section consolidates everything this app relies on about the on-disk format, gathered from the three reverse-engineering projects linked below, plus a couple of corrections found while building this editor. It's here so future changes (or anyone else picking up this format) don't have to re-derive it from scratch.

**Sources, and what each contributed:**

| Source | What it gave us |
|---|---|
| **[Midi-In/akaiutil](https://github.com/Midi-In/akaiutil)** ([`akaiutil.h`](https://github.com/Midi-In/akaiutil/blob/master/akaiutil.h), [`akaiutil_file.h`](https://github.com/Midi-In/akaiutil/blob/master/akaiutil_file.h)) | The primary source of truth: the C structs for the floppy header, FAT, volume directory, sample header, and program/keygroup header, plus all the `AKAI_*` constants (block sizes, FAT codes, file types, name lengths). |
| **[dialtr/akai-fs](https://github.com/dialtr/akai-fs)** | A FUSE filesystem project that, per its own README, vendors a snapshot of the **same** `akaiutils` source by the same original author (Michael Indlekofer) in its `archive/`/`akaiutil/` directories, then refactors it into C++. It is *not* an independent reverse-engineering effort — it's a repackaging of Midi-In/akaiutil's source, with whatever changes the C→C++ refactor introduced. |
| **[keirf/greaseweazle](https://github.com/keirf/greaseweazle)** (`diskdefs_akai.cfg`, imported from [`diskdefs.cfg`](https://github.com/keirf/greaseweazle/blob/master/src/greaseweazle/data/diskdefs.cfg); added in [v1.0, June 2022](https://github.com/keirf/greaseweazle/blob/master/RELEASE_NOTES)) | The **physical** track layout for the `akai.800` and `akai.1600` IMG formats — i.e. how the abstract block stream above is actually laid out on the magnetic media (cylinders, heads, sectors/track, sector size, data rate). This is what `gw read`/`gw write` use, and what `GreaseweazleRunner.swift` shells out to. This is an independent piece of work (GreaseWeazle's own format definition), not derived from akaiutil. |
| **Akai S3000XL Operator's Manual** (1996, Acrobat Distiller-produced PDF, 313 pages — user-supplied, not linked above since it's not hosted anywhere canonical) | The **only source for what bytes actually mean musically** rather than just where they live. akaiutil's structs tell you a byte exists and is called e.g. `filter` or `pmode`; the manual is what confirms units, ranges, and behavior — e.g. that sample `pmode` has 4 real states (not just "loop on/off"), that the keygroup FILT page's cutoff runs 0–99 with resonance 0–15 and key-follow defaulting to +12, and that the velocity-zone `filter` byte (±50) is specifically a *fine-tune trim* layered on top of the keygroup's main cutoff, not an independent filter. This is an independent, primary source — Akai's own documentation of their own hardware — not derived from any of the above. |

**Cross-check status:** GitHub's robots policy blocks browsing akai-fs's vendored source directories directly, so its copies of the structs below were not byte-diffed against akaiutil's — per akai-fs's own README, though, it's explicitly the *same* underlying source (not an independent derivation), so it isn't expected to disagree, and nothing here was found to contradict it. The genuinely independent sources — GreaseWeazle's physical track/format definition, and the Akai Operator's Manual — agree with akaiutil's structs everywhere they overlap (block-count constants, struct field purposes, etc.) with no discrepancy found. **No contradictions were found between any of the sources** on anything in this section. If that ever changes (e.g. a future check turns up a real discrepancy), it will be flagged here in `Source A: ... / Source B: ...` form rather than silently picking one.

Everything below is this app's own paraphrase/translation of those sources into the layout `AkaiDiskImage.swift` actually implements — cross-checked against a real Greaseweazle-read S3000XL disk during development. Where this app found and fixed a bug in its own (not the sources') understanding of the format, that's called out explicitly.

### Physical layout (GreaseWeazle `akai.1600` / `akai.800`)

| | `akai.1600` (HD) | `akai.800` (LD) |
|---|---|---|
| Cylinders | 80 | 80 |
| Heads | 2 | 1 |
| Sectors/track | 10 | 10 |
| Bytes/sector | 1024 | 1024 |
| Total blocks | 1600 | 800 |
| Data rate | 500 kbps (MFM HD) | 250 kbps (MFM DD) |

This app only supports `akai.1600` (the S3000 HD floppy format used by `AkaiDiskFormat` in `AkaiDiskImage.swift`); `akai.800` is offered as a GreaseweazleRunner format option for completeness but isn't parsed by the rest of the app.

### Floppy header (`struct akai_flhhead_s`, akaiutil.h) — blocks 0–4, 5120 bytes total

| Offset | Field | Size | Notes |
|---|---|---|---|
| `0x0000` | `file[64]` | 0x600 (64 × 24-byte `akai_voldir_entry_s`) | The **floppy-header copy** of the volume directory (S900/S1000 floppies use this as their *live* directory; S3000 floppies do not — see below). |
| `0x0600` | `fatblk[1600][2]` | 0xC80 | The FAT: one 16-bit little-endian entry per block, `next-block-number` or a special code (see FAT codes below). |
| `0x1280` | `label` (`akai_flvol_label_s`) | 0x40 | Volume name (12 bytes, Akai-encoded) + 2 reserved + OS version (2 bytes LE) + 0x30 bytes of volume parameters. |
| `0x12C0` | padding | 0x140 | Unused. |

**Gotcha (fixed in this app, June 2026):** the volume label offset was hardcoded as `0xD80` in three places (`parseImage`, `createBlankImage`, `renameVolume`). The correct offset, derived from the struct above, is `0x600 + 0xC80 = 0x1280`. `0xD80` actually lands inside the FAT table — specifically the FAT entry for block 960 (`(0xD80-0x600)/2`) — so renaming a volume was silently corrupting that FAT entry while never touching the real label, which stayed zero-filled. A real S3000 displays zero-filled name bytes as `"000000000000"`, because Akai character code `0x00` is the digit `'0'` (see encoding table below) — that's the literal symptom this surfaced as.

### S3000-specific: where the *live* directory actually is

On S3000 floppies, `file[64]` in the header above is **not** the live directory — slot 0 holds a sentinel entry (type `0xFF`, name `"VVVVVVVVVVVV"`, i.e. `AKAI_EMPTY1000_FNAME`) flagging "this is an S3000 volume," and the rest of the 64 slots are unused. The real directory is `struct akai_voldir3000fl_s` (akaiutil.h), starting at **block 5** (`AKAI_VOLDIR3000FLH_BSTART`) and spanning 12 blocks: 510 × 24-byte entries (`AKAI_VOLDIR_ENTRIES_S3000FL`) plus 0x30 bytes of padding (volume parameters live in the floppy header's `label`, not here). Block 0 (the header's `file[64]` region) should never be touched when writing S3000 files/directory changes.

### FAT codes (`AKAI_FAT_CODE_*`, akaiutil.h)

| Code | Meaning |
|---|---|
| `0x0000` | Free block |
| `0x4000` | System block (reserved — header + volume directory) |
| `0x8000` | End of chain for the *volume directory itself* (S3000) — not used by this app, which doesn't reallocate the directory |
| `0xC000` | End of file chain (`FILEEND`, S1000/S3000) |
| anything else | Next block number, 16-bit LE |

### Volume directory entry (`struct akai_voldir_entry_s`, akaiutil.h) — 24 bytes

| Offset | Field | Notes |
|---|---|---|
| `0x00`–`0x0B` | `name[12]` | Akai-encoded (see character set below). |
| `0x0C`–`0x0F` | `tag[4]` | S3000 free-slot tag = `0x00`; S1000 default = `0x20`. Not used for tagging in this app. |
| `0x10` | `type` | `0x00` = free slot; `0xF3` (`'s'+0x80`) = S3000 sample; `0xF0` (`'p'+0x80`) = S3000 program. |
| `0x11`–`0x13` | `size[3]` | 24-bit LE, total file size in bytes including the header. |
| `0x14`–`0x15` | `start[2]` | 16-bit LE, start block within the partition/floppy. |
| `0x16`–`0x17` | `osver[2]` | 16-bit LE. Real samples = `0x0000`; programs = `0x1100` ("v17.00"). |

**Note on empty-slot handling:** akaiutil treats the directory as a fixed-size array of slots, not a packed list — `type == 0x00` marks a free slot to be skipped, *not* an end-of-directory terminator. This app's `parseDirectory` deliberately continues scanning past empty slots rather than stopping at the first one, since deleting a file mid-directory leaves a hole that later files must still be read past.

### Sample header (`struct akai_sample3000_s` = `akai_sample1000_s` + 42 bytes padding, akaiutil_file.h) — 0xC0 (192) bytes, audio starts immediately after

| Offset | Field | Notes |
|---|---|---|
| `0x00` | `blockid` | `0x03` (`SAMPLE1000_BLOCKID`). |
| `0x01` | `bandw` | Bandwidth select (`0x00`=10kHz, `0x01`=20kHz). |
| `0x02` | `rkey` | MIDI root key. |
| `0x03`–`0x0E` | `name[12]` | Akai-encoded. |
| `0x0F` | `dummy1` | Observed constant `0x80` on real disks. |
| `0x10` | `lnum` | Number of loops. |
| `0x11` | `lfirst` | First active loop − 1. |
| `0x13` | `pmode` | Playback mode — confirmed as a real 4-state field (not just loop on/off) by the S3000XL Operator's Manual (ENV1 page area, p.99–100) and matched against `SAMPLE1000_PMODE_*` in akaiutil_file.h: `0x00`=Loop, `0x01`=Loop Until Release (no release tail on key-up), `0x02`=No Loop, `0x03`=Play to End (ignores both loop points and key-up). Modeled in this app as `AkaiSamplePlaybackMode`. |
| `0x14` | `ctune` | Cents tune, signed. |
| `0x15` | `stune` | Semitone tune, signed. |
| `0x16`–`0x19` | `locat[4]` | Sampler-managed absolute address — never write a meaningful value here (see clone gotcha below). |
| `0x1A`–`0x1D` | `slen[4]` | 32-bit LE, number of samples — the authoritative count the Akai reports (verified against a real S3000XL: a 256-sample factory SINE reports `slen=256`). |
| `0x1E`–`0x21` | `start[4]` | Start marker. |
| `0x22`–`0x25` | `end[4]` | End marker. |
| `0x26`–`0x85` | `loop[8]` | 8 × 12-byte loop records (`akai_sample1000loop_s`): `at[4]` @ +0x00 (loop return point), `flen[2]` @ +0x04 (fine length, 1/65536 sample), `len[4]` @ +0x06 (loop length in samples), `time[2]` @ +0x0A (loop time in ms). Only loop 0 (at absolute `0x26`/`0x2A`/`0x2C`/`0x30`) is used by this app. |
| `0x88`–`0x89` | `stpaira[2]` | Address of the stereo-pair partner's header, sampler-managed; `0xFFFF` = none. **Never copy this from a source sample when cloning** — see gotcha below. |
| `0x8A`–`0x8B` | `srate[2]` | Sample rate in Hz, 16-bit LE. |
| `0x8C` | `hltoff` | HOLD loop tune offset. |
| `0x8D`–`0x95` | `dummy4[9]` | Reserved. |
| `0x96`–`0xBF` | padding | 42 bytes of S3000-specific padding beyond the S1000 struct. |
| `0xC0`+ | audio data | 16-bit signed LE PCM, mono. Verified against a real S3000XL: a 256-sample SINE has directory size 704 = `0xC0` header + 512 audio bytes (256 × 2-byte frames) — audio begins at `0xC0`, not `0xFC`. |

**Gotcha (avoided by design in this app):** `addImportedSample`/`buildSampleHeader` always hand-builds a fresh header from zero rather than cloning an existing sample's header bytes. Cloning would drag along `locat` (`0x16`) and `stpaira` (`0x88`), both sampler-managed pointers that would point at the *wrong* sample on the new disk location — observed on hardware as the sampler starting to load, showing the name, then stopping.

### Program header (`struct akai_program3000_s` = `akai_program1000_s` + 42 bytes padding, akaiutil_file.h) — 0xC0 bytes, keygroups follow

| Offset | Field | Notes |
|---|---|---|
| `0x00` | `blockid` | `0x01` (`PROGRAM1000_BLOCKID`). |
| `0x01`–`0x02` | `kg1a[2]` | Address of keygroup 1, sampler-managed. |
| `0x03`–`0x0E` | `name[12]` | Akai-encoded. |
| `0x10` | `midich1` | On-disk: `0xFF` = Omni, `0`–`15` = MIDI channel (0-indexed). This app's UI uses `0`=Omni, `1`–`16` (1-indexed) and translates at the boundary rather than storing the raw byte in the model. |
| `0x13` | `keylo` | Program-level low key. |
| `0x14` | `keyhi` | Program-level high key. |
| `0x15` | `oct` | Octave offset, signed — used by this app's UI as "bend range." |
| `0x16` | `auxch1` | Aux output channel; `0xFF` = off. |
| `0x29` | `kgxf` | Keygroup crossfade enable. |
| `0x2A` | `kgnum` | Number of keygroups. **Must exactly match** the number of `0xC0`-byte keygroup blocks actually present after the header — a real S3000 reports "bad disk program" if it disagrees, which is why this app always rebuilds the whole program file from scratch on edit (`buildProgramFileData`) rather than patching bytes in place. |

### Program keygroup (`struct akai_program3000kg_s` = `akai_program1000kg_s` + 42 bytes padding) — 0xC0 bytes each, starting at offset `0xC0` in the file

| Offset (within keygroup) | Field | Notes |
|---|---|---|
| `0x00` | `blockid` | `0x02` (`PROGRAM1000KG_BLOCKID`). |
| `0x03` | `keylo` | Low MIDI key for this keygroup. |
| `0x04` | `keyhi` | High MIDI key for this keygroup. |
| `0x22`, `0x22+0x18`, `0x22+0x30`, `0x22+0x48` | 4 × velocity zones (`akai_program1000kgvelzone_s`, 0x18 bytes each) | This app only populates velocity zone 1 (the primary sample assignment) and leaves zones 2–4 as empty/no-sample placeholders. |

**Velocity zone layout** (`akai_program1000kgvelzone_s`, 0x18/24 bytes, offsets relative to the zone's own start):

| Offset | Field | Notes |
|---|---|---|
| `0x00`–`0x0B` | `sname[12]` | Sample name, Akai-encoded. |
| `0x0C` | `vello` | Low MIDI velocity. |
| `0x0D` | `velhi` | High MIDI velocity. |
| `0x0E` | `ctune` | Cents tune offset, signed. |
| `0x0F` | `stune` | Semitone tune offset, signed. |
| `0x10` | `loud` | Loudness offset, signed. |
| `0x11` | `filter` | Filter cutoff **fine-tune trim**, signed, range ±50. Confirmed by the S3000XL Operator's Manual (SMP2 page, p.93): "This parameter allows you to fine tune the filter cutoff slightly to maintain a consistent tone between keygroups." This is layered ON TOP of the keygroup's own main filter (see Filter section below) — it does not set the filter on its own. Modeled in this app as `AkaiProgramKeyzone.filterOffset`. |
| `0x12` | `pan` | Pan offset, signed. |
| `0x13` | `pmode` | Playback mode — confirmed as a real 5-state field by the manual's filter/envelope discussion and matched against `PROGRAM1000_PMODE_*` in akaiutil_file.h: `0x00`=Sample's Setting (inherit the sample's own `pmode`), `0x01`=Loop, `0x02`=Loop Until Release, `0x03`=No Loop, `0x04`=Play to End. Modeled in this app as `AkaiPlaybackMode`. |
| `0x16`–`0x17` | `shdra[2]` | Address of sample header, sampler-managed; `0xFFFF` = none. |

### Filter (confirmed against the S3000XL Operator's Manual, p.96–98 & p.93)

There are **two separate filter controls**, confirmed from real hardware documentation (not just struct field names):

**1. Keygroup-level filter (FILT page)** — the main filter. One 12dB/octave resonant lowpass filter per keygroup (an optional second filter bank adds 24dB/8ve 4-pole lowpass plus multi-mode HP/BP/LP/EQ — separate hardware, out of scope here). Confirmed parameters and ranges:

| Parameter | Range | Notes |
|---|---|---|
| Frequency (cutoff) | 0–99 | Decreasing from 99 removes upper harmonics → softer tone. For any modulation below to have audible effect, this must be set below 99. |
| Key Follow | signed | Default **+12** = tracks the cutoff octave-for-octave with keyboard position. |
| Resonance | 0–15 | Boosts harmonics around the cutoff; high settings give the classic synth "weeow" sound. |
| 3× modulation depth | ±50 each | Defaults: **Velocity→Freq**, **Lfo2→Freq**, **Env2→Freq**. Each is independently re-assignable to: Modwheel, Bend, Pressure, External (footpedal/volume/breath), Key, Lfo1, Env1, or a "!" (note-on-only) variant of any of these. |
| ENV2 | 4-stage (Rate1→Level1, Rate2→Level2, Rate3→Level3=sustain, Rate4→Level4) | A second envelope generator hardwired specifically to the filter (separate from ENV1, which is hardwired to amplitude). |

**Not yet implemented in this app, and not yet safe to implement:** akaiutil's struct (`akai_program1000kg_s`) only names a single `filter` byte at the keygroup level; the rest of the controls above are presumably packed into the struct's `dummy1[22]` region, which akaiutil's authors never decoded. Writing to unconfirmed offsets there risks corrupting sampler-managed data we don't understand, so this app leaves the keygroup-level filter page unimplemented until the real offsets are confirmed independently (e.g. by byte-diffing real S3000XL-saved programs with known, isolated filter settings against a baseline — in progress as of this writing).

**2. Velocity-zone-level filter trim** — see the velocity zone table above (`filter` @ +0x11, ±50). This one IS implemented (`AkaiProgramKeyzone.filterOffset`, exposed as "Filter Trim" in `KeyzoneEditorView`), since both its byte offset (from the struct) and its exact semantics (from the manual) are confirmed.

### Known gaps / in-progress investigations

- **Keygroup-level filter offsets (cutoff, key-follow, resonance, 3× mod depth)** — semantics confirmed (see Filter section above), byte offsets not. Plan to confirm them: set a single-keygroup test program on a real S3000XL to known baseline filter values, save to floppy, then change exactly ONE filter parameter at a time (re-baselining between each), saving each variant to its own `.img`. Byte-diffing each variant against the baseline isolates which byte(s) moved for which control. Once confirmed, wire up the FILT page the same way the velocity-zone filter trim was wired up.
- **Multiple loop points per sample** — `akai_sample1000_s` has `loop[8]` (8 loop slots) plus `lnum`/`lfirst`, but this app only ever reads/writes `loop[0]`. Out of scope for now (explicit decision, not a bug).

### Akai character encoding (confirmed against `akai2ascii`/`ascii2akai` in akaiutil)

| Code | Character | Code | Character |
|---|---|---|---|
| `0`–`9` | `'0'`–`'9'` | `37` | `'#'` |
| `10` | `' '` (space) | `38` | `'+'` |
| `11`–`36` | `'A'`–`'Z'` | `39` | `'-'` |
| | | `40` | `'.'` |

**Gotcha (fixed in this app, June 2026):** this app's decoder (`akaiString`) originally treated byte `0x00` as a terminator and skipped it, while the encoder (`akaiCode(for:)`) correctly mapped `'0'` → byte `0x00` per the table above. That asymmetry meant a literal `'0'` in a name didn't round-trip through decode. Fixed by decoding `0x00` as `'0'`, matching the table exactly. One side effect to be aware of: any 12-byte region that's genuinely all-zero (not a real name field, just unused/reserved bytes) will now decode as `"000000000000"` instead of an empty string — this app always pads its own unused name bytes with the Akai *space* code (`10`), not `0x00`, so this only matters if `akaiString` is ever pointed at a non-name region.

---

## Special thanks

This project wouldn't have been possible without the open-source work of people who reverse-engineered the Akai disk format before me. Huge thanks to:

- **[Midi-In / akaiutil](https://github.com/Midi-In/akaiutil)** — the definitive reference for S1000/S3000 character encoding, FAT structure, and file types. The `akai2ascii` function saved the day.
- **[dialtr / akai-fs](https://github.com/dialtr/akai-fs)** — another invaluable reference for filesystem parsing, WAV export logic, and sample header layout.
- **[keirf / GreaseWeazle](https://github.com/keirf/greaseweazle)** — the hardware and software that makes reading real Akai floppies on modern hardware possible. The `akai.1600` format definition was exactly what was needed.
- **The original Akai S3000XL Operator's Manual** — the missing piece for *semantics*, not just byte layout. Confirmed real units/ranges/behavior for sample and program playback modes and the filter section that the open-source utilities above never fully documented.

---

## Useful links

- [GreaseWeazle](https://github.com/keirf/greaseweazle) — floppy imaging hardware & software
- [akaiutil (Midi-In)](https://github.com/Midi-In/akaiutil) — S1000/S3000 filesystem utility
- [akai-fs (dialtr)](https://github.com/dialtr/akai-fs) — another Akai filesystem implementation
- [Akai S3000XL Wikipedia](https://en.wikipedia.org/wiki/Akai_S3000XL) — background on the sampler

---

*Personal project — use at your own risk. Always keep backups of your disk images before saving changes.*
