-- ============================================================
-- hok_auto_pro.lua — 王者荣耀自动化 PRO 版
-- 架构参考「我不是人机.apk」的多层设计（去 VPN/代理层）
-- ============================================================
-- 平台: iOS 13.6 越狱 + AutoTouch + HOKAuto Swift 引擎
-- ============================================================
--
-- 四层架构:
--   L1 视觉感知层: 模板匹配 → OCR → YOLO → AI 兜底
--   L2 决策引擎层: 优先级队列 + 状态机 + CoordCache
--   L3 执行层:     autotouch 触控 + 键盘输入 + 验证闭环
--   L4 持久化层:   文件日志 + 坐标缓存 + 任务记录
--
-- ============================================================

-- ===================== 全局配置 =====================

local CONFIG = {
    -- 屏幕分辨率（逻辑像素 1242x2208，iPhone 6/7/8 Plus 基准）
    REF_W = 1242,
    REF_H = 2208,

    -- 轮询间隔
    TICK_INTERVAL = 3,        -- 空闲守护间隔 (秒)
    TASK_TICK_INTERVAL = 2,   -- 任务执行间隔 (秒)

    -- 弹窗消除
    POPUP_MAX_ROUNDS = 4,     -- 最多消除轮数
    POPUP_TAP_DELAY = 200000, -- 点击间隔 (微秒)

    -- 视觉识别
    TEMPLATE_THRESHOLD = 0.55, -- 模板匹配最低置信度
    OCR_TIMEOUT = 3000,        -- OCR 超时 (毫秒)
    YOLO_MIN_CONF = 0.25,      -- YOLO 最低置信度

    -- 任务
    MAX_RETRIES = 3,          -- 步骤最大重试次数
    WAIT_AFTER_CLICK = 1.5,   -- 点击后默认等待 (秒)

    -- 路径
    DIR_IMAGES = "/var/mobile/Library/AutoTouch/Scripts/Images",
    DIR_LOGS = "/var/mobile/Documents/HOKAuto/logs",
    DIR_CACHE = "/var/mobile/Documents/HOKAuto",

    -- 游戏
    GAME_BUNDLE = "com.tencent.smoba",        -- 王者荣耀 Bundle ID
    GAME_SCHEME = "tencent1104466820://",     -- URL Scheme
    GAME_NAME = "mobilechess",                -- 进程名 (越狱版可能不同)

    -- 加载检测关键词
    LOBBY_KEYWORDS = {
        "开始游戏", "商城", "英雄", "备战", "铭文",
        "对战", "排位", "社区", "赛事", "任务",
    },

    -- 弹窗关键词
    POPUP_KEYWORDS = {
        "关闭", "取消", "确定", "暂不", "X",
        "公告", "福利", "活动", "限时", "礼包",
        "更新", "提示", "确认", "知道了",
    },

    -- 登录关键词
    LOGIN_KEYWORDS = {
        "登录", "微信登录", "QQ登录", "开始游戏",
        "进入游戏", "点击进入",
    },
}

-- ===================== L1: 视觉感知层 =====================
-- 仿 APK 的 YOLO + PaddleOCR + Tesseract + OpenCV 多引擎策略
-- iOS 等价实现: findImage + Vision OCR + YOLO(CoreML) + DeepSeek

local Vision = {}

--- 引擎 1: 模板匹配 (最快，对应 APK 的 OpenCV 模板匹配)
--- @param img string 模板文件名
--- @param threshold number 最低置信度 0~1
--- @return number|nil, number|nil x, y
function Vision.matchTemplate(img, threshold)
    local fullPath = CONFIG.DIR_IMAGES .. "/" .. img
    if not fileExists(fullPath) then
        return nil, nil
    end
    keepScreen(true)
    local x, y = findImage(fullPath, 1, threshold or CONFIG.TEMPLATE_THRESHOLD, nil, nil)
    keepScreen(false)
    if x and x > 0 then
        return x, y
    end
    return nil, nil
end

--- 引擎 1b: 多模板 OR 匹配（一个按钮多个角度）
--- @param images table 模板文件名列表
--- @param threshold number
--- @return number|nil, number|nil, string|nil x, y, 命中模板名
function Vision.matchAnyTemplate(images, threshold)
    local bestX, bestY, bestName
    local bestScore = 0

    for _, img in ipairs(images) do
        local x, y = Vision.matchTemplate(img, threshold)
        if x and x > 0 then
            -- 简单启发式：越靠近屏幕中央的命中越可能是目标
            local cx, cy = CONFIG.REF_W / 2, CONFIG.REF_H / 2
            local dist = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2)
            local score = 1 / (1 + dist / 1000)
            if score > bestScore then
                bestScore = score
                bestX, bestY = x, y
                bestName = img
            end
        end
    end
    return bestX, bestY, bestName
