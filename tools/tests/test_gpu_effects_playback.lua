-- Actual command routing, video output and next-file regression.
local utils = require 'mp.utils'
local o = {no_vs = false, failure = false, all_rtx = false, focused = false, paused = false, timeout = 900, output = '~~/cache/ux-playback'}
require('mp.options').read_options(o, 'ux-test')
local phase, step = 0, 0
local restarts = 0
mp.register_event('playback-restart', function() restarts = restarts + 1 end)
local function status() return mp.get_property_native('user-data/gpu-effects', {}) end
local function active(id) return status().active == id and status().pending == '' end
local function check(ok, reason) if not ok then error(reason) end end
local function send(action, id) mp.commandv('script-message-to', 'gpu_effects', action, id or '') end
local function shot(name, mode)
    check(mp.get_property_native('pause') == o.paused, 'capture preserves requested pause state: ' .. name)
    local path = mp.command_native({'expand-path', o.output .. '/' .. name .. '.png'})
    local ok, err = mp.commandv('screenshot-to-file', path, mode or 'video')
    check(ok, 'screenshot command: ' .. tostring(err))
    local info = utils.file_info(path)
    check(info and info.size > 1024, 'valid screenshot missing: ' .. name)
end
local function failure(reason)
    mp.msg.error('GPU UX PLAYBACK FAIL: ' .. tostring(reason))
    mp.commandv('quit', '3')
end
local steps = {}
local function add(action, predicate) steps[#steps + 1] = {action, predicate} end
add(function() send('menu') end,
    function() return mp.get_property_native('user-data/uosc/menu/type') == 'gpu-effects' end)
add(function() shot('menu', 'window'); mp.commandv('keypress', 'CTRL+ALT+1') end,
    function() return active('ArtCNN_C4F16') end)
add(function()
    shot('light', 'window'); send('reset')
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'gpu-effects')
end, function() return active('') end)
if o.failure then
    add(function() mp.commandv('keypress', 'CTRL+ALT+1') end, function() return active('ArtCNN_C4F16') end)
    add(function() mp.commandv('keypress', '+') end, function()
        return active('ArtCNN_C4F16') and status().message:find('初始化失败', 1, true)
    end)
    add(function() shot('init-failure-preserved-light'); mp.commandv('keypress', '(') end,
        function() return active('ArtCNN_C4F16') and status().message:find('缺少模型', 1, true) end)
    add(function() shot('missing-model-preserved-light'); mp.commandv('keypress', '!') end,
        function() return active('NR_BILATERAL_CUDA') end)
    add(function() mp.commandv('keypress', '+') end, function()
        return active('NR_BILATERAL_CUDA') and status().message:find('初始化失败', 1, true)
    end)
    add(function() shot('init-failure-preserved-vs'); send('reset') end, function() return active('') end)
elseif o.no_vs then
    add(function() mp.commandv('keypress', 'CTRL+ALT+1') end, function() return active('ArtCNN_C4F16') end)
    add(function() mp.commandv('keypress', '$') end, function()
        return active('ArtCNN_C4F16') and (status().message or ''):find('VapourSynth', 1, true)
    end)
    add(function() shot('no-vs-still-playing'); send('reset') end, function() return active('') end)
