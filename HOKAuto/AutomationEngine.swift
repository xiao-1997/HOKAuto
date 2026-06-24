import Foundation

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

        Task {
            // 直接通过 URL Scheme 启动王者荣耀
            log("启动 王者荣耀...")
            status = "正在启动王者荣耀"

            if let url = URL(string: "tencent1104466820://") {
                if UIApplication.shared.canOpenURL(url) {
                    await UIApplication.shared.open(url)
                    log("王者荣耀已启动")
                } else {
                    log("未安装王者荣耀")
                }
            } else {
                log("URL Scheme 无效")
            }

            // 等待
            for i in 1...10 {
                status = "等待中... \(11 - i)秒"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            status = "完成"
            log("完成")
            isRunning = false
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