end

--- 引擎 2: OCR 文字定位 (对应 APK 的 PaddleOCR + Tesseract)
--- 调用 Swift Vision 引擎，通过文件 IPC 通信
--- @param keywords table 目标关键词列表
--- @return table {{text, x, y, rect}, ...}
function Vision.ocrDetect(keywords)
    -- 写入 OCR 请求
    local reqFile = "/tmp/hok_ocr_req.txt"
    local respFile = "/tmp/hok_ocr_resp.json"

    local req = table.concat(keywords, "|")
    local f = io.open(reqFile, "w")
    if not f then return {} end
    f:write(req)
    f:close()

    -- 触发 Swift 端执行 OCR（通过文件存在性信号）
    keepScreen(true)
    snapshot("/tmp/hok_ocr_screen.png")
    keepScreen(false)

    -- 等待 Swift 端处理
    local results = {}
    for i = 1, 10 do
        usleep(300000) -- 0.3秒
        if fileExists(respFile) then
            local rf = io.open(respFile, "r")
            if rf then
                local raw = rf:read("*a")
                rf:close()
                os.remove(respFile)
                os.remove(reqFile)
                -- 解析 JSON: [{"text":"关闭","x":100,"y":200,"w":80,"h":40}, ...]
                -- 简单 Lua 解析
                for text, x, y, w, h in raw:gmatch('"text":"([^"]-)","x":(%d-),"y":(%d-),"w":(%d-),"h":(%d-)"') do
                    table.insert(results, {
                        text = text,
                        x = tonumber(x),
                        y = tonumber(y),
                        w = tonumber(w),
                        h = tonumber(h),
                    })
                end
            end
            break
        end
    end
    return results
end

--- 引擎 2b: 百度 PP-OCRv5 云端 OCR (对应 APK 的 libpaddleocr.so)
--- 中文精度远高于 Vision OCR，需要 Swift 端配置 PaddleOCR 凭据
--- @param keywords table 目标关键词列表
--- @param timeout number 超时秒数 (云端接口较慢)
--- @return table {{text, x, y, w, h, conf}, ...}
function Vision.paddleDetect(keywords, timeout)
    local reqFile = "/tmp/hok_paddle_req.txt"
    local respFile = "/tmp/hok_paddle_resp.json"

    local req = table.concat(keywords, "|")
    local f = io.open(reqFile, "w")
    if not f then return {} end
    f:write(req)
    f:close()

    keepScreen(true)
    snapshot("/tmp/hok_paddle_screen.png")
    keepScreen(false)

    local results = {}
    local maxWait = (timeout or 8) * 10  -- 转为 0.1s 单位
    for i = 1, maxWait do
        usleep(100000) -- 0.1秒
        if fileExists(respFile) then
            local rf = io.open(respFile, "r")
            if rf then
                local raw = rf:read("*a")
                rf:close()
                os.remove(respFile)
                os.remove(reqFile)
                -- 解析: [{"text":"关闭","x":100,"y":200,"w":80,"h":40,"conf":0.98}, ...]
                for text, x, y, w, h, conf in raw:gmatch(
                    '"text":"([^"]-)","x":(%d-),"y":(%d-),"w":(%d-),"h":(%d-),"conf":([%d.]+)'
                ) do
                    table.insert(results, {
                        text = text,
                        x = tonumber(x),
                        y = tonumber(y),
                        w = tonumber(w),
                        h = tonumber(h),
                        confidence = tonumber(conf),
                    })
                end
            end
            break
        end
    end
    return results
end

