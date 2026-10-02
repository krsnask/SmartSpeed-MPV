# SmartSpeed MPV

SmartSpeed MPV is a lightweight Lua script for [mpv](https://mpv.io/) that automatically changes playback speed using the timing gaps in a selected external `.srt` subtitle file.

- Dialogue speed: **3×**
- Long subtitle gaps: **8×**
- Manual override: press **B** to toggle **2×** speed when action scenes


## How it works

The script reads the timestamps from the selected external SRT subtitle track.


> [!IMPORTANT]
> The current version requires an **external `.srt` subtitle track**. Embedded/internal subtitles are not supported.

## Requirements

- [mpv media player](https://mpv.io/installation/)
- An external `.srt` subtitle file
- The SmartSpeed Lua script

## Installation on Windows

1. Download the Lua script.
2. Rename it to `smart_speed.lua`.
3. Press `Win + R`, paste the following path, and press Enter:

   ```text
   %APPDATA%\mpv\scripts
   ```

4. If the `scripts` folder does not exist, create it.
5. Copy `smart_speed.lua` into that folder.
6. Restart mpv.

The final path should look like this:

```text
C:\Users\YourName\AppData\Roaming\mpv\scripts\smart_speed.lua
```

## Installation on Linux or macOS

Copy `smart_speed.lua` into the appropriate scripts directory:

```text
Linux:   ~/.config/mpv/scripts/
macOS:   ~/.config/mpv/scripts/
```

Restart mpv after copying the file.

## Subtitle setup

For automatic loading, place the video and subtitle in the same folder and give them the same base name:

```text
Movie.mkv
Movie.srt
```

You can also load an SRT manually in mpv. The script follows whichever external SRT subtitle track is currently selected.

## Usage

1. Open a video in mpv.
2. Make sure an external SRT subtitle track is selected.
3. SmartSpeed starts automatically.
4. Press `B` to toggle the manual `2×` override.

| Playback condition | Speed |
| --- | ---: |
| Subtitle/dialogue active | 2.5× |
| Subtitle gap longer than 5 seconds | 4× |
| One second before the next subtitle | 2.5× |
| Manual B-key override | 2× |
| No external SRT selected | 1× |

## Configuration

Open `smart_speed.lua` in a text editor and change these values near the top:

```lua
local DIALOGUE_SPEED = 2.5
local SILENCE_SPEED = 4.0
local MIN_GAP = 5.0
local EARLY_SWITCH = 1.0
local CHECK_INTERVAL = 0.05
local TOGGLE_SPEED = 2.0
```

| Setting | Purpose |
| --- | --- |
| `DIALOGUE_SPEED` | Speed used during subtitle dialogue |
| `SILENCE_SPEED` | Speed used during long subtitle gaps |
| `MIN_GAP` | Minimum full subtitle gap required for silence speed |
| `EARLY_SWITCH` | Seconds before the next subtitle to return to dialogue speed |
| `CHECK_INTERVAL` | How often the script checks the playback position |
| `TOGGLE_SPEED` | Speed used by the B-key manual override |

## Troubleshooting

### Playback stays at 1×

- Confirm that an external `.srt` track is loaded and selected.
- Make sure the subtitle file is valid SRT and contains timestamps.
- Rename the subtitle to match the video filename.
- Restart mpv after installing or changing the script.

### The B key does not work

- Make sure the mpv window is focused.
- Check whether another script or `input.conf` entry already uses `b`.
- Verify that `smart_speed.lua` is inside the correct mpv `scripts` folder.

### Speed changes at the wrong time

The script follows subtitle timestamps, so incorrectly synchronized subtitles will cause incorrectly timed speed changes. Use a subtitle track that matches the video release.

## Notes

- Subtitle gaps are treated as silence; the script does not analyze the video's audio.
- Music, action, or sound effects without subtitles may therefore play at silence speed.
- The script resets playback to `1×` when the video ends or when no external SRT track is selected.

## Project

GitHub: [krsnask/SmartSpeed-MPV](https://github.com/krsnask/SmartSpeed-MPV)

