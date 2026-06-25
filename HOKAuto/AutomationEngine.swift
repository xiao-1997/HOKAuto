import UIKit

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    // MARK: - Run

    func run() {
        guard !isRunning else { return }
        isRunning = true; status = "启动中..."; logs = ""; onUpdate?()

        writeLuaScripts()

        // 1. 启动王者荣耀
        log("启动 王者荣耀...")
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("已启动")
        } else {
            log("未安装游戏"); status = "失败"; isRunning = false; onUpdate?(); return
        }
        onUpdate?()

        // 2. 后台执行 Lua 主循环
        DispatchQueue.global().async {
            self.runLua("hok_main")

            DispatchQueue.main.async {
                self.status = "完成"; self.log("完成")
                self.isRunning = false; self.onUpdate?()
            }
        }

        // 3. DeepSeek 轮询监听（每5秒检查请求文件）
        deepSeekPoll()
    }

    // MARK: - DeepSeek 轮询

    private func deepSeekPoll() {
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            guard self.isRunning else { return }

            let reqFile = "/tmp/ds_request.txt"
            guard FileManager.default.fileExists(atPath: reqFile) else { return }

            // Lua 请求了 DeepSeek 分析
            self.status = "AI分析中..."
            self.onUpdate?()

            // 读截图 → 上传 DeepSeek
            let img = UIImage(contentsOfFile: "/tmp/_ds_screen.png")
            guard let imageData = img?.jpegData(compressionQuality: 0.5) else { return }
            let b64 = imageData.base64EncodedString()
            let prompt = "分析王者荣耀截图(1242x2208)，识别弹窗按钮、关闭按钮坐标，返回JSON: {\"action\":\"click\",\"x\":坐标,\"y\":坐标}"

            DeepSeekClient.chatWithImage(prompt: prompt, base64Image: b64) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        self.log("AI: \(text.prefix(80))")
                        let outFile = "/tmp/ds_response.txt"
                        try? text.write(toFile: outFile, atomically: true, encoding: .utf8)
                    case .failure:
                        try? "{}".write(toFile: "/tmp/ds_response.txt", atomically: true, encoding: .utf8)
                    }
                    try? FileManager.default.removeItem(atPath: reqFile)
                }
            }
        }
    }

    // MARK: - Lua Scripts

    private func writeLuaScripts() {
        let imgDir = "/var/mobile/Library/AutoTouch/Scripts/Images"

        let mainLua = """
        local D = "\(imgDir)"
        local BUTTONS = {
            cancel = { imgs={D.."/cancel_btn.png"} },
            close  = { imgs={D.."/close_btn.png", D.."/close_btn2.png", D.."/x_btn.png"}, fb={{1896,124},{1876,99}} },
            skip   = { imgs={D.."/skip_btn.png"} },
            login  = { imgs={D.."/login_btn.png"} },
        }
        local function match(imgs, th)
            for _,img in ipairs(imgs) do
                if fileExists(img) then
                    keepScreen(true)
                    local x,y = findImage(img, 1, th or 0.6, nil, nil)
                    keepScreen(false)
                    if x and x>0 then return x,y end
                end
            end
            return nil
        end
        local function tap(x,y) touchDown(0,x,y) usleep(50000) touchUp(0,x,y) end
        local function closePopups()
            for _,name in ipairs({"cancel","close","skip"}) do
                local b = BUTTONS[name]
                local p = match(b.imgs, 0.5)
                if p then tap(p[1],p[2]); return true,name end
            end
            for _,pt in ipairs(BUTTONS.close.fb) do tap(pt[1],pt[2]) usleep(200000) end
            return false
        end
        local loginDone = false
        for i=1,20 do
            local ok, name = closePopups()
            if not ok then
                local f = io.open("/tmp/ds_request.txt","w")
                if f then f:write("popup"); f:close() end
                keepScreen(true) snapshot("/tmp/_ds_screen.png") keepScreen(false)
            end
            if i>=6 and not loginDone then
                local p = match(BUTTONS.login.imgs, 0.5)
                if p then tap(p[1],p[2]); loginDone = true end
            end
            usleep(5000000)
        end
        """

        try? "keepScreen(true) snapshot(\"/tmp/hok_screen.png\") keepScreen(false)\n"
            .write(toFile: "/tmp/screenshot.lua", atomically: true, encoding: .utf8)

        try? mainLua.write(toFile: "/tmp/hok_main.lua", atomically: true, encoding: .utf8)
    }

    private func runLua(_ name: String) {
        let cmd = "su mobile -c '/usr/bin/autotouch play start /tmp/\(name).lua'"
        let cArgs: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
        defer { cArgs.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, nil, cArgs, nil)
        var s: Int32 = 0; waitpid(pid, &s, 0)
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
