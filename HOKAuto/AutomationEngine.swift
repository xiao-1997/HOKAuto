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

    func run() {
        guard !isRunning else { return }
        isRunning = true; status = "就绪"; logs = ""; onUpdate?()
        FloatingHUD.shared.show()
        writeLua()

        // 操作步骤悬浮窗
        FloatingHUD.shared.showSteps([
            .running("打开王者荣耀"),
            .pending("等待加载"),
            .pending("检测弹窗"),
        ])

        log("启动 王者荣耀...")
        status = "正在启动王者荣耀"
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("已启动")
            FloatingHUD.shared.showSteps([
                .success("打开王者荣耀"),
                .running("等待加载"),
                .pending("检测弹窗"),
            ])
        } else { log("失败"); status = "失败"; isRunning = false; FloatingHUD.shared.hide(); onUpdate?(); return }
        onUpdate?()

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

        guard let img = UIImage(contentsOfFile: "/tmp/_ds_screen.jpg"),
              let data = img.jpegData(compressionQuality: 0.4) else { return }
        let b64 = data.base64EncodedString()

        DeepSeekClient.chatWithImage(prompt: "王者荣耀1242x2208横屏。列出弹窗上所有按钮名称和坐标(JSON)。对未识别的按钮描述其外观特征。{\"buttons\":[{\"name\":\"\",\"x\":0,\"y\":0,\"desc\":\"外观描述\"}]}", base64Image: b64) { result in
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
        local BUTTONS = {
            cancel = {imgs={D.."/cancel_btn.png"}},
            close  = {imgs={D.."/close_btn.png",D.."/close_btn2.png",D.."/x_btn.png"}, fb={{1896,124},{1876,99}}},
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
        local function matchAll(ms)
            local ai = loadAITemplates()
            local order = {"cancel","close","skip"}
            for _,name in ipairs(order) do
                local b = BUTTONS[name]
                local p = match(b.imgs, ms)
                if p then return p, name end
            end
            -- 匹配 AI 学到的模板
            for name, imgs in pairs(ai) do
                local p = match(imgs, 1)
                if p then return p, "ai_"..name end
            end
            return nil
        end
        local function tap(x,y) touchDown(0,x,y) usleep(50000) touchUp(0,x,y) end
        local loginDone = false
        for i=1,20 do
            local p, name = matchAll(3)
            if p then tap(p[1],p[2])
            else
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
