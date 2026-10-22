#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcW(h, m, w, l); }

int main(int argc, char **argv) {
    FILE *f = fopen(argc > 1 ? argv[1] : "C:\\d3dprobe.txt", "w");
    WNDCLASSW wc = {0}; wc.lpfnWndProc = wp; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"probe";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowW(L"probe", L"probe", WS_OVERLAPPEDWINDOW, 0, 0, 320, 240, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2; sd.BufferDesc.Width = 320; sd.BufferDesc.Height = 240;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL; IDXGISwapChain *sc = NULL; D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    fprintf(f, "create hr=0x%08lx feature_level=0x%x\n", (unsigned long)hr, fl);
    if (SUCCEEDED(hr)) {
        IDXGIDevice *xd; IDXGIAdapter *ad; DXGI_ADAPTER_DESC desc;
        ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&xd);
        IDXGIDevice_GetAdapter(xd, &ad); IDXGIAdapter_GetDesc(ad, &desc);
        fprintf(f, "adapter=%ls vram=%lluMB\n", desc.Description, (unsigned long long)desc.DedicatedVideoMemory >> 20);
        ID3D11Texture2D *bb; ID3D11RenderTargetView *rtv;
        IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
        ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
        float c[4] = {0.5f, 0.1f, 0.2f, 1.0f};
        HRESULT ph = S_OK;
        for (int i = 0; i < 60; i++) { ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c); ph = IDXGISwapChain_Present(sc, 0, 0); if (FAILED(ph)) break; }
        fprintf(f, "present hr=0x%08lx (60 frames)\n", (unsigned long)ph);
    }
    if (SUCCEEDED(hr)) {
        /* IDXGIVkInteropDevice is only implemented by DXVK, never by WineD3D. */
        static const GUID IID_IDXGIVkInteropDevice = {0xe2ef5fa5, 0xdc21, 0x4af7, {0x90, 0xc4, 0xf6, 0x7e, 0xf6, 0xa0, 0x93, 0x23}};
        IUnknown *interop = NULL;
        HRESULT qh = ID3D11Device_QueryInterface(dev, &IID_IDXGIVkInteropDevice, (void **)&interop);
        fprintf(f, "backend=%s\n", SUCCEEDED(qh) ? "DXVK" : "WineD3D");
    }
    fclose(f);
    return SUCCEEDED(hr) ? 0 : 1;
}
