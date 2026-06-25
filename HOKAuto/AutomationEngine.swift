import UIKit

class AutomationEngine {
    var status = "就绪" { didSet { FloatingHUD.shared.setStatus(status) } }
    var logs = ""
    var isRunning = false { didSet { if !isRunning { FloatingHUD.shared.hide() } } }
    var onUpdate: (() -> Void)?

    private var mainTimer: Timer?, dsTimer: Timer?
    private var elapsed = 0
    private var aiCallCount = 0, aiMaxCalls = 5
    private var lastAICall: Date?
    private var loginTapped = false

    // 录制坐标 (1242x2208 Landscape)
    private let cancelPoint = (x: Float(1340), y: Float(732))
    private let loginPoint  = (x: Float(1209), y: Float(945))
    private let closePoints: [(Float, Float)] = [
        (1896, 124), (1898, 146), (1876, 99), (2066, 146), (2062, 158), (1901, 110)
    ]
    private let priorityPoints: [(Float, Float)] = [(1000, 500), (1100, 550)]

    // MARK: - Run

    func run() {
        guard !isRunning else { return }
        aiCallCount = 0; lastAICall = nil; elapsed = 0; loginTapped = false
        isRunning = true; status = "启动中"; logs = ""; onUpdate?()
        Logger.log("=== HOK Auto IOKit直驱 ===")

        // AI 快速检测
        status = "AI检测..."
        DispatchQueue.global().async {
            let sem = DispatchSemaphore(value: 0)
            var aiOk = false
            DeepSeekClient.chat("ping") { if case .success = $0 { aiOk = true }; sem.signal() }
            _ = sem.wait(timeout: .now() + 2)

            DispatchQueue.main.async {
                Logger.log(aiOk ? "AI已连接" : "离线模式")
                self.status = aiOk ? "AI就绪" : "离线模式"
                self.launchGame()
            }
        }
    }

    private func launchGame() {
        log("启动王者荣耀"); status = "启动中"
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("已启动")
        } else { log("失败"); isRunning = false; onUpdate?(); return }
        onUpdate?()

        // 每 3 秒主循环
        mainTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.tick() }
        // 每 3 秒 AI 轮询检查
        dsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.checkDS() }
    }

    // MARK: - 主循环 (纯IOKit触控, 无AutoTouch/Lua)

    private func tick() {
        guard isRunning else { mainTimer?.invalidate(); return }
        elapsed += 3
        status = "检测 \(elapsed)s"; onUpdate?()

        // ① 最高优先级弹窗
        for pt in priorityPoints { ve_click(pt.0, pt.1); usleep(200000) }

        // ② 取消按钮
        ve_click(cancelPoint.x, cancelPoint.y); usleep(300000)

        // ③ 关闭弹窗 (6个录制位置)
        for pt in closePoints { ve_click(pt.0, pt.1); usleep(200000) }

        // ④ AI未命中→触发DeepSeek (每15s限流)
        if aiCallCount < aiMaxCalls, let last = lastAICall, Date().timeIntervalSince(last) < 15 {
            // skip
        } else {
            triggerAI()
        }

        // ⑤ 30s后点登录
        if elapsed >= 30, !loginTapped {
            log("点击登录"); status = "点击登录"
            ve_click(loginPoint.x, loginPoint.y)
            loginTapped = true
            Logger.log("登录已点击")
        }

        // ⑥ 超时
        if elapsed >= 100 { stop() }
    }

    // MARK: - DeepSeek AI

    private func triggerAI() {
        guard aiCallCount < aiMaxCalls else { return }
        if let last = lastAICall, Date().timeIntervalSince(last) < 15 { return }
        aiCallCount += 1; lastAICall = Date()
        Logger.log("AI调用 \(aiCallCount)/\(aiMaxCalls)")

        // 截图 → 上传 VL
        guard let img = captureScreen() else { Logger.log("截图失败"); return }
        status = "AI分析..."; onUpdate?()

        DeepSeekClient.analyze(image: img, prompt: "识别弹窗关闭按钮坐标,返回JSON") { result in
            DispatchQueue.main.async {
                if case .success(let text) = result {
                    Logger.log("AI返回: \(text.prefix(100))")
                    // 提取坐标并点击
                    if let x = self.extractCoord(text, key: "x"),
                       let y = self.extractCoord(text, key: "y") {
                        ve_click(Float(x), Float(y))
                        Logger.log("AI点击: (\(x),\(y))")
                    }
                }
            }
        }
    }

    private func extractCoord(_ text: String, key: String) -> Int? {
        guard let range = text.range(of: "\"\(key)\":\\s*(\\d+)", options: .regularExpression),
              let numRange = text[range].range(of: "\\d+", options: .regularExpression)
        else { return nil }
        return Int(text[numRange])
    }

    // MARK: - 截图 (IOSurface 私有API)

    private func captureScreen() -> UIImage? {
        // 暂用 UIKit snapshot (仅截本app)
        guard let window = UIApplication.shared.windows.first else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
    }

    // MARK: - Helpers

    private func stop() {
        mainTimer?.invalidate(); dsTimer?.invalidate()
        status = "完成"; log("完成"); isRunning = false; onUpdate?()
    }

    private func log(_ msg: String) { logs += msg + "\n"; Logger.log(msg) }
}
