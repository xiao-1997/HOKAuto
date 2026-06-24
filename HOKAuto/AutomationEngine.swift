import UIKit

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    private let loginButtonCenter = CGPoint(x: 207, y: 760) // 登录按钮坐标

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

        // Step 2: 连接 WDA 并执行点击登录
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            self.checkWDAAndTapLogin()
        }
    }

    private func checkWDAAndTapLogin() {
        self.status = "连接 WDA..."
        self.onUpdate?()

        guard let wdaURL = URL(string: "http://localhost:8100/status") else {
            self.log("WDA 不可用")
            self.finishWaiting(loginTapped: false)
            return
        }

        URLSession.shared.dataTask(with: wdaURL) { _, _, error in
            if error != nil {
                DispatchQueue.main.async {
                    self.log("WDA 未连接，仅启动游戏")
                    self.finishWaiting(loginTapped: false)
                }
                return
            }

            // WDA 可用，等待游戏加载后点击登录
            DispatchQueue.main.async {
                self.log("等待游戏加载...")
                self.waitForGameLoad()
            }
        }.resume()
    }

    private func waitForGameLoad() {
        var elapsed = 0
        let maxWait = 60

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { t in
            elapsed += 5
            self.status = "等待游戏加载... \(elapsed)秒"
            self.log("等待中... \(elapsed)秒")
            self.onUpdate?()

            if elapsed >= maxWait {
                t.invalidate()
                self.tapLoginButton()
            }
        }
    }

    private func tapLoginButton() {
        self.log("点击登录按钮")
        self.status = "点击登录"

        let wdaSessionURL = URL(string: "http://localhost:8100/session")!
        var req = URLRequest(url: wdaSessionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "capabilities": ["bundleId": "com.tencent.smoba"]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sessionId = json["sessionId"] as? String {
                    self.doLoginTap(sessionId: sessionId)
                } else {
                    self.log("WDA Session 失败")
                    self.finishWaiting(loginTapped: false)
                }
            }
        }.resume()
    }

    private func doLoginTap(sessionId: String) {
        let tapURL = URL(string: "http://localhost:8100/session/\(sessionId)/wda/tap/0")!
        var req = URLRequest(url: tapURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "x": loginButtonCenter.x,
            "y": loginButtonCenter.y
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { _, _, _ in
            DispatchQueue.main.async {
                self.log("已点击登录按钮")
                self.finishWaiting(loginTapped: true)
            }
        }.resume()
    }

    private func finishWaiting(loginTapped: Bool) {
        status = loginTapped ? "已完成(已点登录)" : "已完成(仅启动)"
        log("完成")
        isRunning = false
        onUpdate?()
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