--- 引擎 3: YOLO 目标检测 (对应 APK 的 libyolo.so)
--- @param classes table 目标类别 {"button","close_button","popup",...}
--- @return table {{class, x, y, w, h, confidence}, ...}
function Vision.yoloDetect(classes)
    local reqFile = "/tmp/hok_yolo_req.txt"
    local respFile = "/tmp/hok_yolo_resp.json"

    local req = table.concat(classes or {"close_button", "popup", "button"}, ",")
    local f = io.open(reqFile, "w")
    if not f then return {} end
    f:write(req)
    f:close()

    keepScreen(true)
    snapshot("/tmp/hok_yolo_screen.png")
    keepScreen(false)

    local results = {}
    for i = 1, 12 do
        usleep(250000)
        if fileExists(respFile) then
            local rf = io.open(respFile, "r")
            if rf then
                local raw = rf:read("*a")
                rf:close()
                os.remove(respFile)
                os.remove(reqFile)
                for class, x, y, w, h, conf in raw:gmatch(
                    '"class":"([^"]-)","x":(%d-),"y":(%d-),"w":(%d-),"h":(%d-),"conf":([%d.]+)'
                ) do
                    table.insert(results, {
                        class = class,
                        x = tonumber(x),
                        y = tonumber(y),
                        w = tonumber(w),
                        h = tonumber(h),
                        confidence = tonumber(conf),
                    })
                end
            end
            break
        end
    end
    return results
end

--- 引擎 4: DeepSeek AI 兜底 (对应 APK 的复杂决策逻辑)
--- 当所有本地引擎都失败时，请求云端 AI
function Vision.deepSeekAnalyze(prompt)
    local reqFile = "/tmp/hok_ds_req.txt"
    local respFile = "/tmp/hok_ds_resp.json"

    keepScreen(true)
    snapshot("/tmp/hok_ds_screen.png")
    keepScreen(false)

    local f = io.open(reqFile, "w")
    if not f then return nil end
    f:write(prompt)
    f:close()

    -- Swift 端负责：截图转 base64 → DeepSeek API → 解析坐标
    local result
    for i = 1, 30 do
        usleep(1000000) -- 1秒
        if fileExists(respFile) then
            local rf = io.open(respFile, "r")
            if rf then
                local raw = rf:read("*a")
                rf:close()
                os.remove(respFile)
                os.remove(reqFile)

                -- 解析坐标: {"action":"click","x":800,"y":400}
                local action = raw:match('"action":"([^"]-)"')
                local x = tonumber(raw:match('"x":(%d+)'))
                local y = tonumber(raw:match('"y":(%d+)'))
                if action == "click" and x and y then
                    result = { action = action, x = x, y = y }
                elseif action == "none" then
                    result = { action = "none" }
                end
            end
            break
        end
    end
    return result
end

-- ===================== L2: 决策引擎层 =====================
-- 仿 APK 的 Lua 脚本决策 + ONNX/NCNN 模型推理
-- 实现优先级队列 + 状态机 + 坐标缓存

local Decision = {}

--- 弹窗按钮定义（优先级越小越高）
local POPUP_BUTTONS = {
    { name = "cancel",   priority = 1, images = {"cancel_btn.png"},                              keywords = {"取消"} },
    { name = "close",    priority = 2, images = {"close_btn.png", "close_btn2.png", "x_btn.png"}, keywords = {"关闭", "X"} },
    { name = "skip",     priority = 3, images = {"skip_btn.png"},                                keywords = {"暂不", "跳过"} },
    { name = "confirm",  priority = 4, images = {"confirm_btn.png"},                             keywords = {"确定", "确认", "知道了"} },
    { name = "announce", priority = 5, images = {},                                             keywords = {"公告", "福利", "活动"} },
}

--- 盲点坐标（当所有识别都失败时的兜底点击位置）
local BLIND_SPOTS = {
    { 1896, 124 },   -- 右上角 X (iPhone Plus)
    { 2076, 146 },   -- 更右上
    { 1340, 732 },   -- 中间取消区域
    { 800,  1400 },  -- 底部区域
    { 1242, 1104 },  -- 屏幕正中央
}

