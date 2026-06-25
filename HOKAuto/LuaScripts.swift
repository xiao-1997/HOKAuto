import Foundation

/// Lua 脚本常量（编译时内嵌）
struct LuaScripts {
    static let hokMain: String = {
        let imgDir = "/var/mobile/Library/AutoTouch/Scripts/Images"
        return """
-- hok_main.lua
local D = "\(imgDir)"
local PRIORITY_ALERT = { auth_clean = {imgs={D.."/alert_clean.png",D.."/alert_auth.png"}, fb={{1000,500},{1100,550}}} }
local BUTTONS = {
    cancel={imgs={D.."/cancel_btn.png"}},
    close={imgs={D.."/close_btn.png",D.."/close_btn2.png",D.."/x_btn.png"}, fb={{1896,124},{1876,99}}},
    announce={imgs={D.."/announce_x.png",D.."/x_announce.png"}, fb={{2100,100},{1800,100}}},
    skip={imgs={D.."/skip_btn.png"}},
    login={imgs={D.."/login_btn.png"}},
}
local function loadAI()
    local ai={}
    local f=io.popen("ls "..D.."/ai_*.png 2>/dev/null")
    if f then for l in f:lines() do local n=l:match("ai_(.+)_%d+%.png") if n then if not ai[n] then ai[n]={} end table.insert(ai[n],D.."/"..l) end end f:close() end
    return ai
end
local function match(imgs,ms)
    local d=os.time()+(ms or 3)
    while os.time()<d do for _,img in ipairs(imgs) do if fileExists(img) then keepScreen(true) local x,y=findImage(img,1,0.5,nil,nil) keepScreen(false) if x and x>0 then return x,y end end end usleep(200000) end
    return nil
end
local function tap(x,y) touchDown(0,x,y) usleep(50000) touchUp(0,x,y) end
local function matchAll(ms)
    for _,b in pairs(PRIORITY_ALERT) do local p=match(b.imgs,1) if p then return p,"priority" end end
    for _,b in pairs(PRIORITY_ALERT) do for _,pt in ipairs(b.fb) do tap(pt[1],pt[2]) usleep(200000) end end
    local ai=loadAI()
    for _,name in ipairs({"cancel","close","announce","skip"}) do local p=match(BUTTONS[name].imgs,1) if p then return p,name end end
    for _,imgs in pairs(ai) do local p=match(imgs,1) if p then return p,"ai" end end
    return nil
end
local loginDone,ai_count=false,0
for i=1,20 do
    local p,name=matchAll(3)
    if p then tap(p[1],p[2])
    else
        ai_count=ai_count+1
        if ai_count<=5 then
            keepScreen(true) snapshot("/tmp/_ds_screen.jpg") keepScreen(false)
            local f=io.open("/tmp/ds_request.txt","w") if f then f:write("popup") f:close() end
            for j=1,20 do usleep(500000)
                if fileExists("/tmp/ds_response.txt") then
                    local r=io.open("/tmp/ds_response.txt") if r then local t=r:read("*a") r:close() os.remove("/tmp/ds_response.txt") local x=tonumber(t:match('"x":(%d+)'))or 0 local y=tonumber(t:match('"y":(%d+)'))or 0 if x>0 then tap(x,y) end end
                    break
                end
            end
        end
        for _,pt in ipairs(BUTTONS.close.fb) do tap(pt[1],pt[2]) usleep(200000) end
    end
    if i>=6 and not loginDone then local lp=match(BUTTONS.login.imgs,3) if lp then tap(lp[1],lp[2]) loginDone=true end end
    usleep(2000000)
end
"""
    }()
}
