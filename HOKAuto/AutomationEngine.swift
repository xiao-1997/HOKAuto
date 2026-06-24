import UIKit

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    private let loginPoint = (x: 540, y: 960)
    private let closePoints = [(x: 1100, y: 100), (x: 1150, y: 100), (x: 1200, y: 150)]

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

        DispatchQueue.global().async {
            var elapsed = 0
            while elapsed < 60 {
                sleep(5)
                elapsed += 5
                DispatchQueue.main.async { self.status = "检测 \(elapsed)秒"; self.onUpdate?() }

                // 关闭弹窗
                for pt in self.closePoints {
                    self.at("touchDown 0 \(pt.x) \(pt.y)")
                    usleep(50000)
                    self.at("touchUp 0 \(pt.x) \(pt.y)")
                    usleep(100000)
                }

                // 30秒后点登录
                if elapsed == 30 {
                    DispatchQueue.main.async { self.status = "点击登录"; self.onUpdate?() }
                    self.at("touchDown 0 \(self.loginPoint.x) \(self.loginPoint.y)")
                    usleep(50000)
                    self.at("touchUp 0 \(self.loginPoint.x) \(self.loginPoint.y)")
                    DispatchQueue.main.async { self.log("已点击登录") }
                }
            }
            DispatchQueue.main.async { self.status = "完成"; self.log("完成"); self.isRunning = false; self.onUpdate?() }
        }
    }

    private func at(_ args: String) {
        let parts = args.components(separatedBy: " ")
        let cArgs = parts.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let ret = posix_spawn(&pid, "/usr/bin/autotouch", nil, nil, cArgs + [nil], nil)
        if ret == 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
