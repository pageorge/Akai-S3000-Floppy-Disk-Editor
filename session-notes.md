# AkaiS3000Editor — Session Notes (Session 8)

## Project
- **Root**: /Users/philgeorge/Projects/Akai-S3000-Floppy-Disk-Editor/
- **GitHub**: pageorge/Akai-S3000-Floppy-Disk-Editor (main branch)
- **Gold standard disk**: AKAI_BOOT_NO_SAMPLES.img (factory fresh, used for new disk seeding)
- **Version tag**: AKE-1.2 written at 0x128C on every save

## Key source files
- AkaiDiskImage.swift — model, all disk format logic
- ProgramDetailView.swift — program editor, keyzone UI, drag/drop
- SidebarView.swift — sidebar, sample/program/multi lists
- SupportingViews.swift — WaveformView, DiskMapView, InfoCard etc.
- SampleDetailView.swift — sample editor
- GreaseweazleRunner.swift — Greaseweazle read/write

## This session — major changes

### Multi-file Finder drag fixed
- `handleProgramDrop` now loops all providers, not just first
- All dropped WAVs get their own keyzone

### Keyzone layout picker
- `KeyzoneLayout` enum: `.singleKey` / `.fullKeyboard`
- `withLayout()` shows picker on first drag, remembers for session
- Single Key: C1 onwards per sample, rkey patched to match
- Full Keyboard: divide 24–127 evenly, redistributed on each add
- Folder drops also go through layout picker
- No Cancel button on picker

### Drum concept removed entirely
- No more `createDrumProgram()`, `drumProgramNames`, `isDrumKit` UI
- `akaiDrumBrown`, `drumKitSymbol` globals removed
- `isDrumOverride` removed from SidebarProgramRow
- All programs: purple `pianokeys.inverse` icon
- `isDrumKit` computed property kept on AkaiProgram (not used in UI)

### Stereo naming fix
- `uniqueSampleBaseName()` added — checks neither base+"-L" nor base+"-R" conflicts
- `addImportedSample` has `forceName: Bool` parameter — skips deduplication for stereo pairs
- Right channel name correctly set in keyzone `rightSampleName`

### Bend range fix
- Both `0x15` (bend down) and `0x27` (bend up) now written from single `bendRange` field
- Single UI stepper "Bend Range" writes both offsets simultaneously
- Parse takes `max(0x15, 0x27)` for backward compatibility

### Playback mode descriptions updated
- `displayName` now includes short bracketed hint in picker list
  - "Loop In Release (keeps looping after key released, fades out)"
  - "Loop Until Release (stops looping when key released, plays tail)"
  - "No Loop (plays once, fades out on key release)"
  - "Play to End (always plays full sample, ignores loop points and key release)"
- Full `explanation` text restored below picker

### Crossfade detection (read-only)
- `hasCrossfade` property: `lnum==4 && rawHeader[0x12] != 0`
- WaveformView: orange diagonal-stripe shaded region at loop end with "Xf" label when active
- Loop InfoCard: orange badge "Crossfade active (applied on hardware — baked into PCM, read-only)"
- Crossfade length NOT stored on disk — baked into PCM by Akai's X-FD function (destructive DSP)
- xf value is a working parameter, not persisted. Cannot implement in app without replicating Akai DSP.

### Add Samples UI
- Always shown at top of right panel, max height 150pt
- Drop zone: "Drop a sample or folder to create a keyzone(s)" + "You'll be asked how to map it to keys"
- SimpleDropZone full width

### Global settings fix (CRITICAL)
- Global settings (transpose, tune etc.) stored in blocks 0-4
- Leaving zeros causes corrupt transpose on load (manifests as all samples half speed)
- `createBlankImage` now seeds blocks 0-4 from hardware-captured factory bytes:
  - Block 0 header slots: volume name, `0x10` at byte 18 (undocumented), osver `0x11`
  - Block 4 at 0x292–0x299: `01 00 00 00 32 09 0C FF` (factory defaults)
- README tip added explaining global settings behaviour

### Loop slot times fix (CRITICAL)
- For NoLoop samples ALL 8 slot time fields must be 0
- Writing 9999 in any slot (even slots 1-7) causes Akai to loop regardless of pmode
- Manifests as sample playing at half speed / dragging
- App writes 0 in all 8 slots for NoLoop imports
- When looping, active loop replicated into slots 0-3 with time=9999

### Greaseweazle write optimisation
- `lastUsedTrack()` computes last used cylinder from FAT
- Write command passes `--tracks=c=0-N`
- Saves up to 68% write time on sparse disks

### Multi-select samples
- `selectedSampleIDs` lifted to ContentView @State, passed as @Binding to SidebarView
- SampleDetailView accepts `selectedSampleIDs: Set<UUID>`
- Editing any field applies to all selected samples
- Multi-select banner shown when 2+ samples selected

### README overhaul
- Complete rewrite of Technical Reference in Ohsaki-style monospace format
- Cross-reference table: akaiutil | ohsaki | manual | this project | status
- Disputed offsets documented: 0x15 (octave shift vs bend down), 0x84/0x85-88 (pitchMode)
- Our findings: 0x4a bend mode, 0x54-56 filter mod sources, 0x95 resonance, 0x97-99 mod depths, 0x9c-9f ENV2

### ExternalResources folder
- Created at project root
- README.md — index
- S3000-format-ohsaki.txt — full Ohsaki format document
- akaiutil_file.h — C struct definitions from akaiutil (Indlekofer)
- akai-fs-notes.md — akai-fs context notes

## Outstanding / pending
1. WAVImport.swift / Data+LittleEndian.swift target membership (recurring)
2. `0x15` in program: Ohsaki says "play octave shift ±2", we write bend down — needs hardware test
3. `0x84` vs `0x85-88` pitchMode: we write at 0x84, Ohsaki says 0x85-88 — zones 2-4 untested
4. Crossfade X-FD implementation: complex DSP, parked. Read-only indicator in place.
5. Not-modelled fields from Ohsaki: pan LFO, key temperament, soft pedal, echo, LFO de-sync,
   pitch law, tune offset, key>LFO, output scale, vel/key>amp, vel/key>filter,
   fixed rate detune, output offset, vel>sample start
6. Screenshots folder case: renamed to Screenshots, run:
   `sed -i '' 's|screenshots|Screenshots|g' AkaiS3000Editor.xcodeproj/project.pbxproj`
7. ZuluSCSI SCSI-to-USB-C — potential future workflow improvement (no floppy needed)

## Key format facts confirmed this session
- Loop xfade: destructive PCM operation, not stored as header field. lnum=4 and 0x12≠0 = xfade applied.
- Global settings in blocks 0-4: must seed from factory bytes or transpose corrupts on load.
- Bend up at 0x27, bend down at 0x15 — both must be written. Factory default: up=2, down=0.
- All 8 loop slot times must be 0 for NoLoop — any 9999 forces loop regardless of pmode.

## Previous transcript
/mnt/transcripts/2026-09-21-10-48-30-akai-s3000-editor-session7.txt
