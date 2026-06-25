/*
 * touch.c - iOS IOKit 触控注入 (无 AutoTouch 依赖)
 * 使用 IOKit 私有 API 直接向 IOHIDSystem 发送触控事件
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// 手动声明 IOKit 私有 API (iOS 13 运行时可用, SDK 头中未暴露)
typedef unsigned int mach_port_t;
typedef unsigned int io_connect_t;
typedef unsigned int io_iterator_t;
typedef unsigned int io_object_t;
typedef int kern_return_t;
typedef unsigned int CFTypeID;
typedef const void* CFStringRef;
typedef void* CFMutableDictionaryRef;

extern mach_port_t mach_host_self(void);
extern mach_port_t bootstrap_port;
extern kern_return_t IOMainPort(mach_port_t, mach_port_t*);
extern CFMutableDictionaryRef IOServiceMatching(const char*);
extern kern_return_t IOServiceGetMatchingServices(mach_port_t, CFMutableDictionaryRef, io_iterator_t*);
extern io_object_t IOIteratorNext(io_iterator_t);
extern kern_return_t IOObjectRelease(io_object_t);
extern kern_return_t IOServiceOpen(io_object_t, mach_port_t, unsigned int, io_connect_t*);
extern kern_return_t IOConnectCallStructMethod(io_connect_t, unsigned int, const void*, unsigned int, void*, unsigned int*);
extern unsigned long long mach_absolute_time(void);

// IOHIDEvent 结构
typedef struct {
    unsigned long long timestamp;
    unsigned long long senderID;
    unsigned long long typeMask;
    unsigned int options;
    unsigned int type;
    unsigned int subtype;
    unsigned int capacity;
    unsigned int count;
    double values[16];
} IOHIDEvent;

static io_connect_t g_conn = 0;

// 打开 IOHIDSystem 连接
static int hid_open(void) {
    if (g_conn) return 0;

    mach_port_t master;
    kern_return_t kr = IOMainPort(bootstrap_port, &master);
    if (kr != 0) { printf("[touch] IOMainPort fail\n"); return -1; }

    CFMutableDictionaryRef match = IOServiceMatching("IOHIDSystem");
    io_iterator_t iter;
    kr = IOServiceGetMatchingServices(master, match, &iter);
    if (kr != 0) { printf("[touch] IOServiceGetMatchingServices fail\n"); return -1; }

    io_object_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) { printf("[touch] IOHIDSystem not found\n"); return -1; }

    kr = IOServiceOpen(svc, mach_host_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != 0) { printf("[touch] IOServiceOpen fail\n"); return -1; }

    printf("[touch] IOHIDSystem opened OK\n");
    return 0;
}

// 发送触控事件
static void hid_send(float x, float y, int phase) {
    if (hid_open() != 0) return;

    IOHIDEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.timestamp = mach_absolute_time();
    ev.type = 11;      // kIOHIDEventTypeDigitizer
    ev.capacity = 6;
    ev.count = 1;
    ev.values[0] = x;
    ev.values[1] = y;
    ev.values[2] = phase;  // 1=began, 2=ended

    IOConnectCallStructMethod(g_conn, 2, &ev, sizeof(ev), NULL, NULL);
}

// 公开 API

void ve_touch_down(int finger, float x, float y) {
    (void)finger;
    hid_send(x, y, 1);
}

void ve_touch_up(int finger, float x, float y) {
    (void)finger;
    hid_send(x, y, 2);
}

void ve_click(float x, float y) {
    ve_touch_down(0, x, y);
    usleep(50000);
    ve_touch_up(0, x, y);
}

void ve_swipe(float x1, float y1, float x2, float y2, int ms) {
    int steps = ms / 10;
    if (steps < 1) steps = 1;
    for (int i = 0; i <= steps; i++) {
        float t = (float)i / steps;
        float x = x1 + (x2 - x1) * t;
        float y = y1 + (y2 - y1) * t;
        int phase = (i == 0) ? 1 : (i == steps) ? 2 : 0;
        hid_send(x, y, phase);
        usleep(10000);
    }
}
