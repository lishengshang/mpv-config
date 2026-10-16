-- auto_bluray.lua —— 在 mpv 打开文件前拦截 .iso，改走蓝光协议播放。
-- 上游：https://github.com/yosh-wang/auto_bluray-ISO-
-- 只认扩展名 .iso，不处理 BDMV 文件夹；非蓝光 ISO（如 DVD）会切换失败并报错。

-- 在 mpv 打开文件前拦截，切换蓝光模式
local function switch_to_bluray()
    local path = mp.get_property("path")
    if not path or not path:lower():match("%.iso$") then
        return
    end

    -- 检查是否已经是蓝光模式
    local current = mp.get_property("stream-open-filename") or ""
    if current:find("^bd://") then
        return
    end

    mp.msg.info("检测到 ISO 文件，切换蓝光模式: " .. path)
    mp.osd_message("检测到蓝光ISO，切换播放模式...", 2)

    -- 替换为蓝光协议
    mp.set_property("stream-open-filename", "bd://")
    mp.set_property("bluray-device", path)
end

mp.add_hook("on_load", 10, switch_to_bluray)
