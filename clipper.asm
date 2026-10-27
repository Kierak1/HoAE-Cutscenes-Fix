.386
.model flat

BLOB_RVA equ 59000h

.code
public tv_present

; Patched entry kept at offset 0 so existing call sites still work.
; Actual implementation is tp_present2 (appended at the end).
tv_present proc
    jmp     tp_present2
    db      26 dup(90h)
tv_present endp

; void clipper_setup(void)
; device pointer in ESI, preserves ESI/EDI/EBX/EBP, clobbers EAX/ECX/EDX.
; Creates a DirectDraw clipper bound to the current foreground window and
; attaches it to the primary surface so blits land in the game window.
; Clipper pointer is cached in device+0x50 (unused backbuffer slot).
clipper_setup proc
    cmp     dword ptr [esi+50h], 0
    jne     cs_ret
    push    ebx
    push    edi
    push    ebp

    call    cs_ip
cs_ip:
    pop     edx
    mov     ebx, edx
    sub     ebx, BLOB_RVA + (cs_ip - tv_present)   ; ebx = module image base
    add     edx, cs_user32 - cs_ip                 ; edx = "user32.dll"
    mov     ebp, ebx
    add     ebp, BLOB_RVA + (cs_getfg - tv_present) ; ebp = "GetForegroundWindow"

    push    edx
    call    dword ptr [ebx+34100h]
    test    eax, eax
    jz      cs_fail

    push    ebp
    push    eax
    call    dword ptr [ebx+34090h]
    test    eax, eax
    jz      cs_fail
    call    eax
    test    eax, eax
    jz      cs_fail
    mov     ebx, eax

    mov     ecx, [esi+44h]
    lea     edi, [esi+50h]
    push    0
    push    edi
    push    0
    push    ecx
    mov     ecx, [ecx]
    call    dword ptr [ecx+16]
    test    eax, eax
    jl      cs_fail

    mov     ebp, [esi+50h]
    test    ebp, ebp
    jz      cs_fail

    push    ebx
    push    0
    push    ebp
    mov     eax, [ebp]
    call    dword ptr [eax+32]

    mov     ecx, [esi+48h]
    test    ecx, ecx
    jz      cs_fail
    push    ebp
    push    ecx
    mov     edx, [ecx]
    call    dword ptr [edx+112]

cs_fail:
    pop     ebp
    pop     edi
    pop     ebx
cs_ret:
    ret
clipper_setup endp

; void copy_rgb32(unsigned char* dst, void* device, void* frame, int lPitch,
;                 int width, int height)
; Software-converts the decoder's YUV420 planes into X8R8G8B8 at dst.
; Y at (device->[0x2C] + frame->[0x18] + frame->[8]), U at (device->[0x30] +
; frame->[0x1C] + frame->[0x14]), V likewise with frame->[0x20]; rows are
; bottom-up (negative strides). Chroma is nearest-sampled 2x2. The planes are
; contiguous with a 24-byte gap (V = U + chroma_plane_size + 24) and the
; decoder updates frame->[0x20] ahead of frame->[0x1C] across frame-ring
; switches; a mixed pair is skipped (the previous frame stays). Width/height
; must be even (the game videos are 800x400 / 1024x768).
; Clobbers EAX/ECX/EDX only; preserves EBX/ESI/EDI/EBP.
public copy_rgb32
copy_rgb32 proc
    push    ebx
    push    esi
    push    edi
    push    ebp
    sub     esp, 40
    ; locals: +0 Y stride, +4 chroma stride, +8 lPitch, +12 width,
    ;         +16 rows, +20 row parity, +24 B off, +28 G off, +32 R off,
    ;         +36 samples/row
    mov     ebx, [esp+60]          ; dst
    mov     ecx, [esp+64]          ; device
    mov     ebp, [esp+68]          ; frame
    mov     eax, [esp+72]
    mov     [esp+8], eax           ; lPitch
    mov     eax, [esp+76]
    mov     [esp+12], eax          ; width
    mov     eax, [esp+80]
    mov     [esp+16], eax          ; rows
    mov     eax, [ebp+8]
    mov     [esp+0], eax           ; Y stride (negative)
    mov     eax, [ebp+14h]
    mov     [esp+4], eax           ; chroma stride (negative)
    mov     esi, [ebp+1Ch]         ; U raw
    mov     edi, [ebp+20h]         ; V raw
    mov     eax, esi
    add     eax, [ecx+30h]
    add     eax, 24
    cmp     edi, eax
    je      cr_pair_ok
    jmp     cr_done                ; mixed pair: keep previous frame
