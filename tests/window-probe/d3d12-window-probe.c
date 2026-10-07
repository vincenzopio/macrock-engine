/* D3D12 window probe: does a D3D12 swapchain keep filling its window?
 *
 * Shows a window and clears its swapchain to a solid color in three phases:
 *   windowed    overlapped window with a 640x400 client area, green
 *   resized     the same window resized to a 960x600 client area, magenta
 *   fullscreen  borderless popup covering its monitor (how games go fullscreen), blue
 * Each phase presents for PHASE_MS; after a third of it the probe prints
 * "PHASE <name> <color> <width>x<height>" (client size), so that an outside tool can capture the
 * window and check that the whole client area has the phase color. With the D3DMetal bridge
 * this catches a Metal view that does not follow its window (white or partly covered window).
 * Prints "DONE" and exits 0 when every phase presented.
 *
 * Build: x86_64-w64-mingw32-clang -O2 -o d3d12-window-probe.exe d3d12-window-probe.c -luser32
 * D3D12 and DXGI are loaded at runtime, so Wine's DLL overrides decide which ones are used. */
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <initguid.h>
#include <d3d12.h>
#include <dxgi1_4.h>

#define BUFFERS 2
#define PHASE_MS 4000

typedef HRESULT (WINAPI *CreateDeviceFn)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
typedef HRESULT (WINAPI *CreateFactoryFn)(UINT, REFIID, void **);

static ID3D12Device *device;
static ID3D12CommandQueue *queue;
static ID3D12CommandAllocator *allocator;
static ID3D12GraphicsCommandList *list;
static ID3D12Fence *fence;
static UINT64 fence_value;
static HANDLE fence_event;
static IDXGISwapChain3 *chain;
static ID3D12DescriptorHeap *heap;
static UINT rtv_stride;
static ID3D12Resource *buffers[BUFFERS];

static void fail(const char *what, HRESULT hr)
{
    printf("FAIL %s 0x%08lx\n", what, (unsigned long)hr);
    ExitProcess(1);
}

static void check(HRESULT hr, const char *what)
{
    if (FAILED(hr)) fail(what, hr);
}

static void wait_gpu(void)
{
    check(ID3D12CommandQueue_Signal(queue, fence, ++fence_value), "Signal");
    if (ID3D12Fence_GetCompletedValue(fence) < fence_value)
    {
        ID3D12Fence_SetEventOnCompletion(fence, fence_value, fence_event);
        if (WaitForSingleObject(fence_event, 5000) != WAIT_OBJECT_0) fail("FenceWait", E_FAIL);
    }
}

static D3D12_CPU_DESCRIPTOR_HANDLE rtv(UINT index)
{
    D3D12_CPU_DESCRIPTOR_HANDLE base;
    heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(heap, &base); /* struct return: C ABI */
    base.ptr += index * rtv_stride;
    return base;
}

static void create_targets(void)
{
    for (UINT i = 0; i < BUFFERS; i++)
    {
        check(IDXGISwapChain3_GetBuffer(chain, i, &IID_ID3D12Resource, (void **)&buffers[i]), "GetBuffer");
        ID3D12Device_CreateRenderTargetView(device, buffers[i], NULL, rtv(i));
    }
}

static void resize_targets(UINT width, UINT height)
{
    wait_gpu();
    for (UINT i = 0; i < BUFFERS; i++) ID3D12Resource_Release(buffers[i]);
    check(IDXGISwapChain3_ResizeBuffers(chain, BUFFERS, width, height, DXGI_FORMAT_UNKNOWN, 0), "ResizeBuffers");
    create_targets();
}

