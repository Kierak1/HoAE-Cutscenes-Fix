// Metronome - 60 FPS limiter + ImGui DX9 overlay for Heroes of Annihilated Empires.
//
// Injected into engine.exe before the game creates its D3D9 device. Hooks the
// engine's Direct3DCreate9 import (the game ships GSC's D3D9 proxy as
// D3D9.DLL), swaps the IDirect3D9 vtable to catch CreateDevice, then swaps the
// device vtable to catch Present/Reset. Present renders the ImGui overlay and
// enforces a 60 FPS minimum frame time.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <timeapi.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "imgui.h"
#include "imgui_impl_win32.h"
#include "imgui_impl_dx9.h"

// imgui_impl_win32.h keeps this declaration in an #if 0 block on purpose.
extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(
    HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "user32.lib")

// IDirect3D9 / IDirect3DDevice9 vtable slots
static const int kCreateDevice = 16;
static const int kReset = 16;
static const int kPresent = 17;
static const int kDeviceVtableSlots = 128;

typedef IDirect3D9* (WINAPI* PFN_Direct3DCreate9)(UINT);
typedef HRESULT (WINAPI* PFN_CreateDevice)(IDirect3D9*, UINT, D3DDEVTYPE, HWND,
                                           DWORD, D3DPRESENT_PARAMETERS*,
                                           IDirect3DDevice9**);
typedef HRESULT (WINAPI* PFN_Reset)(IDirect3DDevice9*, D3DPRESENT_PARAMETERS*);
typedef HRESULT (WINAPI* PFN_Present)(IDirect3DDevice9*, const RECT*, const RECT*,
                                      HWND, const RGNDATA*);

static PFN_Direct3DCreate9 g_realCreate9 = nullptr;
static PFN_CreateDevice g_realCreateDevice = nullptr;
static PFN_Reset g_realReset = nullptr;
static PFN_Present g_realPresent = nullptr;

static IDirect3DDevice9* g_device = nullptr;
static HWND g_hwnd = nullptr;
static WNDPROC g_oldWndProc = nullptr;
static bool g_imguiReady = false;
static bool g_showMenu = false;
static bool g_limit = true;

static LARGE_INTEGER g_qpcFreq;
static LARGE_INTEGER g_lastPresent;
static bool g_timerReady = false;

static HRESULT WINAPI HookReset(IDirect3DDevice9*, D3DPRESENT_PARAMETERS*);
static HRESULT WINAPI HookPresent(IDirect3DDevice9*, const RECT*, const RECT*,
                                  HWND, const RGNDATA*);
static LRESULT CALLBACK HookWndProcA(HWND, UINT, WPARAM, LPARAM);
static LRESULT CALLBACK HookWndProcW(HWND, UINT, WPARAM, LPARAM);

