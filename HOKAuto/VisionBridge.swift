import Foundation

/// VisionEngine C API Swift 桥接
struct VisionEngine {

    // MARK: - Touch

    static func touchDown(_ finger: Int = 0, x: Float, y: Float) {
        ve_touch_down(Int32(finger), x, y)
    }
    static func touchUp(_ finger: Int = 0, x: Float, y: Float) {
        ve_touch_up(Int32(finger), x, y)
    }
    static func click(_ x: Float, _ y: Float) { ve_click(x, y) }
    static func swipe(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, ms: Int = 500) {
        ve_swipe(x1, y1, x2, y2, Int32(ms))
    }

    // MARK: - Screenshot
    static func screenshot(_ path: String = "/tmp/hok_screen.jpg") -> Bool {
        ve_screenshot(path) == 0
    }

    // MARK: - OpenCV Template Match
    static func findTemplate(_ screen: String, _ tmpl: String, threshold: Float = 0.7) -> (Float, Float)? {
        var x: Float = 0, y: Float = 0
        if ve_find_template(screen, tmpl, threshold, &x, &y) == 0 {
            if x > 0 || y > 0 { return (x, y) }
        }
        return nil
    }

    // MARK: - YOLO
    static func yoloDetect(_ screen: String) -> [(x: Float, y: Float, w: Float, h: Float, conf: Float, name: String)] {
        var boxes = [YoloBox](repeating: YoloBox(), count: 32)
        let count = ve_yolo_detect(screen, &boxes, 32)
        return (0..<Int(count)).map { i in
            let b = boxes[i]
            return (b.x, b.y, b.w, b.h, b.conf, String(cString: b.name))
        }
    }

    // MARK: - OCR
    static func ocrRecognize(_ image: String) -> [(x: Float, y: Float, w: Float, h: Float, text: String, conf: Float)] {
        var lines = [OCRLine](repeating: OCRLine(), count: 32)
        let count = ve_ocr_recognize(image, &lines, 32)
        return (0..<Int(count)).map { i in
            let l = lines[i]
            return (l.x, l.y, l.w, l.h, String(cString: l.text), l.conf)
        }
    }

    // MARK: - Lua
    static func luaInit() { ve_lua_init() }
    static func luaRun(_ script: String) { ve_lua_run(script) }
    static func luaRunFile(_ path: String) { ve_lua_run_file(path) }
}