--- 优先级队列弹窗消除
--- @return boolean, string 是否消除了弹窗, 消除方式
function Decision.dismissPopup()
    -- L1: 模板匹配（最快，~0.1秒）
    for _, btn in ipairs(POPUP_BUTTONS) do
        if #btn.images > 0 then
            local x, y, name = Vision.matchAnyTemplate(btn.images, 0.45)
            if x and x > 0 then
                tap(x, y)
                return true, "template:" .. (name or btn.name)
            end
        end
    end

    -- L2: OCR 检测弹窗关键词（~0.5秒）
    local allKW = {}
    for _, btn in ipairs(POPUP_BUTTONS) do
        for _, kw in ipairs(btn.keywords) do
            table.insert(allKW, kw)
        end
    end
    local ocrHits = Vision.ocrDetect(allKW)
    if #ocrHits > 0 then
        -- 按弹窗优先级排序
        for _, btn in ipairs(POPUP_BUTTONS) do
            for _, hit in ipairs(ocrHits) do
                for _, kw in ipairs(btn.keywords) do
                    if hit.text:find(kw) then
                        tap(hit.x, hit.y)
                        return true, "ocr:" .. hit.text
                    end
                end
            end
        end
    end

    -- L3: YOLO 目标检测（~1秒，检测通用 button/close_button）
    local yoloHits = Vision.yoloDetect({"close_button", "button", "popup"})
    for _, hit in ipairs(yoloHits) do
        if hit.confidence >= CONFIG.YOLO_MIN_CONF then
            tap(hit.x, hit.y)
            return true, "yolo:" .. hit.class
        end
    end

    -- L4: 盲点兜底
    for _, pt in ipairs(BLIND_SPOTS) do
        tap(pt[1], pt[2])
        usleep(100000)
    end

    return false, "blind"
end

--- 弹窗消除循环（多轮）
--- @param maxRounds number 最多消除轮数
--- @return number 消除的弹窗数
function Decision.dismissPopupsLoop(maxRounds)
    local rounds = maxRounds or CONFIG.POPUP_MAX_ROUNDS
    local count = 0

    for r = 1, rounds do
        local ok, method = Decision.dismissPopup()
        if ok then
            count = count + 1
            syslog("[popup] round " .. r .. " eliminated via " .. method)
            usleep(CONFIG.POPUP_TAP_DELAY)
        else
            -- 本轮无弹窗，提前退出
            break
        end

        -- 轮间等待屏幕稳定
        usleep(500000)
    end
    return count
end

--- 检测游戏是否已加载到大厅
--- @return boolean
function Decision.isGameLoaded()
    -- 多次截图检测，避免误判
    for attempt = 1, 3 do
        keepScreen(true)
        local imgPath = "/tmp/hok_load_check.png"
        snapshot(imgPath)
        keepScreen(false)

        -- 用 OCR 检测大厅关键词
        local hits = Vision.ocrDetect(CONFIG.LOBBY_KEYWORDS)
        for _, hit in ipairs(hits) do
            for _, kw in ipairs(CONFIG.LOBBY_KEYWORDS) do
                if hit.text:find(kw) then
                    return true
                end
            end
        end

        if attempt < 3 then usleep(1000000) end
    end
    return false
end

--- 检测登录界面
--- @return boolean
function Decision.isLoginScreen()
    local hits = Vision.ocrDetect(CONFIG.LOGIN_KEYWORDS)
    for _, hit in ipairs(hits) do
        for _, kw in ipairs(CONFIG.LOGIN_KEYWORDS) do
            if hit.text:find(kw) then
                return true
            end
        end
    end
    return false
end

--- 查找目标元素（三级降级策略）
--- @param target string 目标描述
--- @param cachedCoords table|nil 缓存坐标 {x, y}
--- @return table|nil {x, y, method}
function Decision.findTarget(target, cachedCoords)
    -- L1: CoordCache 缓存命中（瞬时）
    if cachedCoords and cachedCoords.x and cachedCoords.x > 0 then
        return { x = cachedCoords.x, y = cachedCoords.y, method = "cache" }
    end

    -- L2: 模板匹配（0.1s）
    local tmplFile = target:gsub("[^%w]", "_") .. ".png"
    local x, y = Vision.matchTemplate(tmplFile, 0.5)
    if x and x > 0 then
        return { x = x, y = y, method = "template" }
    end

    -- L3: OCR 定位（0.5s）
    local ocrHits = Vision.ocrDetect({ target })
    if #ocrHits > 0 then
        return { x = ocrHits[1].x, y = ocrHits[1].y, method = "ocr" }
    end

    -- L4: DeepSeek AI（5-10s）
    local aiResult = Vision.deepSeekAnalyze("找到并点击: " .. target)
    if aiResult and aiResult.action == "click" then
        return { x = aiResult.x, y = aiResult.y, method = "ai" }
    end

    return nil
end

-- ===================== L3: 执行层 =====================
-- 仿 APK 的 /dev/input 注入 + 无障碍服务 + 输入法
-- iOS 等价: autotouch 命令 + 验证闭环

local Executor = {}

--- 基础点击（通过 autotouch）
--- @param x number
--- @param y number
function Executor.tap(x, y)
    touchDown(0, x, y)
    usleep(50000)
    touchUp(0, x, y)
end

