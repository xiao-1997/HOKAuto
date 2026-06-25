/*
 * touch.c - GSEvent 私有API 触控注入 (iOS 13 checkra1n 可用)
 * 无 AutoTouch 依赖, 直接向 backboardd 发送触控事件
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
