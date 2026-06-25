import UIKit

class AutomationEngine {
    var status = "就绪" { didSet { FloatingHUD.shared.setStatus(status) } }
    var logs = ""
    var isRunning = false { didSet { if !isRunning { FloatingHUD.shared.hide() } } }
    var onUpdate: (() -> Void)?

    private let imgDir = "/var/mobile/Library/AutoTouch/Scripts/Images"

    // 自学习截取区域 (可自定义)
    private var learnW = 100   // 宽度
    private var learnH = 80    // 高度

    private var dsTimer: Timer?
    private var aiCallCount = 0        // AI 调用计数
    private let aiMaxCalls = 5         // 单次最大调用
    private var lastAICall: Date?      // 上次调用时间

    func run() {
        aiCallCount = 0; lastAICall = nil
        guard !isRunning else { return }
        isRunning = true; status = "测试AI..."; logs = ""; onUpdate?()

        // === 阶段1: 测试 AI 连接 ===
        log("测试 DeepSeek VL 连接...")
        status = "测试AI连接"
        toast("🔗 测试 AI 连接中...")

        // 用一个 1×1 像素图测试连接
        let testImg = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        DeepSeekClient.analyze(image: testImg, prompt: "ping") { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.log("AI 连接成功 ✅")
                    self.status = "AI已连接,启动中..."
                    self.toast("✅ AI 连接成功 → 启动王者荣耀")
                    self.launchAndRun()

                case .failure(let e):
                    self.log("AI 连接失败: \(e.localizedDescription)")
                    self.status = "AI未连接"
                    self.toast("❌ AI 未连接，请检查网络后重试")
                    self.isRunning = false
                    self.onUpdate?()
            }
        }
        }
    }

    private func launchAndRun() {
        writeLua()
        log("启动 王者荣耀...")
        status = "正在启动王者荣耀"
        toast("🚀 启动王者荣耀 → 等待加载 → 检测弹窗")

        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("已启动")
            toast("✅ 已启动 → 检测弹窗")
        } else {
            log("失败"); status = "失败"; isRunning = false; onUpdate?(); return
        }
        onUpdate?()

        // 后台执行 Lua 主循环
        DispatchQueue.global().async {
            self.runLua("main")
            DispatchQueue.main.async {
                self.status = "完成"; self.log("完成")
                self.isRunning = false; self.onUpdate?(); self.dsTimer?.invalidate()
            }
        }
        dsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.checkDS() }
    }

    // MARK: - DeepSeek + 自学习

    private func checkDS() {
        let reqFile = "/tmp/ds_request.txt"
        let learnFile = "/tmp/ds_learn.txt"  // 自学习请求
        guard FileManager.default.fileExists(atPath: reqFile) else { return }

        let prompt = (try? String(contentsOfFile: reqFile)) ?? "analyze"
        try? FileManager.default.removeItem(atPath: reqFile)

        status = "AI分析..."
        FloatingHUD.shared.setStep("AI 视觉分析", color: .cyan)
        onUpdate?()

        guard let img = UIImage(contentsOfFile: "/tmp/_ds_screen.jpg") else { return }

        // 防刷：限制调用次数和间隔
        if aiCallCount >= aiMaxCalls {
            log("AI已达上限(\(aiMaxCalls)次)")
            try? "{\"buttons\":[]}".write(toFile: "/tmp/ds_response.txt", atomically: true, encoding: .utf8)
            return
        }
        if let last = lastAICall, Date().timeIntervalSince(last) < 15 {
            log("AI冷却中...")
            try? "{\"buttons\":[]}".write(toFile: "/tmp/ds_response.txt", atomically: true, encoding: .utf8)
            return
        }
        aiCallCount += 1
        lastAICall = Date()
        log("AI调用 \(aiCallCount)/\(aiMaxCalls)")

        DeepSeekClient.analyze(image: img,
            prompt: "王者荣耀1242x2208横屏。列出弹窗上所有按钮名称和坐标(JSON)。") { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self.log("AI: \(text.prefix(100))")
                    FloatingHUD.shared.recognitionResult("deepseek", name: "AI识别完成", success: true)
                    try? text.write(toFile: "/tmp/ds_response.txt", atomically: true, encoding: .utf8)
                    self.learnFromAI(text)
                case .failure(let e):
                    self.log("AI错误: \(e.localizedDescription)")
                    try? "{}".write(toFile: "/tmp/ds_response.txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// 从AI结果中学习：截取按钮区域保存为模板
    private func learnFromAI(_ aiText: String) {
        // 解析按钮坐标
        let pattern = #""name"\s*:\s*"([^"]+)"[^}]*"x"\s*:\s*(\d+)[^}]*"y"\s*:\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: aiText, range: NSRange(aiText.startIndex..., in: aiText))

        for match in matches.prefix(5) {
            guard let nameRange = Range(match.range(at: 1), in: aiText),
                  let xRange = Range(match.range(at: 2), in: aiText),
                  let yRange = Range(match.range(at: 3), in: aiText) else { continue }

            let name = String(aiText[nameRange]).trimmingCharacters(in: .alphanumerics.inverted)
            let x = Int(String(aiText[xRange])) ?? 0
            let y = Int(String(aiText[yRange])) ?? 0
            guard x > 0, y > 0, !name.isEmpty, name.count < 30 else { continue }

            // 保存按钮截图到模板库（80x60 区域）
            let safeName = name.replacingOccurrences(of: "/", with: "_")
                             .replacingOccurrences(of: " ", with: "_")
            // 去重: 同名模板≤3个
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: imgDir))?.filter { $0.hasPrefix("ai_\(safeName)_") } ?? []
            if existing.count >= 3 { log("跳过重复: \(safeName)"); continue }
            let fileName = "ai_\(safeName)_\(Int(Date().timeIntervalSince1970)).png"
            let hw = learnW / 2, hh = learnH / 2
            let captureLua = """
            keepScreen(true)
            snapshot("\(imgDir)/\(fileName)", \(x-hw), \(y-hh), \(learnW), \(learnH))
            keepScreen(false)
            """

            let tmpPath = "/tmp/learn_\(fileName.replacingOccurrences(of: ".png", with: "")).lua"
            try? captureLua.write(toFile: tmpPath, atomically: true, encoding: .utf8)

            // 后台截取（不阻塞）
            DispatchQueue.global().async {
                let cmd = "su mobile -c '/usr/bin/autotouch play start \(tmpPath)'"
                let cArgs: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
                defer { cArgs.forEach { if let p = $0 { free(p) } } }
                var pid: pid_t = 0
                posix_spawn(&pid, "/bin/sh", nil, nil, cArgs, nil)
                var s: Int32 = 0; waitpid(pid, &s, 0)
            }

            log("学习: \(name) → \(fileName)")
        }
    }

    // MARK: - Lua

    private func writeLua() {
        // 写学习配置
        try? "w=\(learnW)\nh=\(learnH)\n".write(toFile: "/tmp/learn_config.txt", atomically: true, encoding: .utf8)
        // 写 Lua 主脚本
        try? LuaScripts.hokMain.write(toFile: "/tmp/main.lua", atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    /// 通过 AutoTouch toast 在游戏上方显示文字
    private func toast(_ msg: String) {
        let escaped = msg.replacingOccurrences(of: "'", with: "'\\''")
        let lua = "toast('\(escaped)')"
        try? lua.write(toFile: "/tmp/toast.lua", atomically: true, encoding: .utf8)
        runLuaShort("toast")
    }

    private func runLuaShort(_ name: String) {
        DispatchQueue.global().async {
            let c = "su mobile -c '/usr/bin/autotouch play start /tmp/\(name).lua'"
            let a: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(c), nil]
            defer { a.forEach { if let p = $0 { free(p) } } }
            var pid: pid_t = 0
            posix_spawn(&pid, "/bin/sh", nil, nil, a, nil)
            var s: Int32 = 0
            waitpid(pid, &s, 0)
        }
    }

    private func runLua(_ name: String) {
        let c = "su mobile -c '/usr/bin/autotouch play start /tmp/\(name).lua'"
        let a: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(c), nil]
        defer { a.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, nil, a, nil)
        var s: Int32 = 0; waitpid(pid, &s, 0)
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
