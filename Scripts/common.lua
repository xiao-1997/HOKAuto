-- ============================================================
-- common.lua — HOKAuto 通用工具库
-- 仿「我不是人机.apk」架构的 iOS 等价实现
-- 平台: iOS 13.6 越狱 + AutoTouch
-- ============================================================

local M = {}

-- ===================== 屏幕与坐标 =====================

M.REF_W = 1242
M.REF_H = 2208

--- 多点位轮询点击
function M.pollClick(points, intervalUs)
    for _, p in ipairs(points) do
        touchDown(0, p[1], p[2])
        usleep(50000)
        touchUp(0, p[1], p[2])
        usleep(intervalUs or 200000)
    end
end

--- 模板匹配点击（带阈值）
--- @return boolean 是否匹配成功
function M.matchAndClick(templateFile, threshold)
    local x, y = findImage(templateFile, 1, threshold or 0.55, nil, nil)
    if x and x > 0 then
        touchDown(0, x, y)
        usleep(50000)
        touchUp(0, x, y)
        return true
    end
    return false
end

--- 批量模板匹配（命中任意一个即点击）
--- @return boolean, string
function M.matchAny(images, threshold)
    for _, img in ipairs(images) do
        if M.matchAndClick(img, threshold) then
            return true, img
        end
    end
    return false, nil
end

--- 等待指定秒数
function M.wait(seconds)
    usleep((seconds or 1) * 1000000)
end

--- 截图保存
function M.screenshot(path)
    keepScreen(true)
    snapshot(path)
    keepScreen(false)
end

-- ===================== 触控封装 =====================

--- 点击（autotouch 协议）
function M.tap(x, y)
    touchDown(0, x, y)
    usleep(50000)
    touchUp(0, x, y)
end

--- 长按
function M.longPress(x, y, duration)
    touchDown(0, x, y)
    usleep((duration or 1) * 1000000)
    touchUp(0, x, y)
end

--- 滑动
function M.swipe(x1, y1, x2, y2, duration)
    local steps = math.floor((duration or 0.5) / 0.016)
    local dx = (x2 - x1) / steps
    local dy = (y2 - y1) / steps
    touchDown(0, x1, y1)
    for i = 1, steps do
        usleep(16000)
        touchMove(0, x1 + dx * i, y1 + dy * i)
    end
    usleep(50000)
    touchUp(0, x2, y2)
end

--- 右上角盲点（通用关闭）
function M.blindClose()
    local spots = {
        {1896, 124},  -- iPhone Plus 右上角 X
        {2076, 146},  -- iPhone X 系列
        {1876, 99},   -- 备用
    }
    for _, s in ipairs(spots) do
        M.tap(s[1], s[2])
        usleep(100000)
    end
end

-- ===================== 弹窗处理 =====================

--- 多轮弹窗消除
--- @param images table 关闭按钮模板列表
--- @param maxRounds number
--- @return number 消除的弹窗数
function M.dismissPopups(images, maxRounds)
    local imgs = images or {
        "/var/mobile/Library/AutoTouch/Scripts/Images/close_btn.png",
        "/var/mobile/Library/AutoTouch/Scripts/Images/close_btn2.png",
        "/var/mobile/Library/AutoTouch/Scripts/Images/x_btn.png",
        "/var/mobile/Library/AutoTouch/Scripts/Images/cancel_btn.png",
        "/var/mobile/Library/AutoTouch/Scripts/Images/skip_btn.png",
    }

    local count = 0
    for r = 1, (maxRounds or 3) do
        local hit, name = M.matchAny(imgs, 0.45)
        if hit then
            count = count + 1
            usleep(500000)
        else
            if r == 1 then break end
        end
    end

    -- 兜底盲点
    if count == 0 then
        M.blindClose()
    end

    return count
end

-- ===================== 游戏检测 =====================

--- 检测是否在大厅（通过 OCR 关键词）
--- 需要 Swift 端的 LuaVisionBridge 运行中
--- @return boolean
function M.isInLobby()
    local reqFile = "/tmp/hok_ocr_req.txt"
    local respFile = "/tmp/hok_ocr_resp.json"

    local f = io.open(reqFile, "w")
    if not f then return false end
    f:write("开始游戏|商城|英雄|备战|铭文|对战|排位|社区|赛事")
    f:close()

    M.screenshot("/tmp/hok_ocr_screen.png")

    for i = 1, 10 do
        usleep(300000)
        if fileExists(respFile) then
            local rf = io.open(respFile, "r")
            if not rf then break end
            local raw = rf:read("*a")
            rf:close()
            os.remove(respFile)
            os.remove(reqFile)
            return #raw > 5
        end
    end
    os.remove(reqFile)
    return false
end

-- ===================== 系统命令 =====================

--- 打开应用
function M.openApp(scheme)
    if scheme:find("://") then
        os.execute("su mobile -c 'activator open " .. scheme .. "' 2>/dev/null")
    else
        os.execute("su mobile -c 'activator send " .. scheme .. "' 2>/dev/null")
    end
end

--- 关闭应用
function M.killApp(name)
    os.execute("su mobile -c 'killall -9 " .. (name or "mobilechess") .. " 2>/dev/null'")
end

--- 运行 shell 命令
function M.shell(cmd)
    return os.execute(cmd)
end

-- ===================== 日志 =====================

function M.log(level, msg)
    local line = "[" .. os.date("%H:%M:%S") .. "] [" .. (level or "INFO") .. "] " .. msg
    syslog(line)
end

return M