--- 长按
--- @param x number
--- @param y number
--- @param duration number 秒
function Executor.longPress(x, y, duration)
    touchDown(0, x, y)
    usleep((duration or 1) * 1000000)
    touchUp(0, x, y)
end

--- 滑动
--- @param x1, y1, x2, y2 number
function Executor.swipe(x1, y1, x2, y2)
    touchDown(0, x1, y1)
    local steps = 10
    local dx = (x2 - x1) / steps
    local dy = (y2 - y1) / steps
    for i = 1, steps do
        usleep(16000)
        touchMove(0, x1 + dx * i, y1 + dy * i)
    end
    usleep(50000)
    touchUp(0, x2, y2)
end

--- 文本输入（通过 Swift 端键盘模拟）
--- @param text string
function Executor.inputText(text)
    local reqFile = "/tmp/hok_input_req.txt"
    local respFile = "/tmp/hok_input_done.txt"

    local f = io.open(reqFile, "w")
    if not f then return false end
    f:write(text)
    f:close()

    -- 等待 Swift 端通过 UIKeyCommand 或粘贴板输入
    for i = 1, 20 do
        usleep(500000)
        if fileExists(respFile) then
            os.remove(respFile)
            os.remove(reqFile)
            return true
        end
    end
    os.remove(reqFile)
    return false
end

--- 打开应用
--- @param bundleID string
function Executor.openApp(bundleID)
    local cmd = "su mobile -c 'activator send " .. (bundleID or CONFIG.GAME_BUNDLE) .. "'"
    os.execute(cmd)
end

--- 关闭应用
--- @param processName string
function Executor.killApp(processName)
    local name = processName or CONFIG.GAME_NAME
    local cmd = "su mobile -c 'killall -9 " .. name .. " 2>/dev/null'"
    os.execute(cmd)
end

--- 截图保存
--- @param path string
function Executor.screenshot(path)
    keepScreen(true)
    snapshot(path)
    keepScreen(false)
end

--- 验证步骤是否成功（OCR 检查屏幕文字）
--- @param keywords table 期望出现的关键词
--- @return boolean, string
function Executor.verifyStep(keywords)
    if not keywords or #keywords == 0 then
        return true, "no_verify"
    end
    usleep(500000) -- 等动画
    local hits = Vision.ocrDetect(keywords)
    for _, hit in ipairs(hits) do
        for _, kw in ipairs(keywords) do
            if hit.text:find(kw) then
                return true, hit.text
            end
        end
    end
    return false, ""
end

--- 执行单个步骤（带重试和验证）
--- @param step table {action, target, retries, wait, verify}
--- @param cachedCoords table|nil
--- @return boolean, string
function Executor.executeStep(step, cachedCoords)
    local action = step.action or "click"
    local target = step.target or ""
    local maxRetries = step.retries or CONFIG.MAX_RETRIES
    local waitAfter = step.wait or CONFIG.WAIT_AFTER_CLICK
    local verifyKeywords = step.verify

    -- 特殊动作
    if action == "open_app" then
        Executor.openApp(target)
        usleep(waitAfter * 1000000)
        return true, "open_app"
    elseif action == "kill_app" then
        Executor.killApp(target)
        usleep(waitAfter * 1000000)
        return true, "kill_app"
    elseif action == "wait" then
        usleep((tonumber(target) or waitAfter) * 1000000)
        return true, "wait"
    elseif action == "input_text" then
        Executor.inputText(target)
        usleep(waitAfter * 1000000)
        return true, "input_text"
    elseif action == "swipe" then
        -- target 格式: "x1,y1,x2,y2"
        local x1, y1, x2, y2 = target:match("(%d+),(%d+),(%d+),(%d+)")
        if x1 then
            Executor.swipe(tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2))
        end
        usleep(waitAfter * 1000000)
        return true, "swipe"
    end

    -- 标准点击步骤 + 重试
    for attempt = 1, maxRetries do
        -- 每次重试前消除弹窗
        if attempt > 1 then
            Decision.dismissPopupsLoop(2)
        end

        local targetInfo = Decision.findTarget(target, cachedCoords)
        if targetInfo then
            Executor.tap(targetInfo.x, targetInfo.y)
            usleep(waitAfter * 1000000)

            -- OCR 验证
            local ok, matchedText = Executor.verifyStep(verifyKeywords)
            if ok then
                return true, targetInfo.method .. ":" .. (matchedText or "")
            else
                syslog("[step] verify failed, retry " .. attempt .. "/" .. maxRetries)
                -- 缓存可能已过期，标记失效
                if cachedCoords then
                    cachedCoords.x = nil
                    cachedCoords.y = nil
                end
            end
        else
            syslog("[step] target not found, retry " .. attempt .. "/" .. maxRetries)
        end
    end

    return false, "max_retries"
