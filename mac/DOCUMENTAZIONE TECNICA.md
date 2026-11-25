# Elite Studio (Mac)

Lightweight video editor for the Coppa Élite interviews: bin, viewer, timeline (V1/V2 + A1/A2 + titles),
razor, trim, ripple delete, Coppa Élite name cards, MP4 export. Native Swift + AVFoundation, ~1.5 MB.

- App: `Elite Studio.app` (double-click; `.elitestudio` files open in it)
- Rebuild after code changes: `./build.sh`
- Source: `Sources/EliteStudio/` (Model, Editing, Editor, CompositionBuilder, Overlay, TimelineView, Views, App)

## Keys (Premiere style)

| Key | Action |
|---|---|
| Space | play / pause |
| J K L | reverse / stop / forward (press L again for 2x, 4x) |
| ← → | 1 frame (Shift = 5) · ↑ ↓ previous / next cut |
| V / C | selection tool / razor tool (Shift-click with the razor cuts every track) |
| ⌘K | cut at the playhead (selected clips, or everything under the playhead) |
| ⌫ | delete (leaves a gap) · **⇧⌫** delete and close the gap on every track |
| Q / W | remove from the clip start to the playhead / from the playhead to the clip end, closing the gap |
| ⌘T | add a name card at the playhead |
| Sottotitoli button | automatic captions from the timeline audio (see below) |
| S | snapping on/off · = / - zoom (centred on the playhead) · \ fit timeline |
| ⌘Z / ⇧⌘Z | undo / redo · ⌘C / ⌘V copy / paste clips at the playhead |
| ⌘I import · ⌘S save · ⌘E export | |

Mouse: drag on an empty spot to draw a selection box (like a Finder folder; Shift/⌘ adds to the selection), then drag any selected clip to move them all together; drag clips to move them (also between V1 and V2), drag clip edges to trim, click the ruler to scrub,
click an empty spot between clips then ⌫ to close that gap, ⌘/⌥ + scroll or pinch to zoom (the zoom stays centred on the playhead), scroll up/down to reach every track when there are many, drag files from the bin or Finder onto the timeline.
Dropping a clip on top of another one overwrites it (like Premiere). Changes save automatically to the open project file.

## Project file format (`.elitestudio`, plain JSON)

Made to be written by a script or by Claude Code, then opened in the app to finish by hand.
Only `clips` is required. Everything left out gets a sensible default.

```json
{
  "settings": { "width": 1080, "height": 1920, "fps": 30 },
  "clips": [
    { "media": "IMG_7450.mov", "in": 7.04, "out": 21.3 },
    { "media": "IMG_7450.mov", "in": 25.0, "out": 40.2 },
    { "media": "IMG_7454.mov", "in": 0.5 },
    { "media": "broll.mp4", "track": 1, "start": 3.0, "duration": 2.5, "volume": 0 },
    { "title": { "names": "Andrea Liberatore", "tag": "MVP" }, "start": 0.25, "duration": 3 }
  ]
}
```

**Clip fields**

| field | meaning |
|---|---|
| `media` | video/audio file path: absolute, `~/...`, or **relative to the project file's folder** |
| `in` | where the clip starts inside the file, seconds (default 0) |
| `out` *or* `duration` | where it ends inside the file, or how long it is. Neither = to the end of the file |
| `start` | position on the timeline, seconds. **Leave it out to place the clip right after the previous clip on the same track** (easiest way to build a cut) |
| `track` | `0` = V1/A1 main (default), `1` = V2/A2 overlay, on top of V1 |
| `volume` | 1 = 100%, 0 = mute, up to 2 |
| `fill` | `true` = fill the frame (crop), default fits the whole picture |
| `scale`, `x`, `y`, `opacity` | size (1 = 100%), offset as a fraction of the frame (-0.5…0.5), 0…1 |
| `title` | makes it a name card instead of a video clip (goes on the titles track) |

**Title fields** (all optional): `names` (string with one person per line, or an array), `tag` (gold box, e.g. `"MVP"`, `""` = none),
`label` (default `"COPPA ÉLITE  /  WINTER EDITION"`), `showLabel`, `x` / `y` (top-left of the card as a fraction of the frame, default 0.056 / 0.693),
`size` (1 = normal), `fade` (seconds, default 0.4).

**Settings** (all optional): `width`/`height` (default: follows the first clip, vertical → 1080×1920), `fps` (30).
Legacy logo settings are ignored.

When the app saves, it writes the full form (ids, media list with durations, relative paths). Both forms read the same way.

## Export

**File ▸ Esporta** (⌘E) offers the sequence format, the sequence format in **4K** (short side 2160 px: 16:9 → 3840×2160,
9:16 → 2160×3840), vertical / horizontal 1080p and 4K, square, and a 720p preview, in H.264 or HEVC.
4K export upscales sources smaller than 4K: shoot or keep 4K media for a real 4K result.

