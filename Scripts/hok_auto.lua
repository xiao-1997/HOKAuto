-- hok_auto.lua - 王者荣耀自动化主脚本
-- 视觉驱动：findImage 动态识别 + DeepSeek 兜底

local DIR = "/var/mobile/Library/AutoTouch/Scripts/Images"

-- ====== 按钮模板库 ======
local BUTTONS = {
    cancel = {
        priority = 1,
        images = { DIR.."/cancel_btn.png" },
    },
    close = {
        priority = 2,
        images = { DIR.."/close_btn.png", DIR.."/close_btn2.png", DIR.."/x_btn.png" },
        fallback_coords = { {1896,124}, {1876,99}, {2062,146} },
    },
    skip = {
        priority = 3,
        images = { DIR.."/skip_btn.png" },
    },
    login = {
        priority = 10,
        images = { DIR.."/login_btn.png" },
    },
}

-- ====== 核心函数 ======

-- 单模板匹配
local function matchOne(img, threshold)
    if not fileExists(img) then return nil end
    keepScreen(true)
    local x, y = findImage(img, 1, threshold or 0.6, nil, nil)
    keepScreen(false)
    if x and x > 0 then return x, y end
    return nil
end

-- 按钮组匹配（多图 OR）
local function matchGroup(group, threshold)
    for _, img in ipairs(group.images) do
        local pos = matchOne(img, threshold)
        if pos then return pos end
    end
    return nil
end

-- 点击坐标
local function tap(x, y)
    touchDown(0, x, y)
    usleep(50000)
    touchUp(0, x, y)
end

-- 弹窗关闭
local function closePopups()
    local order = {"cancel", "close", "skip"}
    for _, name in ipairs(order) do
        local btn = BUTTONS[name]
        local pos = matchGroup(btn, 0.5)
        if pos then
            tap(pos[1], pos[2])
            return true, name, pos
        end
    end

    -- 兜底盲点
    local fb = BUTTONS.close.fallback_coords
    for _, pt in ipairs(fb) do
        tap(pt[1], pt[2])
        usleep(200000)
    end
    return false, nil, nil
end

-- ====== DeepSeek AI 回调接口 ======
-- 由 Swift 端通过文件通信
-- 写入: /tmp/ds_request.txt (base64截图)
-- 读取: /tmp/ds_response.txt (JSON结果)

local function deepSeekFallback()
    local reqFile = "/tmp/ds_request.txt"
    local respFile = "/tmp/ds_response.txt"

    -- 截图并写 base64
    keepScreen(true)
    snapshot("/tmp/_ds_screen.png")
    keepScreen(false)

    -- 通知 Swift 端上传 DeepSeek
    local f = io.open(reqFile, "w")
    if f then f:write("analyze popup"); f:close() end

    -- 等待 Swift 端处理后写回结果
    for i = 1, 30 do
        usleep(1000000) -- 1秒
        if fileExists(respFile) then
            local f2 = io.open(respFile, "r")
            if f2 then
                local cmd = f2:read("*a"):gsub("%s+", "")
                f2:close()
                os.remove(respFile)
                -- 解析: {"action":"click","x":100,"y":200}
                if cmd:find("click") then
                    local x = tonumber(cmd:match('"x":(%d+)')) or 600
                    local y = tonumber(cmd:match('"y":(%d+)')) or 400
                    tap(x, y)
                    return true
                end
            end
            break
        end
    end
    os.remove(reqFile)
    return false
end

-- ====== 主循环 ======
local function mainLoop()
    local MAX_CYCLES = 20  -- 5秒*20=100秒
    local loginTapped = false

    for i = 1, MAX_CYCLES do
        -- 1. 本地视觉识别弹窗
        local closed, btnName, pos = closePopups()
        if closed then
            syslog("closed: " .. (btnName or "blind"))
        end

        -- 2. 本地无匹配 → DeepSeek
        if not closed then
            syslog("local miss, try DeepSeek")
            deepSeekFallback()
        end

        -- 3. 登录检测（只在30秒后尝试）
        if i >= 6 and not loginTapped then
            local loginPos = matchGroup(BUTTONS.login, 0.5)
            if loginPos then
                tap(loginPos[1], loginPos[2])
                loginTapped = true
                syslog("login tapped")
            end
        end

        usleep(5000000) -- 5秒间隔
    end
end

-- 入口
mainLoop()