cr_pair_ok:
    mov     eax, [ecx+2Ch]
    add     eax, [ebp+18h]
    add     eax, [esp+0]
    mov     esi, eax               ; Y row ptr
    mov     eax, [ecx+30h]
    add     eax, [ebp+1Ch]
    add     eax, [esp+4]
    mov     edi, eax               ; U row ptr
    mov     eax, [ecx+30h]
    add     eax, [ebp+20h]
    add     eax, [esp+4]
    mov     ebp, eax               ; V row ptr
    mov     eax, [esp+12]
    shr     eax, 1
    mov     [esp+36], eax          ; chroma samples per row
    mov     byte ptr [esp+20], 0
cr_row:
    xor     ecx, ecx
cr_col:
    ; per-sample chroma offsets (16.8 fixed point)
    movzx   eax, byte ptr [edi+ecx]
    sub     eax, 128
    imul    edx, eax, 454
    sar     edx, 8
    mov     [esp+24], edx          ; B off
    imul    edx, eax, -88
    sar     edx, 8
    mov     [esp+28], edx          ; G off (u)
    movzx   eax, byte ptr [ebp+ecx]
    sub     eax, 128
    imul    edx, eax, -183
    sar     edx, 8
    add     [esp+28], edx          ; G off total
    imul    edx, eax, 359
    sar     edx, 8
    mov     [esp+32], edx          ; R off
    ; pixel 0
    movzx   eax, byte ptr [esi+ecx*2]
    mov     edx, eax
    add     edx, [esp+24]
    cmp     edx, 0
    jge     @f
    xor     edx, edx
@@: cmp     edx, 255
    jle     @f
    mov     edx, 255
@@: mov     [ebx+ecx*8], dl
    mov     edx, eax
    add     edx, [esp+28]
    cmp     edx, 0
    jge     @f
    xor     edx, edx
@@: cmp     edx, 255
    jle     @f
    mov     edx, 255
@@: mov     [ebx+ecx*8+1], dl
    mov     edx, eax
    add     edx, [esp+32]
    cmp     edx, 0
    jge     @f
    xor     edx, edx
@@: cmp     edx, 255
    jle     @f
    mov     edx, 255
@@: mov     [ebx+ecx*8+2], dl
    mov     byte ptr [ebx+ecx*8+3], 0
    ; pixel 1
    movzx   eax, byte ptr [esi+ecx*2+1]
    mov     edx, eax
    add     edx, [esp+24]
    cmp     edx, 0
    jge     @f
    xor     edx, edx
@@: cmp     edx, 255
    jle     @f
    mov     edx, 255
@@: mov     [ebx+ecx*8+4], dl
    mov     edx, eax
    add     edx, [esp+28]
    cmp     edx, 0
    jge     @f
    xor     edx, edx
@@: cmp     edx, 255
    jle     @f
    mov     edx, 255
@@: mov     [ebx+ecx*8+5], dl
    mov     edx, eax
    add     edx, [esp+32]
    cmp     edx, 0
    jge     @f
    xor     edx, edx
@@: cmp     edx, 255
    jle     @f
    mov     edx, 255
@@: mov     [ebx+ecx*8+6], dl
    mov     byte ptr [ebx+ecx*8+7], 0
    inc     ecx
    cmp     ecx, [esp+36]
    jb      cr_col
    ; next row
    add     esi, [esp+0]
    add     ebx, [esp+8]
    xor     byte ptr [esp+20], 1
    jnz     cr_noadv
    add     edi, [esp+4]
    add     ebp, [esp+4]
cr_noadv:
    dec     dword ptr [esp+16]
    jnz     cr_row
cr_done:
    add     esp, 40
    pop     ebp
    pop     edi
    pop     esi
    pop     ebx
    ret
copy_rgb32 endp

cs_user32 db 'user32.dll',0
cs_getfg  db 'GetForegroundWindow',0

; HRESULT tp_present2(void)
; ESI = video object. Computes a destination rect that fits the video's aspect
; ratio into the foreground window's client area (screen coordinates, like the
; old overlay rect), then Blts the offscreen surface to the primary.
; The window clipper created by clipper_setup keeps the blit inside the window.
; Preserves ESI/EDI/EBX/EBP. Clobbers EAX/ECX/EDX. Returns the Blt HRESULT.
tp_present2 proc
    call    clipper_setup
    push    ebx
    push    ebp
    push    edi
    sub     esp, 50h
    ; locals: +0 client RECT, +10 POINT, +18 dest RECT, +28 videoW/videoH,
    ;         +30 tp_smooth argument block
    call    tp_ip
