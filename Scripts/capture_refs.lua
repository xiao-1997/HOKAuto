-- capture_refs.lua - 截取参考按钮图片
-- 用法: 王者荣耀出现对应按钮时执行
-- autotouch play start /tmp/capture_refs.lua

local DIR = "/var/mobile/Library/AutoTouch/Scripts/Images"

-- 截取指定区域并保存
local function capture(name, x, y, w, h)
    keepScreen(true)
    snapshot(DIR .. "/" .. name, x, y, w, h)
    keepScreen(false)
end

-- 取消按钮 (录制坐标: 1340, 732 附近)
capture("cancel_btn.png", 1310, 700, 80, 60)

-- 关闭按钮 (录制坐标: 1896, 124 附近)
capture("close_btn.png", 1840, 80, 120, 100)

-- 关闭按钮2
capture("close_btn2.png", 1870, 110, 80, 60)

-- 登录按钮 (录制坐标: 1209, 945 附近)
capture("login_btn.png", 1170, 910, 100, 70)

-- X关闭按钮 (右上角区域)
capture("x_btn.png", 1850, 70, 140, 120)
