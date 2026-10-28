# HoAE Cutscenes Fix

0: Download the release and put everything into the main folder of the game

Fixes campaign cutscene playback in **Heroes of Annihilated Empires** for the
Theora/Vorbis video pack (`video/*.ogv` + `.oga`, referenced by tiny `.bik`
stubs). On Windows 8+ the original DLL produced sound but no picture (black
screen); the naive workaround then showed grayscale video in a small pixelated
box. This repository contains the binary patcher for the game's
`theovorb.dll` and the source of the injected x86 code.

## What it is

`theovorb.dll` is the game's Theora/Vorbis video player. It renders video into
a flippable YV12 **DirectDraw overlay** surface and presents it with
`IDirectDrawSurface::UpdateOverlay`. Windows 8 removed DirectDraw overlay
emulation: `CreateSurface` with `DDSCAPS_OVERLAY` fails with
`DDERR_NOOVERLAYHW` (`0x88760104`), `tv_VideoOpen` returns `NULL`, and the
engine silently skips every video (the audio path is separate, so music still
plays).

This mod rewrites the DLL to render into a normal offscreen surface, convert
YUV to RGB in software, and Blt the result to the primary surface through a
window clipper. It also:

* fixes the destination rectangle (fits the video into the game window's
  client area instead of scaling to the whole desktop, which broke on 16:9
  desktops and cropped the video);
* adds an optional GDI HALFTONE smoothing pass over the upscale;
* keeps the plain Blt as a fallback, so the video is still visible if the
  filtered pass is not.

## Requirements

* **Game build whose `engine.exe` imports the TheoVorb API**
  (`tv_Init`, `tv_StreamOpen`, `tv_VideoOpen`, ...). This project's engine
  (MD5 `0B1505695FA5D112A05AFF981D94D2D2`) is that build. A stock retail
  engine uses Bink (`binkw32.dll`) and never calls this DLL.
* The Theora video pack in `video/` (`.ogv`/`.oga` + the 18-byte `.bik`
  redirect stubs).
* Windows 8 or newer (works on older Windows too).
* To rebuild: Python 3.8+ and, only when changing the injected code, MASM
  (`ml.exe`, e.g. from Visual Studio Build Tools).
* A **pristine** `theovorb.dll`
  (MD5 `CE557FDDB8668DDC9793FD98AF232575`). The patcher verifies the bytes at
  every patch site and refuses other builds.

## What the patch changes

All patches are byte writes into the pristine DLL plus one appended PE section
(`.tvcave`, RVA `0x59000`) holding the injected code.

| # | Site | Change |
|---|------|--------|
| 1 | caps check | force the DirectDraw caps test to pass |
| 2 | `GetAttachedSurface` | return success (no flip chain) |
| 3 | surface creation | offscreen surface, X8R8G8B8 pixel format, no backbuffer |
| 4 | per-frame render | lock the offscreen surface, skip the byte-wise Y copy, software-convert the whole frame |
| 5 | present | call the injected `tp_present2` instead of `UpdateOverlay` |
| 6 | hide path | drop the overlay-hide call |
| 7 | `.tvcave` | `tp_present2` + `clipper_setup` + `copy_rgb32` |

## How it works

The injected code is position independent: it finds the DLL's image base with a
`call`/`pop`-style relative trick, then uses the DLL's `GetModuleHandleA` /
`GetProcAddress` import entries.

* **`copy_rgb32`** converts the decoder's YUV420 planes to X8R8G8B8
  (B,G,R,0 bytes). The planes are bottom-up with negative strides; chroma is
  nearest-sampled 2x2. The U/V pair is only used when
  `V == U + chroma_plane_size + 24`; across frame-ring switches the decoder
  updates the two planes at different times, and a mixed pair would read
  uncommitted data, so that frame is skipped and the previous RGB frame stays.
* **`clipper_setup`** creates a DirectDraw clipper bound to
  `GetForegroundWindow()` (the game window) and attaches it to the primary
  surface, so Blts land inside the game window instead of on the desktop.
* **`tp_present2`** locks the offscreen surface, computes a 16.16 min-scale
  fit of the video into the foreground window's client area
  (`GetClientRect` + `ClientToScreen`), Blts the surface to the primary with
  `DDBLT_WAIT`, then redraws the frame with GDI `StretchDIBits` in HALFTONE
  mode when the video is scaled up. The DIB width is the locked pitch divided
  by 4 so padded surface rows are read correctly. The GDI pass is skipped at
  1:1. If GDI drawing is not visible (e.g. an exclusive-fullscreen window),
  the plain Blt underneath still shows the video.
* The old `UpdateOverlay` calls are replaced with NOPs or calls into the new
  section; the overlay surface slot is reused for the offscreen surface and
  the backbuffer slot for the clipper cache.

## Building

The shipped `patch_theovorb.py` already contains the assembled code blob, so
no build step is needed for normal use. Rebuild only if you change
`clipper.asm`.

### 1. Assemble the injected code

```bat
ml /nologo /c /coff /Fo clipper.obj clipper.asm
```

### 2. Extract the `.text` bytes into the patcher

The patcher's `CLIPPER_BLOB` is the raw `.text$mn` section of `clipper.obj`.
Extract it and replace the hex string in `patch_theovorb.py`:

```python
import struct
d = open("clipper.obj", "rb").read()
o = 20 + struct.unpack_from("<H", d, 16)[0]       # first section header
_vs, _va, raw_size, raw_ptr = struct.unpack_from("<IIII", d, o + 8)
blob = d[raw_ptr:raw_ptr + raw_size]
print(blob.hex())
```

Paste the hex into `CLIPPER_BLOB = bytes.fromhex(...)` (split into 64-character
lines if you like).

**Layout constraint:** the `.text` patch sites contain relative call
displacements to fixed offsets in the blob: `clipper_setup` at `0x1F`,
`copy_rgb32` at `0x9B`, `tp_present2` at `0x27A` (the first bytes of the blob
are a `jmp tp_present2` kept at offset 0). Keep the procedure order/sizes or
update those patch bytes in `PATCHES` as well. The `.tvcave` section must be
placed at RVA `0x59000` (the patcher asserts this).

### 3. Patch the DLL

```powershell
# start from the pristine DLL (restore it if needed)
python scripts\patch_theovorb.py "C:\path\to\theovorb.dll"
```

The patcher writes `theovorb.dll.orig` next to the target and patches the DLL
in place.

## Installing

1. Back up the original `theovorb.dll` (the patcher also writes a `.orig`).
2. Run the patcher on the game's `theovorb.dll` (see above).
3. The engine must be the TheoVorb build; no other files are needed. The
   Steam default path is
   `C:\Program Files (x86)\Steam\steamapps\common\Heroes of Annihilated Empires`.
4. Start the game, then Single Player -> Campaign -> Mission 1 to test the
   first video (R01, 800x400).

A prebuilt patched DLL (built from the pristine DLL with this source) has
MD5 `DE12512BCA3C1A3FE1511F8062B408D7`. Rebuilding from the source should
reproduce it exactly if the blob and patch list match.

## Verifying

* The game's `log.txt` should not contain `TheoVorb: ... failed`/error lines
  during a cutscene.
* The video should fill the game window (letterboxed to the video's aspect
  ratio), be in colour, and end normally, returning to the game.
