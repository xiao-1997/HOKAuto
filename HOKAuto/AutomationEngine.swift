import Foundation
import UIKit

@MainActor
class AutomationEngine: ObservableObject {
    @Published var status = "就绪"
    @Published var logs = ""
    @Published var isRunning = false

    func run() {
        guard !isRunning else { return }
        isRunning = true
        status = "启动中..."
        logs = ""

        log("启动 王者荣耀...")
        status = "正在启动王者荣耀"

        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in
                print("完成")
            }
            log("王者荣耀已启动")
        } else {
            log("URL Scheme 无效")
        }

        // 等待 10 秒
        var count = 10
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            count -= 1
            self.status = "等待中... \(count)秒"
            if count <= 0 {
                t.invalidate()
                self.status = "完成"
                self.log("完成")
                self.isRunning = false
            }
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
