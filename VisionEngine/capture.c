/*
 * capture.c - IOMobileFramebuffer + IOSurface 屏幕截图
 * 直接与 iOS 图形底层对话，可捕获 Metal 游戏画面
 * 参考 Display Recorder 实现思路
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

// ── IOMobileFramebuffer 函数指针 ──
typedef kern_return_t (*IOMobileFramebufferOpen_t)(
    mach_port_t, task_t, unsigned int, void **);
typedef kern_return_t (*IOMobileFramebufferGetLayerDefaultSurface_t)(
    void *, unsigned int, void **);

// ── IOSurface 函数指针 ──
typedef kern_return_t (*IOSurfaceLock_t)(void *, unsigned int, unsigned int *);
typedef kern_return_t (*IOSurfaceUnlock_t)(void *, unsigned int, unsigned int *);
typedef size_t (*IOSurfaceGetWidth_t)(void *);
typedef size_t (*IOSurfaceGetHeight_t)(void *);
typedef size_t (*IOSurfaceGetBytesPerRow_t)(void *);
typedef void *(*IOSurfaceGetBaseAddress_t)(void *);

#define kIOSurfaceLockReadOnly  0x00000001

// ── dlopen 缓存 ──
static void *io_fb_handle = NULL;
static void *io_surf_handle = NULL;

static IOMobileFramebufferOpen_t p_IOMobileFramebufferOpen = NULL;
static IOMobileFramebufferGetLayerDefaultSurface_t p_GetLayerDefaultSurface = NULL;
static IOSurfaceLock_t p_IOSurfaceLock = NULL;
static IOSurfaceUnlock_t p_IOSurfaceUnlock = NULL;
static IOSurfaceGetWidth_t p_IOSurfaceGetWidth = NULL;
static IOSurfaceGetHeight_t p_IOSurfaceGetHeight = NULL;
static IOSurfaceGetBytesPerRow_t p_IOSurfaceGetBytesPerRow = NULL;
static IOSurfaceGetBaseAddress_t p_IOSurfaceGetBaseAddress = NULL;

static int load_symbols(void) {
    if (p_IOMobileFramebufferOpen) return 0; // 已加载

    io_fb_handle = dlopen(
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
        RTLD_LAZY);
    if (!io_fb_handle) {
        printf("[capture] IOMobileFramebuffer 加载失败\n");
        return -1;
    }

    io_surf_handle = dlopen(
        "/System/Library/Frameworks/IOSurface.framework/IOSurface",
        RTLD_LAZY);
    if (!io_surf_handle) {
        printf("[capture] IOSurface 加载失败\n");
        dlclose(io_fb_handle); io_fb_handle = NULL;
        return -1;
    }

    p_IOMobileFramebufferOpen = dlsym(io_fb_handle, "IOMobileFramebufferOpen");
    p_GetLayerDefaultSurface = dlsym(io_fb_handle, "IOMobileFramebufferGetLayerDefaultSurface");
    p_IOSurfaceLock = dlsym(io_surf_handle, "IOSurfaceLock");
    p_IOSurfaceUnlock = dlsym(io_surf_handle, "IOSurfaceUnlock");
    p_IOSurfaceGetWidth = dlsym(io_surf_handle, "IOSurfaceGetWidth");
    p_IOSurfaceGetHeight = dlsym(io_surf_handle, "IOSurfaceGetHeight");
    p_IOSurfaceGetBytesPerRow = dlsym(io_surf_handle, "IOSurfaceGetBytesPerRow");
    p_IOSurfaceGetBaseAddress = dlsym(io_surf_handle, "IOSurfaceGetBaseAddress");

    if (!p_IOMobileFramebufferOpen || !p_GetLayerDefaultSurface ||
        !p_IOSurfaceLock || !p_IOSurfaceUnlock ||
        !p_IOSurfaceGetWidth || !p_IOSurfaceGetHeight ||
        !p_IOSurfaceGetBytesPerRow || !p_IOSurfaceGetBaseAddress) {
        printf("[capture] 函数符号解析失败\n");
        dlclose(io_fb_handle); io_fb_handle = NULL;
        dlclose(io_surf_handle); io_surf_handle = NULL;
        return -1;
    }

    printf("[capture] 符号加载成功\n");
    return 0;
}

CGImageRef ve_capture_screen(void) {
    if (load_symbols() != 0) return NULL;

    // ── 1. 打开 IOMobileFramebuffer 服务 ──
    void *fb = NULL;
    kern_return_t kr = p_IOMobileFramebufferOpen(
        mach_task_self(), 0, 0, &fb);  // 修正参数类型
    if (kr != KERN_SUCCESS || !fb) {
        printf("[capture] IOMobileFramebufferOpen 失败 kr=%d\n", kr);
        return NULL;
    }

    // ── 2. 获取图层0的 IOSurface ──
    void *surface = NULL;
    kr = p_GetLayerDefaultSurface(fb, 0, &surface);
    if (kr != KERN_SUCCESS || !surface) {
        printf("[capture] GetLayerDefaultSurface 失败 kr=%d\n", kr);
        // 注意: 这里需要释放 fb 连接
        return NULL;
    }

    // ── 3. 锁定 IOSurface 并读取像素 ──
    p_IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);

    size_t w = p_IOSurfaceGetWidth(surface);
    size_t h = p_IOSurfaceGetHeight(surface);
    size_t bpr = p_IOSurfaceGetBytesPerRow(surface);
    void *base = p_IOSurfaceGetBaseAddress(surface);

    printf("[capture] Surface %zux%zu bpr=%zu base=%p\n", w, h, bpr, base);

    if (!base || w == 0 || h == 0 || bpr == 0) {
        printf("[capture] 无效的 Surface 属性\n");
        p_IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        return NULL;
    }

    // ── 4. 通过 CGBitmapContext 安全创建 CGImage ──
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        base, w, h, 8, bpr, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);

    if (!ctx) {
        printf("[capture] CGBitmapContextCreate 失败\n");
        p_IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        return NULL;
    }

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    // ── 5. 解锁并返回 ──
    p_IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    if (img) {
        printf("[capture] 截图成功 %zux%zu\n", w, h);
    }
    return img;
}
