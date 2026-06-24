import UIKit
import Darwin

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    // 横屏坐标 (iPhone Plus: 1242x2208 landscape)
    private let loginPoint = (x: 1100, y: 400)
    // 常见弹窗关闭按钮位置
    private let closePoints = [
        (x: 1900, y: 200),  // 右上角
        (x: 2000, y: 150),  // 右上角2
        (x: 1800, y: 250),  // 右上角3
    ]

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

        // 后台循环：每 5 秒检测弹窗 + 30 秒后点登录
        DispatchQueue.global().async {
            let bin = Bundle.main.bundlePath + "/touch_inject"
            var elapsed = 0

            while elapsed < 60 {
                sleep(5)
                elapsed += 5

                DispatchQueue.main.async {
                    self.status = "检测中... \(elapsed)秒"
                    self.onUpdate?()
                }

                // 尝试关闭弹窗
                for pt in self.closePoints {
                    _ = system("\(bin) tap \(pt.x) \(pt.y)")
                    usleep(100000)
                }

                // 30 秒后点击登录
                if elapsed == 30 {
                    DispatchQueue.main.async {
                        self.log("点击登录按钮")
                        self.status = "点击登录"
                    }
                    _ = system("\(bin) tap \(self.loginPoint.x) \(self.loginPoint.y)")
                }
            }

            DispatchQueue.main.async {
                self.log("完成")
                self.status = "完成"
                self.isRunning = false
                self.onUpdate?()
            }
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
