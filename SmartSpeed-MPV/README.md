# SmartSpeed-MPV

SmartSpeed-MPV automatically changes MPV playback speed using an external SRT subtitle timeline.

## Default behavior

- Dialogue: **2×**
- Long subtitle gaps: **4×**
- A gap must be longer than **3 seconds**
- Playback returns to 2× **0.2 seconds before** the next subtitle

## Installation on Windows

Copy:

```text
scripts\smart_speed.lua
```

to:

```text
%APPDATA%\mpv\scripts\smart_speed.lua
```

Copy:

```text
script-opts\smart_speed.conf
```

to:

```text
%APPDATA%\mpv\script-opts\smart_speed.conf
```

Create the folders if they do not exist.

## Usage

1. Open a video in MPV.
2. Drag any external `.srt` file onto the MPV window.
3. SmartSpeed detects it and builds the speed timeline automatically.

The subtitle filename does not need to match the video filename.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+S` | Enable or disable SmartSpeed |
| `Ctrl+Shift+D` | Show current SmartSpeed status |
| `Ctrl+Shift+R` | Reload the subtitle timeline |

## Configuration

Edit:

```text
script-opts\smart_speed.conf
```

Example:

```ini
dialogue_speed=2.0
silence_speed=4.0
minimum_gap=3.0
early_switch=0.20
```

## Current limitation

This release directly parses external `.srt` files. Embedded MKV subtitle tracks are not parsed.

## Troubleshooting

Run MPV from Command Prompt to view script messages:

```bat
mpv.exe "C:\Movies\movie.mkv"
```

Look for lines beginning with:

```text
[SmartSpeed]
```
