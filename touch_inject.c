/*
 * touch_inject.c - iOS IOKit touch injector
 * 编译: clang -arch arm64 -o touch_inject touch_inject.c -framework IOKit
 * 用法: ./touch_inject tap <x> <y>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>

#define kMyHIDConnectType 0

static io_connect_t _connect = 0;

static int connect_hid() {
    if (_connect) return 0;
    mach_port_t master;
    kern_return_t kr = IOMainPort(bootstrap_port, &master);
    if (kr != KERN_SUCCESS) return -1;

    CFMutableDictionaryRef match = IOServiceMatching("IOHIDSystem");
    io_iterator_t iter;
    kr = IOServiceGetMatchingServices(master, match, &iter);
    if (kr != KERN_SUCCESS) return -1;

    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) return -1;

    kr = IOServiceOpen(svc, mach_task_self(), kMyHIDConnectType, &_connect);
    IOObjectRelease(svc);
    return kr;
}

void inject_touch(float x, float y, int phase) {
    if (connect_hid() != 0) return;

    struct {
        uint64_t timestamp;
        uint64_t senderID;
        uint64_t typeMask;
        uint32_t options;
        uint32_t type;
        uint32_t subtype;
        uint32_t capacity;
        uint32_t count;
        double values[16];
    } ev;
    memset(&ev, 0, sizeof(ev));

    ev.timestamp = mach_absolute_time();
    ev.type = 11;
    ev.capacity = 6;
    ev.count = 1;
    ev.values[0] = x;
    ev.values[1] = y;
    ev.values[2] = phase;

    IOConnectCallStructMethod(_connect, 2, &ev, sizeof(ev), NULL, NULL);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s tap <x> <y>\n", argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "tap") == 0 && argc >= 4) {
        float x = atof(argv[2]), y = atof(argv[3]);
        inject_touch(x, y, 1);
        usleep(50000);
        inject_touch(x, y, 2);
        printf("OK %.0f %.0f\n", x, y);
    } else {
        printf("Unknown: %s\n", argv[1]);
        return 1;
    }
    return 0;
}
