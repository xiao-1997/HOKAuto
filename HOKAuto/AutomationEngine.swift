import UIKit
import Darwin

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    private let loginPoint = (x: 207, y: 760)

    func run() {
        guard !isRunning else { return }
        isRunning = true
        status = "启动中..."
        logs = ""
        onUpdate?()

        log("启动 王者荣耀...")
        status = "正在启动王者荣耀"

        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("王者荣耀已启动")
        } else {
            log("未安装王者荣耀")
            status = "失败"
            isRunning = false
            onUpdate?()
            return
        }
        onUpdate?()

        // 后台循环：每隔 5 秒关闭弹窗 + 检测登录
        DispatchQueue.global().async {
            var elapsed = 0
            while elapsed < 60 {
                sleep(5)
                elapsed += 5

                DispatchQueue.main.async {
                    self.status = "检测中... \(elapsed)秒"
                    self.onUpdate?()
                }

                // 关闭弹窗
                self.closePopup()

                if elapsed >= 30 {
                    DispatchQueue.main.async {
                        self.tapLogin()
                    }
                    break
                }
            }

            DispatchQueue.main.async {
                if self.isRunning {
                    self.status = "完成"
                    self.isRunning = false
                    self.onUpdate?()
                }
            }
        }
    }

    private func closePopup() {
        // 写入并执行弹窗关闭 Lua 脚本
        let script = """
        local img = "/var/mobile/Library/AutoTouch/Scripts/Images/close_btn.png"
        local x, y = findImage(img, 1, 0.7, nil, nil)
        if x > 0 then
            touchDown(0, x, y)
            usleep(50000)
            touchUp(0, x, y)
        end
        """

        let path = "/tmp/hok_popup.lua"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        _ = system("/usr/bin/autotouch play start \(path)")
    }

    private func tapLogin() {
        log("点击登录按钮")
        status = "点击登录"

        let at = "/usr/bin/autotouch"
        _ = system("\(at) touchDown 0 \(loginPoint.x) \(loginPoint.y)")
        usleep(50000)
        _ = system("\(at) touchUp 0 \(loginPoint.x) \(loginPoint.y)")

        log("已点击登录")
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
