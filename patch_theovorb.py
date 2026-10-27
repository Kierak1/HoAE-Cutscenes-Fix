"""Patch theovorb.dll so cutscenes work on Windows 8+ (no DirectDraw overlays).

Background (verified with IDA/cdb + a live test harness):
  * The DLL renders Theora into a flippable YV12 *overlay* surface and shows
    it with UpdateOverlay. Windows 8+ ddraw emulation has no overlays, so
    CreateSurface fails with DDERR_NOOVERLAYHW (0x88760104), tv_VideoOpen
    returns NULL and the engine silently skips every video.
  * The device caps check tests DDCAPS_CANBLTSYSMEM as 0x800 (old headers);
    current ddraw reports it at 0x80000000, so device init fails anyway.
  * A plain offscreen surface + Blt to the primary works on modern ddraw, but
    a windowed process' primary blits land on the desktop behind the game
    window unless a clipper bound to the game window is attached.
  * The emulator's YV12 blit is degenerate (one chroma plane feeds both Cb and
    Cr) and its scaled YUV->RGB path is unreliable. The surface is therefore a
    plain X8R8G8B8 offscreen and copy_rgb32 software-converts the decoder's
    YUV420 planes; the Blt to the primary is a plain RGB copy.
  * sub_100304F0's fallback rect scales the video to the whole primary
    (desktop) width and can overflow vertically on 16:9 desktops (negative
    top, then a logical shift -> invalid rect). tp_present2 instead fits the
    video's aspect ratio into the foreground window's client rect, so the
    video fills the game window at any desktop/game resolution.

Fix (file offset = VA - 0x10000C00 for .text):
  1. sub_100305B0 (caps check)                    -> force pass.
  2. sub_10030490 (GetAttachedSurface, no flip)   -> return true.
  3. sub_10030A40 (surface creation)              -> offscreen X8R8G8B8.
  4. sub_10030EE0 (per-frame render)              -> lock offscreen (+0x4C),
     software-convert via copy_rgb32, unlock + present.
  5. sub_100304F0 (present)                       -> call tv_present (below).
  6. sub_10030610 (hide)                          -> drop overlay hide call.
  7. New PE section ".tvcave" with tp_present2 + clipper_setup + copy_rgb32:
     attaches a DirectDraw clipper bound to the foreground (game) window,
     fits the video into that window's client rect, then Blts to the primary.
"""
import shutil
import struct
import sys

BASE = 0x10000000
TEXT_RAW_DELTA = 0xC00