else
    add(function() mp.commandv('vf', 'add', '@ux-user:hflip'); mp.commandv('keypress', '!') end,
        function() return active('NR_BILATERAL_CUDA') end)
    add(function() shot('bilateral'); mp.commandv('keypress', '+') end,
        function() return active('NR_DFTTEST_CUDA') end)
    add(function()
        local vf = mp.get_property_native('vf', {})
        check(#vf == 2, 'replace preserves user filter and uses one VS slot')
        shot('dfttest'); send('reset')
    end, function() return active('') end)
    add(function()
        check(#mp.get_property_native('vf', {}) == 1, 'reset preserves unrelated VF')
        send('toggle', 'NR_BILATERAL_CUDA')
    end, function() return active('NR_BILATERAL_CUDA') and #mp.get_property_native('vf', {}) == 2 end)
    add(function() send('compare') end, function()
        return active('') and status().compare == 'NR_BILATERAL_CUDA' and #mp.get_property_native('vf', {}) == 2
    end)
    add(function() shot('compare-suspended'); send('compare') end, function() return active('NR_BILATERAL_CUDA') end)
    add(function() shot('compare-resumed'); send('reset') end, function() return active('') end)
    add(function() mp.commandv('keypress', '$') end, function() return active('MEMC_RIFE_TRT') end)
    add(function() shot('rife'); mp.commandv('keypress', 'ALT+~') end,
        function() return active('') and #mp.get_property_native('vf', {}) == 0 end)
    add(function() mp.commandv('keypress', '$') end, function() return active('MEMC_RIFE_TRT') end)
    add(function() send('reset') end, function() return active('') end)
    add(function() mp.commandv('keypress', 'CTRL+ALT+1') end, function() return active('ArtCNN_C4F16') end)
    add(function() mp.commandv('keypress', 'CTRL+ALT+2') end, function() return active('ArtCNN_C4F32') end)
    add(function() shot('balanced', 'window'); mp.commandv('keypress', 'CTRL+0') end,
        function() return active('') and #mp.get_property_native('glsl-shaders', {}) == 0 end)
    if o.all_rtx then
        for _, item in ipairs({{'%', 'MEMC_DRBA_TRT'}, {"'", 'NR_BM3D_CUDA'},
            {'&', 'SR_ARTCNN_TRT'}, {'ALT+&', 'SR_ARTCNN_CHROMA_TRT'},
            {'ALT+^', 'SR_AnimeJaNaiV2_TRT'}, {'*', 'SR_AnimeJaNaiV3_TRT'},
            {'(', 'SR_HFA2k_TRT'}, {')', 'SR_Anime1080Fixer_TRT'}, {'ALT+_', 'MIX_SR_MEMC_TRT'}}) do
            local key, id = item[1], item[2]
            add(function() mp.commandv('keypress', key) end, function() return active(id) end)
            if id == 'MIX_SR_MEMC_TRT' and o.paused then
                local before_seek
                add(function()
                    shot('MIX-before-paused-seek')
                    before_seek = restarts
                    mp.commandv('seek', tostring(math.max(0, mp.get_property_number('time-pos') - 0.5)), 'absolute+exact')
                end, function() return restarts > before_seek and active(id) end)
            end
            add(function() shot(id); send('reset') end, function() return active('') end)
        end
    end
    add(function() mp.commandv('keypress', '!') end, function() return active('NR_BILATERAL_CUDA') end)
end
if o.focused then
    steps = {}
    add(function() send('menu') end, function() return mp.get_property_native('user-data/uosc/menu/type') == 'gpu-effects' end)
    add(function()
        shot('menu', 'window'); mp.commandv('script-message-to', 'uosc', 'close-menu', 'gpu-effects')
        mp.commandv('vf', 'add', '@ux-user:hflip')
    end, function() return #mp.get_property_native('vf', {}) == 1 end)
    for _, id in ipairs({'MEMC_RIFE_TRT', 'MEMC_DRBA_TRT', 'SR_ARTCNN_TRT', 'SR_ARTCNN_CHROMA_TRT', 'MIX_SR_MEMC_TRT'}) do
        local current = id
        add(function() send('toggle', current) end, function() return active(current) end)
        add(function()
            check(#mp.get_property_native('vf', {}) == 2, 'one managed filter plus user filter')
            shot(current); send('reset')
        end, function() return active('') and #mp.get_property_native('vf', {}) == 1 end)
    end
    add(function() send('toggle', 'MEMC_DRBA_TRT') end, function() return active('MEMC_DRBA_TRT') end)
    add(function() mp.commandv('vf', 'remove', '@ux-user') end, function() return #mp.get_property_native('vf', {}) == 1 end)
end
local function next_step()
    step = step + 1
    if not steps[step] then
        mp.commandv('loadfile', 'av://lavfi:testsrc2=size=640x360:rate=24,format=yuv420p', 'replace')
        return
    end
    mp.msg.info('GPU UX STEP START: ' .. step)
    local ok, err = pcall(steps[step][1])
    if not ok then failure(err); return end
    local started = mp.get_time()
    local poll
    poll = mp.add_periodic_timer(0.15, function()
        local success, ready = pcall(steps[step][2])
        if not success then poll:kill(); failure(ready)
        elseif ready then
            poll:kill()
            mp.msg.info('GPU UX STEP PASS: ' .. step)
            -- Let the new filter render before screenshotting on the next step.
            mp.add_timeout(0.7, next_step)
        elseif not o.failure and status().pending == '' and (status().message or ''):find('初始化失败', 1, true) then
            poll:kill(); failure('step ' .. step .. ': ' .. utils.format_json(status()))
        elseif mp.get_time() - started > (status().pending ~= '' and 320 or 120) then
            poll:kill(); failure('step ' .. step .. ' timed out: ' .. utils.format_json(status()))
        end
    end)
end
mp.register_event('file-loaded', function()
    phase = phase + 1
    mp.add_timeout(1, function()
        if phase == 1 then next_step() else
            local ok, err = pcall(function()
                check(active(''), 'next file resets managed effect')
                check(#mp.get_property_native('vf', {}) == 0, 'next file has no owned VF')
                check(#mp.get_property_native('glsl-shaders', {}) == 0, 'next file restores shaders')
                shot(phase == 2 and 'next-file' or 'shader-next-file')
            end)
            if not ok then failure(err); return end
            if phase == 2 and not o.focused then
                send('toggle', 'ArtCNN_C4F16')
                local began = mp.get_time()
                local poll
                poll = mp.add_periodic_timer(0.2, function()
                    if active('ArtCNN_C4F16') then
                        poll:kill()
                        mp.commandv('loadfile', 'av://lavfi:testsrc2=size=640x360:rate=24,format=yuv420p', 'replace')
                    elseif mp.get_time() - began > 10 then poll:kill(); failure('shader before next file') end
                end)
            else
                mp.msg.info('GPU UX PLAYBACK PASS: ' .. step .. ' steps + VS/shader next-file output')
                mp.commandv('quit', '0')
            end
        end
    end)
end)
mp.add_timeout(o.timeout, function() failure('overall timeout') end)
