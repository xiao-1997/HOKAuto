import UIKit

class AutomationEngine {
    var status = "就绪" { didSet { FloatingHUD.shared.setStatus(status) } }
    var logs = ""
    var isRunning = false { didSet { if !isRunning { FloatingHUD.shared.hide() } } }
    var onUpdate: (() -> Void)?

    private var mainTimer: Timer?
    private var elapsed = 0
    private var loginTapped = false

    // 自适应视觉校验: 5→10→20
    private var verifyInterval = 5
    private var consecutiveOk = 0
    private var tickCount = 0

    // 坐标缓存
    private let coordFile = "/tmp/hok_coords.json"
    private var cancelPt: (Float, Float) = (1340, 732)
    private var loginPt:  (Float, Float) = (1209, 945)
    private var closePts: [(Float, Float)] = [(1896,124),(1898,146),(1876,99),(2066,146),(2062,158),(1901,110)]
    private var priorityPts: [(Float, Float)] = [(1000,500),(1100,550)]
    private var knownPopups: [String: (Float, Float)] = [:]
    private let imgDir = "/var/mobile/Documents/HOKAuto/Images"

    // 本地OCR调用限频
    private var lastLocalScan: Date?

    // MARK: - Run

    func run() {
        guard !isRunning else { return }
        elapsed = 0; loginTapped = false; lastLocalScan = nil
        tickCount = 0; verifyInterval = 5; consecutiveOk = 0
        loadCoords()
        isRunning = true; status = "启动中"; logs = ""; onUpdate?()
        Logger.log("=== HOK Auto ===")

        try? FileManager.default.createDirectory(atPath: imgDir, withIntermediateDirectories: true)
        migrateImages()

        status = "本地识别"
        DispatchQueue.main.async { self.launch() }
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

        // ① 优先弹窗 (缓存坐标)
        for pt in priorityPts { click(pt.0, pt.1); usleep(150000) }
        // ② 取消
        click(cancelPt.0, cancelPt.1); usleep(250000)
        // ③ 关闭
        for pt in closePts { click(pt.0, pt.1); usleep(150000) }

        // ④ 自适应视觉校验
        let needVerify = (tickCount % verifyInterval == 0)
        if needVerify {
            Logger.log("视觉校验(每\(verifyInterval)次) 连续OK:\(consecutiveOk)")
            verifyButtons()
        }

        // ⑤ 本地OCR扫描 (每15s一次，非校验轮)
        let now = Date()
        if !needVerify,
           lastLocalScan == nil || now.timeIntervalSince(lastLocalScan!) >= 15 {
            triggerLocalOCR()
        }

        // ⑥ 登录(缓存坐标)
        if elapsed >= 30, !loginTapped {
            click(loginPt.0, loginPt.1); loginTapped = true
            Logger.log("登录: (\(Int(loginPt.0)),\(Int(loginPt.1)))")
        }

        // ⑦ 30s未登录→本地OCR重录坐标
        if elapsed >= 30, !loginTapped {
            forceLocalRecord()
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

    // MARK: - 自适应视觉校验（纯本地OCR）

    private func verifyButtons() {
        guard let screen = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { verificationFailed(); return }

        // 先尝试已知弹窗位置
        for (label, pt) in knownPopups {
            click(pt.0, pt.1); usleep(300000)
            Logger.log("已知弹窗:\(label)")
        }

        // 关键词快速命中
        let kwHits = LocalVision.detectKeywords(screen)
        let targetKW = ["关闭","取消","登录","确定"]
        if kwHits.contains(where: { h in targetKW.contains(where: { h.text.contains($0) }) }) {
            for h in kwHits {
                click(h.x, h.y); usleep(200000)
                if !knownPopups.keys.contains(h.text) {
                    knownPopups[h.text] = (h.x, h.y)
                    Logger.log("新弹窗记录:\(h.text) (\(Int(h.x)),\(Int(h.y)))")
                }
            }
            verificationPassed(); return
        }

        // 关键词未命中→全量OCR扫描
        let all = LocalVision.ocrSync(image: screen)
        for (text, rect) in all {
            if targetKW.contains(where: { text.contains($0) }) {
                let x = Float(rect.midX * 1242)
                let y = Float(rect.midY * 2208)
                click(x, y); usleep(200000)
                knownPopups[text] = (x, y)
                Logger.log("全量OCR命中:\(text) (\(Int(x)),\(Int(y)))")
                verificationPassed(); return
            }
        }

        verificationFailed()
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

    // MARK: - 坐标缓存

    private func loadCoords() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: coordFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let c = json["cancel"] as? [Float], c.count == 2 { cancelPt = (c[0], c[1]) }
        if let l = json["login"] as? [Float],  l.count == 2 { loginPt  = (l[0], l[1]) }
        if let arr = json["close"] as? [[Float]] { closePts = arr.map { ($0[0], $0[1]) } }
        Logger.log("加载缓存坐标: 取消(\(Int(cancelPt.0)),\(Int(cancelPt.1))) 登录(\(Int(loginPt.0)),\(Int(loginPt.1)))")
    }

    private func saveCoords() {
        let json: [String: Any] = [
            "cancel": [cancelPt.0, cancelPt.1],
            "login":  [loginPt.0, loginPt.1],
            "close":  closePts.map { [$0.0, $0.1] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: URL(fileURLWithPath: coordFile))
            Logger.log("坐标已保存")
        }
    }

    // MARK: - 本地OCR扫描

    /// 定期全量OCR扫描，发现弹窗按钮即点击
    private func triggerLocalOCR() {
        lastLocalScan = Date()
        Logger.log("本地OCR扫描")

        guard let img = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { return }
        let results = LocalVision.ocrSync(image: img)

        if results.isEmpty { Logger.log("本地OCR: 无文字"); return }

        let targetKW = ["取消", "关闭", "暂不", "确定", "登录", "X"]
        var hitCount = 0
        for (text, rect) in results {
            if targetKW.contains(where: { text.contains($0) }) {
                let x = Float(rect.midX * 1242)
                let y = Float(rect.midY * 2208)
                if x > 0, y > 0 {
                    click(x, y); usleep(150000)
                    Logger.log("本地OCR点击:\(text) (\(Int(x)),\(Int(y)))")
                    hitCount += 1
                }
            }
        }
        if hitCount == 0 { Logger.log("本地OCR: 未命中关键词") }
    }

    /// 30s未登录→本地OCR重录坐标
    private func forceLocalRecord() {
        lastLocalScan = Date()
        Logger.log("本地OCR重录坐标")

        guard let img = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { return }
        let results = LocalVision.ocrSync(image: img)

        var foundCancel = false, foundLogin = false
        for (text, rect) in results {
            let x = Float(rect.midX * 1242)
            let y = Float(rect.midY * 2208)
            if x <= 0 || y <= 0 { continue }

            if text.contains("取消") && !foundCancel {
                cancelPt = (x, y); foundCancel = true
            } else if text.contains("登录") && !foundLogin {
                loginPt = (x, y); foundLogin = true
            } else if text.contains("关闭") {
                if !closePts.contains(where: { abs($0.0-x)<5 && abs($0.1-y)<5 }) {
                    closePts.append((x, y))
                }
            }
        }
        if foundCancel || foundLogin {
            saveCoords()
            Logger.log("本地重录完成 取消(\(Int(cancelPt.0)),\(Int(cancelPt.1))) 登录(\(Int(loginPt.0)),\(Int(loginPt.1)))")
        } else {
            Logger.log("本地重录: 未找到按钮")
        }
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