static void barrier(ID3D12Resource *resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b = {0};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = resource;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

static void render(const float color[4])
{
    UINT index = IDXGISwapChain3_GetCurrentBackBufferIndex(chain);
    HRESULT hr;

    ID3D12CommandAllocator_Reset(allocator);
    ID3D12GraphicsCommandList_Reset(list, allocator, NULL);
    barrier(buffers[index], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv(index), color, 0, NULL);
    barrier(buffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
    check(ID3D12GraphicsCommandList_Close(list), "CloseCommandList");
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
    hr = IDXGISwapChain3_Present(chain, 1, 0);
    if (FAILED(hr) && hr != DXGI_STATUS_OCCLUDED) fail("Present", hr);
    wait_gpu();
}

static void pump(void)
{
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

static void phase(HWND window, const char *name, const char *color_name, const float color[4])
{
    RECT client;
    DWORD start;
    BOOL announced = FALSE;

    pump();
    GetClientRect(window, &client);
    resize_targets(client.right, client.bottom);
    start = GetTickCount();
    while (GetTickCount() - start < PHASE_MS)
    {
        pump();
        render(color);
        if (!announced && GetTickCount() - start > PHASE_MS / 3)
        {
            printf("PHASE %s %s %ldx%ld\n", name, color_name, client.right, client.bottom);
            announced = TRUE;
        }
    }
}

static void set_client_size(HWND window, int width, int height)
{
    RECT rect = {0, 0, width, height};
    AdjustWindowRectEx(&rect, GetWindowLongW(window, GWL_STYLE), FALSE, GetWindowLongW(window, GWL_EXSTYLE));
    SetWindowPos(window, NULL, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

int main(void)
{
    static const float green[4] = {0.f, 1.f, 0.f, 1.f}, magenta[4] = {1.f, 0.f, 1.f, 1.f}, blue[4] = {0.f, 0.f, 1.f, 1.f};
    D3D12_COMMAND_QUEUE_DESC queue_desc = {D3D12_COMMAND_LIST_TYPE_DIRECT};
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, BUFFERS};
    DXGI_SWAP_CHAIN_DESC1 swap_desc = {0};
    WNDCLASSW window_class = {0};
    IDXGIFactory4 *factory;
    IDXGISwapChain1 *chain1;
    MONITORINFO monitor = {sizeof(monitor)};
    HMODULE d3d12, dxgi;
    CreateDeviceFn create_device;
    CreateFactoryFn create_factory;
    HWND window;

    setvbuf(stdout, NULL, _IONBF, 0);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    d3d12 = LoadLibraryW(L"d3d12.dll");
    dxgi = LoadLibraryW(L"dxgi.dll");
    create_device = d3d12 ? (CreateDeviceFn)GetProcAddress(d3d12, "D3D12CreateDevice") : NULL;
    create_factory = dxgi ? (CreateFactoryFn)GetProcAddress(dxgi, "CreateDXGIFactory2") : NULL;
    if (!create_device || !create_factory) fail("LoadD3D12", HRESULT_FROM_WIN32(GetLastError()));

    window_class.lpfnWndProc = DefWindowProcW;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    window_class.lpszClassName = L"D3D12WindowProbe";
    RegisterClassW(&window_class);
    window = CreateWindowExW(0, window_class.lpszClassName, L"D3D12 window probe", WS_OVERLAPPEDWINDOW,
                             100, 100, 640, 400, NULL, NULL, window_class.hInstance, NULL);
    if (!window) fail("CreateWindow", HRESULT_FROM_WIN32(GetLastError()));
    set_client_size(window, 640, 400);
    ShowWindow(window, SW_SHOWNORMAL);
    SetForegroundWindow(window);
    pump();

    check(create_device(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device), "CreateDevice");
    check(ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue),
          "CreateCommandQueue");
    check(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
                                              (void **)&allocator), "CreateCommandAllocator");
    check(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
                                         &IID_ID3D12GraphicsCommandList, (void **)&list), "CreateCommandList");
    ID3D12GraphicsCommandList_Close(list);
    check(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence),
          "CreateFence");
    fence_event = CreateEventW(NULL, FALSE, FALSE, NULL);

    check(create_factory(0, &IID_IDXGIFactory4, (void **)&factory), "CreateFactory");
    swap_desc.Width = 640;
    swap_desc.Height = 400;
    swap_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.BufferCount = BUFFERS;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    check(IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, window, &swap_desc, NULL, NULL, &chain1),
          "CreateSwapChain");
    check(IDXGISwapChain1_QueryInterface(chain1, &IID_IDXGISwapChain3, (void **)&chain), "SwapChain3");
    IDXGIFactory4_MakeWindowAssociation(factory, window, DXGI_MWA_NO_ALT_ENTER);
    check(ID3D12Device_CreateDescriptorHeap(device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&heap),
          "CreateDescriptorHeap");
    rtv_stride = ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    create_targets();

    phase(window, "windowed", "green", green);

    set_client_size(window, 960, 600);
    phase(window, "resized", "magenta", magenta);

    GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor);
    SetWindowLongW(window, GWL_STYLE, WS_POPUP | WS_VISIBLE);
    SetWindowPos(window, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                 monitor.rcMonitor.right - monitor.rcMonitor.left, monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    phase(window, "fullscreen", "blue", blue);

    wait_gpu();
    printf("DONE\n");
    return 0;
}
