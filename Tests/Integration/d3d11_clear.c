/*
 * Minimal Direct3D 11 smoke test: opens a window, creates a device + swap chain and clears the
 * back buffer to a pulsing colour for ~6 seconds. Verifies the whole DXMT -> Metal presentation path
 * without needing a game. Writes d3d11_clear.log (HRESULTs) in the working directory.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -mwindows -o d3d11_clear.exe d3d11_clear.c -ld3d11 -ldxgi -luuid
 * License: GPL-3.0-or-later (part of Stirred).
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>

static FILE *logf_;
#define LOG(...) do { if (logf_) { fprintf(logf_, __VA_ARGS__); fflush(logf_); } } while (0)

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

int WINAPI WinMain(HINSTANCE hi, HINSTANCE prev, LPSTR cmd, int show)
{
    (void)prev; (void)show;
    logf_ = fopen("d3d11_clear.log", "w");

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = WndProc; wc.hInstance = hi; wc.lpszClassName = "StirredD3D";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassA(&wc);
    HWND hw = CreateWindowA("StirredD3D", "Stirred D3D11 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            100, 100, 640, 480, NULL, NULL, hi, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 1;
    sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 480;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hw; sd.SampleDesc.Count = 1; sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain *sc = NULL; ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    LOG("D3D11CreateDeviceAndSwapChain hr=0x%08lx feature_level=0x%x\n", (unsigned long)hr, (unsigned)fl);
    if (FAILED(hr)) return 1;

    ID3D11Texture2D *bb = NULL; ID3D11RenderTargetView *rtv = NULL;
    hr = IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    LOG("GetBuffer hr=0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 2;
    hr = ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    LOG("CreateRenderTargetView hr=0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 3;

    int seconds = (cmd && *cmd) ? atoi(cmd) : 6;
    int total = seconds * 60;
    for (int frame = 0; frame < total; frame++) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        /* Strong magenta/orange so a screenshot cannot be mistaken for a black or transparent window. */
        float t = (float)(frame % 60) / 60.0f;
        float color[4] = { 1.0f, 0.1f + 0.4f * t, 0.8f - 0.5f * t, 1.0f };
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, color);
        hr = IDXGISwapChain_Present(sc, 1, 0);
        if (frame == 0 || frame == total - 1 || FAILED(hr)) LOG("Present frame=%d hr=0x%08lx\n", frame, (unsigned long)hr);
        Sleep(16);
    }
    LOG("done\n");
    return 0;
}
