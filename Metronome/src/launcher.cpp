// MetronomeLauncher - the single entry point for the HoAE fixes.
//
//   1. applies the cutscene fix (theovorb.dll patches) if the DLL is pristine,
//   2. starts engine.exe suspended, injects Metronome.dll (60 FPS limiter +
//      ImGui overlay), then resumes the game.
//
// Usage:
//   MetronomeLauncher.exe [game folder]
//   MetronomeLauncher.exe --patch [game folder]   (apply the cutscene fix only)
//
// With no path the launcher's own folder is used, so it can be dropped next to
// engine.exe. Injection must happen before the engine creates its D3D9 device.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
#include <string>

#include "video_patch.h"

static void DirName(char* path)
{
    char* slash = strrchr(path, '\\');
    if (slash) *slash = 0;
}

static bool FileExists(const char* path)
{
    DWORD attr = GetFileAttributesA(path);
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

static DWORD FindRunningGame(const char* exePath)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32 pe = {};
    pe.dwSize = sizeof(pe);
    DWORD found = 0;
    if (Process32First(snap, &pe)) {
        do {
            if (_stricmp(pe.szExeFile, "engine.exe") != 0) continue;
            HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                      pe.th32ProcessID);
            if (!proc) continue;
            char path[MAX_PATH] = {};
            DWORD size = MAX_PATH;
            BOOL ok = QueryFullProcessImageNameA(proc, 0, path, &size);
            CloseHandle(proc);
            if (ok && _stricmp(path, exePath) == 0) {
                found = pe.th32ProcessID;
                break;
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

static bool Inject(HANDLE process, const char* dllPath)
{
    SIZE_T size = strlen(dllPath) + 1;
    void* remote = VirtualAllocEx(process, nullptr, size,
                                  MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) return false;
    bool ok = false;
    if (WriteProcessMemory(process, remote, dllPath, size, nullptr)) {
        HMODULE k32 = GetModuleHandleA("kernel32.dll");
        auto loadLibrary = (LPTHREAD_START_ROUTINE)
            GetProcAddress(k32, "LoadLibraryA");
        HANDLE thread = CreateRemoteThread(process, nullptr, 0, loadLibrary,
                                           remote, 0, nullptr);
        if (thread) {
            WaitForSingleObject(thread, 15000);
            DWORD result = 0;
            GetExitCodeThread(thread, &result);
            ok = result != 0;
            CloseHandle(thread);
        }
    }
    VirtualFreeEx(process, remote, 0, MEM_RELEASE);
    return ok;
}

// The Steam build imports Steam.dll but does not ship it in the game folder.
// When the game lives under <steam>\steamapps\common\<game>, put the Steam root
// on the child's PATH so the loader can resolve it.
static void AddSteamRootToPath(const char* gameDir)
{
    char steamDll[MAX_PATH];
    snprintf(steamDll, sizeof(steamDll), "%s\\Steam.dll", gameDir);
    if (FileExists(steamDll)) return;

    char root[MAX_PATH];
    snprintf(root, sizeof(root), "%s", gameDir);
    for (int i = 0; i < 3; i++) DirName(root);

    char rootDll[MAX_PATH];
    snprintf(rootDll, sizeof(rootDll), "%s\\Steam.dll", root);
    if (!FileExists(rootDll)) return;

    char oldPath[32767] = {};
    DWORD n = GetEnvironmentVariableA("PATH", oldPath, sizeof(oldPath));
    char newPath[32767];
    snprintf(newPath, sizeof(newPath), "%s;%s", root, n ? oldPath : "");
    SetEnvironmentVariableA("PATH", newPath);
    printf("Steam.dll: added %s to PATH\n", root);
}

static void ResolveGameDir(const char* arg, char* gameDir, size_t size)
{
    if (arg) {
        GetFullPathNameA(arg, (DWORD)size, gameDir, nullptr);
        DWORD attr = GetFileAttributesA(gameDir);
        if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY))
            DirName(gameDir);
    } else {
        GetModuleFileNameA(nullptr, gameDir, (DWORD)size);
        DirName(gameDir);
    }
}

int main(int argc, char** argv)
{
    bool patchOnly = false;
    const char* argPath = nullptr;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--patch") == 0) patchOnly = true;
        else argPath = argv[i];
    }

    char gameDir[MAX_PATH] = {};
    ResolveGameDir(argPath, gameDir, sizeof(gameDir));
    char exePath[MAX_PATH], theovorb[MAX_PATH];
    snprintf(exePath, sizeof(exePath), "%s\\engine.exe", gameDir);
    snprintf(theovorb, sizeof(theovorb), "%s\\theovorb.dll", gameDir);

    if (DWORD pid = FindRunningGame(exePath)) {
        printf("engine.exe is already running (pid %lu).\n", pid);
        printf("Close it and start the game with this launcher instead: the "
               "hooks must be installed before the game creates its D3D9 "
               "device.\n");
        return 2;
    }

    char videoStatus[192];
    EnsureVideoFix(theovorb, videoStatus, sizeof(videoStatus));
    printf("%s\n", videoStatus);
    if (patchOnly) return 0;

    char dllPath[MAX_PATH], localDll[MAX_PATH];
    GetModuleFileNameA(nullptr, localDll, MAX_PATH);
    DirName(localDll);
    snprintf(dllPath, sizeof(dllPath), "%s\\Metronome.dll", localDll);
    if (!FileExists(dllPath))
        snprintf(dllPath, sizeof(dllPath), "%s\\Metronome.dll", gameDir);

    if (!FileExists(exePath)) {
        printf("engine.exe not found in %s\n", gameDir);
        return 1;
    }
    if (!FileExists(dllPath)) {
        printf("Metronome.dll not found in %s\n", gameDir);
        return 1;
    }

    AddSteamRootToPath(gameDir);

    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};
    char cmdline[MAX_PATH + 16];
    snprintf(cmdline, sizeof(cmdline), "\"%s\"", exePath);
    if (!CreateProcessA(exePath, cmdline, nullptr, nullptr, FALSE,
                        CREATE_SUSPENDED, nullptr, gameDir, &si, &pi)) {
        printf("CreateProcess failed: %lu\n", GetLastError());
        return 1;
    }

    printf("injecting Metronome.dll...\n");
    if (!Inject(pi.hProcess, dllPath)) {
        printf("injection failed (error %lu).\n", GetLastError());
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return 1;
    }

    ResumeThread(pi.hThread);
    printf("injected, game started. Insert toggles the overlay.\n");
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
