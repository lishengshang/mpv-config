local mp = require 'mp'
local utils = require 'mp.utils'
local options = {output = ''}
require('mp.options').read_options(options, 'menu-test')
local steps, passed, loaded = {}, 0, 0

local function get(name) return mp.get_property_native(name) end
local function kind() return get('user-data/uosc/menu/type') end
local function command(...) mp.commandv(...) end
local function shot(name)
    local path = options.output .. '/' .. name .. '.png'
    command('screenshot-to-file', path, 'window')
    assert((utils.file_info(path) or {}).size > 1024, 'missing screenshot: ' .. name)
end
local function add(run, ready)
    steps[#steps + 1] = {run = run, ready = ready}
end
local function report(ok, message)
    local file = assert(io.open(options.output .. '/report.json', 'w'))
    file:write(utils.format_json({ok = ok, steps = passed, error = message}))
    file:close()
    mp.msg.info(ok and ('MENU UI PASS: ' .. passed .. ' Base steps') or ('MENU UI FAIL: ' .. message))
    command('quit', ok and '0' or '3')
end

mp.register_event('file-loaded', function() loaded = loaded + 1 end)
add(function()
    assert(get('options/load-scripts') == false, 'unexpected auto-load')
    assert(get('options/load-auto-profiles') == false, 'unexpected automatic profiles')
    assert((mp.get_property('input-ipc-server') or '') == '', 'unexpected IPC')
    local list = get('options/scripts') or {}
    local expected = {['/scripts/uosc'] = true, ['/scripts/thumbfast.lua'] = true, ['/release/base/extensions.lua'] = true}
    for _, path in ipairs(list) do
        path = path:gsub('\\', '/'):gsub('/$', '')
        for suffix in pairs(expected) do if path:sub(-#suffix) == suffix then expected[suffix] = nil end end
        assert(not path:find('sub%-fastwhisper') and not path:find('gpu%-effects') and not path:find('webui'),
            'optional script in Base')
    end
    assert(next(expected) == nil and #list == 4, 'unexpected Base script list')
    command('keypress', 'MBTN_RIGHT')
end, function() return kind() ~= nil end)
add(function()
    shot('main')
    command('script-message-to', 'uosc', 'close-menu')
    command('keypress', 'Alt+f')
end, function() return kind() == 'extensions-whisper' end)
add(function()
    shot('subtitles')
    local path = mp.get_property('path')
    command('script-message-to', 'uosc', 'close-menu')
    command('set', 'speed', '1.5')
    command('loadfile', path, 'append')
    command('playlist-next', 'force')
end, function() return loaded >= 2 and get('speed') == 1 end)
add(function()
    shot('next-file')
    assert(get('user-data/ai-subtitles/status') == nil, 'AI controller was loaded in Base')
end, function() return true end)

mp.add_periodic_timer(0.2, function()
    if loaded == 0 then return end
    local step = steps[passed + 1]
    if not step then report(true); return end
    local ok, err = pcall(function()
        if not step.started then step.run(); step.started = true end
        if step.ready() then passed = passed + 1 end
    end)
    if not ok then report(false, tostring(err)) end
end)
mp.add_timeout(60, function() report(false, 'timeout after step ' .. passed) end)
