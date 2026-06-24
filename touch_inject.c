/*
 * touch_inject.c - 越狱 iPhone 触控注入
 * 编译: clang -arch arm64 -isysroot /path/to/iPhoneOS.sdk -o touch_inject touch_inject.c -framework IOKit
 * 用法: ./touch_inject <x> <y>
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>

typedef struct {
    uint64_t field_0;
    uint64_t field_8;
    uint64_t field_10;
    uint64_t field_18;
    uint64_t field_20;
    uint64_t field_28;
    uint64_t field_30;
    uint64_t field_38;
    uint64_t field_40;
    uint64_t field_48;
    uint64_t field_50;
    int x;
    int y;
    int field_68;
    int field_72;
    int field_76;
    int field_80;
} __attribute__((packed)) TouchEvent;

static io_connect_t g_connect = 0;

static int open_service() {
    if (g_connect) return 0;
    mach_port_t master;
    IOMainPort(bootstrap_port, &master);
    CFMutableDictionaryRef matching = IOServiceMatching("IOHIDEventService");
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(master, matching, &iter) != KERN_SUCCESS) return -1;
    io_object_t service = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!service) return -1;
    IOServiceOpen(service, mach_task_self(), 0, &g_connect);
    IOObjectRelease(service);
    return g_connect ? 0 : -1;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        printf("Usage: %s <x> <y>\n", argv[0]);
        return 1;
    }

    int x = atoi(argv[1]);
    int y = atoi(argv[2]);

    if (open_service() != 0) {
        fprintf(stderr, "Cannot open IOHIDEventService\n");
        return 1;
    }

    TouchEvent ev = {0};
    ev.field_30 = 1;
    ev.field_38 = 1;
    ev.field_50 = 1;
    ev.x = x;
    ev.y = y;

    // Touch down
    IOConnectCallStructMethod(g_connect, 0, &ev, sizeof(ev), NULL, 0);

    usleep(50000);

    ev.field_38 = 0;
    // Touch up
    IOConnectCallStructMethod(g_connect, 0, &ev, sizeof(ev), NULL, 0);

    return 0;
}
