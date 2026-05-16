# Akai S3000 Editor — macOS App

A native macOS SwiftUI application for reading, editing, and writing Akai S3000 `.img` disk images. Browse samples and programs, export/import WAV files, and edit keyzone mappings. The perfect companion to GreaseWeazel.

---

## Features

- **Open `.img` disk images** — drag & drop or use File → Open
- **Browse samples** — view all samples with metadata (name, sample rate, root note, duration, loop points)
- **Waveform display** — visual audio preview of each sample
- **Preview playback** — click Play to audition any sample
- **Export WAV** — extract any sample as a standard 16-bit PCM WAV file
- **Import WAV** — add WAV files as new samples, converted to Akai format
- **Edit sample parameters** — root note, fine tune, loudness, loop start/end
- **Browse programs** — view all programs with keyzone counts
- **Keyzone editor** — add/remove/edit keyzones with full parameter control
- **Piano keyboard visualizer** — see keyzone ranges drawn on a piano keyboard
- **Save changes** — write modifications back to the `.img` file
- **Disk info** — free blocks, file counts, disk name

---

## Requirements

- **macOS 14.0 (Sonoma)** or later
- **Xcode 15** or later
- No third-party dependencies — pure Swift/SwiftUI/AVFoundation

---

## Setup

### 1. Create the Xcode project

The source files are provided as individual `.swift` files. To build:

**Option A — Create manually in Xcode:**

1. Open Xcode → File → New → Project
2. Choose **macOS → App**
3. Set:
   - Product Name: `AkaiS3000Editor`
   - Interface: `SwiftUI`
   - Language: `Swift`
   - Minimum Deployment: `macOS 14.0`
4. Replace the generated files with the provided `.swift` files
5. Add all `.swift` files to the target

**Option B — Use the provided `.xcodeproj`:**

1. Open `AkaiS3000Editor.xcodeproj` in Xcode
2. Move all `.swift` source files into the `AkaiS3000Editor/` subfolder
3. Verify all files appear in the target's "Compile Sources" build phase
4. Set your Development Team in Signing & Capabilities
5. Press **⌘R** to build and run

### 2. File structure

```
AkaiS3000Editor/
├── AkaiS3000Editor.xcodeproj/
│   └── project.pbxproj
├── AkaiS3000EditorApp.swift      ← App entry point
├── ContentView.swift              ← Main window + navigation
├── AkaiDiskImage.swift           ← Disk format parser + read/write engine
├── SidebarView.swift             ← File browser sidebar
├── WelcomeView.swift             ← Drop zone / empty state
├── SampleDetailView.swift        ← Sample editor + WAV export/import
├── ProgramDetailView.swift       ← Program + keyzone editor
├── PianoKeyboardView.swift       ← Visual keyzone range display
└── SupportingViews.swift         ← Waveform, disk info, shared components
```

---

## Akai S3000 Format Notes

### Disk Layout

The S3000 uses a custom filesystem on standard 1.44MB HD floppy disks:

| Field | Value |
|-------|-------|
| Sector size | 512 bytes |
| Tracks | 80 × 2 sides |
| Sectors/track | 18 |
| Block size | 1024 bytes (2 sectors) |
| Directory | Starts at sector 1, 24 bytes/entry |
| Volume header | Sector 0 |

### File Types

| Type byte | Meaning |
|-----------|---------|
| `0x46` | Sample file |
| `0x50` | Program file |

### Sample Header (offset in file)

| Offset | Field |
|--------|-------|
| `0x00` | Name (12 bytes Akai ASCII) |
| `0x0C` | Bandwidth (0=11kHz, 1=22kHz, 2=44kHz) |
| `0x0D` | MIDI root note |
| `0x0E` | Fine tune (signed byte, cents) |
| `0x0F` | Loudness |
| `0x10–0x11` | Loop start (16-bit LE) |
| `0x12–0x13` | Loop end (16-bit LE) |
| `0x14` | Loop enabled |
| `0x18–0x1B` | Number of samples (32-bit LE) |
| `0x96` | Audio data begins (16-bit signed big-endian) |

### Audio Format

- **Internal:** 16-bit signed **big-endian** PCM
- **Export:** Converted to 16-bit signed **little-endian** WAV (standard)
- **Mono** — each sample layer is a single channel

### Program Keyzones

Each keyzone entry is 22 bytes starting at offset `0x14` in the program file:

| Offset | Field |
|--------|-------|
| `0x00` | Sample name (12 bytes) |
| `0x0C` | Low key (MIDI 0–127) |
| `0x0D` | High key (MIDI 0–127) |
| `0x0E` | Root note (MIDI 0–127) |
| `0x0F` | Tune offset (signed, semitones) |
| `0x10` | Fine tune (signed, cents) |
| `0x11` | Volume |
| `0x12` | Pan (signed, –50 to +50) |
| `0x13` | Loop flag |
| `0x14` | Velocity low |
| `0x15` | Velocity high |

---

## Known Limitations & Next Steps

- **Multi-sample import**: Currently imports one WAV per sample slot. A future "batch import + auto-keymap" feature is planned.
- **New file allocation**: Imported WAVs that don't fit in the existing sample's block space need a block allocator (the FAT is parsed but not yet written for new allocations).
- **Velocity layers**: The S3000 supports multiple velocity layers per key — these are visible in the keyzone list but a dedicated velocity-layer editor would improve the UX.
- **CD-ROM images**: The S3000 also reads CD-ROMs; these use a different (ISO9660) filesystem and are not currently supported.

---

## Resources

- [Akai S3000 Service Manual](https://manuals.fdiskc.com/flat/Akai%20S3000%20Service%20Manual.pdf)
- [Akai disk format reverse engineering (various)](https://github.com/search?q=akai+s3000+disk+format)
- [S3000/S2000 sample format documentation](http://www.2writers.com/eddie/TutsAkaiS3000.htm)
