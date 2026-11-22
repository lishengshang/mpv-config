local u = require 'mp.utils'
local o = {seconds = 30, preset = 'none', output = '', seek = false, start = 0}
require('mp.options').read_options(o, 'benchmark')
local phase, began, restarted = 0, mp.get_time(), nil
mp.register_event('playback-restart', function() if phase == 21 then restarted = mp.get_time() end end)
local function fail(reason) mp.msg.error('BENCHMARK FAIL: ' .. reason); mp.commandv('quit', 3) end
mp.register_event('file-loaded', function()
    if phase ~= 0 then fail('media changed during benchmark'); return end
    phase = 1
    mp.add_timeout(1, function()
        if o.preset ~= 'none' then mp.commandv('script-message-to', 'gpu_effects', 'toggle', o.preset) end
        phase = 2
    end)
end)
mp.add_periodic_timer(0.2, function()
    if mp.get_time() - began > 480 then fail('initialization/sample timeout'); return end
    local gpu = mp.get_property_native('user-data/gpu-effects', {})
    if phase == 2 and (o.preset == 'none' or (gpu.active == o.preset and gpu.pending == '')) then
        if o.seek then
            phase, restarted = 21, nil
            mp.commandv('seek', tostring(o.start), 'absolute+exact')
        else phase, restarted = 21, mp.get_time() end
    elseif phase == 2 and gpu.pending == '' and (gpu.message or ''):find('失败', 1, true) then fail(gpu.message)
    elseif phase == 21 and restarted and mp.get_time() - restarted > 0.3 then
        phase = 3
        mp.commandv('script-message-to', 'player_health', 'health-sample', tostring(o.seconds))
    elseif phase == 3 then
        local state = mp.get_property_native('user-data/player-health/sample', {})
        if state.state == 'complete' then
            mp.commandv('screenshot-to-file', o.output .. '/output.png', 'video')
            local f = assert(io.open(o.output .. '/result.json', 'wb'))
            f:write(u.format_json({report = state.report, preset = o.preset}) .. '\n'); f:close()
            mp.msg.info('BENCHMARK PASS: ' .. state.report); mp.commandv('quit', 0)
        elseif state.state == 'invalid' or state.state == 'failed' then fail(state.reason or 'invalid sample') end
    end
end)
