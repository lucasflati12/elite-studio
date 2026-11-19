# Elite Studio

A lightweight video editor I built for my own reels — and the workflow where an AI does the editing.

**How I use it:** I record ~1 minute of me talking, an AI assistant (Claude) reads the transcript and writes a `.elitestudio` timeline (a plain JSON file: best takes, cuts, B-roll lanes, captions), then I open it in Elite Studio, tweak and export. Raw 1:12 → reel 0:15.

## What's inside

| Folder | Platform | Stack |
|---|---|---|
| [`mac/`](mac/) | macOS (Apple Silicon, macOS 26+) | Swift / SwiftUI + AVFoundation, no external dependencies |
| [`windows/`](windows/) | Windows | see `windows/README` |

Features: two video lanes (V1/V2), audio levels, automatic captions, title overlays, Insta360 360° reframing (Mac), and a command line to check/export projects without opening the UI.

## Mac — quick start

```bash
cd mac
./build.sh            # builds Elite Studio.app (needs Xcode command line tools)
open "Avvia Elite Studio.command"
```

The `.elitestudio` project format and the CLI (`elitestudio --check / --export / --captions`) are documented in [`mac/DOCUMENTAZIONE TECNICA.md`](mac/DOCUMENTAZIONE%20TECNICA.md) (Italian).

## Let an AI edit your video

Give your AI assistant the format doc above plus the transcript of your clip and ask it to write a `.elitestudio` file that keeps the best takes. Open it in Elite Studio, check, export.

## License

Code: MIT (see `LICENSE`). Bundled Archivo fonts: SIL Open Font License 1.1.