# code blob assembled from clipper.asm (ml /c /coff, .text$mn):
#   tv_present:    jmp tp_present2 (entry kept at cave+0 for the call sites)
#   clipper_setup: creates clipper bound to GetForegroundWindow(), caches it
#                  in device+0x50, attaches it to device+0x48 primary
#   copy_rgb32:    software YUV420 -> X8R8G8B8 + chroma interleave check
#   tp_present2:   fits the video into the window client rect, Blts to primary
CLIPPER_BLOB = bytes.fromhex(
    "e975020000909090909090909090909090909090909090909090909090909083"
    "7e50007575535755e8000000005a8bda81eb2d90050081c22e0200008beb81c5"
    "6692050052ff930041030085c074485550ff939040030085c0743cffd085c074"
    "368bd88b4e448d7e506a00576a00518b09ff511085c07c1f8b6e5085ed741853"
    "6a00558b4500ff50208b4e4885c9740755518b11ff52705d5f5bc35356575583"
    "ec288b5c243c8b4c24408b6c24448b442448894424088b44244c8944240c8b44"
    "2450894424108b45088904248b4514894424048b751c8b7d208bc603413083c0"
    "183bf87405e9690100008b412c0345180304248bf08b413003451c034424048b"
    "f88b4130034520034424048be88b44240cd1e889442424c64424140033c90fb6"
    "040f2d8000000069d0c6010000c1fa08895424186bd0a8c1fa088954241c0fb6"
    "440d002d8000000069d049ffffffc1fa080154241c69d067010000c1fa088954"
    "24200fb6044e8bd00354241883fa007d0233d281faff0000007e05baff000000"
    "8814cb8bd00354241c83fa007d0233d281faff0000007e05baff0000008854cb"
    "018bd00354242083fa007d0233d281faff0000007e05baff0000008854cb02c6"
    "44cb03000fb6444e018bd00354241883fa007d0233d281faff0000007e05baff"
    "0000008854cb048bd00354241c83fa007d0233d281faff0000007e05baff0000"
    "008854cb058bd00354242083fa007d0233d281faff0000007e05baff00000088"
    "54cb06c644cb0700413b4c24240f82ebfeffff033424035c2408807424140175"
    "08037c2404036c2404ff4c24100f85c9feffff83c4285d5f5e5bc37573657233"
    "322e646c6c00476574466f726567726f756e6457696e646f7700e8a0fdffff53"
    "555783ec50e8000000005a8bda81eb8a9205008bc3055b92050050ff93004103"
    "0085c00f84920100008be88bc305669205005055ff939040030085c00f847901"
    "0000ffd085c00f846f0100008bf88bc3057b9605005055ff939040030085c00f"
    "84560100008d14245257ffd085c00f84470100008bc305899605005055ff9390"
    "40030085c00f84300100008b0c248b542404894c2410895424148d5424105257"
    "ffd00fb74e3c894c24280fb74e3e894c242c85c90f84010100008b442408c1e0"
    "1033d2f77424288bc88b44240cc1e01033d2f774242c3bc176028bc18b4c2428"
    "0fafc8c1e9108b54242c0fafd0c1ea108b4424082bc1d1e80344241089442418"
    "8b5c240c2bdad1eb035c2414895c241c03c18944242003da895c24248b46488b"
    "564c6a0068000000016a00528d4c2428518b08508b5114ffd28bd88b4424202b"
    "4424188b4c24283bc175108b4424242b44241c8b4c242c3bc1745c8d5424308b"
    "c789028b4424088942048b44240c8942088b4424202b44241889420c8b442424"
    "2b44241c8942108b4424288942148b44242c89421889721cff721cff7218ff72"
    "14ff7210ff720cff7208ff7204ff32e81000000083c4208bc3eb0233c083c450"
    "5f5d5bc3558bec53565781ec000100008d95f4feffffc7027c0000008b45248b"
    "404c8945cc6a006a01526a00508b08ff516485c00f8cf60100008b8518ffffff"
    "8945dce8000000005a8bda81eb88940500895dd48bc3055b92050050ff930041"
    "030085c00f84b80100008945d88bc3059896050050ff75d8ff939040030085c0"
    "0f849c010000ff7508ffd085c00f848f0100008945d08bc305a896050050ff93"
    "0041030085c00f84590100008945e88bc305b296050050ff75e8ff9390400300"
    "85c00f843d0100006a04ff75d0ffd08bc305c496050050ff75e8ff9390400300"
    "85c00f841d0100006a006a006a00ff75d0ffd08bc305d296050050ff75e8ff93"
    "9040030085c00f84f90000008945e8c78570ffffff280000008b8d04ffffffc1"
    "e902898d74ffffff8b4d20f7d9898d78ffffff66c7857cffffff010066c7857e"
    "ffffff2000c7458000000000c7458400000000c7458800000000c7458c000000"
    "00c7459000000000c74594000000008b450c2b4514d1e88945e08b4d102b4d18"
    "d1e9894de48d55988b45d089028b45e08942048b45e48942088b451489420c8b"
    "4518894210c7421400000000c74218000000008b451c89421c8b45208942208b"
    "45dc8942248d8570ffffff894228c7422c00000000c742302000cc00ff7230ff"
    "722cff7228ff7224ff7220ff721cff7218ff7214ff7210ff720cff7208ff7204"
    "ff32ff55e88bc3059e96050050ff75d8ff939040030085c07408ff75d0ff7508"
    "ffd08b45cc8b086a0050ff918000000081c4000100005f5e5b5dc3476574436c"
    "69656e745265637400436c69656e74546f53637265656e004765744443005265"
    "6c6561736544430067646933322e646c6c0053657453747265746368426c744d"
    "6f64650053657442727573684f72674578005374726574636844494269747300"
)

