/*
 * ScreenCapServer.m - SpringBoard 注入 Dylib
 * Unix Socket 截图服务，通过 CARenderServerRenderDisplay 捕获全屏
 * 无相册写入，内存直接返回 JPEG，100% Metal/游戏兼容
 */

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <stdio.h>
#import <mach-o/dyld.h>

#define SOCK_PATH "/var/mobile/Library/HOKAuto/cap.sock"
#define JPEG_WIDTH  600
#define JPEG_QUALITY 0.5

// CARenderServerRenderDisplay 函数指针
static CGImageRef (*p_CARenderServerRenderDisplay)(int displayID, void *options) = NULL;

static void loadGS(void) {
    void *gs = dlopen(
        "/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
        RTLD_LAZY);
    if (gs) {
        p_CARenderServerRenderDisplay = dlsym(gs, "CARenderServerRenderDisplay");
    }
}

static NSData *captureAndCompress(void) {
    if (!p_CARenderServerRenderDisplay) {
        loadGS();
        if (!p_CARenderServerRenderDisplay) {
            printf("[ScreenCap] CARenderServerRenderDisplay 加载失败\n");
            return nil;
        }
    }

    CGImageRef img = p_CARenderServerRenderDisplay(0, NULL);
    if (!img) {
        printf("[ScreenCap] 截图失败\n");
        return nil;
    }

    // 缩放 + JPEG 压缩
    size_t w = CGImageGetWidth(img);
    size_t h = CGImageGetHeight(img);
    float scale = (float)JPEG_WIDTH / w;
    CGSize size = CGSizeMake(JPEG_WIDTH, h * scale);

    UIGraphicsBeginImageContext(size);
    [[UIImage imageWithCGImage:img] drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(img);

    NSData *jpeg = UIImageJPEGRepresentation(scaled, JPEG_QUALITY);
    printf("[ScreenCap] 截图完成 %zux%zu → %lux%lu, %lu bytes\n",
           w, h, (unsigned long)size.width, (unsigned long)size.height, (unsigned long)jpeg.length);
    return jpeg;
}

static void socketLoop(void) {
    loadGS();

    unlink(SOCK_PATH);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) { printf("[ScreenCap] socket 创建失败\n"); return; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);

    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        printf("[ScreenCap] bind 失败\n"); close(server); return;
    }
    if (listen(server, 3) < 0) {
        printf("[ScreenCap] listen 失败\n"); close(server); return;
    }
    chmod(SOCK_PATH, 0666);
    printf("[ScreenCap] 服务启动: %s\n", SOCK_PATH);

    while (1) {
        int client = accept(server, NULL, NULL);
        if (client < 0) continue;

        NSData *jpeg = captureAndCompress();
        if (jpeg) {
            // 先发 4 字节长度，再发数据
            uint32_t len = (uint32_t)jpeg.length;
            send(client, &len, 4, MSG_NOSIGNAL);
            send(client, jpeg.bytes, len, MSG_NOSIGNAL);
        } else {
            uint32_t zero = 0;
            send(client, &zero, 4, MSG_NOSIGNAL);
        }
        close(client);
    }
}

// MobileSubstrate 注入入口
__attribute__((constructor))
static void init(void) {
    printf("[ScreenCap] 注入 SpringBoard\n");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        socketLoop();
    });
}
