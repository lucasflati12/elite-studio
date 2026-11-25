<img src="assets/icon.png" width="96" alt="Elite Studio icon">

# Elite Studio

A lightweight video editor I built for my own reels — and the workflow where an AI does the editing.

**How I use it:** I record ~1 minute of me talking, an AI assistant (Claude) reads the transcript and writes a `.elitestudio` timeline (a plain JSON file: best takes, cuts, B-roll lanes, captions), then I open it in Elite Studio, tweak and export. Raw 1:12 → reel 0:15.

## What's inside

| Folder | Platform | Stack |
|---|---|---|
| [`mac/`](mac/) | macOS (Apple Silicon, macOS 26+) | Swift / SwiftUI + AVFoundation, no external dependencies |
| [`windows/`](windows/) | Windows 10/11 | Python 3.10+ / PySide6 (Qt), OpenCV, faster-whisper; FFmpeg on PATH |

Features: two video lanes (V1/V2), audio levels, automatic captions, title overlays, basic colour grading with a shared 3D LUT, Insta360 360° reframing (Mac), and a command line to check/export projects without opening the UI.

Round 3a Windows adds timeline markers, speed and duration controls with ramp segments, freeze frames, reverse clips, crop/flip and blurred canvas backgrounds. Shared JSON fields are documented in [`docs/FORMATO-MONTAGGIO.md`](docs/FORMATO-MONTAGGIO.md).

## Mac — quick start

**Insta360 360° on a Mac:** download the ready-to-use folder (app + Italian guide) [Insta360-360-su-Mac.zip](https://github.com/lucasflati12/elite-studio/releases/latest/download/Insta360-360-su-Mac.zip) — guide: [`mac/GUIDA-360-INSTA360.md`](mac/GUIDA-360-INSTA360.md).

```bash
cd mac
./build.sh            # builds Elite Studio.app (needs Xcode command line tools)
open "Avvia Elite Studio.command"
```

The `.elitestudio` project format and the CLI (`elitestudio --check / --export / --captions`) are documented in [`mac/DOCUMENTAZIONE TECNICA.md`](mac/DOCUMENTAZIONE%20TECNICA.md) (Italian).

## Windows — quick start

Needs Python 3.10+ and FFmpeg/ffprobe on PATH.

```bat
cd windows
:: creates the runtime in %LOCALAPPDATA%\EliteStudioWindows, a Desktop shortcut and the .elitestudio association
"Installa Elite Studio.bat"
"Start Elite Studio.bat"
```

Command line (with the runtime's Python):

```bat
python Windows\app.py --check|--export|--captions project.elitestudio
```

Details in [`windows/Windows/README.md`](windows/Windows/README.md) (Italian).

## Let an AI edit your video

Give your AI assistant the format doc above plus the transcript of your clip and ask it to write a `.elitestudio` file that keeps the best takes. Open it in Elite Studio, check, export.

## License

Code: MIT (see `LICENSE`). Bundled Archivo fonts: SIL Open Font License 1.1.
