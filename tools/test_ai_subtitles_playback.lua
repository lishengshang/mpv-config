-- Real mpv routing, subtitle loading, next-file, reset and persistent reuse.
local utils = require 'mp.utils'
local o = {root = '', first = '', second = '', timeout = 180, menu_switch = false, management = false}
require('mp.options').read_options(o, 'asr-playback')
package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local cache = require 'ai-subtitle-cache'
local phase, previous, first_result, second_result = 0, nil, nil, nil
local started = mp.get_time()
local function check(ok, reason) if not ok then error(reason) end end
local function cached_track()
    for _, track in ipairs(mp.get_property_native('track-list', {})) do
        local path = track['external-filename']
        if track.type == 'sub' and path and path:gsub('\\', '/'):find(o.root .. '/results/', 1, true) then
            return path
        end
    end
end
local function verify(path)
    check(cache.valid_srt(cache.read(path)), 'valid subtitle output')
    local dir = utils.split_path(path)
    local meta = utils.parse_json(cache.read(utils.join_path(dir, 'complete.json')) or '')
    check(meta and meta.complete, 'completion marker required')
    check(meta.payload == cache.digest(cache.read(path)), 'completed output checksum')
end
local function clean_media_folder(media)
    for _, name in ipairs(utils.readdir(utils.split_path(media), 'files') or {}) do
        check(not name:lower():match('%.srt$') and not name:lower():match('%.ass$') and
            not name:lower():match('%.vtt$'), 'no media sidecar: ' .. name)
    end
end
local function reset_subtitles()
    mp.commandv('set', 'sub-delay', '1.5')
    mp.commandv('set', 'secondary-sub-delay', '-1')
    mp.commandv('keypress', 'SHIFT+BS')
end
local function reset_done()
    return mp.get_property_number('sub-delay') == 0 and mp.get_property_number('secondary-sub-delay') == 0
end
mp.register_event('file-loaded', function()
    local ok, err = pcall(function()
        check(mp.get_property_number('duration', 0) > 0, 'media duration available')
        check(mp.get_property_native('current-tracks/audio') ~= nil, 'audio track loaded')
        if phase == 0 then
            if o.menu_switch then
                phase = 90
                mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-backend-menu')
            else
                phase = 1
                mp.commandv('keypress', 'ALT+f')
            end
        elseif phase == 12 then
            phase = 2
            check(not cached_track(), 'next file does not inherit prior subtitle')
            mp.commandv('keypress', 'ALT+f')
        elseif phase == 32 then phase = 3
        end
    end)
    if not ok then mp.msg.error('ASR CACHE PLAYBACK FAIL: ' .. tostring(err)); mp.commandv('quit', '3') end
end)
mp.add_periodic_timer(0.15, function()
    local ok, err = pcall(function()
        check(mp.get_time() - started < o.timeout, 'playback test timeout')
        local result = cached_track()
        if phase == 90 and mp.get_property_native('user-data/uosc/menu/type') == 'ai-subtitle-backend' then
            -- uosc publishes its type before finishing menu layout and enabling bindings.
            phase, previous = 94, mp.get_time()
        elseif phase == 94 and mp.get_time() - previous > 0.3 then
            phase, previous = 91, mp.get_time()
            mp.commandv('keypress', 'END')
        elseif phase == 91 and mp.get_time() - previous > 0.3 then
            phase = 92
            mp.commandv('keypress', 'ENTER')
        elseif phase == 92 and mp.get_property_native('user-data/ai-subtitles/backend') == 'qwen' then
            phase = 1
            mp.commandv('keypress', 'ESC')
            mp.commandv('keypress', 'ALT+f')
        elseif phase == 1 and result then
            verify(result)
            clean_media_folder(o.first)
            first_result, phase = result, 11
            reset_subtitles()
            mp.msg.info('ASR CACHE STEP PASS: first generation')
        elseif phase == 11 and reset_done() then
            phase = 12
            mp.commandv('loadfile', o.second, 'replace')
        elseif phase == 2 and result then
            check(result ~= first_result, 'same basename uses distinct cache')
            verify(result)
            clean_media_folder(o.second)
            second_result, phase = result, 21
            reset_subtitles()
            mp.msg.info('ASR CACHE STEP PASS: next-file generation')
        elseif phase == 21 and reset_done() then
            phase = 32
            mp.commandv('loadfile', o.first, 'replace')
        elseif phase == 3 and result then
            check(result == first_result, 'first file auto-reuses original result')
            check(mp.get_property('current-tracks/sub/external-filename') == first_result,
                'automatic reuse selects subtitle when no other subtitle is selected')
            verify(result)
            mp.commandv('keypress', 'ALT+f')
            reset_subtitles()
            previous, phase = mp.get_time(), 4
        elseif phase == 4 and mp.get_time() - previous > 0.5 then
            check(reset_done(), 'existing subtitle reset shortcut')
            clean_media_folder(o.first)
            clean_media_folder(o.second)
            if o.management then
                phase, previous = 70, mp.get_time()
                mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-manager')
                return
            end
            if o.menu_switch then
                mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-backend', 'whisper')
                phase = 93
                return
            end
            phase = 93
        elseif phase == 70 and mp.get_property_native('user-data/uosc/menu/type') == 'ai-subtitle-manager' and mp.get_time() - previous > 0.4 then
            local status = mp.get_property_native('user-data/ai-subtitles/status', {})
            check(status.cached and not status.running, 'management status reflects current completed cache')
            mp.commandv('screenshot-to-file', o.root .. '/management.png', 'window')
            mp.commandv('keypress', 'HOME')
            phase, previous = 71, mp.get_time()
        elseif phase == 71 and mp.get_time() - previous > 0.2 then
            mp.commandv('keypress', 'DOWN'); phase, previous = 72, mp.get_time()
        elseif phase == 72 and mp.get_time() - previous > 0.2 then
            mp.commandv('keypress', 'ENTER'); phase = 73
        elseif phase == 73 and mp.get_property_native('user-data/ai-subtitles/status/running') then
            verify(first_result) -- Previous completed result remains valid while regenerating.
            phase = 74
        elseif phase == 74 and not mp.get_property_native('user-data/ai-subtitles/status/running') then
            verify(first_result)
            mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-export', o.root .. '/selected-export.srt')
            phase = 75
        elseif phase == 75 and cache.read(o.root .. '/selected-export.srt') then
            check(cache.read(o.root .. '/selected-export.srt') == cache.read(first_result), 'explicit export matches completed result')
            clean_media_folder(o.first); clean_media_folder(o.second)
            mp.commandv('keypress', 'ESC')
            if o.menu_switch then mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-backend', 'whisper') end
            phase = 93
        elseif phase == 93 then
            if o.menu_switch then
                check(mp.get_property_native('user-data/ai-subtitles/backend') == 'whisper', 'restored default engine')
                check(not cached_track(), 'Qwen subtitle removed on switch back')
            end
            check(cache.write(utils.join_path(o.root, 'playback.json'), utils.format_json({
                first = first_result, second = second_result, menu_switch = o.menu_switch, passed = true}) .. '\n'), 'write report')
            mp.msg.info('ASR CACHE PLAYBACK PASS: generate, next-file, reset, automatic and explicit reuse')
            phase = 5
            mp.commandv('quit', '0')
        end
    end)
    if not ok then mp.msg.error('ASR CACHE PLAYBACK FAIL: ' .. tostring(err)); mp.commandv('quit', '3') end
end)
