import UIKit

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    func run() {
        guard !isRunning else { return }
        isRunning = true
        status = "启动中..."
        logs = ""
        onUpdate?()

        log("启动 王者荣耀...")
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("王者荣耀已启动")
        } else {
            log("未安装王者荣耀"); status = "失败"; isRunning = false; onUpdate?(); return
        }
        onUpdate?()

        var count = 10
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            count -= 1
            self.status = "等待... \(count + 1)秒"
            self.onUpdate?()
            if count <= 0 {
                t.invalidate()
                self.status = "完成"; self.log("完成")
                self.isRunning = false; self.onUpdate?()
            }
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
