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

    // 固定坐标 (1242x2208 Landscape)
    private let cancelPoint = (Float(1340), Float(732))
    private let loginPoint  = (Float(1209), Float(945))
    private let closePoints: [(Float, Float)] = [
        (1896,124),(1898,146),(1876,99),(2066,146),(2062,158),(1901,110)
    ]
    private let priorityPoints: [(Float, Float)] = [(1000,500),(1100,550)]

    // 模板名称
    private let templates = ["cancel_btn","close_btn","close_btn2","x_btn","skip_btn","announce_x","alert_clean","login_btn"]
    private let imgDir = "/var/mobile/Documents/HOKAuto/Images"

    // MARK: - Run

    func run() {
        guard !isRunning else { return }
        aiCallCount = 0; lastAICall = nil; elapsed = 0; loginTapped = false
        MacroRecorder.startSession()
        isRunning = true; status = "启动中"; logs = ""; onUpdate?()
        Logger.log("=== HOK Auto 4层视觉 ===")

        status = "AI检测..."
        DispatchQueue.global().async {
            let sem = DispatchSemaphore(value: 0); var ok = false
            DeepSeekClient.chat("ping") { if case .success = $0 { ok = true }; sem.signal() }
            _ = sem.wait(timeout: .now() + 2)
            DispatchQueue.main.async {
                Logger.log(ok ? "AI在线" : "离线模式")
                self.launch()
            }
        }
    }

    private func launch() {
        // 确保图片目录存在
        try? FileManager.default.createDirectory(atPath: imgDir, withIntermediateDirectories: true)
        // 从旧位置迁移图片
        let oldDir = "/var/mobile/Library/AutoTouch/Scripts/Images"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: oldDir)) ?? [] {
            let src = "\(oldDir)/\(f)"; let dst = "\(imgDir)/\(f)"
            if !FileManager.default.fileExists(atPath: dst) {
                try? FileManager.default.copyItem(atPath: src, toPath: dst)
            }
        }

        log("启动王者荣耀"); status = "启动中"
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }; log("已启动")
        } else { log("失败"); isRunning = false; onUpdate?(); return }
        onUpdate?()
        mainTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.tick() }
    }

    // MARK: - 4层视觉主循环

    private func tick() {
        guard isRunning else { mainTimer?.invalidate(); return }
        elapsed += 3
        status = "检测 \(elapsed)s"; onUpdate?()

        // ── 第一层: 固定坐标(最快) ──
        for pt in priorityPoints { tap(pt.0, pt.1, source: "fixed", label: "priority"); usleep(150000) }
        tap(cancelPoint.0, cancelPoint.1, source: "fixed", label: "cancel"); usleep(250000)
        for (i, pt) in closePoints.enumerated() { tap(pt.0, pt.1, source: "fixed", label: "close\(i)"); usleep(150000) }

        // ── 第二层: 本地模板匹配 ──
        if let screen = ScreenCapture.capture(maxWidth: 400, quality: 0.3) {
            if let (pt, name) = LocalVision.matchBest(screen: screen, templates: templates,
                imgDir: imgDir, threshold: 0.5) {
                let scaledX = Float(pt.x / screen.size.width * 1242)
                let scaledY = Float(pt.y / screen.size.height * 2208)
                tap(scaledX, scaledY, source: "template", label: name)
                Logger.log("模板命中: \(name)")
            }

            // ── 第三层: OCR文字识别 ──
            let texts = LocalVision.ocrSync(image: screen, timeout: 2)
            for (text, rect) in texts {
                let kw = ["关闭","取消","确定","暂不","登录","公告","福利","商城"]
                if kw.contains(where: { text.contains($0) }) {
                    let x = Float(rect.midX * 1242), y = Float(rect.midY * 2208)
                    ve_click(x, y)
                    Logger.log("OCR命中: \(text) (\(x),\(y))")
                    break
                }
            }
        }

        // ── 第四层: DeepSeek AI推理 ──
        triggerAI()

        // ── 30s点登录 ──
        if elapsed >= 30, !loginTapped {
            log("点击登录"); ve_click(loginPoint.0, loginPoint.1)
            loginTapped = true; Logger.log("登录已点击")
        }

        if elapsed >= 100 { stop() }
    }

    // MARK: - AI

    private func triggerAI() {
        guard aiCallCount < aiMaxCalls else { return }
        if let last = lastAICall, Date().timeIntervalSince(last) < 15 { return }
        aiCallCount += 1; lastAICall = Date()

        guard let img = ScreenCapture.capture(maxWidth: 400, quality: 0.3) else { return }
        status = "AI分析..."; onUpdate?()

        DeepSeekClient.analyze(image: img, prompt: "识别弹窗关闭按钮坐标,JSON:{x:数字,y:数字}") { result in
            DispatchQueue.main.async {
                if case .success(let txt) = result {
                    Logger.log("AI: \(txt.prefix(80))")
                    if let x = self.extract(txt, "x"), let y = self.extract(txt, "y") {
                        ve_click(Float(x), Float(y))
                    }
                }
            }
        }
    }

    private func extract(_ t: String, _ k: String) -> Int? {
        guard let r = t.range(of: "\"\(k)\":\\s*(\\d+)", options: .regularExpression),
              let n = t[r].range(of: "\\d+", options: .regularExpression) else { return nil }
        return Int(t[n])
    }

    // MARK: - Helpers

    // MARK: - 触控 (AutoTouch via su mobile)

    private func tap(_ x: Float, _ y: Float, source: String, label: String = "") {
        let cmd = "su mobile -c '/usr/bin/autotouch touchDown 0 \(Int(x)) \(Int(y)); sleep 0.05; /usr/bin/autotouch touchUp 0 \(Int(x)) \(Int(y))'"
        let a: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
        defer { a.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, nil, a, nil)
        var s: Int32 = 0; waitpid(pid, &s, 0)
        MacroRecorder.record(x: x, y: y, source: source, label: label)
    }

    /// 回放已保存的宏
    func replayMacro(name: String) {
        guard let steps = MacroRecorder.load(name) else { return }
        Logger.log("回放: \(name) (\(steps.count)步)")
        DispatchQueue.global().async {
            for (i, s) in steps.enumerated() {
                DispatchQueue.main.async { self.status = "回放 \(i+1)/\(steps.count)"; self.onUpdate?() }
                self.tap(s.x, s.y, source: "replay", label: s.label)
                usleep(200000)
            }
            DispatchQueue.main.async { self.status = "回放完成" }
        }
    }

    func saveMacro(name: String) -> Bool { return MacroRecorder.save(name) }

    private func stop() {
        mainTimer?.invalidate(); dsTimer?.invalidate()
        MacroRecorder.stopSession()
        status = "完成"; log("完成"); isRunning = false; onUpdate?()
    }

    private func log(_ msg: String) { logs += msg + "\n"; Logger.log(msg) }
}
