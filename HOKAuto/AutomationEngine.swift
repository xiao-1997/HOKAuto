import UIKit

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    private let loginPoint  = (x: 1209, y: 945)
    private let cancelPoint = (x: 1340, y: 732)
    private let closePoints = [(x: 1896, y: 124), (x: 1898, y: 146), (x: 1876, y: 99)]

    func run() {
        guard !isRunning else { return }
        isRunning = true; status = "启动中..."; logs = ""; onUpdate?()

        // 写入 Lua 脚本
        writeScripts()

        log("启动 王者荣耀...")
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("王者荣耀已启动")
        } else { log("未安装王者荣耀"); status = "失败"; isRunning = false; onUpdate?(); return }
        onUpdate?()

        DispatchQueue.global().async {
            var elapsed = 0
            while elapsed < 60 {
                sleep(3); elapsed += 3
                DispatchQueue.main.async { self.status = "检测 \(elapsed)秒"; self.onUpdate?() }

                // === 第一层: 坐标盲点 ===
                self.at("touchDown 0 \(self.cancelPoint.x) \(self.cancelPoint.y)")
                usleep(50000)
                self.at("touchUp 0 \(self.cancelPoint.x) \(self.cancelPoint.y)")
                usleep(300000)

                for pt in self.closePoints {
                    self.at("touchDown 0 \(pt.x) \(pt.y)")
                    usleep(50000)
                    self.at("touchUp 0 \(pt.x) \(pt.y)")
                    usleep(200000)
                }

                // === 第二层: AutoTouch 图像识别 ===
                self.playLua("hok_popup")

                // === 第三层: DeepSeek 视觉(每15秒) ===
                if elapsed % 15 == 0 {
                    DispatchQueue.main.async { self.deepSeekAnalyze() }
                }

                // 登录
                if elapsed >= 30 && elapsed < 33 {
                    DispatchQueue.main.async { self.status = "点击登录"; self.onUpdate?() }
                    self.at("touchDown 0 \(self.loginPoint.x) \(self.loginPoint.y)")
                    usleep(50000)
                    self.at("touchUp 0 \(self.loginPoint.x) \(self.loginPoint.y)")
                    DispatchQueue.main.async { self.log("已点击登录") }
                    break
                }
            }
            DispatchQueue.main.async { self.status = "完成"; self.log("完成"); self.isRunning = false; self.onUpdate?() }
        }
    }

    private func writeScripts() {
        // 截图脚本
        try? "keepScreen(true)\nsnapshot(\"/tmp/hok_screen.jpg\")\nkeepScreen(false)\n"
            .write(toFile: "/tmp/screenshot.lua", atomically: true, encoding: .utf8)

        // 弹窗关闭脚本
        let imgDir = "/var/mobile/Library/AutoTouch/Scripts/Images"
        try? """
        keepScreen(true)
        local imgs = {"\(imgDir)/close_btn.png","\(imgDir)/skip_btn.png","\(imgDir)/back_btn.png"}
        for _,img in ipairs(imgs) do
          if fileExists(img) then
            local x,y=findImage(img,1,0.6,nil,nil)
            if x>0 then touchDown(0,x,y) usleep(50000) touchUp(0,x,y) keepScreen(false) return end
          end
        end
        keepScreen(false)
        """.write(toFile: "/tmp/hok_popup.lua", atomically: true, encoding: .utf8)
    }

    // MARK: - DeepSeek Vision

    private func deepSeekAnalyze() {
        guard !DeepSeekClient.apiKey.isEmpty else { return }

        // 1. 用 AutoTouch 截图
        playLua("screenshot")

        // 2. 读取截图文件
        let path = "/tmp/hok_screen.jpg"
        guard let img = UIImage(contentsOfFile: path) else {
            self.log("截图失败"); return
        }

        // 3. 发送 DeepSeek 分析
        self.status = "DeepSeek分析..."
        self.onUpdate?()

        DeepSeekClient.analyzeScreenshot(img, prompt: "识别按鈕位置") { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self.log("DeepSeek: \(text.prefix(100))")
                    let buttons = DeepSeekClient.parseButtons(from: text)
                    // 4. 点击识别到的按钮
                    DispatchQueue.global().async {
                        for btn in buttons {
                            if btn.name.contains("关闭") || btn.name.contains("X") ||
                               btn.name.contains("取消") || btn.name.contains("暫不") {
                                self.log("AI点击: \(btn.name) (\(btn.x),\(btn.y))")
                                self.at("touchDown 0 \(Int(btn.x)) \(Int(btn.y))")
                                usleep(50000)
                                self.at("touchUp 0 \(Int(btn.x)) \(Int(btn.y))")
                                usleep(200000)
                            }
                        }
                    }
                case .failure(let e):
                    self.log("DeepSeek错误: \(e.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func playLua(_ name: String) {
        let path = "/tmp/\(name).lua"
        at("play start \(path)")
    }

    private func at(_ args: String) {
        let parts = args.components(separatedBy: " ")
        let cArgs = parts.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        if posix_spawn(&pid, "/usr/bin/autotouch", nil, nil, cArgs + [nil], nil) == 0 {
            var s: Int32 = 0; waitpid(pid, &s, 0)
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
