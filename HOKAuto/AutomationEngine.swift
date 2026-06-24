import UIKit

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    // 录制平均值 (1242x2208 Landscape)
    private let loginPoint  = (x: 1209, y: 945)
    private let cancelPoint = (x: 1340, y: 732)
    private let closePoints = [
        (x: 1896, y: 124),   // 关闭弹窗
        (x: 1898, y: 146),   // 关闭弹窗
        (x: 1876, y: 99),    // 关闭弹窗
    ]

    func run() {
        guard !isRunning else { return }
        isRunning = true
        status = "启动中..."
        logs = ""
        onUpdate?()

        log("启动 王者荣耀...")
        if let url = URL(string: "tencent1104466820://") {
            UIApplication.shared.open(url, options: [:]) { _ in }
            log("王者荣耀已启动")
        } else {
            log("未安装王者荣耀"); status = "失败"; isRunning = false; onUpdate?(); return
        }
        onUpdate?()

        DispatchQueue.global().async {
            var elapsed = 0
            while elapsed < 60 {
                sleep(3)
                elapsed += 3
                DispatchQueue.main.async {
                    self.status = "检测 \(elapsed)秒"
                    self.onUpdate?()
                }

                // 先点取消
                self.at("touchDown 0 \(self.cancelPoint.x) \(self.cancelPoint.y)")
                usleep(50000)
                self.at("touchUp 0 \(self.cancelPoint.x) \(self.cancelPoint.y)")
                usleep(300000)

                // 关闭弹窗（4个位置逐个点）
                for pt in self.closePoints {
                    self.at("touchDown 0 \(pt.x) \(pt.y)")
                    usleep(50000)
                    self.at("touchUp 0 \(pt.x) \(pt.y)")
                    usleep(200000)
                }

                // 图像识别补充
                self.at("play start /tmp/hok_popup.lua")

                // 30秒后点登录
                if elapsed >= 30 && elapsed < 33 {
                    DispatchQueue.main.async { self.status = "点击登录"; self.onUpdate?() }
                    self.at("touchDown 0 \(self.loginPoint.x) \(self.loginPoint.y)")
                    usleep(50000)
                    self.at("touchUp 0 \(self.loginPoint.x) \(self.loginPoint.y)")
                    DispatchQueue.main.async { self.log("已点击登录") }
                    break
                }
            }
            DispatchQueue.main.async {
                self.status = "完成"; self.log("完成")
                self.isRunning = false; self.onUpdate?()
            }
        }
    }

    private func writePopupScript() {
        let imgDir = "/var/mobile/Library/AutoTouch/Scripts/Images"
        let lua = """
        local imgs = {"\(imgDir)/close_btn.png","\(imgDir)/skip_btn.png","\(imgDir)/back_btn.png"}
        for _,img in ipairs(imgs) do
          if fileExists(img) then
            local x,y=findImage(img,1,0.6,nil,nil)
            if x>0 then touchDown(0,x,y) usleep(50000) touchUp(0,x,y) return end
          end
        end
        """
        try? lua.write(toFile: "/tmp/hok_popup.lua", atomically: true, encoding: .utf8)
    }

    private func at(_ args: String) {
        let parts = args.components(separatedBy: " ")
        let cArgs = parts.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let ret = posix_spawn(&pid, "/usr/bin/autotouch", nil, nil, cArgs + [nil], nil)
        if ret == 0 { var s: Int32 = 0; waitpid(pid, &s, 0) }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
