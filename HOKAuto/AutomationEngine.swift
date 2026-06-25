import UIKit

// MARK: - Engine

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    private let imgDir = "/var/mobile/Library/AutoTouch/Scripts/Images"
    private var dsTimer: Timer?

    func run() {
        guard !isRunning else { return }
        isRunning = true; status = "启动中..."; logs = ""; onUpdate?()

        writeLua()

        log("启动 王者荣耀...")
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("已启动")
        } else { log("失败"); status = "失败"; isRunning = false; onUpdate?(); return }
        onUpdate?()

        // 后台执行 Lua 主循环
        DispatchQueue.global().async {
            self.runLua("main")
            DispatchQueue.main.async {
                self.status = "完成"; self.log("完成")
                self.isRunning = false; self.onUpdate?(); self.dsTimer?.invalidate()
            }
        }

        // DeepSeek 监听 (每 3 秒检查)
        dsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            self.checkDeepSeekRequest()
        }
    }

    // MARK: - DeepSeek Fallback

    private func checkDeepSeekRequest() {
        let reqFile = "/tmp/ds_request.txt"
        guard FileManager.default.fileExists(atPath: reqFile) else { return }
        // 读取请求参数
        let prompt = (try? String(contentsOfFile: reqFile)) ?? "analyze popup"
        try? FileManager.default.removeItem(atPath: reqFile)

        status = "DeepSeek 分析..."
        onUpdate?()

        // 读截图
        guard let img = UIImage(contentsOfFile: "/tmp/_ds_screen.jpg"),
              let data = img.jpegData(compressionQuality: 0.4)
        else { log("截图读取失败"); return }

        let b64 = data.base64EncodedString()
        let aiPrompt = "王者荣耀1242x2208横屏。识别弹窗上的按钮名称和坐标。返回JSON: {\"buttons\":[{\"name\":\"按钮名\",\"x\":坐标,\"y\":坐标}]}"

        DeepSeekClient.chatWithImage(prompt: aiPrompt, base64Image: b64) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self.log("AI结果: \(text.prefix(80))")
                    // 写回结果 → Lua 读取并执行点击
                    try? text.write(toFile: "/tmp/ds_response.txt", atomically: true, encoding: .utf8)
                    // Lua 读取后会删除此文件
                case .failure(let e):
                    self.log("AI错误: \(e.localizedDescription)")
                    try? "{\"buttons\":[]}".write(toFile: "/tmp/ds_response.txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }

    // MARK: - Lua Script

    private func writeLua() {
        let D = imgDir
        let lua = """
        -- hok_main.lua - findImage(3秒超时) → DeepSeek兜底
        local D = "\(D)"
        local BUTTONS = {
            cancel = {imgs={D.."/cancel_btn.png"}},
            close  = {imgs={D.."/close_btn.png",D.."/close_btn2.png",D.."/x_btn.png"}, fb={{1896,124},{1876,99},{2062,146}}},
            skip   = {imgs={D.."/skip_btn.png"}},
            login  = {imgs={D.."/login_btn.png"}},
        }
        local function match(imgs, ms)
            local deadline = os.time() + (ms or 3000) / 1000
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
        local function tap(x,y) touchDown(0,x,y) usleep(50000) touchUp(0,x,y) end
        local function closePopups()
            for _,name in ipairs({"cancel","close","skip"}) do
                local b = BUTTONS[name]
                local p = match(b.imgs, 3)
                if p then tap(p[1],p[2]); return true,name end
            end
            -- 本地未匹配 → 触发 DeepSeek
            keepScreen(true) snapshot("/tmp/_ds_screen.jpg") keepScreen(false)
            local f = io.open("/tmp/ds_request.txt","w")
            if f then f:write("popup"); f:close() end
            -- 等待 Swift 写回 ds_response.txt
            for i=1,20 do
                usleep(500000)
                if fileExists("/tmp/ds_response.txt") then
                    local r = io.open("/tmp/ds_response.txt")
                    if r then
                        local txt = r:read("*a"); r:close()
                        os.remove("/tmp/ds_response.txt")
                        local x = tonumber(string.match(txt, '"x":(%d+)')) or 600
                        local y = tonumber(string.match(txt, '"y":(%d+)')) or 400
                        tap(x, y)
                        return true, "ai"
                    end
                    break
                end
            end
            -- 全失败→盲点
            for _,pt in ipairs(BUTTONS.close.fb) do tap(pt[1],pt[2]) usleep(200000) end
            return false
        end
        local loginDone = false
        for i=1,20 do
            closePopups()
            if i>=6 and not loginDone then
                local p = match(BUTTONS.login.imgs, 3)
                if p then tap(p[1],p[2]); loginDone = true end
            end
            usleep(2000000)
        end
        """
        try? lua.write(toFile: "/tmp/main.lua", atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

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
