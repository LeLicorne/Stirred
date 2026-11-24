/* License: GPL-3.0-or-later (part of Stirred).
   Minimal Direct3D 12 probe: create a device on the default adapter, a command queue and a swap chain, clear and present
   a few frames. Writes d3d12_clear.log. Build: x86_64-w64-mingw32-gcc -O2 -o d3d12_clear.exe d3d12_clear.c -ld3d12 -ldxgi -luuid */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
static FILE *L;
#define LOG(...) do { fprintf(L, __VA_ARGS__); fflush(L); } while (0)
static LRESULT CALLBACK P(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }
int main(void) {
    L = fopen("d3d12_clear.log", "w");
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    LOG("D3D12CreateDevice(11_0) hr=0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 1;
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = {0}; D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    fl.NumFeatureLevels = 4; fl.pFeatureLevelsRequested = levels;
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof fl))) LOG("max feature level 0x%x\n", fl.MaxSupportedFeatureLevel);
    D3D12_COMMAND_QUEUE_DESC qd = {0}; ID3D12CommandQueue *q = NULL;
    hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q);
    LOG("CreateCommandQueue hr=0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 2;
    WNDCLASSA wc = {0}; wc.lpfnWndProc = P; wc.lpszClassName = "d3d12probe"; RegisterClassA(&wc);
    HWND hw = CreateWindowA("d3d12probe", "d3d12 probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 480, 0, 0, 0, 0);
    IDXGIFactory4 *f = NULL; hr = CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&f);
    LOG("CreateDXGIFactory1 hr=0x%08lx\n", (unsigned long)hr);
    DXGI_SWAP_CHAIN_DESC1 sd = {0}; sd.Width = 640; sd.Height = 480; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain1 *sc = NULL;
    hr = IDXGIFactory4_CreateSwapChainForHwnd(f, (IUnknown *)q, hw, &sd, NULL, NULL, &sc);
    LOG("CreateSwapChainForHwnd hr=0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 3;
    for (int i = 0; i < 120; i++) { hr = IDXGISwapChain1_Present(sc, 1, 0); if (FAILED(hr)) { LOG("Present %d hr=0x%08lx\n", i, (unsigned long)hr); return 4; } Sleep(16); }
    LOG("presented 120 frames\n");
    return 0;
}
