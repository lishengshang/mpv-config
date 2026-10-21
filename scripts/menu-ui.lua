-- Local menu integration. Uses uosc's public overwrite-binding/open-menu API;
-- upstream uosc and dyn_menu remain unmodified. Labels live in input.conf.
local utils = require 'mp.utils'
local name, menu_type = mp.get_script_name(), 'menu-ui'
local roots = {'打开与文件', '播放', '画面', '画质增强', '音频', '字幕', '截图与导出', '窗口', '工具与高级', '退出程序'}
local entries, watched, actions = {}, {}, {}
local view, continuous = 'main', nil
local refresh
local function trim(s) return (s or ''):match('^%s*(.-)%s*$') end
local function get(prop)
    -- String-list options need their serialized value for selection and hints.
    if prop == 'reset-on-next-file' then return mp.get_property(prop, '') end
    return mp.get_property_native(prop)
end
local function on(value)
    if type(value) == 'boolean' then return value end
    if type(value) == 'number' then return value ~= 0 end
    return value ~= nil and value ~= '' and value ~= 'no' and value ~= 'off' and value ~= 'false'
end
local function display(value)
    if value == nil then return '不可用' end
    if type(value) == 'boolean' then return value and '开启' or '关闭' end
    if type(value) == 'number' then return string.format('%.4g', value) end
    if type(value) == 'table' then
        if #value == 0 then return '无' end
        return tostring(#value) .. ' 项'
    end
    return ({yes = '开启', no = '关闭', auto = '自动', inf = '无限', [''] = '无'})[value] or tostring(value)
end
local update_timer = mp.add_timeout(0.08, function() if refresh then refresh() end end)
update_timer:kill()
local function changed() update_timer:kill(); update_timer:resume() end
local function watch(prop)
    if prop and not watched[prop] then
        watched[prop] = true
        mp.observe_property(prop, 'native', changed)
    end
end
local function tokens(text)
    local result, token, quote, escaped = {}, '', nil, false
    local started = false
    for i = 1, #text do
        local c = text:sub(i, i)
        if escaped then token = token .. c; escaped = false
        elseif c == '\\' and quote then escaped = true
        elseif quote then
            if c == quote then quote = nil else token = token .. c end
        elseif c == '"' or c == "'" then quote = c; started = true
        elseif c:match('%s') then
            if started then result[#result + 1] = token; token, started = '', false end
        else token = token .. c; started = true end
    end
    if started then result[#result + 1] = token end
    return result
end
local function first_command(command)
    local text = command:match('^([^;]+)') or command
    text = text:gsub('^no%-osd%s+', ''):gsub('^osd%-auto%s+', '')
    return tokens(text)
end
local input = mp.get_property('input-conf', '')
input = input == '' and '~~/input.conf' or input
local source, err
if input:sub(1, 9) == 'memory://' then source = input:sub(10)
else
    local path = mp.command_native({'expand-path', input})
    local file; file, err = io.open(path, 'r')
    if file then source = file:read('*a'); file:close() end
end
if not source then mp.msg.error('无法读取菜单配置：' .. tostring(err)); return end
local line_no = 0
for line in source:gmatch('[^\r\n]+') do
    line_no = line_no + 1
    local key, command, comment = line:match('^%s*(%S+)%s+([^#]-)%s*#menu:%s*(.*)$')
    if key and (key == '#' or key:sub(1, 1) ~= '#') then
        local title = trim(comment:match('^([^#]*)'))
        if trim(command) ~= '' and trim(command) ~= 'ignore' and title:sub(-3) ~= '---' then
            local e = {id = 'entry:' .. line_no, key = key ~= '#' and key or nil,
                command = trim(command), path = title}
            e.words = first_command(e.command)
            local verb, prop = e.words[1], e.words[2]
            if verb == 'add' or verb == 'set' or verb == 'cycle' or verb == 'cycle-values' or verb == 'multiply' or verb == 'change-list' then
                e.prop = prop
            end
            e.state = comment:match('#@state=%(%s*([%w_]+)')
            if e.state then e.state = e.state:gsub('_', '-') end
            e.prop = comment:match('#@value=([%w_/%-]+)') or e.prop or e.state
            e.choices = comment:match('#@choices=([%w%-]+)')
            e.keep = e.prop ~= nil or e.command:match('^script%-message%-to gpu_effects (reset)') ~= nil
                or e.command:match('^script%-message%-to gpu_effects restore%-defaults') ~= nil
                or e.command:match('^script%-message%-to gpu_effects clear') ~= nil
                or e.command:match('^script%-message%-to menu_ui continuous') ~= nil
                or e.command:match('^script%-message%-to menu_ui shuffle') ~= nil
            entries[#entries + 1] = e
            watch(e.prop)
        end
    end
end
local reset_default = mp.get_property('reset-on-next-file', '')

-- uosc does not publish its private shuffle state. Both local menu and bottom
-- control use this owner and forward changes to uosc; initialize from its config.
local shuffle = false
local conf = io.open(mp.command_native({'expand-path', '~~/script-opts/uosc.conf'}), 'r')
if conf then
    for line in conf:lines() do
        local value = line:match('^%s*shuffle%s*=%s*(%S+)')
        if value then shuffle = value == 'yes' end
    end
    conf:close()
end
local shuffle_opt = mp.get_opt('uosc-shuffle')
if shuffle_opt then shuffle = shuffle_opt == 'yes' end
local function publish()
    mp.set_property_bool('user-data/menu-ui/shuffle', shuffle)
    mp.set_property('user-data/menu-ui/continuous', continuous or '')
    mp.commandv('script-message-to', 'uosc', 'set', 'shuffle', shuffle and 'yes' or 'no')
end
local function set_shuffle(value)
    if shuffle ~= value then
        shuffle = value
        mp.commandv('script-binding', 'uosc/shuffle')
    end
    publish(); changed()
end
local function stop_continuous()
    if continuous then
        local ok, message = mp.commandv('screenshot', continuous .. '+each-frame')
        if not ok then mp.msg.error('停止连续截图失败：' .. tostring(message)); return false end
        continuous = nil; publish()
    end
    return true
end
local function toggle_continuous(mode)
    if mode ~= 'subtitles' and mode ~= 'video' then return end
    local previous = continuous
    if not stop_continuous() then return end
    if previous ~= mode then
        local ok, message = mp.commandv('screenshot', mode .. '+each-frame')
        if ok then continuous = mode else mp.msg.error('连续截图失败：' .. tostring(message)) end
    end
    publish(); changed()
end

local function track_count(kind)
    local count = 0
    for _, track in ipairs(get('track-list') or {}) do if track.type == kind then count = count + 1 end end
    return count
end
local function unavailable(e)
    local path, cmd = e.path, e.command
    local media = not get('idle-active') and get('path') ~= nil
    if cmd:find('uosc/chapters', 1, true) or cmd:match('^add chapter') or path:find('播放 > 章节 >', 1, true) then
        if #(get('chapter-list') or {}) == 0 then return '当前无章节' end
    elseif cmd:find('uosc/editions', 1, true) then
        if #(get('edition-list') or {}) < 2 then return '当前无多版本' end
    elseif cmd:find('uosc/playlist', 1, true) or cmd:match('^playlist%-') or cmd:find('playlistmanager shuffle', 1, true)
        or cmd:find('menu_ui shuffle', 1, true) then
        if #(get('playlist') or {}) < 2 then return '当前只有一个文件' end
    elseif path:find('网络媒体', 1, true) then
        if not mp.get_property('path', ''):match('^https?://') then return '仅网络媒体可用' end
    elseif path:find('字幕 >', 1, true) then
        local entry = path:match('^字幕 > (.*)')
        if entry:find('下载／生成', 1, true) or entry:find('加载外部', 1, true) or e.choices == 'secondary-sid' then
            if not media then return '请先打开媒体' end
        elseif track_count('sub') == 0 then return '当前无字幕' end
        if path:find('次字幕', 1, true) and e.choices ~= 'secondary-sid' and cmd:find('menu_ui secondary', 1, true) == nil
            and not tonumber(mp.get_property('secondary-sid')) then return '尚未选择次字幕' end
    elseif path:find('画面 >', 1, true) or path:find('画质增强 >', 1, true) or path:find('截图与导出 >', 1, true) then
        if track_count('video') == 0 then return '当前无视频' end
    elseif path:find('音频 >', 1, true) and not cmd:find('audio-device', 1, true) and not cmd:find('load-audio', 1, true) then
        if track_count('audio') == 0 then return '当前无音轨' end
    elseif path:find('播放 >', 1, true) and not media then return '请先打开媒体' end
end
local function action(id, title, command, keep, active)
    actions[id] = {command = command, keep = keep}
    return {title = title, value = id, active = active, keep_open = true}
end
local function choice_data(e)
    local prop, choices = e.choices, {}
    local current = get(prop)
    if prop == 'secondary-sid' then
        choices[#choices + 1] = {'不显示次字幕', 'no'}
        for _, track in ipairs(get('track-list') or {}) do
            if track.type == 'sub' then
                choices[#choices + 1] = {track.title or ((track.lang or '字幕') .. ' · ' .. track.id), tostring(track.id)}
            end
        end
    elseif prop == 'reset-on-next-file' then
        choices = {{'常用项目（配置默认）', reset_default}, {'重置全部可重置选项', 'all'}, {'保留全部更改', ''}}
        if e.words[5] ~= reset_default then choices[#choices + 1] = {'原快捷键的自定义列表', e.words[5]} end
    else
        for i = 3, #e.words do
            local value = e.words[i]
            local title = display(value)
            if prop == 'video-aspect-override' and value == 'no' then title = '原始比例'
            elseif prop == 'af' then title = value:find('dynaudnorm', 1, true) and '动态音量均衡'
                or (value:find('loudnorm', 1, true) and '响度标准化' or '关闭音量处理') end
            choices[#choices + 1] = {title, value}
        end
    end
    local items = {}
    for i, choice in ipairs(choices) do
        if choice[2] ~= nil then
            local selected = tostring(current) == choice[2]
            if prop == 'video-aspect-override' then
                local a, b = choice[2]:match('^(%d+%.?%d*):(%d+%.?%d*)$')
                local ratio = a and tonumber(a) / tonumber(b)
                if ratio then selected = math.abs((tonumber(current) or 0) - ratio) < 0.00001 end
            end
            if prop == 'video-aspect-override' and choice[2] == 'no' then
                selected = current ~= nil and (current == false or current == 'no' or (tonumber(current) or 1) <= 0)
            end
            if prop == 'secondary-sid' and choice[2] == 'no' then selected = not tonumber(current) end
            if prop == 'af' then
                local label = choice[2]:match('^@([^:]+):')
                selected = choice[2] == '' and #(get('af') or {}) == 0
                for _, filter in ipairs(get('af') or {}) do
                    if label and filter.label == label then selected = true end
                end
            end
            items[#items + 1] = action(e.id .. ':' .. i, choice[1], {'set', prop, choice[2]}, true, selected)
        end
    end
    return items
end
local function make_item(e)
    local title = e.path:match('([^>]+)$')
    local item = {id = e.path, title = trim(title), hint = e.key, keep_open = true}
    local reason = unavailable(e)
    if e.prop then
        local value = get(e.prop)
        local text = display(value)
        if e.choices == 'video-aspect-override' and (value == false or value == 'no' or (tonumber(value) or 1) <= 0) then
            text = '原始比例'
        elseif e.choices == 'reset-on-next-file' then
            text = value == reset_default and '配置默认' or (value == 'all' and '全部重置' or (value == '' and '全部保留' or '自定义'))
        elseif e.choices == 'af' then
            local af = mp.get_property('af', '')
            text = af:find('dynaudnorm', 1, true) and '动态均衡' or (af:find('loudnorm', 1, true) and '响度标准化' or (#(value or {}) == 0 and '关闭' or '其他滤镜'))
        end
        item.hint = text .. (e.key and ' · ' .. e.key or '')
        if e.state or type(value) == 'boolean' then item.active = on(value) end
        if e.words[1] == 'change-list' and e.words[3] == 'toggle' then
            item.active = false
            local function canonical(path)
                return mp.command_native({'expand-path', path}):gsub('\\', '/'):lower()
            end
            for _, path in ipairs(type(value) == 'table' and value or {}) do
                if canonical(path) == canonical(e.words[4]) then item.active = true end
            end
        end
    end
    if e.command:find('menu_ui continuous ', 1, true) then
        item.active = continuous == e.command:match('continuous (%S+)')
        item.hint = item.active and '截图中 · 点击停止' or ('已停止' .. (e.key and ' · ' .. e.key or ''))
    end
    if e.choices and not reason then item.items = choice_data(e)
    else
        actions[e.id] = {command = e.command, keep = e.keep}
        item.value = e.id
    end
    if reason then
        item.items, item.value, item.active = nil, nil, nil
        actions[e.id] = nil
        item.selectable, item.muted, item.hint = false, true, reason
    end
    return item
end
local function track_items(kind, prop)
    local items = {action(prop .. ':no', '不启用', {'set', prop, 'no'}, true, not tonumber(mp.get_property(prop)))}
    for _, track in ipairs(get('track-list') or {}) do
        if track.type == kind then
            items[#items + 1] = action(prop .. ':' .. track.id,
                track.title or ((track.lang or kind) .. ' · ' .. track.id), {'set', prop, tostring(track.id)}, true,
                tonumber(mp.get_property(prop)) == track.id)
        end
    end
    return items
end
local function data()
    actions = {}
    local items, by_path = {}, {}
    if view == 'secondary' then
        items = track_items('sub', 'secondary-sid')
    elseif view == 'tracks' then
        for _, t in ipairs({{'视频', 'video', 'vid'}, {'音频', 'audio', 'aid'}, {'主字幕', 'sub', 'sid'}, {'次字幕', 'sub', 'secondary-sid'}}) do
            items[#items + 1] = {id = t[3], title = t[1], items = track_items(t[2], t[3])}
        end
    else
        for _, root in ipairs(roots) do
            if root ~= '退出程序' then
                local item = {id = root, title = root, items = {}}
                items[#items + 1], by_path[root] = item, item
            end
        end
        for _, e in ipairs(entries) do
            local parts = {}
            for part in e.path:gmatch('[^>]+') do parts[#parts + 1] = trim(part) end
            local target, path = items, ''
            for i = 1, #parts - 1 do
                path = path == '' and parts[i] or path .. ' > ' .. parts[i]
                if not by_path[path] then
                    local node = {id = path, title = parts[i], items = {}}
                    target[#target + 1], by_path[path] = node, node
                end
                target = by_path[path].items
            end
            target[#target + 1] = make_item(e)
        end
        if #items > 1 then items[#items - 1].separator = true end
    end
    local result = {type = menu_type, title = view == 'tracks' and '选择轨道' or (view == 'secondary' and '选择次字幕' or '菜单'),
        items = items, callback = {name, 'event'}, keep_open = true, search_submenus = true}
    mp.set_property_native('user-data/menu-ui/menu', result)
    return result
end
refresh = function()
    if get('user-data/uosc/menu/type') == menu_type then
        mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(data()))
    end
end
local function open(mode, submenu)
    view = mode or 'main'
    if submenu and submenu ~= '' then
        mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(data()), submenu)
    else mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(data())) end
end
local function toggle()
    if get('user-data/uosc/menu/type') == menu_type then mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
    else open() end
end
mp.register_script_message('event', function(json)
    local event = utils.parse_json(json)
    if not event or event.type ~= 'activate' or get('user-data/uosc/menu/type') ~= menu_type then return end
    if event.modifiers and event.modifiers ~= 'alt' then return end
    local selected = actions[event.value]
    if not selected then return end
    if not selected.keep then mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type) end
    local ok, message
    if type(selected.command) == 'table' then ok, message = mp.commandv(unpack(selected.command))
    else ok, message = mp.command(selected.command) end
    if not ok then mp.osd_message('操作失败：' .. tostring(message), 4) end
    changed()
end)
mp.register_script_message('open', function(submenu) open('main', submenu) end)
mp.register_script_message('toggle', toggle)
mp.register_script_message('secondary', function() open('secondary') end)
mp.register_script_message('tracks', function() open('tracks') end)
mp.register_script_message('shuffle', function() set_shuffle(not shuffle) end)
mp.register_script_message('set', function(prop, value) if prop == 'shuffle' then set_shuffle(value == 'yes') end end)
mp.register_script_message('continuous', toggle_continuous)
mp.register_script_message('reset', function()
    -- Match existing per-section resets. Leave rendering profiles, window state,
    -- reset-on-next-file policy and user-owned filter chains intact.
    stop_continuous()
    for prop, value in pairs({speed = 1, ['audio-delay'] = 0, contrast = 0, brightness = 0, gamma = 0, saturation = 0, hue = 0,
        ['video-zoom'] = 0, ['video-pan-x'] = 0, ['video-pan-y'] = 0, ['video-rotate'] = 0, panscan = 0,
        ['video-aspect-override'] = 'no', ['sub-pos'] = 100, ['sub-scale'] = 1, ['sub-delay'] = 0,
        ['secondary-sub-pos'] = 0, ['secondary-sub-scale'] = 1, ['secondary-sub-delay'] = 0}) do
        mp.set_property(prop, tostring(value))
    end
    mp.commandv('script-message-to', 'gpu_effects', 'reset')
    mp.osd_message('已恢复常用播放调整；保留独立滤镜、配置组和窗口设置。', 4)
    changed()
end)
local function connect()
    mp.commandv('script-message-to', 'uosc', 'overwrite-binding', 'menu', 'script-message-to ' .. name .. ' toggle')
    mp.commandv('script-message-to', 'uosc', 'overwrite-binding', 'menu-blurred', 'script-message-to ' .. name .. ' toggle')
    publish()
end
mp.register_script_message('uosc-version', connect)
mp.add_timeout(0, connect)
for _, prop in ipairs({'idle-active', 'path', 'track-list', 'chapter-list', 'edition-list', 'playlist', 'vid', 'aid', 'sid', 'secondary-sid', 'af'}) do watch(prop) end
mp.add_hook('on_unload', 20, stop_continuous)
mp.register_event('file-loaded', changed)