static void PatchIAT(HMODULE module, const char* importName, void* target,
                     void* replacement)
{
    if (!module) return;
    auto* dos = (IMAGE_DOS_HEADER*)module;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    auto* nt = (IMAGE_NT_HEADERS*)((BYTE*)module + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return;

    auto* imp = (IMAGE_IMPORT_DESCRIPTOR*)((BYTE*)module + dir.VirtualAddress);
    for (; imp->Name; ++imp) {
        const char* name = (const char*)((BYTE*)module + imp->Name);
        if (_stricmp(name, importName) != 0) continue;
        auto* thunk = (IMAGE_THUNK_DATA*)((BYTE*)module +
            (imp->OriginalFirstThunk ? imp->OriginalFirstThunk : imp->FirstThunk));
        auto* iat = (IMAGE_THUNK_DATA*)((BYTE*)module + imp->FirstThunk);
        for (; thunk->u1.Function; ++thunk, ++iat) {
            if ((void*)iat->u1.Function != target) continue;
            DWORD old = 0;
            if (VirtualProtect(&iat->u1.Function, sizeof(void*),
                               PAGE_EXECUTE_READWRITE, &old)) {
                iat->u1.Function = (ULONG_PTR)replacement;
                VirtualProtect(&iat->u1.Function, sizeof(void*), old, &old);
            }
        }
    }
}

// ---------------------------------------------------------------- ImGui

static bool InitImGui(IDirect3DDevice9* device)
{
    if (g_imguiReady) return true;
    if (!g_hwnd) {
        IDirect3DSwapChain9* swap = nullptr;
        if (SUCCEEDED(device->GetSwapChain(0, &swap)) && swap) {
            D3DPRESENT_PARAMETERS pp = {};
            if (SUCCEEDED(swap->GetPresentParameters(&pp)))
                g_hwnd = pp.hDeviceWindow;
            swap->Release();
        }
    }
    if (!g_hwnd) g_hwnd = GetForegroundWindow();
    if (!g_hwnd) return false;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    ImGui::StyleColorsDark();

    ImGui_ImplWin32_Init(g_hwnd);
    if (!ImGui_ImplDX9_Init(device)) {
        ImGui_ImplWin32_Shutdown();
        ImGui::DestroyContext();
        return false;
    }

    if (IsWindowUnicode(g_hwnd)) {
        g_oldWndProc = (WNDPROC)SetWindowLongPtrW(g_hwnd, GWLP_WNDPROC,
                                                  (LONG_PTR)HookWndProcW);
    } else {
        g_oldWndProc = (WNDPROC)SetWindowLongPtrA(g_hwnd, GWLP_WNDPROC,
                                                  (LONG_PTR)HookWndProcA);
    }
    g_imguiReady = true;
    return true;
}

static void DrawUi()
{
    ImGui::SetNextWindowPos(ImVec2(40, 60), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(280, 0), ImGuiCond_FirstUseEver);
    ImGui::Begin("Metronome", &g_showMenu, ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::Text("FPS: %.1f", ImGui::GetIO().Framerate);
    ImGui::Checkbox("Limit to 60 FPS", &g_limit);
    ImGui::TextDisabled("Insert toggles this window");
    ImGui::End();
}

static LRESULT HandleMessage(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    if (msg == WM_KEYDOWN && wparam == VK_INSERT) {
        g_showMenu = !g_showMenu;
        return 0;
    }
    if (g_showMenu) {
        if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam))
            return 1;
        if ((msg >= WM_MOUSEFIRST && msg <= WM_MOUSELAST) ||
            (msg >= WM_KEYFIRST && msg <= WM_KEYLAST))
            return 0;
    }
    return -1;
}

static LRESULT CALLBACK HookWndProcA(HWND hwnd, UINT msg, WPARAM wparam,
                                     LPARAM lparam)
{
    LRESULT r = HandleMessage(hwnd, msg, wparam, lparam);
    if (r != -1) return r;
    return CallWindowProcA(g_oldWndProc, hwnd, msg, wparam, lparam);
}

