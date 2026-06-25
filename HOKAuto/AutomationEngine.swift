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

    // MARK: - DeepSeek AI 语义分析

    private func deepSeekAnalyze() {
        guard !DeepSeekClient.apiKey.isEmpty else { return }

        let ctx: [String: Any] = [
            "status": status,
            "buttons": "取消(1340,732) 关闭(1896,124) 关闭(1898,146) 关闭(1876,99) 登录(1209,945)",
            "lastAction": logs.components(separatedBy: "\n").last ?? ""
        ]

        DeepSeekClient.analyzeScreen(context: ctx) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let dict):
                    if let action = dict["action"] as? String {
                        self.log("AI建议: \(action) \(dict["reason"] as? String ?? "")")
                        if action == "click",
                           let x = dict["x"] as? Double,
                           let y = dict["y"] as? Double {
                            DispatchQueue.global().async {
                                self.at("touchDown 0 \(Int(x)) \(Int(y))")
                                usleep(50000)
                                self.at("touchUp 0 \(Int(x)) \(Int(y))")
                            }
                        }
                    }
                case .failure(let e):
                    self.log("AI错误: \(e.localizedDescription)")
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
        // 通过 su mobile -c 调用 autotouch（Substrate 只在 mobile 用户下注入）
        let cmd = "su mobile -c '/usr/bin/autotouch \(args)'"
        let shell = "/bin/sh"
        let cArgs: [UnsafeMutablePointer<CChar>?] = [
            strdup(shell), strdup("-c"), strdup(cmd), nil
        ]
        defer { cArgs.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        if posix_spawn(&pid, shell, nil, nil, cArgs, nil) == 0 {
            var s: Int32 = 0; waitpid(pid, &s, 0)
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
