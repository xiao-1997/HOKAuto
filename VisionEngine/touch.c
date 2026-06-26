/*
 * touch.c - GSEvent 私有API 触控注入 + IOMobileFramebuffer 截图
 * iOS 13+ jailbreak 可用
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>

// GSEvent 结构 (iOS 13)
typedef struct __GSEvent *GSEventRef;

// 私有 API 声明 (运行时通过 dlsym 加载)
static void (*GSEventCreateWithEventRecord)(void*, void*) = NULL;
static void (*GSSendEvent)(GSEventRef, int) = NULL;

// 触控事件记录结构
typedef struct {
    unsigned char unk1[8];
    int type;           // 0=null, 1=down, 2=move, 3=up
    int unknown1;
    float x;
    float y;
    float unknown2;
    float unknown3;
    float unknown4;
    int finger;
    unsigned char unk2[0x30];
    float pressure;
    int unknown5;
    unsigned char unk3[0x1A0];
} GSHandInfo;

typedef struct {
    int size;
    int eventType;      // 0=touch, 1=key...
    GSHandInfo handInfo;
} GSEventRecord;

// dlsym 动态加载 GSEvent API
static int load_gs(void) {
    if (GSSendEvent) return 0;
    void *gs = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_NOW);
    if (!gs) { printf("[touch] GraphicsServices not found\n"); return -1; }
    GSEventCreateWithEventRecord = dlsym(gs, "GSEventCreateWithEventRecord");
    GSSendEvent = dlsym(gs, "GSSendEvent");
    if (!GSSendEvent) { printf("[touch] GSSendEvent not found\n"); return -1; }
    printf("[touch] GSEvent loaded OK\n");
    return 0;
}

static void gs_send(float x, float y, int phase) {
    if (load_gs() != 0) return;

    GSEventRecord rec;
    memset(&rec, 0, sizeof(rec));
    rec.size = sizeof(rec);
    rec.eventType = 0;  // touch event
    rec.handInfo.type = phase;  // 1=down, 3=up
    rec.handInfo.x = x;
    rec.handInfo.y = y;
    rec.handInfo.finger = 0;
    rec.handInfo.pressure = 1.0;

    GSEventRef ev = NULL;
    GSEventCreateWithEventRecord(&rec, &ev);
    if (ev) {
        GSSendEvent(ev, 0);
        CFRelease(ev);
    }
}

void ve_touch_down(int finger, float x, float y) { (void)finger; gs_send(x, y, 1); }
void ve_touch_up(int finger, float x, float y)   { (void)finger; gs_send(x, y, 3); }
void ve_click(float x, float y) {
    ve_touch_down(0, x, y); usleep(50000); ve_touch_up(0, x, y);
}
void ve_swipe(float x1, float y1, float x2, float y2, int ms) {
    int steps = ms / 10; if (steps < 1) steps = 1;
    for (int i = 0; i <= steps; i++) {
        float t = (float)i / steps;
        float x = x1 + (x2-x1)*t, y = y1 + (y2-y1)*t;
        gs_send(x, y, (i==0)?1:(i==steps)?3:2);
        usleep(10000);
    }
}

// ── IOMobileFramebuffer 截图 (解决GPU渲染白屏) ──
// 通过 IOMobileFramebuffer 获取显示层的 IOSurface，直接读像素

// 私有 IOMobileFramebuffer 函数声明
typedef kern_return_t (*IOMobileFramebufferGetLayerDefaultSurface_t)(
    io_connect_t connect, int layer, unsigned *surfaceID);

CGImageRef ve_capture_screen(void) {
    // 打开 IOMobileFramebuffer 服务
    io_service_t fb = IOServiceGetMatchingService(
        kIOMasterPortDefault,
        IOServiceMatching("IOMobileFramebuffer"));
    if (!MACH_PORT_VALID(fb)) {
        printf("[capture] IOMobileFramebuffer service not found\n");
        return NULL;
    }

    io_connect_t connect;
    kern_return_t kr = IOServiceOpen(fb, mach_task_self(), 0, &connect);
    IOObjectRelease(fb);
    if (kr != KERN_SUCCESS) {
        printf("[capture] IOServiceOpen failed: %d\n", kr);
        return NULL;
    }

    // 动态加载 IOMobileFramebufferGetLayerDefaultSurface
    void *iofb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
    if (!iofb) {
        printf("[capture] IOMobileFramebuffer.framework not found\n");
        IOServiceClose(connect);
        return NULL;
    }

    IOMobileFramebufferGetLayerDefaultSurface_t getSurface =
        (IOMobileFramebufferGetLayerDefaultSurface_t)dlsym(iofb, "IOMobileFramebufferGetLayerDefaultSurface");
    if (!getSurface) {
        printf("[capture] GetLayerDefaultSurface not found\n");
        dlclose(iofb);
        IOServiceClose(connect);
        return NULL;
    }

    // 获取图层0的 IOSurface ID
    unsigned surfaceID = 0;
    kr = getSurface(connect, 0, &surfaceID);
    IOServiceClose(connect);

    if (kr != KERN_SUCCESS || surfaceID == 0) {
        printf("[capture] GetLayerDefaultSurface failed: %d id=%u\n", kr, surfaceID);
        dlclose(iofb);
        return NULL;
    }

    printf("[capture] Surface ID: %u\n", surfaceID);

    // 用 IOSurfaceLookup 获取 surface
    void *iosurf = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!iosurf) { dlclose(iofb); return NULL; }

    typedef void* (*IOSurfaceLookup_t)(int);
    typedef int (*IOSurfaceGetWidth_t)(void*);
    typedef int (*IOSurfaceGetHeight_t)(void*);
    typedef int (*IOSurfaceGetBytesPerRow_t)(void*);
    typedef void* (*IOSurfaceGetBaseAddress_t)(void*);

    IOSurfaceLookup_t surfLookup = (IOSurfaceLookup_t)dlsym(iosurf, "IOSurfaceLookup");
    IOSurfaceGetWidth_t surfW = (IOSurfaceGetWidth_t)dlsym(iosurf, "IOSurfaceGetWidth");
    IOSurfaceGetHeight_t surfH = (IOSurfaceGetHeight_t)dlsym(iosurf, "IOSurfaceGetHeight");
    IOSurfaceGetBytesPerRow_t surfBPR = (IOSurfaceGetBytesPerRow_t)dlsym(iosurf, "IOSurfaceGetBytesPerRow");
    IOSurfaceGetBaseAddress_t surfBase = (IOSurfaceGetBaseAddress_t)dlsym(iosurf, "IOSurfaceGetBaseAddress");

    CGImageRef result = NULL;
    if (surfLookup && surfW && surfH && surfBPR && surfBase) {
        void *surface = surfLookup((int)surfaceID);
        if (surface) {
            int w = surfW(surface);
            int h = surfH(surface);
            int bpr = surfBPR(surface);
            void *base = surfBase(surface);

            if (base && w > 0 && h > 0 && bpr > 0) {
                printf("[capture] IOMobileFramebuffer %dx%d bpr=%d\n", w, h, bpr);
                CGDataProviderRef provider = CGDataProviderCreateWithData(
                    NULL, base, h * bpr, NULL);
                if (provider) {
                    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                    result = CGImageCreate(w, h, 8, 32, bpr, cs,
                        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                        provider, NULL, true, kCGRenderingIntentDefault);
                    CGColorSpaceRelease(cs);
                    CGDataProviderRelease(provider);
                }
            }
        }
    }

    dlclose(iosurf);
    dlclose(iofb);
    return result;
}
