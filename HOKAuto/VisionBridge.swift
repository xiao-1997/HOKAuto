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
        path.withCString { ve_screenshot($0) == 0 }
    }

    // MARK: - OpenCV Template Match
    static func findTemplate(_ screen: String, _ tmpl: String, threshold: Float = 0.7) -> (Float, Float)? {
        var x: Float = 0, y: Float = 0
        let r = screen.withCString { s in
            tmpl.withCString { t in
                ve_find_template(s, t, threshold, &x, &y)
            }
        }
        if r == 0 && (x > 0 || y > 0) { return (x, y) }
        return nil
    }

    // MARK: - Lua
    static func luaInit() { ve_lua_init() }
    static func luaRun(_ script: String) { script.withCString { ve_lua_run($0) } }
    static func luaRunFile(_ path: String) { path.withCString { ve_lua_run_file($0) } }
}
