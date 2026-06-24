import UIKit

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

        // Step 1: 启动王者荣耀
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

        // Step 2: 等待游戏加载后点击登录
        var elapsed = 0
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { t in
            elapsed += 5
            self.status = "等待游戏加载... \(elapsed)秒"
            self.log("等待... \(elapsed)秒")
            self.onUpdate?()

            if elapsed >= 30 {
                t.invalidate()
                self.tapLogin()
            }
        }
    }

    private func tapLogin() {
        log("点击登录按钮 (\(loginPoint.x),\(loginPoint.y))")
        status = "点击登录"

        let cmd = "stouch touch \(loginPoint.x) \(loginPoint.y)"
        _ = system(cmd)

        log("已点击登录按钮")
        status = "完成"
        isRunning = false
        onUpdate?()
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
