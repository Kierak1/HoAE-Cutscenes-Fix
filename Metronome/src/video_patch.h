#pragma once
#include <stddef.h>

// Applies the cutscene fix to theovorb.dll if it is the known pristine build.
// Returns true when the DLL is patched afterwards; writes a status line.
bool EnsureVideoFix(const char* dllPath, char* status, size_t statusSize);
