/*
 * Direct3D 11 geometry test: fills a window's client area with pure magenta so a screenshot shows where the
 * picture really lands (view placement, grey bars, offsets), and logs where Windows thinks the client area is.
 * Usage: d3d11_geometry.exe <window|full|resize> [seconds]
 *   window: 800x500 client area at (200,150)   full: borderless window covering the screen
 *   resize: starts as `window`, then moves and resizes to 1000x600 at (300,200) after 3 s (swap chain resized too)
 *   move:   starts as `window`, then only moves to (300,200) after 3 s
 *   rebuf:  starts as `window`, then only calls ResizeBuffers (same size) after 3 s
 *   grow:   starts as `window`, then only resizes the window to 1000x600 (swap chain untouched)
 * Writes d3d11_geometry.log in the working directory.
 * Build: x86_64-w64-mingw32-gcc -O2 -mwindows -o d3d11_geometry.exe d3d11_geometry.c -ld3d11 -ldxgi -luuid
 * License: GPL-3.0-or-later (part of Stirred).
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *logf_;
#define LOG(...) do { if (logf_) { fprintf(logf_, __VA_ARGS__); fflush(logf_); } } while (0)

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

static void report(HWND hw, const char *tag)
{
    RECT wr, cr; POINT p = {0, 0};
    GetWindowRect(hw, &wr); GetClientRect(hw, &cr); ClientToScreen(hw, &p);
    LOG("%s window=(%ld,%ld,%ld,%ld) client_origin=(%ld,%ld) client_size=%ldx%ld screen=%dx%d\n", tag,
        wr.left, wr.top, wr.right, wr.bottom, p.x, p.y, cr.right, cr.bottom,
        GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
}

int WINAPI WinMain(HINSTANCE hi, HINSTANCE prev, LPSTR cmd, int show)
{
    (void)prev; (void)show;
    logf_ = fopen("d3d11_geometry.log", "w");
    char mode[16] = "window"; int seconds = 8;
    if (cmd && *cmd) sscanf(cmd, "%15s %d", mode, &seconds);
    int full = !strcmp(mode, "full"), resize = !strcmp(mode, "resize");
    int move = !strcmp(mode, "move"), rebuf = !strcmp(mode, "rebuf"), grow = !strcmp(mode, "grow");

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = WndProc; wc.hInstance = hi; wc.lpszClassName = "StirredGeo";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassA(&wc);

    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    DWORD style = full ? (WS_POPUP | WS_VISIBLE) : (WS_OVERLAPPEDWINDOW | WS_VISIBLE);
    RECT r = { 200, 150, 1000, 650 };
    if (full) { r.left = 0; r.top = 0; r.right = sw; r.bottom = sh; } else AdjustWindowRect(&r, style, FALSE);
    /* Topmost so a screenshot sees it even when the test is started from a background process. */
    HWND hw = CreateWindowExA(WS_EX_TOPMOST, "StirredGeo", "Stirred geometry test", style, r.left, r.top, r.right - r.left, r.bottom - r.top,
                            NULL, NULL, hi, NULL);
    RECT cr; GetClientRect(hw, &cr);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 1;
    sd.BufferDesc.Width = cr.right; sd.BufferDesc.Height = cr.bottom;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hw; sd.SampleDesc.Count = 1; sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain *sc = NULL; ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    LOG("mode=%s create hr=0x%08lx feature_level=0x%x\n", mode, (unsigned long)hr, (unsigned)fl);
    if (FAILED(hr)) return 1;
    ID3D11Texture2D *bb = NULL; ID3D11RenderTargetView *rtv = NULL;
    if (FAILED(IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb))) return 2;
    if (FAILED(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv))) return 3;
    ID3D11Texture2D_Release(bb);

    int total = seconds * 60, resized = 0;
    for (int frame = 0; frame < total; frame++) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        if (frame == 60) report(hw, "placed");
        if ((move || grow) && !resized && frame >= 180) {
            RECT n = { 300, 200, move ? 1100 : 1300, move ? 700 : 800 };
            AdjustWindowRect(&n, style, FALSE);
            SetWindowPos(hw, NULL, n.left, n.top, n.right - n.left, n.bottom - n.top, SWP_NOZORDER);
            resized = 1;
        }
        if ((resize || rebuf) && !resized && frame >= 180) {
            RECT n = { 300, 200, 1300, 800 };
            AdjustWindowRect(&n, style, FALSE);
            if (resize) SetWindowPos(hw, NULL, n.left, n.top, n.right - n.left, n.bottom - n.top, SWP_NOZORDER);
            ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
            ID3D11RenderTargetView_Release(rtv);
            GetClientRect(hw, &cr);
            hr = IDXGISwapChain_ResizeBuffers(sc, 1, cr.right, cr.bottom, DXGI_FORMAT_R8G8B8A8_UNORM, 0);
            LOG("ResizeBuffers hr=0x%08lx\n", (unsigned long)hr);
            if (FAILED(IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb))) return 4;
            if (FAILED(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv))) return 5;
            ID3D11Texture2D_Release(bb);
            resized = 1;
        }
        if (resized && frame == 240) report(hw, "resized");
        float color[4] = { 1.0f, 0.0f, 1.0f, 1.0f };
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, color);
        hr = IDXGISwapChain_Present(sc, 1, 0);
        if (FAILED(hr)) { LOG("Present frame=%d hr=0x%08lx\n", frame, (unsigned long)hr); break; }
        Sleep(16);
    }
    LOG("done\n");
    return 0;
}
