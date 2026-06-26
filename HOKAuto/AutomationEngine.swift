import UIKit

class AutomationEngine {
    var status = "就绪" { didSet { FloatingHUD.shared.setStatus(status) } }
    var logs = ""
    var isRunning = false { didSet { if !isRunning { FloatingHUD.shared.hide() } } }
    var onUpdate: (() -> Void)?

    private var mainTimer: Timer?
    private var elapsed = 0
    private var loginTapped = false
    private var gameLoaded = false

    // 自适应校验: 5→10→20
    private var verifyInterval = 5
    private var consecutiveOk = 0
    private var tickCount = 0

    // 新架构组件
    let yolo = YOLODetector()
    let semantic = SemanticEngine()
    let cache = CoordCache.shared
    var executor: TaskExecutor?
    var isExecutingTask = false { didSet { onUpdate?() } }

    // 本地OCR调用限频
    private var lastLocalScan: Date?

    // 屏幕分辨率常量
    private let refW: Float = 1242
    private let refH: Float = 2208

    private let imgDir = "/var/mobile/Documents/HOKAuto/Images"

    // MARK: - Run / Stop

    func run() {
        guard !isRunning else { return }
        elapsed = 0; loginTapped = false; lastLocalScan = nil
        tickCount = 0; verifyInterval = 5; consecutiveOk = 0
        isRunning = true; status = "启动中"; logs = ""; onUpdate?()
        Logger.log("=== HOK Auto ===")

        try? FileManager.default.createDirectory(atPath: imgDir, withIntermediateDirectories: true)
        migrateImages()

        // 自动开始录制人工点击
        MacroRecorder.isRecording = true
        MacroRecorder.startSession()
        Logger.log("开始录制人工点击")

        // 调试模式：截图保存到相册（调试时开启，正式关闭）
        ScreenCapture.debugSaveToPhotos = true

        // 异步预热 YOLO 模型
        DispatchQueue.global().async { _ = self.yolo.loadModel() }

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

    private func stop() {
        mainTimer?.invalidate()
        // 自动保存录制
        if MacroRecorder.isRecording {
            let name = "auto_\(Int(Date().timeIntervalSince1970))"
            if MacroRecorder.save(name) {
                Logger.log("录制已保存: \(name)")
                log("录制已保存: \(name)")
            }
            MacroRecorder.isRecording = false
        }
        status = "完成"; log("完成"); isRunning = false; onUpdate?()
        CoordCache.shared.save()
    }

    // MARK: - Tick（空闲模式：弹窗守护）

    /// 游戏大厅关键词（检测到则判定加载完成）
    private let lobbyKeywords = ["开始游戏", "商城", "英雄", "备战", "铭文"]

    private func tick() {
        guard isRunning else { mainTimer?.invalidate(); return }

        // ── 任务模式：暂停盲打循环 ──
        if isExecutingTask { return }

        elapsed += 3; tickCount += 1

        // ── 游戏加载检测 ──
        if !gameLoaded {
            guard let screen = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { return }
            let results = LocalVision.ocrSync(image: screen)
            let allText = results.map { $0.text }.joined(separator: " ")
            if lobbyKeywords.contains(where: { allText.contains($0) }) {
                gameLoaded = true
                status = "已加载，冷却中"; onUpdate?()
                Logger.log("游戏加载完成，等待10s冷却")
            } else {
                status = "等待加载 \(elapsed)s"; onUpdate?()
                Logger.log("等待加载...")
            }
            return
        }

        // ── 加载后 10s 冷却期：不动，等游戏稳定 ──
        if elapsed < 10 {
            status = "冷却 \(elapsed)/10s"; onUpdate?()
            return
        }

        // ── 加载后 20s 开始截图检测登录 ──
        if !loginTapped, elapsed >= 20 {
            status = "检测登录 \(elapsed)s"; onUpdate?()
            Logger.log("截图检测登录")
            guard let screen = ScreenCapture.capture(maxWidth: 640, quality: 0.5) else { return }
            let command = semantic.parse("点击登录按钮")
            if let hit = semantic.findTarget(command: command, cache: cache,
                                             screen: screen, yolo: yolo) {
                click(hit.x, hit.y); loginTapped = true
                Logger.log("登录: (\(Int(hit.x)),\(Int(hit.y))) [\(hit.source)]")
            } else {
                // 登录未命中，继续弹窗消除
            }
        }

        status = "守护 \(elapsed)s"; onUpdate?()

        // ① 弹窗消除（CoordCache 快速路径）
        let popups = cache.popupEntries()
        if !popups.isEmpty {
            for entry in popups.prefix(5) {
                click(entry.x, entry.y); usleep(200000)
            }
            cache.touch(popups.first!.label)
        }

        // ② 自适应OCR校验（每N轮）
        let needVerify = (tickCount % verifyInterval == 0)
        if needVerify {
            Logger.log("视觉校验(每\(verifyInterval)次) 连续OK:\(consecutiveOk)")
            verifyWithCache()
        }

        // ③ 全量OCR扫描（非校验轮，每5s）
        let now = Date()
        if !needVerify,
           lastLocalScan == nil || now.timeIntervalSince(lastLocalScan!) >= 5 {
            scanAndCache()
        }

        if elapsed >= 600 { stop() } // 10分钟自动停止
    }

    // MARK: - 校验（CoordCache + OCR）

    private func verifyWithCache() {
        guard let screen = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { verificationFailed(); return }

        // 缓存弹窗坐标快速消除
        for entry in cache.popupEntries() {
            click(entry.x, entry.y); usleep(250000)
        }
        usleep(300000)

        // OCR 关键词检测
        let kwHits = LocalVision.detectKeywords(screen)
        let targetKW = ["关闭", "取消", "登录", "确定"]
        let hasKeyword = kwHits.contains { h in targetKW.contains { h.text.contains($0) } }

        if hasKeyword {
            for h in kwHits {
                click(h.x, h.y); usleep(200000)
                cache.set(label: "弹窗_\(h.text)", x: h.x, y: h.y, source: "ocr")
            }
            verificationPassed(); return
        }

        // 全量OCR扫描
        let all = LocalVision.ocrSync(image: screen)
        for (text, rect) in all {
            if targetKW.contains(where: { text.contains($0) }) {
                let x = Float(rect.midX * CGFloat(refW))
                let y = Float(rect.midY * CGFloat(refH))
                click(x, y); usleep(200000)
                cache.set(label: "弹窗_\(text)", x: x, y: y, source: "ocr")
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

    // MARK: - 定期OCR扫描

    private func scanAndCache() {
        lastLocalScan = Date()
        Logger.log("定期OCR扫描")

        guard let img = ScreenCapture.capture(maxWidth: 600, quality: 0.4) else { return }
        let results = LocalVision.ocrSync(image: img)

        if results.isEmpty { Logger.log("OCR: 无文字"); return }

        let targetKW = ["取消", "关闭", "暂不", "确定", "登录", "X"]
        var hitCount = 0
        for (text, rect) in results {
            if targetKW.contains(where: { text.contains($0) }) {
                let x = Float(rect.midX * CGFloat(refW))
                let y = Float(rect.midY * CGFloat(refH))
                if x > 0, y > 0 {
                    click(x, y); usleep(150000)
                    cache.set(label: "弹窗_\(text)", x: x, y: y, source: "ocr")
                    Logger.log("OCR点击:\(text) (\(Int(x)),\(Int(y)))")
                    hitCount += 1
                }
            }
        }
        if hitCount == 0 { Logger.log("OCR: 未命中关键词") }
    }

    // MARK: - 任务模式

    /// 用户下达高层指令入口
    func runTask(_ goal: String) {
        guard isRunning else { Logger.log("请先启动引擎"); return }

        // 1. 解析参数
        let amount = TaskTemplate.extractAmount(from: goal)
        let password = TaskTemplate.extractPassword(from: goal)

        // 2. 优先匹配预置模板
        var steps: [TaskStep] = []
        if let template = TaskTemplate.match(goal: goal) {
            Logger.log("匹配模板: \(template.name)")
            steps = template.steps
        }
        // 如果模板有 {amount} 占位且提取到了实际金额，填充实际金额
        if let amt = amount {
            steps = steps.map { step in
                var s = step
                if s.target.contains("{amount}") { s = TaskStep(
                    id: s.id, action: s.action,
                    target: s.target.replacingOccurrences(of: "{amount}", with: amt),
                    coordLabel: s.coordLabel.replacingOccurrences(of: "{amount}", with: amt),
                    maxRetries: s.maxRetries, waitAfter: s.waitAfter,
                    verifyText: s.verifyText?.replacingOccurrences(of: "{amount}", with: amt),
                    optional: s.optional
                )}
                if s.verifyText?.contains("{amount}") ?? false {
                    s = TaskStep(id: s.id, action: s.action, target: s.target,
                                 coordLabel: s.coordLabel, maxRetries: s.maxRetries,
                                 waitAfter: s.waitAfter,
                                 verifyText: s.verifyText?.replacingOccurrences(of: "{amount}", with: amt),
                                 optional: s.optional)
                }
                return s
            }
        }

        // 3. 模板匹配失败 → DeepSeek 动态规划
        if steps.isEmpty {
            Logger.log("无匹配模板，请求 DeepSeek 规划...")
            FloatingHUD.shared.setStatus("AI规划中")
            let sem = DispatchSemaphore(value: 0)
            var planned: [TaskStep]?
            DeepSeekClient.planTask(goal) { result in
                if case .success(let s) = result { planned = s }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 12)
            guard let p = planned, !p.isEmpty else {
                Logger.log("DeepSeek规划失败，无法执行任务")
                FloatingHUD.shared.setStatus("规划失败")
                return
            }
            steps = p
            Logger.log("DeepSeek规划: \(steps.count)步")
        }

        // 如果有密码参数，追加到最后一个 input_text 步骤
        if let pw = password {
            for i in 0..<steps.count where steps[i].action == "input_text" {
                steps[i] = TaskStep(
                    id: steps[i].id, action: steps[i].action,
                    target: "输入密码(\(pw.prefix(1))***)",
                    coordLabel: steps[i].coordLabel,
                    maxRetries: steps[i].maxRetries,
                    waitAfter: steps[i].waitAfter,
                    verifyText: steps[i].verifyText,
                    optional: steps[i].optional
                )
            }
        }

        // 4. 启动任务执行
        isExecutingTask = true
        status = "任务中"; onUpdate?()
        executor = TaskExecutor(engine: self, yolo: yolo, semantic: semantic, cache: cache)
        executor?.run(steps: steps, onProgress: { progress in
            FloatingHUD.shared.showTaskProgress(progress)
        }, completion: { result in
            self.isExecutingTask = false
            self.status = result.success ? "任务完成" : "任务失败"
            self.onUpdate?()
            FloatingHUD.shared.showTaskResult(result)
            Logger.log("任务结果: \(result.success ? "成功" : "失败") \(result.completedSteps)/\(result.totalSteps)步")
            self.log(result.success ? "任务成功" : "任务失败: \(result.errorMessage ?? "")")
        })
    }

    func cancelTask() {
        executor?.cancel()
        isExecutingTask = false
        status = "已取消"
        onUpdate?()
    }

    // MARK: - Touch

    func click(_ x: Float, _ y: Float) {
        let cmd = "su mobile -c '/usr/bin/autotouch touchDown 0 \(Int(x)) \(Int(y)); sleep 0.05; /usr/bin/autotouch touchUp 0 \(Int(x)) \(Int(y))'"
        let a: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
        defer { a.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, nil, a, nil)
        var s: Int32 = 0; waitpid(pid, &s, 0)
        if MacroRecorder.isRecording { MacroRecorder.record(x: x, y: y, source: "auto", label: "") }
    }

    func tapNoRecord(_ x: Float, _ y: Float) {
        let cmd = "su mobile -c '/usr/bin/autotouch touchDown 0 \(Int(x)) \(Int(y)); sleep 0.05; /usr/bin/autotouch touchUp 0 \(Int(x)) \(Int(y))'"
        let a: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
        defer { a.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, nil, a, nil)
        var s: Int32 = 0; waitpid(pid, &s, 0)
    }

    // MARK: - Macro

    func replayMacro(name: String) { MacroRecorder.smartReplay(name: name, engine: self) }
    func saveMacro(name: String) -> Bool { MacroRecorder.save(name) }

    // MARK: - Helpers

    private func migrateImages() {
        let old = "/var/mobile/Library/AutoTouch/Scripts/Images"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: old)) ?? [] {
            let s = "\(old)/\(f)", d = "\(imgDir)/\(f)"
            if !FileManager.default.fileExists(atPath: d) { try? FileManager.default.copyItem(atPath: s, toPath: d) }
        }
    }

    private func log(_ msg: String) { logs += msg + "\n"; Logger.log(msg) }
}