end

-- ===================== L4: 持久化层 =====================
-- 仿 APK 的 MySQL + JavaMail，iOS 用文件 + syslog

local Storage = {}

--- 写日志
--- @param level string "INFO"/"WARN"/"ERROR"
--- @param msg string
function Storage.log(level, msg)
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = "[" .. ts .. "] [" .. (level or "INFO") .. "] " .. (msg or "")
    syslog(line)

    -- 同时写文件
    local logFile = CONFIG.DIR_LOGS .. "/auto_" .. os.date("%Y%m%d") .. ".log"
    local f = io.open(logFile, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    end
end

--- 保存坐标缓存
--- @param cache table
function Storage.saveCache(cache)
    local cacheFile = CONFIG.DIR_CACHE .. "/coord_cache.json"
    local f = io.open(cacheFile, "w")
    if not f then return false end
    -- 简单 JSON 序列化
    local items = {}
    for label, coord in pairs(cache) do
        table.insert(items, string.format(
            '{"label":"%s","x":%d,"y":%d,"hits":%d,"source":"%s"}',
            label, coord.x or 0, coord.y or 0, coord.hits or 0, coord.source or "lua"
        ))
    end
    f:write("[" .. table.concat(items, ",") .. "]")
    f:close()
    return true
end

--- 加载坐标缓存
--- @return table
function Storage.loadCache()
    local cache = {}
    local cacheFile = CONFIG.DIR_CACHE .. "/coord_cache.json"
    local f = io.open(cacheFile, "r")
    if not f then return cache end
    local raw = f:read("*a")
    f:close()

    for label, x, y, hits, source in raw:gmatch(
        '"label":"([^"]-)","x":(%d-),"y":(%d-),"hits":(%d-),"source":"([^"]-)"'
    ) do
        cache[label] = {
            x = tonumber(x),
            y = tonumber(y),
            hits = tonumber(hits),
            source = source,
            lastHit = os.time(),
        }
    end
    return cache
end

-- ===================== 任务模板库 =====================
-- 仿 APK 的预置脚本模板

local Templates = {

    --- 充值点券
    recharge = function(amount)
        local amt = amount or "45"
        return {
            { action = "open_app",  target = CONFIG.GAME_BUNDLE, wait = 2 },
            { action = "wait",      target = "10", retries = 30, verify = CONFIG.LOBBY_KEYWORDS,
              desc = "等待游戏加载到大厅" },
            { action = "click",     target = "点券充值入口", retries = 4, wait = 2,
              verify = {"点券", "充值"}, desc = "进入充值界面" },
            { action = "click",     target = amt .. "点券", retries = 3, wait = 1,
              verify = { amt }, desc = "选择" .. amt .. "点券" },
            { action = "click",     target = "确认支付", retries = 3, wait = 2.5,
              verify = {"支付", "密码", "Touch ID"}, desc = "确认支付" },
            { action = "input_text", target = "", retries = 1, wait = 2,
              desc = "输入密码" },
            { action = "click",     target = "支付完成返回", retries = 3, wait = 1.5,
              verify = {"充值成功", "支付成功"}, desc = "等待支付结果" },
        }
    end,

    --- 每日签到
    dailyCheckin = {
        { action = "open_app",  target = CONFIG.GAME_BUNDLE, wait = 2 },
        { action = "wait",      target = "10", retries = 30, verify = CONFIG.LOBBY_KEYWORDS },
        { action = "click",     target = "活动入口", retries = 4, wait = 2,
          verify = {"活动", "签到", "每日"} },
        { action = "click",     target = "签到按钮", retries = 3, wait = 1.5,
          verify = {"已签到", "签到成功"} },
        { action = "click",     target = "领取奖励", retries = 3, wait = 1, optional = true },
    },

    --- 领取邮件
    claimMail = {
        { action = "open_app",  target = CONFIG.GAME_BUNDLE, wait = 2 },
        { action = "wait",      target = "10", retries = 30, verify = CONFIG.LOBBY_KEYWORDS },
        { action = "click",     target = "邮件入口", retries = 3, wait = 1.5,
          verify = {"邮件", "系统邮件"} },
        { action = "click",     target = "一键领取", retries = 3, wait = 1,
          verify = {"领取"} },
        { action = "click",     target = "关闭邮件", retries = 2, wait = 1, optional = true },
    },

    --- 购买英雄
    buyHero = function(heroName)
        return {
            { action = "open_app",  target = CONFIG.GAME_BUNDLE, wait = 2 },
            { action = "wait",      target = "10", retries = 30, verify = CONFIG.LOBBY_KEYWORDS },
            { action = "click",     target = "商城入口", retries = 3, wait = 2,
              verify = {"商城", "商店"} },
            { action = "click",     target = "英雄 tab", retries = 3, wait = 1.5,
              verify = {"英雄"} },
            { action = "click",     target = heroName or "英雄", retries = 4, wait = 1.5,
              verify = { heroName or "英雄" } },
            { action = "click",     target = "购买按钮", retries = 3, wait = 2,
              verify = {"购买", "金币", "点券"} },
            { action = "click",     target = "确认购买", retries = 2, wait = 2,
              verify = {"获得", "购买成功"} },
        }
    end,
}

-- ===================== 主循环 =====================

local Engine = {}

--- 空闲守护模式：持续监控并消除弹窗
--- @param duration number 守护时长 (秒), 0=无限
function Engine.idleGuard(duration)
    local startTime = os.time()
    Storage.log("INFO", "=== 空闲守护启动 ===")

    local tickCount = 0
    while true do
        -- 超时检查
        if duration > 0 and (os.time() - startTime) >= duration then
            Storage.log("INFO", "守护时长到达，退出")
            break
        end

        tickCount = tickCount + 1
        Storage.log("INFO", "tick " .. tickCount)

        -- 弹窗消除
        local eliminated = Decision.dismissPopupsLoop()
        if eliminated > 0 then
            Storage.log("INFO", "消除 " .. eliminated .. " 个弹窗")
        end

        -- 每30秒 OCR 全量扫描
        if tickCount % 10 == 0 then
            Storage.log("INFO", "全量OCR扫描")
            local hits = Vision.ocrDetect(CONFIG.POPUP_KEYWORDS)
            for _, hit in ipairs(hits) do
                Executor.tap(hit.x, hit.y)
                usleep(150000)
            end
        end

        -- 休眠
        usleep(CONFIG.TICK_INTERVAL * 1000000)
    end

    Storage.log("INFO", "=== 空闲守护结束 ===")
end

--- 任务模式：执行指定任务
--- @param taskName string 任务名 ("recharge", "dailyCheckin", "claimMail", "buyHero")
--- @param params table 任务参数 {amount="45", heroName="妲己", ...}
--- @return boolean, string
function Engine.runTask(taskName, params)
    params = params or {}
    Storage.log("INFO", "=== 开始任务: " .. taskName .. " ===")

    -- 获取步骤列表
    local steps
    if taskName == "recharge" then
        steps = Templates.recharge(params.amount)
    elseif taskName == "dailyCheckin" then
        steps = Templates.dailyCheckin
    elseif taskName == "claimMail" then
        steps = Templates.claimMail
    elseif taskName == "buyHero" then
        steps = Templates.buyHero(params.heroName)
    else
        return false, "未知任务: " .. taskName
    end

    -- 加载坐标缓存
    local cache = Storage.loadCache()
    local completed = 0
    local total = #steps

    for i, step in ipairs(steps) do
        local stepDesc = step.desc or step.action .. ":" .. (step.target or "")
        Storage.log("INFO", "步骤 " .. i .. "/" .. total .. ": " .. stepDesc)

        -- 步骤前弹窗消除
        Decision.dismissPopupsLoop(2)

        -- 查找缓存坐标
        local cachedKey = step.target or ""
        local cachedCoords = cache[cachedKey]

        -- 执行步骤
        local ok, reason = Executor.executeStep(step, cachedCoords)
        if ok then
            completed = completed + 1
            Storage.log("INFO", "  ✓ " .. stepDesc .. " (" .. reason .. ")")

            -- 更新缓存
            if step.target then
                cache[step.target] = cache[step.target] or {}
                cache[step.target].hits = (cache[step.target].hits or 0) + 1
                cache[step.target].lastHit = os.time()
                cache[step.target].source = reason
            end
        else
            Storage.log("ERROR", "  ✗ " .. stepDesc .. " 失败: " .. reason)
            if not step.optional then
                Storage.saveCache(cache)
                return false, "步骤" .. i .. "失败: " .. stepDesc
            else
                Storage.log("WARN", "  可选步骤，跳过")
                completed = completed + 1
            end
        end

        -- 步骤间弹窗检查
        Decision.dismissPopupsLoop(1)
    end

    -- 保存缓存
    Storage.saveCache(cache)

    -- 自动关闭游戏
    Executor.killApp(CONFIG.GAME_NAME)
    usleep(1000000)

    Storage.log("INFO", "=== 任务完成: " .. completed .. "/" .. total .. " 步 ===")
    return true, "完成 " .. completed .. "/" .. total .. " 步"
end

--- 完整自动化：加载游戏 → 登录 → 弹窗消除 → 任务 → 退出
--- @param taskName string
--- @param params table
function Engine.fullAuto(taskName, params)
    Storage.log("INFO", "========== 全自动任务开始 ==========")

    -- 1. 确保游戏运行
    Executor.openApp(CONFIG.GAME_BUNDLE)
    usleep(5000000) -- 5秒启动

    -- 2. 等待加载到大厅
    Storage.log("INFO", "等待游戏加载...")
    local loaded = false
    for i = 1, 30 do
        usleep(3000000) -- 3秒
        Decision.dismissPopupsLoop(2) -- 期间可能弹公告/活动
        if Decision.isGameLoaded() then
            loaded = true
            Storage.log("INFO", "游戏加载完成，等待冷却")
            usleep(10000000) -- 10秒冷却
            break
        end
        Storage.log("INFO", "等待加载 " .. (i * 3) .. "s")
    end

    if not loaded then
        Storage.log("ERROR", "游戏加载超时")
        return false, "游戏加载超时"
    end

    -- 3. 检测登录
    if Decision.isLoginScreen() then
        Storage.log("INFO", "检测到登录界面")
        local loginHit = Decision.findTarget("登录按钮", nil)
        if loginHit then
            Executor.tap(loginHit.x, loginHit.y)
            usleep(5000000)
        end
    end

    -- 4. 执行任务
    local ok, msg = Engine.runTask(taskName, params)
    Storage.log("INFO", "========== 全自动任务结束: " .. msg .. " ==========")
    return ok, msg
end

-- ===================== 入口 =====================

--- 主入口：根据命令行参数决定运行模式
local function main()
    -- 确保目录存在
    os.execute("mkdir -p " .. CONFIG.DIR_LOGS)
    os.execute("mkdir -p " .. CONFIG.DIR_CACHE)

    -- 解析参数
    local args = {}
    local mode = "guard"  -- 默认守护模式

    -- AutoTouch 传入参数格式: "mode=task taskName=recharge amount=45"
    -- 或者直接作为全局变量由 Swift 设置
    if _ARGS then
        for k, v in _ARGS:gmatch("(%w+)=([%w_]+)") do
            args[k] = v
        end
    elseif HOK_MODE then
        mode = HOK_MODE
        if HOK_PARAMS then
            for k, v in HOK_PARAMS:gmatch("(%w+)=([%w_]+)") do
                args[k] = v
            end
        end
    end

    if args.mode then mode = args.mode end

    -- 路由
    if mode == "guard" then
        local duration = tonumber(args.duration) or 0
        Engine.idleGuard(duration)

    elseif mode == "task" then
        local taskName = args.taskName or args.task or "dailyCheckin"
        local params = {
            amount = args.amount,
            heroName = args.heroName,
        }
        Engine.runTask(taskName, params)

    elseif mode == "fullAuto" then
        local taskName = args.taskName or args.task or "dailyCheckin"
        local params = {
            amount = args.amount,
            heroName = args.heroName,
        }
        Engine.fullAuto(taskName, params)

    elseif mode == "test" then
        -- 测试模式：拍照并 OCR
        Storage.log("INFO", "=== 测试模式 ===")
        Executor.screenshot("/tmp/hok_test.png")
        Storage.log("INFO", "截图已保存")

        local hits = Vision.ocrDetect(CONFIG.POPUP_KEYWORDS)
        for _, hit in ipairs(hits) do
            Storage.log("INFO", "OCR: " .. hit.text .. " @ (" .. hit.x .. "," .. hit.y .. ")")
        end

    else
        Storage.log("ERROR", "未知模式: " .. mode)
        Storage.log("INFO", "可用模式: guard | task | fullAuto | test")
    end
end

-- 运行
main()
