local u = require 'mp.utils'
local o = {root = ''}
require('mp.options').read_options(o, 'manager-test')
package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local g = require 'managed-update'
local config = o.root .. '/portable_config'
local target = config .. '/scripts/'
local count, phase, menu_time = 0, 0, 0
local function check(ok, why) assert(ok, why); count = count + 1 end
local function send(message) mp.commandv('script-message-to', 'manager', message) end
local function status() return mp.get_property_native('user-data/manager', {}) end
local function preview()
    mp.set_property_native('user-data/manager', {state = 'waiting'})
    if phase == 0 then mp.commandv('keypress', 'M') else send('manager-update-all') end
end
local function version(n)
    check(g.write(config .. '/manager.json', u.format_json({{git = o.root .. '/upstream', branch = 'v' .. n, whitelist = '%.lua$'}})), 'fixture configuration')
end
local function failed(err) mp.msg.error('MANAGER FAIL: ' .. tostring(err)); mp.commandv('quit', 3) end
local function suite()
    check(g.classify('local', 'remote', nil) == 'conflict', 'unknown local bytes protected')
    check(g.classify('edited', 'remote', 'old') == 'conflict', 'changed baseline protected')
    preview(); phase = 1
end
mp.register_event('file-loaded', function()
    if phase == 0 then mp.add_timeout(0.1, function() local ok, err = pcall(suite); if not ok then failed(err) end end)
    elseif phase == 8 then
        check(status().state == 'applied', 'next file preserves completed maintenance status')
        mp.msg.info('MANAGER PASS: ' .. count .. ' checks, preview/cancel/stale/backup/local edits/next-file')
        mp.commandv('quit', 0)
    end
end)
mp.add_periodic_timer(0.1, function()
    local ok, err = pcall(function()
        local s = status()
        if s.state == 'failed' and phase ~= 6 then error(s.error) end
        if phase == 1 and s.state == 'preview' and mp.get_property_native('user-data/uosc/menu/type') == 'manager-preview' then
            check(not g.read(target .. 'new.lua'), 'preview does not install')
            send('manager-cancel'); phase = 2
        elseif phase == 2 and s.state == 'cancelled' then
            check(not g.read(target .. 'new.lua'), 'cancel leaves targets alone')
            preview(); phase = 3
        elseif phase == 3 and s.state == 'preview' and mp.get_property_native('user-data/uosc/menu/type') == 'manager-preview' then
            phase, menu_time = 31, mp.get_time()
        elseif phase == 31 and mp.get_time() - menu_time > 0.4 then
            mp.commandv('screenshot-to-file', o.root .. '/preview.png', 'window')
            send('manager-apply'); phase = 4
        elseif phase == 4 and s.state == 'applied' then
            check(s.updated == 1, 'first apply only installs missing file')
            check(g.read(target .. 'custom.lua') == '-- personal customization\n', 'committed/unknown local modifications retained')
            version(2); preview(); phase = 5
        elseif phase == 5 and s.state == 'preview' then
            check(g.write(target .. 'safe.lua', '-- edit after preview\n'), 'late edit fixture')
            send('manager-apply'); phase = 6
        elseif phase == 6 and s.state == 'failed' then
            check(s.error:find('stale'), 'stale plan fails')
            check(g.read(target .. 'safe.lua') == '-- edit after preview\n', 'late edit retained')
            check(g.read(target .. 'new.lua') == '-- new.lua version 1\n', 'stale plan changes no earlier target')
            check(g.write(target .. 'safe.lua', '-- safe.lua version 1\n'), 'restore fixture baseline')
            preview(); phase = 7
        elseif phase == 7 and s.state == 'preview' then send('manager-apply'); phase = 71
        elseif phase == 71 and s.state == 'applied' then
            check(s.updated == 2, 'two baseline-matching files updated')
            check(g.read(target .. 'safe.lua') == '-- safe.lua version 2\n', 'new upstream installed')
            check(g.read(target .. 'custom.lua') == '-- personal customization\n', 'custom bytes retained after successive updates')
            local manifest = u.parse_json(g.read(s.backup .. '/manifest.json'))
            local backed = false
            for _, item in ipairs(manifest) do
                if item.target:match('/safe%.lua$') then backed = g.read(s.backup .. '/' .. item.original) == '-- safe.lua version 1\n' end
            end
            check(backed, 'recoverable original with manifest mapping')
            check(not u.file_info(target .. '.git'), 'no nested Git repository in scripts')
            -- Inject one rename failure after an earlier replacement: both originals must survive.
            local p = {{target = target .. 'safe.lua', before = g.read(target .. 'safe.lua'), data = 'replacement', state = 'update'},
                {target = target .. 'new.lua', before = g.read(target .. 'new.lua'), data = 'replacement', state = 'update'}}
            local rename = os.rename
            os.rename = function(a, b) if b == target .. 'new.lua' then return nil, 'injected failure' end; return rename(a, b) end
            local applied = g.apply(p, s.backup, function() return true end)
            os.rename = rename
            check(not applied and g.read(p[1].target) == p[1].before and g.read(p[2].target) == p[2].before, 'failed install rolls back both targets')
            phase = 8
            mp.commandv('loadfile', 'av://lavfi:testsrc2=size=160x90:rate=25', 'replace')
        end
    end)
    if not ok then failed(err) end
end)
mp.add_timeout(80, function() failed('timeout at phase ' .. phase .. ': ' .. u.format_json(status())) end)
