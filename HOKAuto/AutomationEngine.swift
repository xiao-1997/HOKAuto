import UIKit

class AutomationEngine {
    var status = "就绪" { didSet { FloatingHUD.shared.setStatus(status) } }
    var logs = ""
    var isRunning = false { didSet { if !isRunning { FloatingHUD.shared.hide() } } }
    var onUpdate: (() -> Void)?

    private var mainTimer: Timer?
    private var elapsed = 0
    private var aiCallCount = 0, aiMaxCalls = 5
    private var lastAICall: Date?
    private var loginTapped = false

    private let cancelPoint = (Float(1340), Float(732))
    private let loginPoint  = (Float(1209), Float(945))
    private let closePoints: [(Float, Float)] = [(1896,124),(1898,146),(1876,99),(2066,146),(2062,158),(1901,110)]
    private let priorityPoints: [(Float, Float)] = [(1000,500),(1100,550)]
    private let imgDir = "/var/mobile/Documents/HOKAuto/Images"

    // MARK: - Run

    func run() {
        guard !isRunning else { return }
        aiCallCount = 0; lastAICall = nil; elapsed = 0; loginTapped = false
        isRunning = true; status = "启动中"; logs = ""; onUpdate?()
        Logger.log("=== HOK Auto ===")

        try? FileManager.default.createDirectory(atPath: imgDir, withIntermediateDirectories: true)
        migrateImages()

        status = "AI检测..."
        DispatchQueue.global().async {
            let sem = DispatchSemaphore(value: 0); var ok = false
            DeepSeekClient.chat("ping") { if case .success = $0 { ok = true }; sem.signal() }
            _ = sem.wait(timeout: .now() + 2)
            DispatchQueue.main.async { self.launch() }
        }
    }

    private func launch() {
        log("启动王者荣耀"); status = "启动中"
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }; log("已启动")
        } else { log("失败"); isRunning = false; onUpdate?(); return }
        onUpdate?()
        mainTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.tick() }
    }

    private func tick() {
        guard isRunning else { mainTimer?.invalidate(); return }
        elapsed += 3; status = "检测 \(elapsed)s"; onUpdate?()

        // ① 优先弹窗
        for pt in priorityPoints { click(pt.0, pt.1); usleep(150000) }
        // ② 取消
        click(cancelPoint.0, cancelPoint.1); usleep(250000)
        // ③ 关闭
        for pt in closePoints { click(pt.0, pt.1); usleep(150000) }

        // ④ OCR
        if let screen = ScreenCapture.capture(maxWidth: 400, quality: 0.3) {
            if let first = LocalVision.detectKeywords(screen).first {
                click(first.x, first.y); Logger.log("OCR: \(first.text)")
            }
        }

        // ⑤ AI (每15s一次, OCR无结果时)
        let now = Date()
        if aiCallCount < aiMaxCalls,
           lastAICall == nil || now.timeIntervalSince(lastAICall!) >= 15 {
            triggerAI()
        }

        // ⑥ 登录
        if elapsed >= 30, !loginTapped {
            click(loginPoint.0, loginPoint.1); loginTapped = true
        }

        if elapsed >= 100 { stop() }
    }

    // MARK: - Touch

    private func click(_ x: Float, _ y: Float) {
        let cmd = "su mobile -c '/usr/bin/autotouch touchDown 0 \(Int(x)) \(Int(y)); sleep 0.05; /usr/bin/autotouch touchUp 0 \(Int(x)) \(Int(y))'"
        let a: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
        defer { a.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, nil, a, nil)
        var s: Int32 = 0; waitpid(pid, &s, 0)
        if MacroRecorder.isRecording { MacroRecorder.record(x: x, y: y, source: "auto", label: "") }
    }

    func tapNoRecord(_ x: Float, _ y: Float) { click(x, y) }

    // MARK: - Macro

    func replayMacro(name: String) {
        MacroRecorder.smartReplay(name: name, engine: self)
    }

    func saveMacro(name: String) -> Bool { MacroRecorder.save(name) }

    // MARK: - AI (VL2 视觉 + 降级纯文本)

    private func triggerAI() {
        guard aiCallCount < aiMaxCalls else { return }
        if let last = lastAICall, Date().timeIntervalSince(last) < 15 { return }
        aiCallCount += 1; lastAICall = Date()
        Logger.log("AI \(aiCallCount)/\(aiMaxCalls)")

        guard let img = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { return }
        DeepSeekClient.analyze(image: img, prompt: "游戏1242x2208横屏。识别弹窗关闭按钮坐标,返回JSON:{\"x\":数字,\"y\":数字}") { r in
            if case .success(let t) = r,
               let x = self.extractCoord(t, "x"), let y = self.extractCoord(t, "y") {
                DispatchQueue.main.async { self.click(Float(x), Float(y)) }
            }
        }
    }

    private func extractCoord(_ t: String, _ k: String) -> Int? {
        guard let r = t.range(of: "\"\(k)\":\\s*(\\d+)", options: .regularExpression),
              let n = t[r].range(of: "\\d+", options: .regularExpression) else { return nil }
        return Int(t[n])
    }

    // MARK: - Helpers

    private func migrateImages() {
        let old = "/var/mobile/Library/AutoTouch/Scripts/Images"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: old)) ?? [] {
            let s="\(old)/\(f)", d="\(imgDir)/\(f)"
            if !FileManager.default.fileExists(atPath: d) { try? FileManager.default.copyItem(atPath: s, toPath: d) }
        }
    }

    private func stop() { mainTimer?.invalidate(); status = "完成"; log("完成"); isRunning = false; onUpdate?() }
    private func log(_ msg: String) { logs += msg + "\n"; Logger.log(msg) }
}
