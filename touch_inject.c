/*
 * touch_inject.c - iOS IOKit touch injector
 * Compiles on Codemagic Mac for arm64
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <IOKit/IOKitLib.h>

int main(int argc, char *argv[]) {
    if (argc < 3) { printf("Usage: %s <x> <y>\n", argv[0]); return 1; }

    float x = atof(argv[1]), y = atof(argv[2]);

    mach_port_t master;
    host_get_io_main(mach_host_self(), &master);

    CFMutableDictionaryRef match = IOServiceMatching("IOHIDSystem");
    io_iterator_t iter;
    IOServiceGetMatchingServices(master, match, &iter);
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);

    io_connect_t conn;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { printf("ERR: IOServiceOpen\n"); return 1; }

    struct {
        uint64_t timestamp, senderID, typeMask;
        uint32_t options, type, subtype, capacity, count;
        double values[16];
    } ev;
    memset(&ev, 0, sizeof(ev));

    ev.timestamp = mach_absolute_time();
    ev.type = 11;  // Digitizer
    ev.capacity = 6;
    ev.count = 1;
    ev.values[0] = x;
    ev.values[1] = y;

    // Touch down
    ev.values[2] = 1;
    IOConnectCallStructMethod(conn, 2, &ev, sizeof(ev), NULL, NULL);
    usleep(50000);

    // Touch up
    ev.values[2] = 2;
    IOConnectCallStructMethod(conn, 2, &ev, sizeof(ev), NULL, NULL);

    printf("OK %.0f %.0f\n", x, y);
    return 0;
}
