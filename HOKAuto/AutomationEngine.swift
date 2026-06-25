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

    // 自适应视觉校验: 5→10→20
    private var verifyInterval = 5        // 当前校验间隔(轮次)
    private var consecutiveOk = 0         // 连续成功次数
    private var tickCount = 0             // 总轮次计数

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
        elapsed += 3; tickCount += 1
        status = "检测 \(elapsed)s [校验:\(tickCount)/\(verifyInterval)]"; onUpdate?()

        // ① 优先弹窗
        for pt in priorityPoints { click(pt.0, pt.1); usleep(150000) }
        // ② 取消
        click(cancelPoint.0, cancelPoint.1); usleep(250000)
        // ③ 关闭
        for pt in closePoints { click(pt.0, pt.1); usleep(150000) }

        // ④ 自适应视觉校验
        let needVerify = (tickCount % verifyInterval == 0)
        if needVerify {
            Logger.log("视觉校验(每\(verifyInterval)次) 连续OK:\(consecutiveOk)")
            verifyButtons()
        }

        // ⑤ AI (每15s一次)
        let now = Date()
        if aiCallCount < aiMaxCalls,
           lastAICall == nil || now.timeIntervalSince(lastAICall!) >= 15,
           !needVerify {  // 非校验轮才调AI节省成本
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

    // MARK: - 自适应视觉校验

    private func verifyButtons() {
        guard let screen = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { verificationFailed(); return }
        let imgW = Float(screen.size.width * screen.scale)
        let imgH = Float(screen.size.height * screen.scale)

        let ocrHits = LocalVision.detectKeywords(screen)
        if ocrHits.contains(where: { $0.text.contains("关闭")||$0.text.contains("取消")||$0.text.contains("登录") }) {
            for h in ocrHits { click(h.x, h.y); usleep(200000) }
            verificationPassed(); return
        }

        // OCR未命中→VL2
        let prompt = "截图(\(Int(imgW))x\(Int(imgH)))。返回JSON:{\"close_button\":{\"x\":0,\"y\":0},\"cancel_button\":{\"x\":0,\"y\":0}}"
        DeepSeekClient.analyze(image: screen, prompt: prompt) { r in
            var found = false
            if case .success(let t) = r {
                let sx: Float = 1242/imgW, sy: Float = 2208/imgH
                for (k,label) in [("close_button","关闭"),("cancel_button","取消")] {
                    if let cx = self.extractCoord(t,k,"x"), let cy = self.extractCoord(t,k,"y"), cx>0,cy>0 {
                        self.click(cx*sx, cy*sy); found = true
                        Logger.log("校验VL2:\(label)")
                    }
                }
            }
            found ? self.verificationPassed() : self.verificationFailed()
        }
    }

    private func verificationPassed() {
        consecutiveOk += 1
        Logger.log("校验通过 连续OK:\(consecutiveOk) 间隔:\(verifyInterval)")
        if consecutiveOk >= 3 {
            if verifyInterval == 5 { verifyInterval = 10; Logger.log("升级→每10次") }
            else if verifyInterval == 10 { verifyInterval = 20; Logger.log("升级→每20次") }
            consecutiveOk = 0
        }
    }

    private func verificationFailed() {
        Logger.log("校验失败 重置→每5次")
        verifyInterval = 5; consecutiveOk = 0
    }

    // MARK: - V4 Pro 视觉识别

    private func triggerAI() {
        guard aiCallCount < aiMaxCalls else { return }
        if let last = lastAICall, Date().timeIntervalSince(last) < 15 { return }
        aiCallCount += 1; lastAICall = Date()
        Logger.log("VL2 \(aiCallCount)/\(aiMaxCalls)")

        guard let img = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { return }
        let imgW = Float(img.size.width * img.scale)
        let imgH = Float(img.size.height * img.scale)

        let prompt = """
        王者荣耀横屏截图(\(Int(imgW))x\(Int(imgH)))。找到弹窗上的按钮并返回JSON坐标:
        {"cancel_button":{"x":0,"y":0},"close_button":{"x":0,"y":0},"skip_button":{"x":0,"y":0}}
        没有某按钮则填null。原点左上角。
        """

        DeepSeekClient.analyze(image: img, prompt: prompt) { r in
            if case .success(let t) = r {
                Logger.log("VL2: \(t.prefix(120))")

                // 坐标映射: 图片 → 屏幕 (1242x2208)
                let sw: Float = 1242, sh: Float = 2208
                let sx = sw / imgW, sy = sh / imgH

                // 解析按钮坐标
                let btns: [(String, String)] = [("cancel_button","取消"),("close_button","关闭"),("skip_button","暂不参与")]
                for (key, label) in btns {
                    if let cx = self.extractCoord(t, key, "x"),
                       let cy = self.extractCoord(t, key, "y") {
                        let mx = cx * sx, my = cy * sy
                        if mx > 0, my > 0 {
                            DispatchQueue.main.async {
                                self.click(mx, my)
                                Logger.log("VL2点击:\(label) (\(Int(mx)),\(Int(my)))")
                            }
                        }
                    }
                }
            }
        }
    }

    /// 解析嵌套JSON坐标: "cancel_button":{"x":200,"y":380} → Float
    private func extractCoord(_ t: String, _ btn: String, _ axis: String) -> Float? {
        let pattern = "\"\(btn)\"[^}]*\"\(axis)\":\\s*(\\d+)"
        guard let r = t.range(of: pattern, options: .regularExpression),
              let n = t[r].range(of: "\\d+", options: .regularExpression) else { return nil }
        return Float(t[n])
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
