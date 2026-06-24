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

        // 写入弹窗检测 Lua 脚本
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

                // 执行 Lua 视觉脚本关闭弹窗
                self.spawnAutotouch("play", "start", "/tmp/hok_popup.lua")

                // 30秒后点登录
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
        -- 弹窗关闭脚本 (图像识别 + 文字识别)
        local imgs = {
            "/var/mobile/Library/AutoTouch/Scripts/Images/close_btn.png",
            "/var/mobile/Library/AutoTouch/Scripts/Images/cancel_btn.png",
            "/var/mobile/Library/AutoTouch/Scripts/Images/x_btn.png",
        }

        local function closeByImage()
            for _, img in ipairs(imgs) do
                if fileExists(img) then
                    local x, y = findImage(img, 1, 0.7, nil, nil)
                    if x > 0 and y > 0 then
                        touchDown(0, x, y)
                        usleep(50000)
                        touchUp(0, x, y)
                        syslog("closed: " .. img)
                        return true
                    end
                end
            end
            return false
        end

        local function closeByOCR()
            -- OCR 检测常见弹窗文字
            local texts = ocr()
            if texts then
                for _, t in ipairs(texts) do
                    local txt = t.text or ""
                    -- 检测到弹窗关键词，在附近查找 X 关闭
                    if string.find(txt, "活动") or string.find(txt, "公告")
                       or string.find(txt, "福利") or string.find(txt, "商城")
                       or string.find(txt, "更新") or string.find(txt, "提示") then
                        -- 在文字右侧10px处尝试点击（可能的X按钮位置）
                        local cx = (t.x or 100) + (t.width or 200) + 10
                        local cy = t.y or 200
                        touchDown(0, cx, cy)
                        usleep(50000)
                        touchUp(0, cx, cy)
                        return true
                    end
                end
            end
            return false
        end

        local function closeByCoord()
            -- 盲点常见关闭位置（横屏右上角区域）
            local pts = {{1900,150}, {2000,150}, {2100,150}, {1950,200}}
            for _, p in ipairs(pts) do
                touchDown(0, p[1], p[2])
                usleep(50000)
                touchUp(0, p[1], p[2])
                usleep(200000)
            end
        end

        if not closeByImage() then
            closeByOCR()
        end
        closeByCoord()
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
