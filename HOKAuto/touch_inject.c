/*
 * touch_inject.c - iOS 越狱触控注入/读取
 * 编译: clang -arch arm64 -o touch_inject touch_inject.c -framework IOKit -framework UIKit
 * 使用: ./touch_inject tap <x> <y>     点击
 *       ./touch_inject swipe <x1> <y1> <x2> <y2>  滑动
 *       ./touch_inject listen           读取全局触摸事件
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

// IOHIDEvent 标准结构
typedef struct {
    uint64_t timestamp;
    uint64_t senderID;
    uint64_t typeMask;
    uint32_t options;
    uint32_t type;
    uint32_t subtype;
    uint32_t capacity;
    uint32_t count;
    double  values[16];
} IOHIDEvent;

static io_connect_t _connect = MACH_PORT_NULL;

static int connect_hid() {
    if (_connect != MACH_PORT_NULL) return 0;
    mach_port_t master;
    IOMainPort(bootstrap_port, &master);
    CFMutableDictionaryRef match = IOServiceMatching("IOHIDSystem");
    io_iterator_t iter;
    IOServiceGetMatchingServices(master, match, &iter);
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(),
        kIOHIDParamConnectType, &_connect);
    IOObjectRelease(svc);
    return kr;
}

// 注入触控事件
void inject_touch(float x, float y, int phase) {
    if (connect_hid() != 0) return;

    IOHIDEvent ev = {0};
    ev.timestamp = mach_absolute_time();
    ev.type = 11;  // kIOHIDEventTypeDigitizer
    ev.subtype = 0;
    ev.capacity = 6;
    ev.count = 1;

    // x, y
    ev.values[0] = x;
    ev.values[1] = y;

    // phase: 0=moved, 1=began, 2=ended
    ev.values[2] = phase;
    ev.values[3] = 0;  // force

    uint32_t sz = sizeof(ev);
    IOConnectCallStructMethod(_connect, 2, &ev, sz, NULL, NULL);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s tap <x> <y>\n", argv[0]);
        printf("       %s swipe <x1> <y1> <x2> <y2>\n", argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "tap") == 0 && argc >= 4) {
        float x = atof(argv[2]);
        float y = atof(argv[3]);
        inject_touch(x, y, 1);
        usleep(50000);
        inject_touch(x, y, 2);
        printf("Tapped: %.1f, %.1f\n", x, y);
    } else if (strcmp(argv[1], "swipe") == 0 && argc >= 6) {
        float x1 = atof(argv[2]), y1 = atof(argv[3]);
        float x2 = atof(argv[4]), y2 = atof(argv[5]);
        int steps = 20;
        for (int i = 0; i <= steps; i++) {
            float t = (float)i / steps;
            float x = x1 + (x2 - x1) * t;
            float y = y1 + (y2 - y1) * t;
            int phase = (i == 0) ? 1 : (i == steps) ? 2 : 0;
            inject_touch(x, y, phase);
            usleep(5000);
        }
        printf("Swiped: %.1f,%.1f -> %.1f,%.1f\n", x1, y1, x2, y2);
    } else {
        printf("Unknown command\n");
        return 1;
    }

    return 0;
}
