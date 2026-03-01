# VidIcon

**Rich video thumbnails for macOS Finder** — see codec, resolution, duration, and file size right on the icon.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![FFmpeg](https://img.shields.io/badge/FFmpeg-required-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## What it does

VidIcon extracts a frame from any video file and sets it as the Finder icon, overlaid with:

- 🎬 **Video frame** as background
- ⏱ **Duration** badge (top-right)
- 📺 **Resolution** badge (1080p, 4K, etc.)
- 🟣 **Codec** badge (HEVC, H.264, VP9, AV1...)
- 📦 **File size** badge
- ▶️ **Play button** overlay

### Supported formats

MP4, MKV, AVI, MOV, WMV, FLV, WebM, MPG, MPEG, 3GP, VOB, MTS, M2TS, OGV, RMVB, DivX, MXF, DV, F4V, ASF, and 20+ more — anything FFmpeg can decode.

## Install

### Prerequisites

- **macOS 14+** (Sonoma)
- **FFmpeg** via Homebrew:
  ```bash
  brew install ffmpeg
  ```

### Build & Install

```bash
git clone https://github.com/MuntasirMalek/video_icon_preview_mac.git
cd video_icon_preview_mac
make
make install   # Installs to /usr/local/bin/
```

## Usage

### Set video icons for a folder

```bash
vidicon icons ~/Movies
vidicon icons ~/Downloads --recursive
killall Finder   # Refresh to see icons
```

### Other commands

```bash
vidicon info movie.mkv          # Show video metadata
vidicon thumbnail movie.mkv     # Extract frame as PNG
vidicon ql movie.mkv            # Quick Look preview (remux to MOV)
vidicon preview movie.mkv       # Open in native player window
```

### Keyboard shortcut (Karabiner)

If you use [Karabiner-Elements](https://karabiner-elements.pqrs.org/), add this rule to trigger VidIcon on the current Finder folder with a hotkey:

```json
{
    "description": "Cmd+R → Set video icons in current Finder folder",
    "manipulators": [
        {
            "conditions": [
                {
                    "bundle_identifiers": ["^com\\.apple\\.finder$"],
                    "type": "frontmost_application_if"
                }
            ],
            "from": {
                "key_code": "r",
                "modifiers": { "mandatory": ["left_command"] }
            },
            "to": [{ "shell_command": "/usr/local/bin/vidicon-finder &" }],
            "type": "basic"
        }
    ]
}
```

> Change the key to whatever you prefer. This only triggers in Finder.

## Uninstall

```bash
make uninstall
```

## How it works

VidIcon links directly against FFmpeg's C libraries (`libavformat`, `libavcodec`, `libswscale`, `libavutil`) — no subprocess calls. This means it works inside sandboxed environments and is fast.

For each video file:
1. Opens the container with `libavformat`
2. Decodes a frame at 10% into the video
3. Scales to icon size with `libswscale`
4. Composites metadata badges using Core Graphics
5. Sets as the Finder icon via `NSWorkspace`

## License

MIT