## Command line

```bash
ES="/Users/lucasflati/Desktop/Elite Studio Mac/elitestudio"
"$ES" --check  progetto.elitestudio             # prints the timeline as the app reads it; errors on missing files
"$ES" --export progetto.elitestudio out.mp4     # renders it (same engine as the app; --hevc for HEVC, --4k for 4K UHD)
"$ES" --captions progetto.elitestudio           # transcribes the audio and writes captions into the project [--lang it-IT] [--words 3]
open progetto.elitestudio                       # opens it in the app to keep editing
```

## Notes for Claude Code (building a cut for Luca)

1. List the clips in the folder (`ffprobe` for durations). Old transcripts with **word-level timestamps** for many
   interviews are in `../Elite Interview Studio/data/transcripts/<file>.json`
   (list of segments: `start`, `end`, `text`, `words[{w,s,e}]`). Use them to pick `in`/`out` at sentence boundaries.
   For files without a transcript, `ffmpeg -i f.mov -af silencedetect=n=-35dB:d=0.4 -f null -` finds pauses.
2. Write `<folder>/<name>.elitestudio` with clips in order and no `start` (they line up back to back), add a title per person.
   Use relative `media` paths so the project lives next to the videos.
3. Run `--check`, then optionally `--export` a preview and look at a few frames (`ffmpeg -ss T -i out.mp4 -frames:v 1 f.png`).
4. Tell Luca the project path. He opens it (double-click) and finishes in the app.

## Transparent overlays

A video with an alpha channel (ProRes 4444 `.mov`) on V2 is composited with its transparency, so animated graphics made elsewhere (text, lower thirds, end cards) sit on top of V1. This works on the GPU compositor (`flatLayer` in `PanoCompositor.swift`), which is used whenever any clip has effects or keyframes or the project has captions.

## Automatic captions (CapCut style)

**Sottotitoli** in the timeline bar (or Sequenza menu, or the inspector with nothing selected) transcribes everything you hear on
the timeline with Apple's on-device speech recognition (macOS 26+, no internet; Italian/English models are already installed,
others download once), splits it into short phrases and puts them on the **S** lane above the titles.
Click a phrase to edit its text in the inspector, drag it / its edges to retime, C (razor) splits it, ⌫ deletes it.
Ripple deletes and speed changes move the captions with the cut. "Parole per frase" regroups without transcribing again.

Looks: **Negativo** (the text has no colour: it shows the video inverted, a difference blend), **Bianco** (white, black outline),
**Oro** (white, the word being spoken in Coppa Élite gold). Position, size, capitals and the pop-in animation apply to all captions.
Captions are drawn by the GPU compositor (`PanoCompositor`), so viewer and export match; when that compositor is used the export
also draws titles on the GPU (`OverlayTrack`), because Core Animation on top of a custom compositor comes out white.
Code: `Captions.swift`.

JSON (top level, both optional):

```json
"captionStyle": { "look": "negativo", "y": 0.62, "size": 1, "uppercase": true, "pop": true, "maxWords": 3, "language": "it-IT" },
"captions": [ { "start": 0.6, "end": 1.86, "text": "Scusate un attimo",
                "words": [ { "w": "Scusate", "s": 0.6, "e": 1.14 }, { "w": "un", "s": 1.14, "e": 1.32 }, { "w": "attimo", "s": 1.32, "e": 1.86 } ] } ]
```

Times are timeline seconds. `words` is optional (without it the words are spread evenly); if `text` differs from the words, the text wins.
`look`: `negativo` | `bianco` | `oro`. Hide them all with `"tracks": { "captionsHidden": true }`.

## 360 clips (Insta360 .insv)

Import the `VID_…_00_….insv` file (the `_10_` second lens and `LRV_` previews are picked up/hidden automatically; side-by-side single files work too).
The clip is stabilized with the camera's gyro (horizon lock + smooth heading) and rendered reframed into the sequence frame.
Drag in the viewer to look around; the inspector has direction / tilt / roll / field of view / perspective (normal → wide → little planet),
stabilization toggles and keyframes (stored in media time, so cuts keep them in place). Code: `Pano.swift` (trailer, IMU, stabilizer),
`PanoCompositor.swift` (Metal renderer, used only when the project contains 360 clips), `PanoUI.swift`.

JSON: clip field `pano` = `{ "yaw", "pitch", "roll", "fov", "distance", "stabilize", "lockDirection", "smooth", "keys": [{ "t", "view": {…} }] }` (all optional).
The gyro is sampled at the start time of the source frame actually shown (`CompLayer.frameTime`, from the track's nominal frame rate), not at the composition time: sampling at the composition time left up to one frame of mismatch, seen as residual wobble.
Tested only on ONE R 360 footage; IMU axis mapping and lens model for other Insta360 models are unverified.
