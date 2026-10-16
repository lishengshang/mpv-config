-- Exercise actual uosc keyboard activation and the local menu callbacks.
local utils = require 'mp.utils'
local o = {output = '~~/cache/menu-rework/playback'}
require('mp.options').read_options(o, 'menu-test')
local checks, completed, loaded = 0, {}, 0
local function check(ok, why)
    checks = checks + 1
    if not ok then error(why) end
end
local function get(prop) return mp.get_property_native(prop) end
local function kind() return get('user-data/uosc/menu/type') end
local function menu() return get('user-data/menu-ui/menu') end
local function find(id, items)
    for _, item in ipairs(items or (menu() and menu().items) or {}) do
        if item.id == id then return item end
        if item.items then local found = find(id, item.items); if found then return found end end
    end
end
local function open(path) mp.commandv('script-message-to', 'menu_ui', 'open', path or '') end
local function close() mp.commandv('script-message-to', 'uosc', 'close-menu') end
local function choose(parent, title)
    local items = parent == '' and menu().items or assert(find(parent), parent).items
    local index
    for i, item in ipairs(items) do if item.title == title then index = i; break end end
    check(index ~= nil, 'item exists: ' .. parent .. ' > ' .. title)
    mp.commandv('script-message-to', 'uosc', 'select-menu-item', 'menu-ui', tostring(index), parent == '' and '{root}' or parent)
    mp.add_timeout(0.12, function() mp.commandv('keypress', 'ENTER') end)
end
local function shot(name)
    local path = mp.command_native({'expand-path', o.output .. '/' .. name .. '.png'})
    check(mp.commandv('screenshot-to-file', path, 'window'), 'screenshot command')
    local info = utils.file_info(path)
    check(info and info.size > 1024, 'nonempty screenshot: ' .. name)
