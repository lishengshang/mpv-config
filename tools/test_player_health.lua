local u = require 'mp.utils'
local o = {output = ''}
require('mp.options').read_options(o, 'health-test')
local phase, began, ticks, checks = 0, mp.get_time(), 0, 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function send(name, value) mp.commandv('script-message-to', 'player_health', name, value or '') end
local function state() return mp.get_property_native('user-data/player-health', {}) end
local prior_report
local function sample()
    prior_report = state().sample.report
    send('health-sample', '2')
end
local function read(path)
    local f = assert(io.open(path, 'rb')); local text = f:read('*a'); f:close(); return assert(u.parse_json(text))
end
local function fail(why) mp.msg.error('PLAYER HEALTH FAIL: ' .. tostring(why)); mp.commandv('quit', 3) end
mp.register_event('file-loaded', function()
    if phase == 0 then mp.add_timeout(0.5, function() send('health-menu'); phase, began = 1, mp.get_time() end) end
end)
mp.add_periodic_timer(0.1, function()
    local ok, err = pcall(function()
        local s = state()
        if phase == 1 and mp.get_property_native('user-data/uosc/menu/type') == 'player-health' and mp.get_time() - began > 0.4 then
            mp.commandv('screenshot-to-file', o.output .. '/menu.png', 'window')
            sample(); phase = 2
        elseif phase == 2 and s.sample.state == 'complete' then
            local data = read(s.sample.report)
            check(data.valid and data.elapsed >= 2 and data.vo_fresh_ms.p95 >= 0, 'timed valid GPU sample')
            check(data.context.filename and data.context.window.w > 0 and data.counter_deltas['frame-drop-count'] ~= nil, 'context, window and drop deltas recorded')
            sample()
            phase = 3
            mp.add_timeout(0.4, function() mp.set_property_native('pause', true) end)
        elseif phase == 3 and s.sample.state == 'invalid' and s.sample.report ~= prior_report then
            check(s.sample.reason:find('暂停'), 'pause invalidates sample')
            mp.set_property_native('pause', false)
            sample(); phase = 4
            mp.add_timeout(0.4, function() mp.commandv('loadfile', o.output .. '/second.mkv', 'replace') end)
        elseif phase == 4 and s.sample.state == 'invalid' and s.sample.report ~= prior_report and mp.get_property('filename') == 'second.mkv' then
            check(s.sample.reason:find('媒体'), 'next file invalidates prior sample')
            phase, began = 41, mp.get_time()
        elseif phase == 41 and mp.get_time() - began > 0.5 then
            sample(); phase = 5
            mp.add_timeout(0.5, function() mp.commandv('seek', '3', 'relative+exact') end)
        elseif phase == 5 and s.sample.state == 'invalid' and s.sample.report ~= prior_report then
            check(s.sample.reason:find('跳转'), 'seek invalidates sample')
            sample(); phase = 6
            mp.add_timeout(0.4, function() mp.commandv('vf', 'add', '@health-fixture:hflip') end)
        elseif phase == 6 and s.sample.state == 'invalid' and s.sample.report ~= prior_report then
            check(s.sample.reason:find('滤镜'), 'filter change invalidates sample')
            mp.commandv('vf', 'remove', '@health-fixture')
            sample(); phase = 7
            mp.add_timeout(0.4, function() send('health-cancel') end)
        elseif phase == 7 and s.sample.state == 'invalid' and s.sample.report ~= prior_report then
            check(s.sample.reason:find('取消'), 'manual cancel invalidates sample')
            send('health-diagnose'); phase = 8
        elseif phase == 8 and s.diagnostic.state == 'complete' then
            local report = read(s.diagnostic.report)
            check(#report.checks == 5 and #report.files >= 8, 'all diagnostic jobs and component checks recorded')
            local configuration, vs, qwen = false, false, false
            for _, item in ipairs(report.checks) do
                if item.name == '配置与原生接线' then configuration = item.ok end
                if item.name:find('VS Bilateral', 1, true) then vs = item.ok end
                if item.name:find('Qwen Python', 1, true) then qwen = item.ok end
            end
            check(configuration and vs and qwen, 'installed configuration/VS/Qwen environments pass their stated checks')
            check(#mp.get_property_native('vf', {}) == 0, 'diagnostics preserve default playback filter state')
            local f = assert(io.open(o.output .. '/result.json', 'wb'))
            f:write(u.format_json({passed = true, checks = checks, diagnostic = s.diagnostic.report}) .. '\n'); f:close()
            mp.msg.info('PLAYER HEALTH PASS: ' .. checks .. ' checks'); mp.commandv('quit', 0)
        end
        ticks = ticks + 1
        if ticks > 800 then error('timeout at phase ' .. phase .. ': ' .. u.format_json(s)) end
    end)
    if not ok then fail(err) end
end)