tp_ip:
    pop     edx
    mov     ebx, edx
    sub     ebx, BLOB_RVA + (tp_ip - tv_present)    ; ebx = image base

    mov     eax, ebx
    add     eax, BLOB_RVA + (cs_user32 - tv_present)
    push    eax
    call    dword ptr [ebx+34100h]                  ; GetModuleHandleA
    test    eax, eax
    jz      tp_fail
    mov     ebp, eax                                ; user32 module

    mov     eax, ebx
    add     eax, BLOB_RVA + (cs_getfg - tv_present)
    push    eax
    push    ebp
    call    dword ptr [ebx+34090h]                  ; GetProcAddress
    test    eax, eax
    jz      tp_fail
    call    eax                                     ; GetForegroundWindow
    test    eax, eax
    jz      tp_fail
    mov     edi, eax                                ; hwnd

    mov     eax, ebx
    add     eax, BLOB_RVA + (tp_getclient - tv_present)
    push    eax
    push    ebp
    call    dword ptr [ebx+34090h]
    test    eax, eax
    jz      tp_fail
    lea     edx, [esp+0]
    push    edx
    push    edi
    call    eax                                     ; GetClientRect
    test    eax, eax
    jz      tp_fail

    mov     eax, ebx
    add     eax, BLOB_RVA + (tp_c2s - tv_present)
    push    eax
    push    ebp
    call    dword ptr [ebx+34090h]
    test    eax, eax
    jz      tp_fail
    mov     ecx, [esp+0]
    mov     edx, [esp+4]
    mov     [esp+10h], ecx
    mov     [esp+14h], edx
    lea     edx, [esp+10h]
    push    edx
    push    edi
    call    eax                                     ; ClientToScreen

    movzx   ecx, word ptr [esi+3Ch]
    mov     [esp+28h], ecx                          ; videoW
    movzx   ecx, word ptr [esi+3Eh]
    mov     [esp+2Ch], ecx                          ; videoH
    test    ecx, ecx
    jz      tp_fail

    mov     eax, [esp+08h]                          ; clientW
    shl     eax, 10h
    xor     edx, edx
    div     dword ptr [esp+28h]
    mov     ecx, eax                                ; scaleX (16.16)

    mov     eax, [esp+0Ch]                          ; clientH
    shl     eax, 10h
    xor     edx, edx
    div     dword ptr [esp+2Ch]
    cmp     eax, ecx
    jbe     tp_scale_ok
    mov     eax, ecx
tp_scale_ok:
    mov     ecx, [esp+28h]
    imul    ecx, eax
    shr     ecx, 10h                                ; w
    mov     edx, [esp+2Ch]
    imul    edx, eax
    shr     edx, 10h                                ; h

    mov     eax, [esp+08h]
    sub     eax, ecx
    shr     eax, 1
    add     eax, [esp+10h]
    mov     [esp+18h], eax
    mov     ebx, [esp+0Ch]
    sub     ebx, edx
    shr     ebx, 1
    add     ebx, [esp+14h]
    mov     [esp+1Ch], ebx
    add     eax, ecx
    mov     [esp+20h], eax
    add     ebx, edx
    mov     [esp+24h], ebx

    mov     eax, [esi+48h]
    mov     edx, [esi+4Ch]
    push    0
    push    01000000h
    push    0
    push    edx
    lea     ecx, [esp+28h]
    push    ecx
    mov     ecx, [eax]
    push    eax
    mov     edx, [ecx+14h]
    call    edx
    mov     ebx, eax                                ; keep the Blt result

    ; filtered overlay pass: GDI StretchDIBits with HALFTONE scaling draws a
    ; smoothed copy over the Blt. If GDI fails (or is invisible on an
    ; exclusive-fullscreen window) the Blt underneath still shows the video.
    ; Skip it when the video is already displayed 1:1.
    mov     eax, [esp+20h]
    sub     eax, [esp+18h]
    mov     ecx, [esp+28h]
    cmp     eax, ecx
    jne     tp_do_smooth
    mov     eax, [esp+24h]
    sub     eax, [esp+1Ch]
    mov     ecx, [esp+2Ch]
    cmp     eax, ecx
    je      tp_skip_smooth
