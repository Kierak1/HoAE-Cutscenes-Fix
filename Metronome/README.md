# Metronome

A single entry point for the HoAE fixes: it installs the **cutscene fix**
(`theovorb.dll` patch) if needed, then starts the game with a **60 FPS
limiter + ImGui overlay**.

The name: 60 FPS is 60 beats per minute, so a steady 60 is a metronome.

This folder is part of the same repository as the HoAE cutscene fix.

## Contents

```
Metronome/
  README.md
  build.bat                  build script (Visual Studio 2022, x86)
  src/metronome.cpp          injected DLL: D3D9 hooks + limiter + overlay
  src/launcher.cpp           combined launcher: video patch + injector
  src/video_patch.cpp        embedded theovorb.dll patcher
  src/video_patch.h
  third_party/imgui/         Dear ImGui 1.91.5 (MIT), DX9 + Win32 backends
```

Build outputs are not committed; `build.bat` creates
`build\Metronome.dll` and `build\MetronomeLauncher.exe`.

## How it works

* The launcher first applies the cutscene fix to the game's `theovorb.dll`:
  * if the DLL already contains the appended `.tvcave` section, it is left
    alone;
  * if it is the known pristine build (every patched byte matches the
    expected value), the same byte patches and `.tvcave` section as
    `../patch_theovorb.py` are written, with a `theovorb.dll.orig` backup
    (created if missing);
  * any other build is left untouched and a status line is printed.
  * `MetronomeLauncher.exe --patch <game folder>` performs only this step.
* Then the launcher starts `engine.exe` with `CREATE_SUSPENDED`, injects
  `Metronome.dll`, and resumes. Injecting before the game runs means the
  hooks exist before the D3D9 device is created.
* `Metronome.dll` patches the engine's `d3d9.dll!Direct3DCreate9` IAT entry.
  The hook calls the real function, copies the returned `IDirect3D9` vtable,
  replaces `CreateDevice` (slot 16), and returns the object.
* `CreateDevice` is called through the patched vtable. After the real
  `CreateDevice` succeeds, the device's `IDirect3DDevice9` vtable is copied
  and `Reset` (16) and `Present` (17) are replaced.
* `Present` renders the ImGui frame (DX9 backend), waits until 16.67 ms have
  elapsed since the previous present using `QueryPerformanceCounter` (coarse
  `Sleep` plus a short spin), then calls the real `Present`. `Reset` recreates
  the ImGui device objects.
* The window procedure is hooked (ANSI/Unicode aware) so ImGui receives
  input; while the window is open, mouse/keyboard messages are not forwarded
  to the game.

Notes:

* The cutscene fix is written to disk once and persists afterwards; the
  overlay and limiter are active only when the game is started with the
  launcher.
* The overlay is a D3D9 layer. During cutscenes the video is presented through
  DirectDraw/GDI on top of the game window, so the overlay can be hidden
  behind the video; this does not affect the limiter.
* The game is a 2006 RTS; if its simulation is frame-rate dependent, locking
  to 60 may change game speed. Test before playing a full campaign.

## Build

Requirements: Windows, Visual Studio 2022 (or Build Tools) with the C++
x86 toolset. The ImGui sources are vendored; no download is needed.

```bat
cd Metronome
build.bat
```

`build.bat` calls `VsDevCmd.bat -arch=x86`; edit the VS path inside the script
if yours differs.

## Install

1. Copy `build\Metronome.dll` and `build\MetronomeLauncher.exe` into the game
   folder (next to `engine.exe`), e.g.
   `C:\Program Files (x86)\Steam\steamapps\common\Heroes of Annihilated Empires`.
2. Start the game with `MetronomeLauncher.exe`, **not** through Steam. It
   applies the cutscene fix on the first run (backup: `theovorb.dll.orig`) and
   then launches the game with the overlay.
3. The overlay starts hidden; press `Insert` to show/hide it. The window shows
   the current FPS and has a "Limit to 60 FPS" checkbox (enabled by default).

The launcher accepts a game folder argument:

```bat
MetronomeLauncher.exe "D:\Games\Heroes of Annihilated Empires"
MetronomeLauncher.exe --patch "D:\Games\Heroes of Annihilated Empires"
```

The first form launches the game; the second only installs the cutscene fix.
Writing into a Program Files folder may require starting the launcher as
administrator (only for the first-run patch; an already patched install needs
no write access).

For the Steam build the game folder does not contain `Steam.dll` (the launcher
adds the Steam root to the child's `PATH` so the static import resolves). Keep
Steam running if the game needs it.

## Licensing

Dear ImGui is included under its MIT license
(`third_party/imgui/LICENSE.txt`). The rest of this folder is part of the
project's mod code.
