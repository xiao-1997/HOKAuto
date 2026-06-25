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
                    toast("✅ AI 连接成功 → 启动王者荣耀")
                    self.launchAndRun()

                case .failure(let e):
                    self.log("AI 连接失败: \(e.localizedDescription)")
                    self.status = "AI未连接"
                    toast("❌ AI 未连接，请检查网络后重试")
                    self.isRunning = false
                    self.onUpdate?()
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
        // 写学习配置（用户可编辑）
        let cfg = "w=\(learnW)\nh=\(learnH)\n"
        try? cfg.write(toFile: "/tmp/learn_config.txt", atomically: true, encoding: .utf8)

        let D = imgDir
        let lua = """
        local D = "\(D)"
        -- 优先级1: 最高优先级弹窗（第三方授权/清理数据）
        local PRIORITY_ALERT = {
            auth_clean = {imgs={D.."/alert_clean.png",D.."/alert_auth.png"}, fb={{1000,500},{1100,550}}},
        }
        -- 优先级2: 常规弹窗
        local BUTTONS = {
            cancel = {imgs={D.."/cancel_btn.png"}},
            close  = {imgs={D.."/close_btn.png",D.."/close_btn2.png",D.."/x_btn.png"}, fb={{1896,124},{1876,99}}},
            announce = {imgs={D.."/announce_x.png",D.."/x_announce.png"}, fb={{2100,100},{1800,100}}},  -- 公告X
            skip   = {imgs={D.."/skip_btn.png"}},
            login  = {imgs={D.."/login_btn.png"}},
        }
        -- 动态加载 AI 学习到的模板
        local function loadAITemplates()
            local ai = {}
            local f = io.popen("ls "..D.."/ai_*.png 2>/dev/null")
            if f then
                for line in f:lines() do
                    local name = line:match("ai_(.+)_%d+%.png")
                    if name then
                        if not ai[name] then ai[name] = {} end
                        table.insert(ai[name], D.."/"..line)
                    end
                end
                f:close()
            end
            return ai
        end
        -- 读取学习配置
        local learn_w, learn_h = 100, 80
        toast("⏳ 视觉检测中...")
        local cfg = io.open("/tmp/learn_config.txt")
        if cfg then
            for line in cfg:lines() do
                local w = string.match(line, "w=(%d+)")
                local h = string.match(line, "h=(%d+)")
                if w then learn_w = tonumber(w) end
                if h then learn_h = tonumber(h) end
            end
            cfg:close()
        end

        local function match(imgs, ms)
            local deadline = os.time() + (ms or 3)
            while os.time() < deadline do
                for _,img in ipairs(imgs) do
                    if fileExists(img) then
                        keepScreen(true)
                        local x,y = findImage(img, 1, 0.5, nil, nil)
                        keepScreen(false)
                        if x and x>0 then return x,y end
                    end
                end
                usleep(200000)
            end
            return nil
        end
        -- 模板去重: 检查相似(同名+相近尺寸即跳过)
        local function isDuplicate(name)
            local base = name:match("([^_]+)")
            if not base then return false end
            local f = io.popen("ls "..D.."/ai_"..base.."_*.png 2>/dev/null")
            if f then
                local cnt = 0
                for _ in f:lines() do cnt = cnt + 1 end
                f:close()
                return cnt >= 3  -- 同名模板超过3个不再存储
            end
            return false
        end

        local function matchAll(ms)
            -- 1) 最高优先级: 第三方授权/清理弹窗
            for _,b in pairs(PRIORITY_ALERT) do
                local p = match(b.imgs, 1)
                if p then return p, "priority" end
            end
            -- 盲点兜底
            for _,b in pairs(PRIORITY_ALERT) do
                for _,pt in ipairs(b.fb) do tap(pt[1],pt[2]) usleep(200000) end
            end

            -- 2) 常规弹窗
            local ai = loadAITemplates()
            local order = {"cancel","close","announce","skip"}
            for _,name in ipairs(order) do
                local b = BUTTONS[name]
                local p = match(b.imgs, 1)
                if p then return p, name end
            end
            for name, imgs in pairs(ai) do
                local p = match(imgs, 1)
                if p then return p, "ai_"..name end
            end
            return nil
        end
        local function tap(x,y) touchDown(0,x,y) usleep(50000) touchUp(0,x,y) end
        local loginDone = false
        local ai_count = 0
        for i=1,20 do
            local p, name = matchAll(3)
            if p then tap(p[1],p[2])
            else
                ai_count = ai_count + 1
                if ai_count > 5 then goto continue end  -- 限制AI调用
                keepScreen(true) snapshot("/tmp/_ds_screen.jpg") keepScreen(false)
                local f = io.open("/tmp/ds_request.txt","w")
                if f then f:write("popup"); f:close() end
                for j=1,20 do
                    usleep(500000)
                    if fileExists("/tmp/ds_response.txt") then
                        local r = io.open("/tmp/ds_response.txt")
                        if r then
                            local txt = r:read("*a"); r:close()
                            os.remove("/tmp/ds_response.txt")
                            local x = tonumber(string.match(txt, '"x":(%d+)')) or 0
                            local y = tonumber(string.match(txt, '"y":(%d+)')) or 0
                            if x>0 then tap(x,y) end
                        end
                        break
                    end
                end
                -- 盲点兜底
                for _,pt in ipairs(BUTTONS.close.fb) do tap(pt[1],pt[2]) usleep(200000) end
            end
            if i>=6 and not loginDone then
                local lp = match(BUTTONS.login.imgs, 3)
                if lp then tap(lp[1],lp[2]); loginDone = true end
            end
            usleep(2000000)
        end
        """
        try? lua.write(toFile: "/tmp/main.lua", atomically: true, encoding: .utf8)
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