tp_do_smooth:
    lea     edx, [esp+30h]
    mov     eax, edi
    mov     [edx+0], eax                            ; hwnd
    mov     eax, [esp+08h]
    mov     [edx+4], eax                            ; clientW
    mov     eax, [esp+0Ch]
    mov     [edx+8], eax                            ; clientH
    mov     eax, [esp+20h]
    sub     eax, [esp+18h]
    mov     [edx+0Ch], eax                          ; dstW
    mov     eax, [esp+24h]
    sub     eax, [esp+1Ch]
    mov     [edx+10h], eax                          ; dstH
    mov     eax, [esp+28h]
    mov     [edx+14h], eax                          ; srcW
    mov     eax, [esp+2Ch]
    mov     [edx+18h], eax                          ; srcH
    mov     [edx+1Ch], esi                          ; device
    push    dword ptr [edx+1Ch]
    push    dword ptr [edx+18h]
    push    dword ptr [edx+14h]
    push    dword ptr [edx+10h]
    push    dword ptr [edx+0Ch]
    push    dword ptr [edx+08h]
    push    dword ptr [edx+04h]
    push    dword ptr [edx+00h]
    call    tp_smooth
    add     esp, 20h
tp_skip_smooth:
    mov     eax, ebx
    jmp     tp_done
tp_fail:
    xor     eax, eax
tp_done:
    add     esp, 50h
    pop     edi
    pop     ebp
    pop     ebx
    ret
tp_present2 endp

; void tp_smooth(HWND hwnd, int clientW, int clientH, int dstW, int dstH,
;                int srcW, int srcH, void* device)
; Locks the offscreen surface and redraws the frame into the window with
; StretchDIBits in HALFTONE mode (smooth upscale). Leaves the surface
; unlocked. Failures are non-fatal: the plain Blt already drew the frame.
; Preserves ESI/EDI/EBX/EBP.
tp_smooth proc
    push    ebp
    mov     ebp, esp
    push    ebx
    push    esi
    push    edi
    sub     esp, 100h
    ; locals: -10Ch DDSURFACEDESC2, -90h BITMAPINFOHEADER, -68h arg block,
    ;         -34h surface, -30h hdc, -2Ch image base, -28h user32,
    ;         -24h bits, -20h xDst, -1Ch yDst, -18h fn/gdi32

    lea     edx, [ebp-10Ch]
    mov     dword ptr [edx], 7Ch
    mov     eax, [ebp+24h]
    mov     eax, [eax+4Ch]
    mov     [ebp-34h], eax
    push    0
    push    1
    push    edx
    push    0
    push    eax
    mov     ecx, [eax]
    call    dword ptr [ecx+64h]                     ; Lock(offscreen)
    test    eax, eax
    jl      ts_ret
    mov     eax, [ebp-10Ch+24h]
    mov     [ebp-24h], eax                          ; lpSurface

    call    ts_ip