NEW_SECTION_VA = 0x10059000
NEW_SECTION_NAME = ".tvcave"


def off(va):
    return va - BASE - TEXT_RAW_DELTA


# (VA, expected bytes hex or None, replacement bytes hex, description)
PATCHES = [
    # 1. caps check: mov eax,[esp+4]; shr eax,0Bh; and eax,1 -> mov eax,1
    (0x100305FA, "8b442404c1e80b83e001", "b8010000009090909090",
     "caps check -> always pass"),
    # 2. sub_10030490 -> mov eax,1; ret  (no back buffer to attach)
    (0x10030490, "83ec1833c056", "b801000000c3",
     "skip attached surface"),
    # 3a. dwFlags 0x1027 -> 0x1007 (drop DDSD_BACKBUFFERCOUNT)
    (0x10030A90, "27100000", "07100000",
     "surface flags: drop backbuffer"),
    # 3b. ddscaps 0x10004098 -> 0x4040 (OFFSCREENPLAIN|VIDEOMEMORY)
    (0x10030ABD, "98400010", "40400000",
     "surface caps: offscreen+vidmem"),
    # 3c. fallback ddscaps 0x4098 -> 0x840 (OFFSCREENPLAIN|SYSTEMMEMORY)
    (0x10030AE0, "98400000", "40080000",
     "surface caps: offscreen+sysmem"),
    # 4a. lock target [esi+0x50] -> [esi+0x4C] (both lock attempts)
    (0x10030F06, "8b4650", "8b464c",
     "lock target -> offscreen"),
    (0x10030F45, "8b4650", "8b464c",
     "lock target -> offscreen (retry)"),
    # 4b. unlock + present instead of Flip. 0x10031047..0x10031065 (31 bytes)
    (0x10031047, None,
     "8b464c" "8b08" "8b9180000000" "6a00" "50" "ffd2"
     "33c0" "8bce" "e890f4ffff" "909090909090",
     "present via sub_100304F0"),
    # 4c. video-start clear (sub_10030B30) memsets "chroma planes" after the
    #     Y plane at YV12 offsets; the RGB32 surface has no chroma planes, so
    #     those two memsets run past the surface. Drop them (the per-frame
    #     copy_rgb32 rewrites every pixel anyway).
    (0x10030BAA, None, "90" * 16,
     "video-start clear: drop chroma memset 1"),
    (0x10030BBE, None, "90" * 3,
     "video-start clear: drop memset 1 stack cleanup"),
    (0x10030BC1, None, "90" * 18,
     "video-start clear: drop chroma memset 2"),
    (0x10030BDC, None, "90" * 3,
     "video-start clear: drop memset 2 stack cleanup"),
    # 4d. modern ddraw's YV12 blit is broken (it reads a single chroma plane
    #     for both Cb and Cr -> all hues collapse to green<->magenta). NV12
    #     converts correctly, so switch the surface FourCC and interleave U/V.
    (0x100511C4, "04000000", "41000000",
     "pixel format: DDPF_RGB|DDPF_ALPHAPIXELS"),
    (0x100511C8, "59563132" + "00000000" * 5,
     "00000000" "20000000" "0000ff00" "00ff0000" "ff000000" "000000ff",
     "pixel format: NV12 -> X8R8G8B8"),
    # 4d. replace both planar chroma copy loops (0x10030FB2..0x1003103F) with
    #     a trampoline to copy_nv12(dst, device, frame, lPitch, w, h) in the
    #     injected section, which writes the NV12 UV plane.
    (0x10030FB2, None,
     "ff74242cff742434ff74243c55ffb424b8000000ff74245ce8cc80020083c418"
     + "90" * 110,
     "render copies -> software RGB32"),
    # 4e. the render loop still copies the Y plane byte-wise into the surface
    #     before the RGB32 conversion. The converter rewrites every pixel; on
    #     the skipped mixed-chroma frames the byte copy would display Y debris,
    #     so jump straight to the converter.
    (0x10030F63, "8b5c244885db", "e94a00000090",
     "render: skip byte-wise Y copy (rgb32 build)"),
    # 5. UpdateOverlay -> call tv_present. 0x10030566..0x10030581 (28 bytes)
    (0x10030566, None,
     "e8958a0200" + "90" * 23,
     "UpdateOverlay -> tv_present"),
    # 5b. drop GetDC(primary) before the blit. 0x1003054E..0x10030565 (24 bytes)
    (0x1003054E, None,
     "90" * 24,
     "drop GetDC on primary"),
    # 5c. drop ReleaseDC + DC bookkeeping after the blit; keep mov edi,eax.
    #     0x10030582..0x10030593 (18 bytes)
    (0x10030582, None,
     "8bf8" + "90" * 16,
     "drop ReleaseDC on primary"),
    # 6. drop UpdateOverlay(hide). 0x1003063A..0x1003064E (21 bytes)
    (0x1003063A, None,
     "90" * 21,
     "hide: drop overlay call"),
]


