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

## Special thanks

This project wouldn't have been possible without the open-source work of people who reverse-engineered the Akai disk format before me. Huge thanks to:

- **[Midi-In / akaiutil](https://github.com/Midi-In/akaiutil)** — the definitive reference for S1000/S3000 character encoding, FAT structure, and file types. The `akai2ascii` function saved the day.
- **[dialtr / akai-fs](https://github.com/dialtr/akai-fs)** — another invaluable reference for filesystem parsing, WAV export logic, and sample header layout.
- **[keirf / GreaseWeazle](https://github.com/keirf/greaseweazle)** — the hardware and software that makes reading real Akai floppies on modern hardware possible. The `akai.1600` format definition was exactly what was needed.

---

## Useful links

- [GreaseWeazle](https://github.com/keirf/greaseweazle) — floppy imaging hardware & software
- [akaiutil (Midi-In)](https://github.com/Midi-In/akaiutil) — S1000/S3000 filesystem utility
- [akai-fs (dialtr)](https://github.com/dialtr/akai-fs) — another Akai filesystem implementation
- [Akai S3000XL Wikipedia](https://en.wikipedia.org/wiki/Akai_S3000XL) — background on the sampler

---

*Personal project — use at your own risk. Always keep backups of your disk images before saving changes.*