ts_ip:
    pop     edx
    mov     ebx, edx
    sub     ebx, BLOB_RVA + (ts_ip - tv_present)    ; image base
    mov     [ebp-2Ch], ebx

    mov     eax, ebx
    add     eax, BLOB_RVA + (cs_user32 - tv_present)
    push    eax
    call    dword ptr [ebx+34100h]
    test    eax, eax
    jz      ts_unlock
    mov     [ebp-28h], eax

    mov     eax, ebx
    add     eax, BLOB_RVA + (ts_getdc - tv_present)
    push    eax
    push    dword ptr [ebp-28h]
    call    dword ptr [ebx+34090h]
    test    eax, eax
    jz      ts_unlock
    push    dword ptr [ebp+8]
    call    eax                                     ; GetDC(hwnd)
    test    eax, eax
    jz      ts_unlock
    mov     [ebp-30h], eax

    mov     eax, ebx
    add     eax, BLOB_RVA + (ts_gdi32 - tv_present)
    push    eax
    call    dword ptr [ebx+34100h]
    test    eax, eax
    jz      ts_rel_dc
    mov     [ebp-18h], eax

    mov     eax, ebx
    add     eax, BLOB_RVA + (ts_setmode - tv_present)
    push    eax
    push    dword ptr [ebp-18h]
    call    dword ptr [ebx+34090h]
    test    eax, eax
    jz      ts_rel_dc
    push    4                                       ; HALFTONE
    push    dword ptr [ebp-30h]
    call    eax

    mov     eax, ebx
    add     eax, BLOB_RVA + (ts_setorg - tv_present)
    push    eax
    push    dword ptr [ebp-18h]
    call    dword ptr [ebx+34090h]
    test    eax, eax
    jz      ts_rel_dc
    push    0
    push    0
    push    0
    push    dword ptr [ebp-30h]
    call    eax                                     ; SetBrushOrgEx(hdc,0,0,0)

    mov     eax, ebx
    add     eax, BLOB_RVA + (ts_stretchdib - tv_present)
    push    eax
    push    dword ptr [ebp-18h]
    call    dword ptr [ebx+34090h]
    test    eax, eax
    jz      ts_rel_dc
    mov     [ebp-18h], eax

    mov     dword ptr [ebp-90h+00h], 40
    mov     ecx, [ebp-10Ch+10h]                     ; locked lPitch
    shr     ecx, 2
    mov     [ebp-90h+04h], ecx                      ; biWidth = lPitch/4
    mov     ecx, [ebp+20h]
    neg     ecx
    mov     [ebp-90h+08h], ecx                      ; biHeight = -srcH
    mov     word ptr [ebp-90h+0Ch], 1
    mov     word ptr [ebp-90h+0Eh], 32
    mov     dword ptr [ebp-90h+10h], 0
    mov     dword ptr [ebp-90h+14h], 0
    mov     dword ptr [ebp-90h+18h], 0
    mov     dword ptr [ebp-90h+1Ch], 0
    mov     dword ptr [ebp-90h+20h], 0
    mov     dword ptr [ebp-90h+24h], 0

    mov     eax, [ebp+0Ch]
    sub     eax, [ebp+14h]
    shr     eax, 1
    mov     [ebp-20h], eax                          ; xDst
    mov     ecx, [ebp+10h]
    sub     ecx, [ebp+18h]
    shr     ecx, 1
    mov     [ebp-1Ch], ecx                          ; yDst

    lea     edx, [ebp-68h]
    mov     eax, [ebp-30h]
    mov     [edx+00h], eax
    mov     eax, [ebp-20h]
    mov     [edx+04h], eax
    mov     eax, [ebp-1Ch]
    mov     [edx+08h], eax
    mov     eax, [ebp+14h]
    mov     [edx+0Ch], eax
    mov     eax, [ebp+18h]
    mov     [edx+10h], eax
    mov     dword ptr [edx+14h], 0                  ; xSrc
    mov     dword ptr [edx+18h], 0                  ; ySrc
    mov     eax, [ebp+1Ch]
    mov     [edx+1Ch], eax
    mov     eax, [ebp+20h]
    mov     [edx+20h], eax
    mov     eax, [ebp-24h]
    mov     [edx+24h], eax
    lea     eax, [ebp-90h]
    mov     [edx+28h], eax
    mov     dword ptr [edx+2Ch], 0                  ; DIB_RGB_COLORS
    mov     dword ptr [edx+30h], 00CC0020h          ; SRCCOPY
    push    dword ptr [edx+30h]
    push    dword ptr [edx+2Ch]
    push    dword ptr [edx+28h]
    push    dword ptr [edx+24h]
    push    dword ptr [edx+20h]
    push    dword ptr [edx+1Ch]
    push    dword ptr [edx+18h]
    push    dword ptr [edx+14h]
    push    dword ptr [edx+10h]
    push    dword ptr [edx+0Ch]
    push    dword ptr [edx+08h]
    push    dword ptr [edx+04h]
    push    dword ptr [edx+00h]
    call    dword ptr [ebp-18h]                     ; StretchDIBits

ts_rel_dc:
    mov     eax, ebx
    add     eax, BLOB_RVA + (ts_releasedc - tv_present)
    push    eax
    push    dword ptr [ebp-28h]
    call    dword ptr [ebx+34090h]
    test    eax, eax
    jz      ts_unlock
    push    dword ptr [ebp-30h]
    push    dword ptr [ebp+8]
    call    eax                                     ; ReleaseDC(hwnd, hdc)
ts_unlock:
    mov     eax, [ebp-34h]
    mov     ecx, [eax]
    push    0
    push    eax
    call    dword ptr [ecx+80h]                     ; Unlock(offscreen)
ts_ret:
    add     esp, 100h
    pop     edi
    pop     esi
    pop     ebx
    pop     ebp
    ret
tp_smooth endp

tp_getclient db 'GetClientRect',0
tp_c2s       db 'ClientToScreen',0
ts_getdc     db 'GetDC',0
ts_releasedc db 'ReleaseDC',0
ts_gdi32     db 'gdi32.dll',0
ts_setmode   db 'SetStretchBltMode',0
ts_setorg    db 'SetBrushOrgEx',0
ts_stretchdib db 'StretchDIBits',0
end


