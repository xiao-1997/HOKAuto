-- hok_main.lua - 王者荣耀自动化主脚本
local D = "/var/mobile/Library/AutoTouch/Scripts/Images"

-- 优先级1: 最高优先级弹窗
local PRIORITY_ALERT = {
    auth_clean = {
        imgs = {D.."/alert_clean.png", D.."/alert_auth.png"},
        fb = {{1000,500}, {1100,550}},
    },
}
-- 优先级2: 常规弹窗
local BUTTONS = {
    cancel   = {imgs = {D.."/cancel_btn.png"}},
    close    = {imgs = {D.."/close_btn.png", D.."/close_btn2.png", D.."/x_btn.png"}, fb = {{1896,124},{1876,99}}},
    announce = {imgs = {D.."/announce_x.png", D.."/x_announce.png"}, fb = {{2100,100},{1800,100}}},
    skip     = {imgs = {D.."/skip_btn.png"}},
    login    = {imgs = {D.."/login_btn.png"}},
}

-- 动态加载 AI 模板
local function loadAI()
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

-- 单模板匹配
local function match(imgs, ms)
    local deadline = os.time() + (ms or 3)
    while os.time() < deadline do
        for _, img in ipairs(imgs) do
            if fileExists(img) then
                keepScreen(true)
                local x, y = findImage(img, 1, 0.5, nil, nil)
                keepScreen(false)
                if x and x > 0 then return x, y end
            end
        end
        usleep(200000)
    end
    return nil
end

-- 多层次匹配
local function matchAll(ms)
    -- 最高优先级: 第三方授权/清理弹窗
    for _, b in pairs(PRIORITY_ALERT) do
        local p = match(b.imgs, 1)
        if p then return p, "priority" end
    end
    -- 盲点
    for _, b in pairs(PRIORITY_ALERT) do
        for _, pt in ipairs(b.fb) do tap(pt[1], pt[2]) usleep(200000) end
    end
    -- 常规
    local ai = loadAI()
    local order = {"cancel", "close", "announce", "skip"}
    for _, name in ipairs(order) do
        local p = match(BUTTONS[name].imgs, 1)
        if p then return p, name end
    end
    for _, imgs in pairs(ai) do
        local p = match(imgs, 1)
        if p then return p, "ai" end
    end
    return nil
end

local function tap(x, y)
    touchDown(0, x, y) usleep(50000) touchUp(0, x, y)
end

-- 主循环
local loginDone = false
local ai_count = 0
for i = 1, 20 do
    local p, name = matchAll(3)
    if p then
        tap(p[1], p[2])
    else
        ai_count = ai_count + 1
        if ai_count <= 5 then
            keepScreen(true) snapshot("/tmp/_ds_screen.jpg") keepScreen(false)
            local f = io.open("/tmp/ds_request.txt", "w")
            if f then f:write("popup") f:close() end
            for j = 1, 20 do
                usleep(500000)
                if fileExists("/tmp/ds_response.txt") then
                    local r = io.open("/tmp/ds_response.txt")
                    if r then
                        local txt = r:read("*a") r:close()
                        os.remove("/tmp/ds_response.txt")
                        local x = tonumber(string.match(txt, '"x":(%d+)')) or 0
                        local y = tonumber(string.match(txt, '"y":(%d+)')) or 0
                        if x > 0 then tap(x, y) end
                    end
                    break
                end
            end
        end
        -- 盲点兜底
        for _, pt in ipairs(BUTTONS.close.fb) do tap(pt[1], pt[2]) usleep(200000) end
    end
    if i >= 6 and not loginDone then
        local lp = match(BUTTONS.login.imgs, 3)
        if lp then tap(lp[1], lp[2]) loginDone = true end
    end
    usleep(2000000)
    ::continue::
end
