import UIKit

class AutomationEngine {
    var status = "就绪"
    var logs = ""
    var isRunning = false
    var onUpdate: (() -> Void)?

    private let loginPoint = (x: 540, y: 960)

    func run() {
        guard !isRunning else { return }
        isRunning = true
        status = "启动中..."
        logs = ""
        onUpdate?()

        writePopupScript()

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
                    self.status = "视觉检测 \(elapsed)秒"
                    self.onUpdate?()
                }
                self.spawnAutotouch("play", "start", "/tmp/hok_popup.lua")

                if elapsed >= 30 && elapsed < 33 {
                    DispatchQueue.main.async { self.status = "点击登录"; self.onUpdate?() }
                    self.spawnAutotouch("touchDown", "0", "\(self.loginPoint.x)", "\(self.loginPoint.y)")
                    usleep(50000)
                    self.spawnAutotouch("touchUp", "0", "\(self.loginPoint.x)", "\(self.loginPoint.y)")
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
        let lua = """
        -- 弹窗关闭脚本 (多图片匹配)
        local IMG_DIR = "/var/mobile/Library/AutoTouch/Scripts/Images"

        -- 按钮组: 每组可配多张参考图，命中任意一张即点击该按钮
        local buttonGroups = {
            close = { -- X关闭按钮
                IMG_DIR .. "/close_btn.png",
                IMG_DIR .. "/x_btn.png",
                IMG_DIR .. "/close_btn2.png",
            },
            cancel = { -- 取消按钮
                IMG_DIR .. "/cancel_btn.png",
                IMG_DIR .. "/cancel_btn2.png",
            },
            skip = { -- 暂不参与
                IMG_DIR .. "/skip_btn.png",
                IMG_DIR .. "/skip_btn2.png",
                IMG_DIR .. "/skip_btn3.png",
            },
            later = { -- 稍后再说
                IMG_DIR .. "/later_btn.png",
                IMG_DIR .. "/later_btn2.png",
            },
            ok = { -- 确定
                IMG_DIR .. "/ok_btn.png",
                IMG_DIR .. "/ok_btn2.png",
            },
        }

        local function tryGroup(imgs)
            for _, img in ipairs(imgs) do
                if fileExists(img) then
                    local x, y = findImage(img, 1, 0.7, nil, nil)
                    if x > 0 and y > 0 then
                        touchDown(0, x, y)
                        usleep(50000)
                        touchUp(0, x, y)
                        return true
                    end
                end
            end
            return false
        end

        -- 优先级: 关闭X > 取消 > 暂不参与 > 稍后再说 > 确定
        if tryGroup(buttonGroups.close) then return end
        if tryGroup(buttonGroups.cancel) then return end
        if tryGroup(buttonGroups.skip) then return end
        if tryGroup(buttonGroups.later) then return end
        if tryGroup(buttonGroups.ok) then return end

        -- 盲点角落
        local pts = {{1900,150}, {2000,150}, {2100,150}, {1950,200}, {1900,250}}
        for _, p in ipairs(pts) do
            touchDown(0, p[1], p[2])
            usleep(50000)
            touchUp(0, p[1], p[2])
            usleep(200000)
        end
        """

        try? lua.write(toFile: "/tmp/hok_popup.lua", atomically: true, encoding: .utf8)
    }

    private func spawnAutotouch(_ args: String...) {
        let cArgs = args.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        if posix_spawn(&pid, "/usr/bin/autotouch", nil, nil, cArgs + [nil], nil) == 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    private func log(_ msg: String) { logs += msg + "\n" }
}
