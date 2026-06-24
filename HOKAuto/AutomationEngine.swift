import UIKit

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    private let loginPoint = (x: 1100, y: 400)
    private let closePoints = [(x: 1900, y: 200), (x: 2000, y: 150), (x: 1800, y: 250)]

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
            status = "失败"; isRunning = false; onUpdate?()
            return
        }
        onUpdate?()

        let bin = Bundle.main.bundlePath + "/touch_inject"

        DispatchQueue.global().async {
            var elapsed = 0
            while elapsed < 60 {
                sleep(5)
                elapsed += 5

                DispatchQueue.main.async {
                    self.status = "检测中... \(elapsed)秒"
                    self.onUpdate?()
                }

                for pt in self.closePoints {
                    _ = spawn(bin, ["tap", "\(pt.x)", "\(pt.y)"])
                    usleep(100000)
                }

                if elapsed == 30 {
                    DispatchQueue.main.async {
                        self.log("点击登录按钮")
                        self.status = "点击登录"
                    }
                    _ = spawn(bin, ["tap", "\(self.loginPoint.x)", "\(self.loginPoint.y)"])
                }
            }

            DispatchQueue.main.async {
                self.log("完成"); self.status = "完成"
                self.isRunning = false; self.onUpdate?()
            }
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}

// posix_spawn 替代 system()
func spawn(_ path: String, _ args: [String]) -> Int32 {
    let cArgs = args.map { strdup($0) }
    defer { cArgs.forEach { free($0) } }
    var pid: pid_t = 0
    let ret = posix_spawn(&pid, path, nil, nil, cArgs + [nil], nil)
    if ret == 0 {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
    return ret
}
