-- common.lua - 通用工具函数
-- VisionEngine Lua API: vision.click(x,y), vision.findTemplate(), vision.ocr(), vision.yolo()

local M = {}

-- 多点位轮询点击
function M.pollClick(points, interval_ms)
    for _, p in ipairs(points) do
        vision.click(p[1], p[2])
        usleep(interval_ms or 200000)
    end
end

-- 模板匹配点击
function M.matchAndClick(tmpl, threshold)
    local x, y = vision.findTemplate(tmpl, threshold or 0.7)
    if x and x > 0 then
        vision.click(x, y)
        return true
    end
    return false
end

-- 批量模板匹配
function M.matchAny(images, threshold)
    for _, img in ipairs(images) do
        if M.matchAndClick(img, threshold) then return true end
    end
    return false
end

-- 等待指定时间
function M.wait(seconds)
    local ms = (seconds or 1) * 1000000
    usleep(ms)
end

return M