def add_section(dll):
    """Append an executable .tvcave section holding clipper.bin and return its VA."""
    pe = struct.unpack_from("<I", dll, 0x3C)[0]
    nsec = struct.unpack_from("<H", dll, pe + 6)[0]
    optsz = struct.unpack_from("<H", dll, pe + 20)[0]
    opt = pe + 24
    sec_align = struct.unpack_from("<I", dll, opt + 32)[0]
    file_align = struct.unpack_from("<I", dll, opt + 36)[0]
    size_of_image = struct.unpack_from("<I", dll, opt + 56)[0]

    va_rva = (size_of_image + sec_align - 1) // sec_align * sec_align
    raw = (len(dll) + file_align - 1) // file_align * file_align
    raw_size = (len(CLIPPER_BLOB) + file_align - 1) // file_align * file_align

    dll.extend(b"\0" * (raw - len(dll)))
    dll.extend(CLIPPER_BLOB)
    dll.extend(b"\0" * (raw_size - len(CLIPPER_BLOB)))

    hdr = pe + 24 + optsz + 40 * nsec
    dll[hdr:hdr + 40] = struct.pack(
        "<8sIIIIIIHHI",
        NEW_SECTION_NAME.encode(),
        len(CLIPPER_BLOB),          # VirtualSize
        va_rva,                     # VirtualAddress (RVA)
        raw_size,                   # SizeOfRawData
        raw,                        # PointerToRawData
        0, 0, 0, 0,                 # relocs, lines
        0x60000020,                 # CODE | EXECUTE | READ
    )
    struct.pack_into("<H", dll, pe + 6, nsec + 1)
    struct.pack_into("<I", dll, opt + 56,
                     va_rva + (len(CLIPPER_BLOB) + sec_align - 1) // sec_align * sec_align)
    return BASE + va_rva


def patch(path):
    shutil.copy2(path, path + ".orig")
    dll = bytearray(open(path, "rb").read())
    for va, old_hex, new_hex, desc in PATCHES:
        o = off(va)
        new = bytes.fromhex(new_hex)
        cur = bytes(dll[o:o + len(new)])
        if old_hex is not None and cur != bytes.fromhex(old_hex):
            raise SystemExit(f"{desc}: bytes at {o:#x} are {cur.hex()}, expected {old_hex}")
        dll[o:o + len(new)] = new
        print(f"{desc:34s} {va:#010x}  {cur.hex()} -> {new_hex}")

    blob_va = add_section(dll)
    if blob_va != NEW_SECTION_VA:
        raise SystemExit(f"section VA {blob_va:#x} != expected {NEW_SECTION_VA:#x}")
    print(f"{'appended ' + NEW_SECTION_NAME:34s} {blob_va:#010x}  "
          f"{len(CLIPPER_BLOB)} bytes")
    open(path, "wb").write(dll)
    print("written", path, "(backup:", path + ".orig", ")")


if __name__ == "__main__":
    patch(sys.argv[1])
