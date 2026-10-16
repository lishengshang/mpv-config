-- toggleHDR.lua —— 按视频类型自动切换 Windows HDR，依赖 HDRTray 的 HDRCmd.exe。
-- 上游：https://github.com/yosh-wang/mpv-hdr-auto-toggle
-- 本地改动：配置改用 mp.options.read_options，使 ~~/local.conf 可覆盖 hdr_cmd_path；
-- 路径未配置或 HDRCmd 不可用时只记一行日志后退出，不在每次换片时反复告警。
local msg = require 'mp.msg'
local o = {
    enabled = true,
    hdr_cmd_path = '',
    hdr_hdr = true,
    hdr_off_open = true,
    hdr_open_off = true,
    sdr_sdr = true,
}
require('mp.options').read_options(o, 'toggleHDR')

if not o.enabled then
    msg.info('toggleHDR: 已禁用，不接管 HDR 切换')
    return
end

local HDR_CMD = (o.hdr_cmd_path or ''):match('^%s*(.-)%s*$')
if HDR_CMD == '' then
    msg.info('toggleHDR: 未配置 hdr_cmd_path，跳过；安装 HDRTray 后写入 ~~/local.conf')
    return
end
HDR_CMD = mp.command_native({'normalize-path', mp.command_native({'expand-path', HDR_CMD})})

-- mpv 在启动子进程失败时把 error 置为空串而非 nil，需要逐项回退才能给出可用原因。
local function fail_reason(r)
    if not r then return 'no result' end
    if r.error and r.error ~= '' then return r.error end
    local stderr = (r.stderr or ''):match('^%s*(.-)%s*$')
    if stderr ~= nil and stderr ~= '' then return stderr end
    return '退出码 ' .. tostring(r.status)
end

local function hdr_status()
    local r = mp.command_native({name = 'subprocess', args = {HDR_CMD, 'status'},
        capture_stdout = true, capture_stderr = true, playback_only = false})
    if not r or r.status ~= 0 then
        msg.warn('toggleHDR: 无法执行 ' .. HDR_CMD .. ' status：' .. fail_reason(r))
        return nil
    end
    return r.stdout:match('%s*on%s*') ~= nil
end

local function hdr_set(on)
    local r = mp.command_native({name = 'subprocess', args = {HDR_CMD, on and 'on' or 'off'},
        playback_only = false, detach = true, capture_stderr = true})
    if r.error and r.error ~= '' then
        msg.warn('toggleHDR: 执行 ' .. HDR_CMD .. ' 失败：' .. r.error)
    end
end

local initial_hdr_state = hdr_status()
if initial_hdr_state == nil then return end
msg.info('toggleHDR: 启动时显示器 HDR = ' .. tostring(initial_hdr_state))

local hdr_was_toggled = false

local function restore_hdr()
    if hdr_was_toggled then
        msg.info('toggleHDR: 恢复显示器 HDR 为 ' .. tostring(initial_hdr_state))
        hdr_set(initial_hdr_state)
        hdr_was_toggled = false
    end
end

mp.register_event('end-file', function()
    if mp.get_property_number('playlist-pos-1', 0) < mp.get_property_number('playlist-count', 0) then return end
    restore_hdr()
end)

mp.register_event('shutdown', restore_hdr)

mp.observe_property('video-params', 'native', function(_, params)
    if not params or not params.primaries or not params.gamma then return end
    local is_hdr = params.primaries == 'bt.2020' and (params.gamma == 'pq' or params.gamma == 'hlg')
    local current_hdr = hdr_status()
    if current_hdr == nil then return end

    if is_hdr == current_hdr then
        if (is_hdr and o.hdr_hdr) or (not is_hdr and o.sdr_sdr) then
            msg.info('toggleHDR: ' .. (is_hdr and '#1 HDR+HDR' or '#4 SDR+SDR') .. ' → 保持现状')
        end
        return
    end

    if is_hdr then
        if not o.hdr_open_off then
            msg.info('toggleHDR: #3 SDR+HDR → 该规则已禁用，跳过')
            return
        end
        msg.info('toggleHDR: #3 SDR+HDR → 开启显示器 HDR')
        hdr_set(true)
    else
        if not o.hdr_off_open then
            msg.info('toggleHDR: #2 HDR+SDR → 该规则已禁用，跳过')
            return
        end
        msg.info('toggleHDR: #2 HDR+SDR → 关闭显示器 HDR')
        hdr_set(false)
    end
    hdr_was_toggled = true
end)
