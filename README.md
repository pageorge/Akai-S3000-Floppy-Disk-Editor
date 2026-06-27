# Akai S3000 Floppy Disk Editor

![Akai S3000 Editor Logo](AkaiS3000Editor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png)

I love the sound of Akai samplers. Maybe it’s just me, but when I play back old drum and bass loops from the 90s, they sound MASSIVE! Sure, plugin samplers are easy to use, but they just seem to lack the magic of going through the crunch and op amps of the Akais. I also love the simplicity of being restricted to a 1.4Mb floppy disk — it really does make you think, “I need to choose my samples carefully, every one must be a banger and cut through the mix!"

This is a personal macOS project that allows me to read and write Akai S3000XL floppy disks using a UI that is super easy and powerful: quickly create programs, then drag and drop WAV files into program or drum key group configs with filter and loop settings, then save to an .img file. For reading and editing Akai S3000 floppy disk images (.img), I use the AMAZING [Greaseweazle](https://github.com/keirf/greaseweazle) floppy-to-USB-C card.

My app is built with SwiftUI — no dependencies — so it should run on most modern Macs. You will need to edit permissions in Settings to trust it, as it’s not on the App Store yet!

**[View on GitHub](https://github.com/pageorge/Akai-S3000-Floppy-Disk-Editor)**

---

## Download

**[⬇️ Download latest build](https://github.com/pageorge/Akai-S3000-Floppy-Disk-Editor/releases/latest)**

1. Download `AkaiS3000Editor.zip` from the link above
2. Run the App
3. On first launch modern Mac will say it can't run, go in to Settings -> Privacy & Security -> Open Anyway - I trust this guy!


<p align="center">
  <img src="screenshots/permissions.png" alt="Showing permissions for the app">
</p>

---

## Screenshots

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="screenshots/sample-edit.png" alt="Sample editing" width="100%">
      <p align="center">Drag in a sample, tweak loop points etc...</p>
    </td>
    <td width="50%" valign="top">
      <img src="screenshots/program-drum.png" alt="Program and drum program creation" width="100%">
      <p align="center">Easily create new or clone keyzones, create a drum program by dragging in multiple samples on to the drum drop zone! Set filter settings</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="screenshots/disk-info.png" alt="Disk info and map" width="100%">
      <p align="center">Floppy disk info and a map of where everything will live on the disk</p>
    </td>
    <td width="50%" valign="top">
      <img src="screenshots/greaseweazle.png" alt="Greaseweazle integration" width="100%">
      <p align="center">Read / Write buttons call Greaseweazle commands and show log and progress writing to disk</p>
    </td>
  </tr>
</table>

---

## Requirements

- **macOS 14 Sonoma** or later
- No third-party dependencies

To build from source: **Xcode 15** or later.

---

## All source code is available - if you want to building it yourself:

1. Clone this repo
2. Open `AkaiS3000Editor.xcodeproj` in Xcode
3. Set your Development Team in Signing & Capabilities
4. Press **⌘R**

---

### Tips & Tricks

## How to create a new program on the S3000XL

There's no separate "blank new program" function — every new program is made by copying an existing one (most simply, the built-in default TEST PROGRAM, which is what loads when you go into EDIT SINGLE for the first time):

1. Go to EDIT PROGRAM → SINGLE. You'll land on the main screen showing whatever program is currently selected (e.g. `program: TEST PROGRAM`).
2. Press the NAME key. The front panel keys become a letter keyboard, and you'll see: `LETTERS .. (NAME for numbers ENT to exit)`
3. Type your new program's name (up to 12 characters, uppercase only). Use CURSOR keys + the DATA wheel to move around and scroll through characters if you don't want to type letter-by-letter; +/< and -/> on the numeric keypad give you backspace and space.
4. Press ENT. You'll get: `Select: [COPY] [REN] [exit]`
5. Press COPY. This duplicates whatever program was currently loaded (e.g. TEST PROGRAM) under your new name — that's your new program.

A few things worth knowing:

- If the name you typed already exists, it'll show `*existing Prog*` and then `!! MUST USE A DIFFERENT NAME !!` — just enter a unique name and try again.
- REN (instead of COPY) renames the current program in place rather than making a copy — not what you want for a new program.
- Since it's always a copy of something, the cleanest "from scratch" approach (and the one the manual itself recommends) is to make sure TEST PROGRAM is the currently loaded program before you start naming — that's the single-keygroup default, so your "new" program starts simple rather than inheriting a complex existing one's keygroups/filter settings.

---

## Technical Reference: Akai S3000 Disk Format

A compact map of the on-disk format, sourced from [Midi-In/akaiutil](https://github.com/Midi-In/akaiutil) (primary struct source), [keirf/GreaseWeazle](https://github.com/keirf/greaseweazle) (physical track layout), and the Akai S3000XL Operator's Manual (parameter semantics/ranges), with several offsets confirmed/corrected by direct hardware testing.

### Physical layout (`akai.1600` / `akai.800`)

| | `akai.1600` (HD) | `akai.800` (LD) |
|---|---|---|
| Cylinders | 80 | 80 |
| Heads | 2 | 1 |
| Sectors/track | 10 | 10 |
| Bytes/sector | 1024 | 1024 |
| Total blocks | 1600 | 800 |
| Data rate | 500 kbps (MFM HD) | 250 kbps (MFM DD) |

### Floppy header (`akai_flhhead_s`) — blocks 0–4, 5120 bytes

| Offset | Field | Size | Notes |
|---|---|---|---|
| `0x0000` | `file[64]` | 0x600 | Floppy-header directory copy. On S3000 disks, slot 0 is a sentinel (type `0xFF`, name `VVVVVVVVVVVV`); the real directory lives elsewhere (see below). |
| `0x0600` | `fatblk[1600][2]` | 0xC80 | FAT: 16-bit LE per block. |
| `0x1280` | `label` (`akai_flvol_label_s`) | 0x40 | Volume name (12 bytes) + 2 reserved + OS version (2 bytes) + 0x30 params. |
| `0x12C0` | padding | 0x140 | Unused. |

### Live volume directory — `akai_voldir3000fl_s`

Starts at **block 5**, 510 × 24-byte entries, spans 12 blocks.

### FAT codes

| Code | Meaning |
|---|---|
| `0x0000` | Free |
| `0x4000` | System (header + directory) |
| `0x8000` | End of directory's own chain (S3000) |
| `0xC000` | End of file chain |
| other | Next block number (16-bit LE) |

### Volume directory entry (`akai_voldir_entry_s`) — 24 bytes

| Offset | Field | Notes |
|---|---|---|
| `0x00`–`0x0B` | `name[12]` | Akai-encoded. |
| `0x0C`–`0x0F` | `tag[4]` | S3000 free = `0x00`; S1000 default = `0x20`. |
| `0x10` | `type` | `0x00`=free, `0xF3`=sample, `0xF0`=program. |
| `0x11`–`0x13` | `size[3]` | 24-bit LE, total bytes incl. header. |
| `0x14`–`0x15` | `start[2]` | 16-bit LE start block. |
| `0x16`–`0x17` | `osver[2]` | Samples=`0x0000`; programs=`0x1100`. |

### Sample header (`akai_sample3000_s`) — 0xC0 (192) bytes, audio follows immediately

| Offset | Field | Notes |
|---|---|---|
| `0x00` | `blockid` | `0x03`. |
| `0x01` | `bandw` | `0x00`=10kHz, `0x01`=20kHz. |
| `0x02` | `rkey` | MIDI root key. |
| `0x03`–`0x0E` | `name[12]` | Akai-encoded. |
| `0x10` | `lnum` | Number of loops. |
| `0x11` | `lfirst` | First active loop − 1. |
| `0x13` | `pmode` | `0x00`=Loop, `0x01`=Loop Until Release, `0x02`=No Loop, `0x03`=Play to End. |
| `0x14` | `ctune` | Cents tune, signed. |
| `0x15` | `stune` | Semitone tune, signed. |
| `0x16`–`0x19` | `locat[4]` | Sampler-managed address. |
| `0x1A`–`0x1D` | `slen[4]` | Number of samples. |
| `0x1E`–`0x21` | `start[4]` | Start marker. |
| `0x22`–`0x25` | `end[4]` | End marker. |
| `0x26`–`0x85` | `loop[8]` | 8 × 12 bytes: `at[4]`, `flen[2]`, `len[4]`, `time[2]`. |
| `0x88`–`0x89` | `stpaira[2]` | Stereo-pair partner header address; `0xFFFF`=none. |
| `0x8A`–`0x8B` | `srate[2]` | Sample rate, Hz, 16-bit LE. |
| `0x8C` | `hltoff` | HOLD loop tune offset. |
| `0xC0`+ | audio | 16-bit signed LE PCM, mono. |

### Program header (`akai_program3000_s`) — 0xC0 bytes, keygroups follow

| Offset | Field | Notes |
|---|---|---|
| `0x00` | `blockid` | `0x01`. |
| `0x01`–`0x02` | `kg1a[2]` | Address of keygroup 1, sampler-managed. |
| `0x03`–`0x0E` | `name[12]` | Akai-encoded. |
| `0x10` | `midich1` | `0xFF`=Omni, else 0-indexed channel. |
| `0x13` | `keylo` | Program-level low key. |
| `0x14` | `keyhi` | Program-level high key. |
| `0x15` | `oct` | Octave offset, signed. |
| `0x16` | `auxch1` | `0xFF`=off. |
| `0x29` | `kgxf` | Keygroup crossfade enable. |
| `0x2A` | `kgnum` | Number of keygroups (must match actual count). |

### Program keygroup (`akai_program3000kg_s`) — 0xC0 bytes each, starting at file offset `0xC0`

| Offset (in keygroup) | Field | Notes |
|---|---|---|
| `0x00` | `blockid` | `0x02`. |
| `0x03` | `keylo` | Low MIDI key. |
| `0x04` | `keyhi` | High MIDI key. |
| `0x07` | `filter` (Frequency/cutoff) | 0–99, direct value. Hardware-confirmed. |
| `0x08` | Key Follow | Signed. Real blank-keygroup default is **0**, not the manual's stated +12. Hardware-confirmed. |
| `0x95` | Resonance | 0–15, direct. Hardware-confirmed; outside akaiutil's documented struct entirely. |
| `0x97` | Filter mod depth #1 (Velocity→Freq) | ±50, signed. Hardware-confirmed. |
| `0x98` | Filter mod depth #2 (Lfo2→Freq) | ±50, signed. Hardware-confirmed. |
| `0x99` | Filter mod depth #3 (Env2→Freq) | ±50, signed. Hardware-confirmed. |
| `0x22`, `+0x18`, `+0x30`, `+0x48` | 4 × velocity zones | 0x18 bytes each (table below). |

### Velocity zone (`akai_program1000kgvelzone_s`) — 0x18 (24) bytes

| Offset | Field | Notes |
|---|---|---|
| `0x00`–`0x0B` | `sname[12]` | Sample name, Akai-encoded. |
| `0x0C` | `vello` | Low velocity. |
| `0x0D` | `velhi` | High velocity. |
| `0x0E` | `ctune` | Cents tune, signed. |
| `0x0F` | `stune` | Semitone tune, signed. |
| `0x10` | `loud` | Loudness offset, signed. |
| `0x11` | `filter` (cutoff trim) | ±50, signed. Layered on top of the keygroup's Frequency. |
| `0x12` | `pan` | Pan offset, signed. |
| `0x13` | `pmode` | `0x00`=Sample's Setting, `0x01`=Loop, `0x02`=Loop Until Release, `0x03`=No Loop, `0x04`=Play to End. |
| `0x16`–`0x17` | `shdra[2]` | Sample header address; `0xFFFF`=none. |

### Filter — remaining gaps

Mod-depth source selectors (which of Modwheel/Bend/Pressure/External/Key/Lfo1/Env1/Velocity/Lfo2/Env2, or their note-on-only "!" variants, each of the 3 depth slots above routes from) and ENV2's own 4-stage rate/level envelope.

### Akai character encoding

| Code | Char | Code | Char |
|---|---|---|---|
| `0`–`9` | `'0'`–`'9'` | `37` | `'#'` |
| `10` | `' '` | `38` | `'+'` |
| `11`–`36` | `'A'`–`'Z'` | `39` | `'-'` |
| | | `40` | `'.'` |

---

### Reading a floppy with GreaseWeazle

```bash
gw read --format=akai.1600 my_disk.img --drive=B
```

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