end
local steps = {}
local function add(title, run, ready) steps[#steps + 1] = {title, run, ready} end
mp.register_event('file-loaded', function() loaded = loaded + 1 end)
add('start and right menu', function() mp.commandv('keypress', 'MBTN_RIGHT') end, function() return kind() == 'menu-ui' end)
add('root structure and empty states', function()
    local expected = {'打开与文件','播放','画面','画质增强','音频','字幕','截图与导出','窗口','工具与高级','退出程序'}
    check(#menu().items == #expected, 'ten top-level entries')
    local function nonempty(items)
        for _, item in ipairs(items) do if item.items then check(#item.items > 0, 'nonempty ' .. item.title); nonempty(item.items) end end
    end
    nonempty(menu().items)
    for i, title in ipairs(expected) do check(menu().items[i].title == title, 'root order ' .. i) end
    check(find('播放 > 章节…').selectable == false, 'chapter unavailable reason')
    check(find('播放 > 版本…').selectable == false, 'edition unavailable reason')
    check(find('字幕 > 主字幕调整 > 字幕上移').selectable == false, 'no subtitle disabled')
    check(find('画面 > 宽高比').items ~= nil, 'aspect direct choices')
    shot('main'); close()
end, function() return kind() == nil end)
add('bottom command same menu', function() mp.commandv('script-binding', 'uosc/menu-blurred') end, function() return kind() == 'menu-ui' end)
add('open speed', function() open('播放 > 速度') end, function() return kind() == 'menu-ui' end)
add('adjust speed with actual Enter', function() choose('播放 > 速度', '加快 0.1 倍') end,
    function() return math.abs(mp.get_property_number('speed') - 1.1) < 0.001 and kind() == 'menu-ui' end)
add('speed live hint and second adjustment', function()
    check(find('播放 > 速度 > 加快 0.1 倍').hint:find('1.1', 1, true), 'speed hint updated')
    choose('播放 > 速度', '加快 0.1 倍')
end, function() return math.abs(mp.get_property_number('speed') - 1.2) < 0.001 end)
add('speed reset', function() choose('播放 > 速度', '恢复 1 倍') end, function() return mp.get_property_number('speed') == 1 end)
add('open audio', function() open('音频') end, function() return kind() == 'menu-ui' end)
add('mute checkbox', function() choose('音频', '静音') end,
    function() return get('mute') and find('音频 > 静音').active == true end)
add('restore mute', function() choose('音频', '静音') end,
    function() return not get('mute') and find('音频 > 静音').active == false end)
local baseline_af
add('audio choices with unrelated filter', function()
    baseline_af = get('af')
    mp.commandv('af', 'set', 'volume=0.8')
    open('音频 > 音量均衡模式')
end, function() return kind() == 'menu-ui' and #get('af') == 1 end)
add('unrelated filter is not off', function()
    check(not find('音频 > 音量均衡模式').items[3].active, 'unrelated filter is not falsely checked as off')
    choose('音频 > 音量均衡模式', '动态音量均衡')
end, function() return get('af')[1] and get('af')[1].label == 'dynaudnorm'
    and find('音频 > 音量均衡模式').items[1].active end)
add('direct loudness choice', function() choose('音频 > 音量均衡模式', '响度标准化') end,
    function() return get('af')[1] and get('af')[1].label == 'loudnorm' and find('音频 > 音量均衡模式').items[2].active end)
add('turn audio processing off', function() choose('音频 > 音量均衡模式', '关闭音量处理') end,
    function() return #get('af') == 0 and find('音频 > 音量均衡模式').items[3].active end)
add('restore unrelated audio filter baseline', function() mp.set_property_native('af', baseline_af) end,
    function() return utils.format_json(get('af')) == utils.format_json(baseline_af) end)
add('open aspect choices', function() open('画面 > 宽高比') end, function() return kind() == 'menu-ui' end)
add('direct aspect selection', function() choose('画面 > 宽高比', '4:3') end,
    function() return math.abs(mp.get_property_number('video-aspect-override') - 4/3) < 0.0001
        and find('画面 > 宽高比').items[2].active == true end)
add('aspect selected check', function()
    local choices = find('画面 > 宽高比').items
    check(choices[2].active == true, 'selected ratio checked')
    choose('画面 > 宽高比', '原始比例')
end, function()
    local value = get('video-aspect-override')
    return value == false or value == 'no' or (tonumber(value) or 1) <= 0
end)
add('reset policy keyboard all', function() close(); mp.commandv('keypress', 'CTRL+R') end,
    function() return mp.get_property('reset-on-next-file') == 'all' end)
add('reset policy keyboard empty', function() mp.commandv('keypress', 'CTRL+R') end,
    function() return mp.get_property('reset-on-next-file') == '' end)
add('reset policy choices', function() open('工具与高级 > 播放设置 > 下一文件的设置保留策略') end,
    function() return kind() == 'menu-ui' end)
add('change policy does not reset current', function()
    mp.set_property_number('speed', 1.4)
    choose('工具与高级 > 播放设置 > 下一文件的设置保留策略', '保留全部更改')
end, function() return mp.get_property('reset-on-next-file') == '' and mp.get_property_number('speed') == 1.4 end)
add('immediate reset separate', function()
    local item = find('工具与高级 > 播放设置 > 下一文件的设置保留策略')
    check(item.items[3].active == true, 'empty reset list choice marked')
    check(item.hint:find('全部保留', 1, true), 'serialized reset policy hint')
    open('工具与高级 > 播放设置')
end, function() return kind() == 'menu-ui' end)
add('immediate reset action', function() choose('工具与高级 > 播放设置', '立即恢复常用播放调整') end,
    function() return mp.get_property_number('speed') == 1 and mp.get_property('reset-on-next-file') == '' end)
add('F5 list', function() mp.commandv('keypress', 'F5') end, function() return kind() == 'playlist' end)
add('F6 device', function() mp.commandv('keypress', 'F6') end, function() return kind() == 'audio-device-list' end)
add('F8 tracks', function() mp.commandv('keypress', 'F8') end, function() return kind() == 'menu-ui' and menu().title == '选择轨道' end)
add('F9 video', function() close() end, function() return kind() == nil end)
add('F9 video command', function() mp.commandv('keypress', 'F9') end, function() return kind() == 'video' end)
add('F10 audio', function() mp.commandv('keypress', 'F10') end, function() return kind() == 'audio' end)
add('F11 subtitles', function() mp.commandv('keypress', 'F11') end, function() return kind() == 'sub' end)
add('load two subtitle tracks', function()
    close()
    mp.commandv('sub-add', mp.command_native({'expand-path', o.output .. '/one.srt'}), 'select', '测试主字幕')
    mp.commandv('sub-add', mp.command_native({'expand-path', o.output .. '/two.srt'}), 'auto', '测试次字幕')
end, function() return #(get('track-list') or {}) >= 4 end)
add('secondary F-key', function() mp.commandv('keypress', 'ALT+F11') end,
    function() return kind() == 'menu-ui' and menu().title == '选择次字幕' end)
add('choose secondary actual Enter', function()
    mp.commandv('script-message-to', 'uosc', 'select-menu-item', 'menu-ui', '3', '{root}')
    mp.add_timeout(0.12, function() mp.commandv('keypress', 'ENTER') end)
end, function() return tonumber(mp.get_property('secondary-sid')) ~= nil end)
add('subtitle visible and size', function() open('字幕 > 次字幕调整') end, function() return kind() == 'menu-ui' end)
add('secondary font adjustment', function() choose('字幕 > 次字幕调整', '次字幕字号 +0.1') end,
    function() return mp.get_property_number('secondary-sub-scale') > 1 and kind() == 'menu-ui' end)
add('main screenshot after subtitles', function() shot('subtitles'); open('画质增强') end, function() return kind() == 'menu-ui' end)
add('GPU menu handoff', function() choose('画质增强', 'GPU 增强…') end, function() return kind() == 'gpu-effects' end)
add('return from GPU', function() mp.commandv('script-binding', 'uosc/menu-blurred') end, function() return kind() == 'menu-ui' end)
add('continuous screenshot', function() close() end, function() return kind() == nil end)
add('start continuous keyboard', function() mp.commandv('keypress', 'ALT+s') end,
    function() return get('user-data/menu-ui/continuous') == 'subtitles' end)
add('continuous active state', function() open('截图与导出 > 连续截图') end, function() return kind() == 'menu-ui' end)
add('stop continuous through menu', function()
    check(find('截图与导出 > 连续截图 > 含字幕：开始／停止').active == true, 'continuous checked')
    choose('截图与导出 > 连续截图', '含字幕：开始／停止')
end, function() return get('user-data/menu-ui/continuous') == '' end)
add('prepare next file', function()
    close()
    mp.commandv('loadfile', mp.get_property('path'), 'append')
    mp.commandv('script-message-to', 'menu_ui', 'set', 'shuffle', 'yes')
end, function() return #get('playlist') == 2 and get('user-data/menu-ui/shuffle') == true end)
add('shuffle menu state', function() open('播放 > 循环与随机') end, function() return kind() == 'menu-ui' end)
add('shuffle through same bottom owner', function()
    check(find('播放 > 循环与随机 > 随机播放').active == true, 'shuffle checked')
    choose('播放 > 循环与随机', '随机播放')
end, function() return get('user-data/menu-ui/shuffle') == false end)
add('next-file clears continuous state', function()
    close(); mp.commandv('script-message-to', 'menu_ui', 'continuous', 'video')
end, function() return get('user-data/menu-ui/continuous') == 'video' end)
add('switch next', function() mp.set_property_number('speed', 1.25); mp.commandv('playlist-next', 'force') end,
    function() return loaded == 2 and get('playlist-pos') == 1 and get('user-data/menu-ui/continuous') == '' end)
add('right menu next file', function() mp.commandv('keypress', 'MBTN_RIGHT') end, function() return kind() == 'menu-ui' end)
add('default and restored output', function()
    check(mp.get_property_number('video-params/w') == 640, 'next file video output')
    check(mp.get_property('reset-on-next-file') == '', 'empty reset policy persists across file change')
    mp.set_property_number('speed', 1)
    check(find('字幕 > 主字幕调整 > 字幕上移').selectable == false, 'no stale subtitle availability')
    shot('next-file'); close(); mp.set_property_bool('pause', false)
end, function() return kind() == nil and mp.get_property_number('time-pos', 0) > 0.15 end)
add('next file under empty policy', function()
    mp.set_property_bool('pause', true)
    mp.set_property_number('speed', 1.25)
    mp.commandv('loadfile', mp.get_property('path'), 'append')
    mp.commandv('playlist-next', 'force')
end, function() return loaded == 3 end)
add('empty policy preserves subsequent changes', function()
    check(mp.get_property_number('speed') == 1.25, 'empty policy preserves speed after original per-file backup restored')
    mp.set_property_number('speed', 1)
    mp.set_property_bool('pause', false)
end, function() return not get('pause') and mp.get_property_number('time-pos', 0) > 0.15 end)
local step, started, start_time = 1, false, nil
local function write_report(ok, message)
    local file = assert(io.open(mp.command_native({'expand-path', o.output .. '/report.json'}), 'w'))
    file:write(utils.format_json({ok = ok, checks = checks, completed = completed, error = message})); file:close()
end
local function tick()
    local item = steps[step]
    if not item then
        write_report(true)
        mp.msg.info('MENU UI PASS: ' .. checks .. ' checks, ' .. #completed .. ' steps')
        mp.commandv('quit', '0'); return
    end
    if not started then started = true; start_time = mp.get_time(); item[2](); return end
    if item[3]() then completed[#completed + 1] = item[1]; step = step + 1; started = false
    elseif mp.get_time() - start_time > 8 then error('timeout: ' .. item[1]) end
end
mp.add_timeout(1, function()
    mp.add_periodic_timer(0.2, function()
        local ok, message = pcall(tick)
        if not ok then pcall(write_report, false, tostring(message)); mp.msg.error('MENU UI FAIL: ' .. tostring(message)); mp.commandv('quit', '3') end
    end)
end)
mp.add_timeout(100, function() pcall(write_report, false, 'overall timeout'); mp.commandv('quit', '4') end)
