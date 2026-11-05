/*
 * steamwebhelper wrapper (Windows PE, cross-compiled with mingw-w64).
 *
 * Why: under Wine 11 on macOS the Steam UI (Chromium Embedded Framework) paints a black window
 * with GPU rendering and runs into Wine's winsock NetworkService limits. Forcing Chromium into
 * software rendering and a single process avoids both.
 *
 * How: Steam starts "steamwebhelper.exe". We replace it with this program, and keep the original
 * next to it as "steamwebhelper_real.exe". We start the real one with the same arguments plus
 * our extra flags, wait for it, and return its exit code.
 *
 * Steam re-verifies its files at boot and may restore the original helper: Stirred re-deploys
 * the wrapper before every launch.
 *
 * License: GPL-3.0-or-later (part of Stirred).
 */
#include <windows.h>
#include <wchar.h>
#include <stdlib.h>

#define EXTRA_FLAGS L" --disable-gpu --single-process"

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmd, int show)
{
    (void)inst; (void)prev; (void)cmd; (void)show;

    const wchar_t *full = GetCommandLineW();

    /* Split off argv[0] (quoted or not); keep the rest of the line untouched. */
    const wchar_t *rest = full;
    if (*rest == L'"') {
        rest++;
        while (*rest && *rest != L'"') rest++;
        if (*rest == L'"') rest++;
    } else {
        while (*rest && *rest != L' ' && *rest != L'\t') rest++;
    }

    /* Directory of this executable. */
    wchar_t self[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 2;
    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return 2;
    *slash = 0;

    wchar_t real[MAX_PATH];
    if (swprintf(real, MAX_PATH, L"%ls\\steamwebhelper_real.exe", self) < 0) return 2;

    size_t cap = wcslen(real) + wcslen(rest) + wcslen(EXTRA_FLAGS) + 8;
    wchar_t *line = (wchar_t *)malloc(cap * sizeof(wchar_t));
    if (!line) return 2;
    if (swprintf(line, cap, L"\"%ls\"%ls%ls", real, rest, EXTRA_FLAGS) < 0) return 2;

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);

    if (!CreateProcessW(real, line, NULL, NULL, TRUE, 0, NULL, self, &si, &pi)) return 3;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    free(line);
    return (int)code;
}
