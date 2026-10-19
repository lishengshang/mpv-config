-- Real mpv routing, subtitle loading, next-file, reset and persistent reuse.
local utils = require 'mp.utils'
local o = {root = '', first = '', second = '', timeout = 180, menu_switch = false, management = false, segment = false, render = false}
require('mp.options').read_options(o, 'asr-playback')
package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local cache = require 'ai-subtitle-cache'
local phase, previous, first_result, second_result = 0, nil, nil, nil
local started = mp.get_time()
local job_started, cancel_sent, partial_path
local metrics = {}
local screenshot_pending = false
local function generate(next_phase)
    phase, job_started = next_phase, mp.get_time()
    mp.commandv('keypress', 'ALT+f')
end
local function check(ok, reason) if not ok then error(reason) end end
local function capture_subtitles(path, name)
    if not o.render then return end
    local first, last = cache.read(path):match('(%d%d:%d%d:%d%d,%d%d%d)%s+%-%->%s+(%d%d:%d%d:%d%d,%d%d%d)')
    local function seconds(value)
        local h, m, s, ms = value:match('(%d+):(%d+):(%d+),(%d+)')
        return h * 3600 + m * 60 + s + ms / 1000
    end
    check(first and last, 'screenshot requires a timed subtitle')
    local target = (seconds(first) + seconds(last)) / 2
    mp.commandv('seek', target, 'absolute+exact')
    screenshot_pending = true
    local deadline = mp.get_time() + 10
    local function capture()
        local ok, err = pcall(function()
            check(mp.get_time() < deadline, 'subtitle screenshot timed out')
            if math.abs(mp.get_property_number('time-pos', -1) - target) > 0.15 or
                mp.get_property('sub-text', '') == '' then
                mp.add_timeout(0.1, capture)
                return
            end
            mp.commandv('screenshot-to-file', o.root .. '/' .. name .. '.png', 'subtitles')
            metrics[name .. '_screenshot_position'] = mp.get_property_number('time-pos')
            screenshot_pending = false
        end)
        if not ok then mp.msg.error('ASR CACHE PLAYBACK FAIL: ' .. tostring(err)); mp.commandv('quit', '3') end
    end
    mp.add_timeout(0.3, capture)
end
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
            if o.segment then
                generate(100)
            elseif o.menu_switch then
                phase = 90
                mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-backend-menu')
            else
                generate(1)
            end
        elseif phase == 12 then
            check(not cached_track(), 'next file does not inherit prior subtitle')
            generate(2)
        elseif phase == 32 then phase = 3
        elseif phase == 103 then
            check(not cached_track(), 'switch during partial output removes old track')
            check(not cache.read(partial_path), 'unload removes incomplete output')
            check(not mp.get_property_native('user-data/ai-subtitles/status/running'), 'unload cancels segment job')
            metrics.next_file_cancelled = true
            phase = 104
        elseif phase == 105 then generate(1)
        end
    end)
    if not ok then mp.msg.error('ASR CACHE PLAYBACK FAIL: ' .. tostring(err)); mp.commandv('quit', '3') end
end)
mp.add_periodic_timer(0.15, function()
    local ok, err = pcall(function()
        check(mp.get_time() - started < o.timeout, 'playback test timeout')
        local result = cached_track()
        local running = mp.get_property_native('user-data/ai-subtitles/status/running')
        if o.segment and (phase == 1 or phase == 2) and result and running then
            local key = phase == 1 and 'first' or 'second'
            if phase == 1 and o.render and not metrics.first_partial_seconds then
                capture_subtitles(result, 'partial')
            end
            metrics[key .. '_partial_seconds'] = metrics[key .. '_partial_seconds'] or (mp.get_time() - job_started)
            check(cache.valid_srt(cache.read(result)), 'partial output is valid SRT')
            return
        end
        if phase == 100 then
            check(mp.get_time() - job_started < 15, 'segment task publishes running state promptly')
            if running and mp.get_time() - job_started > 0.5 then
                cancel_sent, phase = mp.get_time(), 101
                mp.commandv('script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-cancel')
            end
        elseif phase == 101 then
            check(mp.get_time() - cancel_sent < 3, 'cancel responds without waiting for recognition')
            if not running then
                check(not cached_track(), 'cancel leaves no partial track')
                metrics.cancel_seconds = mp.get_time() - cancel_sent
                generate(102)
            end
        elseif phase == 102 and result and running then
            partial_path, phase = result, 103
            local work = utils.split_path(result)
            check(not cache.read(work .. '../complete.json'), 'partial output has no completion marker')
            mp.commandv('loadfile', o.second, 'replace')
        elseif phase == 104 then
            phase = 105
            mp.commandv('loadfile', o.first, 'replace')
        elseif phase == 90 and mp.get_property_native('user-data/uosc/menu/type') == 'ai-subtitle-backend' then
            -- uosc publishes its type before finishing menu layout and enabling bindings.
            phase, previous = 94, mp.get_time()
        elseif phase == 94 and mp.get_time() - previous > 0.3 then
            phase, previous = 91, mp.get_time()
            mp.commandv('keypress', 'END')
        elseif phase == 91 and mp.get_time() - previous > 0.3 then
            phase = 92
            mp.commandv('keypress', 'ENTER')
        elseif phase == 92 and mp.get_property_native('user-data/ai-subtitles/backend') == 'qwen' then
            mp.commandv('keypress', 'ESC')
            generate(1)
        elseif phase == 1 and result then
            metrics.first_total_seconds = mp.get_time() - job_started
            metrics.media_duration = mp.get_property_number('duration')
            if o.segment then check(metrics.first_partial_seconds, 'first output arrives before completion') end
            verify(result)
            capture_subtitles(result, 'completed')
            clean_media_folder(o.first)
            first_result, phase = result, 11
            reset_subtitles()
            mp.msg.info('ASR CACHE STEP PASS: first generation')
        elseif phase == 11 and reset_done() and not screenshot_pending then
            phase = 12
            mp.commandv('loadfile', o.second, 'replace')
        elseif phase == 2 and result then
            metrics.second_total_seconds = mp.get_time() - job_started
            if o.segment then check(metrics.second_partial_seconds, 'second output arrives before completion') end
            check(result ~= first_result, 'same basename uses distinct cache')
            verify(result)
            clean_media_folder(o.second)
            second_result, phase = result, 21
            reset_subtitles()
            mp.msg.info('ASR CACHE STEP PASS: next-file generation')
        elseif phase == 21 and reset_done() then
            phase, previous = 32, mp.get_time()
            mp.commandv('loadfile', o.first, 'replace')
        elseif phase == 3 and result then
            metrics.auto_reuse_seconds = mp.get_time() - previous
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
                first = first_result, second = second_result, menu_switch = o.menu_switch, metrics = metrics, passed = true}) .. '\n'), 'write report')
            mp.msg.info('ASR CACHE PLAYBACK PASS: generate, next-file, reset, automatic and explicit reuse')
            phase = 5
            mp.commandv('quit', '0')
        end
    end)
    if not ok then mp.msg.error('ASR CACHE PLAYBACK FAIL: ' .. tostring(err)); mp.commandv('quit', '3') end
end)