static LRESULT CALLBACK HookWndProcW(HWND hwnd, UINT msg, WPARAM wparam,
                                     LPARAM lparam)
{
    LRESULT r = HandleMessage(hwnd, msg, wparam, lparam);
    if (r != -1) return r;
    return CallWindowProcW(g_oldWndProc, hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------- limiter

static void LimitFps()
{
    if (!g_timerReady) {
        QueryPerformanceFrequency(&g_qpcFreq);
        QueryPerformanceCounter(&g_lastPresent);
        g_timerReady = true;
        return;
    }

    LONGLONG period = g_qpcFreq.QuadPart / 60;
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);

    LONGLONG next = g_lastPresent.QuadPart + period;
    // A long stall (alt-tab, loading) must not trigger a catch-up burst.
    if (now.QuadPart - next > period * 4) {
        g_lastPresent = now;
        next = now.QuadPart + period;
    }

    if (now.QuadPart < next) {
        LONGLONG remainMs = (next - now.QuadPart) * 1000 / g_qpcFreq.QuadPart;
        if (remainMs > 2) Sleep((DWORD)(remainMs - 1));
        do {
            QueryPerformanceCounter(&now);
            if (now.QuadPart >= next) break;
            YieldProcessor();
        } while (true);
        g_lastPresent.QuadPart = next;
    } else {
        g_lastPresent = now;
    }
}

// ---------------------------------------------------------------- D3D9

static void HookDevice(IDirect3DDevice9* device)
{
    if (!device) return;
    void** original = *(void***)device;
    void** copy = (void**)malloc(sizeof(void*) * kDeviceVtableSlots);
    if (!copy) return;
    memcpy(copy, original, sizeof(void*) * kDeviceVtableSlots);

    g_realReset = (PFN_Reset)copy[kReset];
    g_realPresent = (PFN_Present)copy[kPresent];
    copy[kReset] = (void*)HookReset;
    copy[kPresent] = (void*)HookPresent;

    *(void***)device = copy;
    g_device = device;
}

static HRESULT WINAPI HookCreateDevice(IDirect3D9* self, UINT adapter,
                                       D3DDEVTYPE type, HWND focus,
                                       DWORD flags, D3DPRESENT_PARAMETERS* pp,
                                       IDirect3DDevice9** out)
{
    HRESULT hr = g_realCreateDevice
        ? g_realCreateDevice(self, adapter, type, focus, flags, pp, out)
        : E_FAIL;
    if (SUCCEEDED(hr) && out && *out) {
        if (pp && pp->hDeviceWindow) g_hwnd = pp->hDeviceWindow;
        else if (focus) g_hwnd = focus;
        HookDevice(*out);
    }
    return hr;
}

static IDirect3D9* WINAPI HookDirect3DCreate9(UINT sdk)
{
    IDirect3D9* dd = g_realCreate9 ? g_realCreate9(sdk) : nullptr;
    if (!dd) return nullptr;

    void** original = *(void***)dd;
    void** copy = (void**)malloc(sizeof(void*) * 32);
    if (!copy) return dd;
    memcpy(copy, original, sizeof(void*) * 32);

    g_realCreateDevice = (PFN_CreateDevice)copy[kCreateDevice];
    copy[kCreateDevice] = (void*)HookCreateDevice;
    *(void***)dd = copy;
    return dd;
}

static HRESULT WINAPI HookReset(IDirect3DDevice9* device,
                                D3DPRESENT_PARAMETERS* pp)
{
    if (g_imguiReady) ImGui_ImplDX9_InvalidateDeviceObjects();
    HRESULT hr = g_realReset ? g_realReset(device, pp) : E_FAIL;
    if (SUCCEEDED(hr) && g_imguiReady) {
        ImGui_ImplDX9_CreateDeviceObjects();
        if (pp && pp->hDeviceWindow) g_hwnd = pp->hDeviceWindow;
    }
    return hr;
}

static HRESULT WINAPI HookPresent(IDirect3DDevice9* device, const RECT* src,
                                  const RECT* dst, HWND wnd,
                                  const RGNDATA* dirty)
{
    bool ready = g_imguiReady || InitImGui(device);
    if (ready && device->TestCooperativeLevel() == D3D_OK) {
        ImGui_ImplDX9_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();
        if (g_showMenu) DrawUi();
        ImGui::Render();
        ImGui_ImplDX9_RenderDrawData(ImGui::GetDrawData());
    }

    if (g_limit) LimitFps();
    return g_realPresent ? g_realPresent(device, src, dst, wnd, dirty)
                         : D3DERR_INVALIDCALL;
}

// ---------------------------------------------------------------- entry

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        timeBeginPeriod(1);

        HMODULE d3d9 = GetModuleHandleA("d3d9.dll");
        if (!d3d9) d3d9 = LoadLibraryA("d3d9.dll");
        if (d3d9) {
            g_realCreate9 = (PFN_Direct3DCreate9)
                GetProcAddress(d3d9, "Direct3DCreate9");
            if (g_realCreate9) {
                PatchIAT(GetModuleHandleW(nullptr), "d3d9.dll",
                         (void*)g_realCreate9, (void*)HookDirect3DCreate9);
            }
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        timeEndPeriod(1);
    }
    return TRUE;
}



