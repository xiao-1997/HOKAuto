/*
 * VisionEngine - 本地视觉+AI语义混合引擎
 *
 * OpenCV (图像处理/模板匹配)
 * NCNN+YOLO (目标检测)
 * PaddleOCR (文字识别)
 * Lua (脚本引擎)
 * DeepSeek (AI语义)
 */

#ifndef VISION_CORE_H
#define VISION_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ====== 触控 ======
void ve_touch_down(int finger, float x, float y);
void ve_touch_up(int finger, float x, float y);
void ve_click(float x, float y);
void ve_swipe(float x1, float y1, float x2, float y2, int ms);

// ====== 截图 ======
int ve_screenshot(const char *path);

// ====== OpenCV 图像处理 ======
int ve_find_template(const char *screen_path, const char *tmpl_path,
                     float threshold, float *out_x, float *out_y);

// ====== YOLO 目标检测 ======
typedef struct { float x, y, w, h, conf; int cls; char name[64]; } YoloBox;
int ve_yolo_detect(const char *screen_path, YoloBox *boxes, int max_boxes);

// ====== PaddleOCR 文字识别 ======
typedef struct { float x, y, w, h; char text[256]; float conf; } OCRLine;
int ve_ocr_recognize(const char *image_path, OCRLine *lines, int max_lines);

// ====== Lua 引擎 ======
int ve_lua_init(void);  // 注册 vision API 到全局 Lua 状态
int ve_lua_run(const char *script);
int ve_lua_run_file(const char *path);

// ====== DeepSeek AI ======
typedef void (*DSECallback)(const char *json_response, void *ctx);
int ve_deepseek_query(const char *screen_path, const char *prompt,
                      DSECallback cb, void *ctx);

#ifdef __cplusplus
}
#endif
#endif
