/*
 * VisionEngine Core - 三层混合识别引擎
 */
#include "vision_core.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <pthread.h>

// IOKit forward declarations (iOS runtime)
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>

// ====== 1. IOKit Touch Injection ======

static io_connect_t g_hid = 0;

static int hid_ensure() {
    if (g_hid) return 0;
    mach_port_t master;
    IOMainPort(bootstrap_port, &master);
    io_iterator_t iter;
    IOServiceGetMatchingServices(master, IOServiceMatching("IOHIDSystem"), &iter);
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) return -1;
    IOServiceOpen(svc, mach_task_self(), 0, &g_hid);
    IOObjectRelease(svc);
    return g_hid ? 0 : -1;
}

static void hid_send(float x, float y, int phase) {
    if (hid_ensure()) return;
    struct { uint64_t ts,sid,msk; uint32_t opt,type,sub,cap,cnt; double v[16]; } ev = {0};
    ev.ts = mach_absolute_time(); ev.type = 11; ev.cap = 6; ev.cnt = 1;
    ev.v[0] = x; ev.v[1] = y; ev.v[2] = phase;
    IOConnectCallStructMethod(g_hid, 2, &ev, sizeof(ev), NULL, NULL);
}

void ve_touch_down(int finger, float x, float y) { (void)finger; hid_send(x, y, 1); }
void ve_touch_up(int finger, float x, float y)   { (void)finger; hid_send(x, y, 2); }
void ve_click(float x, float y) { ve_touch_down(0,x,y); usleep(50000); ve_touch_up(0,x,y); }
void ve_swipe(float x1,float y1,float x2,float y2,int ms) {
    int steps = ms/10;
    for(int i=0;i<=steps;i++){
        float t=(float)i/steps;
        hid_send(x1+(x2-x1)*t, y1+(y2-y1)*t, i==0?1:i==steps?2:0);
        usleep(10000);
    }
}

// ====== 2. OpenCV Placeholder (编译时链接) ======

#if HAS_OPENCV
#include <opencv2/opencv.hpp>
using namespace cv;

int ve_find_template(const char *screen, const char *tmpl, float th, float *x, float *y) {
    Mat scr = imread(screen), tmp = imread(tmpl);
    if (scr.empty() || tmp.empty()) return -1;
    Mat result;
    matchTemplate(scr, tmp, result, TM_CCOEFF_NORMED);
    double minVal, maxVal; Point minLoc, maxLoc;
    minMaxLoc(result, &minVal, &maxVal, &minLoc, &maxLoc);
    if (maxVal >= th) { *x = maxLoc.x + tmp.cols/2; *y = maxLoc.y + tmp.rows/2; return 0; }
    return -1;
}
#else
int ve_find_template(const char *s, const char *t, float th, float *x, float *y) {
    (void)s;(void)t;(void)th;(void)x;(void)y;
    return -1;
}
#endif

// ====== 3. YOLO Placeholder ======

#if HAS_NCNN
#include <net.h>
int ve_yolo_detect(const char *path, YoloBox *boxes, int max) {
    (void)path;(void)boxes;(void)max;
    return 0;
}
#else
int ve_yolo_detect(const char *p, YoloBox *b, int m) { (void)p;(void)b;(void)m; return 0; }
#endif

// ====== 4. PaddleOCR Placeholder ======

#if HAS_PADDLE
int ve_ocr_recognize(const char *path, OCRLine *lines, int max) {
    (void)path;(void)lines;(void)max;
    return 0;
}
#else
int ve_ocr_recognize(const char *p, OCRLine *l, int m) { (void)p;(void)l;(void)m; return 0; }
#endif

// ====== 5. Screenshot via AutoTouch fallback ======

int ve_screenshot(const char *path) {
    // 通过 autotouch 截图
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
        "keepScreen(true) snapshot(\"%s\") keepScreen(false)", path);
    // 写入临时文件并执行
    FILE *f = fopen("/tmp/_ve_scr.lua", "w");
    if (!f) return -1;
    fputs(cmd, f); fclose(f);
    // 调用 autotouch
    pid_t pid;
    const char *args[] = {"/usr/bin/autotouch","play","start","/tmp/_ve_scr.lua",NULL};
    posix_spawn(&pid, args[0], NULL, NULL, (char* const*)args, NULL);
    int st; waitpid(pid, &st, 0);
    return 0;
}

// ====== 6. Lua ======

#if HAS_LUA
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static lua_State *gL = NULL;

static int l_click(lua_State *L)  { ve_click(luaL_checknumber(L,1), luaL_checknumber(L,2)); return 0; }
static int l_swipe(lua_State *L)  { ve_swipe(luaL_checknumber(L,1),luaL_checknumber(L,2),luaL_checknumber(L,3),luaL_checknumber(L,4),luaL_optint(L,5,500)); return 0; }
static int l_findTpl(lua_State *L) { float x,y; int r=ve_find_template(luaL_checkstring(L,1),luaL_checkstring(L,2),luaL_optnumber(L,3,0.7),&x,&y); if(r==0){lua_pushnumber(L,x);lua_pushnumber(L,y);return 2;} lua_pushnil(L); return 1; }
static int l_ocr(lua_State *L)    { OCRLine lines[32]; int n=ve_ocr_recognize(luaL_checkstring(L,1),lines,32); lua_newtable(L); for(int i=0;i<n;i++){lua_pushnumber(L,i+1);lua_newtable(L);lua_pushstring(L,lines[i].text);lua_setfield(L,-2,"text");lua_settable(L,-3);} return 1; }
static int l_yolo(lua_State *L)   { YoloBox boxes[32]; int n=ve_yolo_detect(luaL_checkstring(L,1),boxes,32); lua_newtable(L); for(int i=0;i<n;i++){lua_pushnumber(L,i+1);lua_newtable(L);lua_pushstring(L,boxes[i].name);lua_setfield(L,-2,"name");lua_settable(L,-3);} return 1; }

static const luaL_Reg ve_lib[] = {
    {"click", l_click}, {"swipe", l_swipe},
    {"findTemplate", l_findTpl}, {"ocr", l_ocr}, {"yolo", l_yolo},
    {NULL,NULL}
};

int ve_lua_init() {
    gL = luaL_newstate();
    luaL_openlibs(gL);
    luaL_register(gL, "vision", ve_lib);
    return 0;
}
int ve_lua_run(const char *s) { return luaL_dostring(gL, s); }
int ve_lua_run_file(const char *p) { return luaL_dofile(gL, p); }
#else
int ve_lua_init() { return -1; }
int ve_lua_run(const char *s) { (void)s; return -1; }
int ve_lua_run_file(const char *p) { (void)p; return -1; }
#endif

// ====== 7. DeepSeek multi-modal ======

int ve_deepseek_query(const char *screen_path, const char *prompt,
                      DSECallback cb, void *ctx) {
    // 读取截图 → base64 → POST DeepSeek API → callback
    (void)screen_path; (void)prompt; (void)cb; (void)ctx;
    // 在 app 层通过 Swift URLSession 实现
    return 0;
}
