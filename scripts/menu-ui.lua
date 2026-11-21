-- Adapted from dev's menu-ui. Use uosc's menu API with the Linux input.conf.
local mp = require 'mp'
local utils = require 'mp.utils'
local name, menu_type = mp.get_script_name(), 'menu-ui'
local entries, actions, watched = {}, {}, {}
local view, pending = 'main', nil

local function trim(value) return value:match('^%s*(.-)%s*$') end
local function get(property) return mp.get_property_native(property) end

local function first_command(command)
    local words, token, quote, escaped = {}, nil, nil, false
    for i = 1, #command do
        local c = command:sub(i, i)
        if escaped then token, escaped = token .. c, false
        elseif quote then
            if c == quote then quote = nil
            elseif c == '\\' then escaped = true
            else token = token .. c end
        elseif c == '"' or c == "'" then quote, token = c, token or ''
        elseif c == ';' or c:match('%s') then
            if token then words[#words + 1], token = token, nil end
            if c == ';' then break end
        else token = (token or '') .. c end
    end
    if token then words[#words + 1] = token end
    if words[1] == 'no-osd' or words[1] == 'osd-auto' then table.remove(words, 1) end
    return words
end

local function read_input()
    local path = mp.get_property('input-conf', '')
    if path:sub(1, 9) == 'memory://' then return path:sub(10) end
    if path == '' then path = mp.find_config_file('input.conf') end
    local file = path and io.open(mp.command_native({'expand-path', path}), 'r')
    if not file then return end
    local contents = file:read('*a')
    file:close()
    return contents
end

local input = read_input()
if not input then return end
local property_commands = {add = true, set = true, cycle = true, ['cycle-values'] = true, multiply = true}
local aliases = {audio = 'aid', sub = 'sid'}
for line in input:gmatch('[^\r\n]+') do
    local key, command, comment = line:match('^%s*(%S+)%s+(.-)%s*#menu:%s*(.*)$')
    if key and (key == '#' or key:sub(1, 1) ~= '#') and command ~= '' and command ~= 'ignore' then
        local path = trim(comment:match('^[^#]*'))
        local words = first_command(command)
        local prop = comment:match('#@value=([%w_/%-]+)') or (property_commands[words[1]] and words[2])
        entries[#entries + 1] = {
            id = 'entry:' .. (#entries + 1), key = key ~= '#' and key or nil, command = command, path = path,
            words = words, property = aliases[prop] or prop, choices = comment:match('#@choices=([%w%-]+)'),
        }
    end
end
if #entries == 0 then return end

local function display(value)
    if value == nil then return '不可用' end
    if type(value) == 'boolean' then return value and '开启' or '关闭' end
    if type(value) == 'number' then return ('%.4g'):format(value) end
    return ({yes = '开启', no = '关闭', auto = '自动', inf = '无限', [''] = '无'})[value] or tostring(value)
end

local function action(item, command, keep)
    actions[item.value] = {command = command, keep = keep}
    item.keep_open = true
    return item
end

local function track_items(tracks, kind, property)
    local current = mp.get_property_number(property)
    local items = {action({title = '关闭', value = property .. ':no', active = not current},
        {'set', property, 'no'}, true)}
    for _, track in ipairs(tracks) do
        if track.type == kind then
            local title = track.title or ('轨道 ' .. track.id)
            local hint = track.lang or track.codec
            items[#items + 1] = action({title = title, hint = hint, value = property .. ':' .. track.id,
                active = current == track.id}, {'set', property, track.id}, true)
        end
    end
    return items
end

local function choice_items(entry, tracks)
    local property = entry.choices
    if property == 'secondary-sid' then return track_items(tracks, 'sub', property) end
    local current = mp.get_property(property)
    local items = {}
    for i = 3, #entry.words do
        local value = entry.words[i]
        local title, active = display(value), current == value
        if property == 'video-aspect-override' then
            if value == 'no' then
                title = '原始比例'
                active = current == 'no' or (tonumber(current) or 1) <= 0
            else
                local a, b = value:match('^(%d+%.?%d*):(%d+%.?%d*)$')
                if a then active = active or math.abs((tonumber(current) or 0) - a / b) < 0.00001 end
            end
        end
        items[#items + 1] = action({title = title, value = entry.id .. ':' .. i, active = active},
            {'set', property, value}, true)
    end
    return items
end

local function unavailable(entry, state)
    local cmd, path = entry.command, entry.path
    if cmd == 'script-binding uosc/load-subtitles' or cmd == 'script-binding uosc/load-audio' then
        if state.idle then return '请先打开媒体' end
    elseif path:match('^字幕 >') and not state.kinds.sub then return '当前无字幕'
    elseif path:match('^音频 >') and cmd ~= 'script-binding uosc/audio-device' and not state.kinds.audio then return '当前无音轨'
    elseif (path:match('^画面 >') or path:match('^画质增强 >') or path:match('^截图与导出 >'))
        and not state.kinds.video then return '当前无视频'
    elseif path:match('^播放 >') and state.idle then return '请先打开媒体'
    elseif (cmd:match('^add chapter ') or cmd == 'script-binding uosc/chapters') and not state.chapters then return '当前无章节'
    elseif (cmd:match('^playlist%-') or cmd:find('local_tools sort-playlist', 1, true)) and state.count < 2 then
        return '需要至少两项'
    end
end

local function status(entry, item, state)
    local property = entry.property
    local verb, target, operation, argument = unpack(entry.words)
    local value, current
    if property then
        value = get(property)
        current = display(type(value) == 'table' and mp.get_property(property) or value)
        if type(value) == 'boolean' then item.active = value
        elseif property == 'loop-file' or property == 'loop-playlist' then item.active = value ~= 'no' and value ~= nil end
    end
    if entry.choices == 'video-aspect-override' and (value == false or value == 'no' or (tonumber(value) or 1) <= 0) then
        current = '原始比例'
    end
    if verb == 'af' and operation and (operation == '@audio-normalization' or operation:match('^@audio%-normalization:')) then
        local mode = operation:match('lavfi=%[([%w_]+)')
        item.active = target == 'remove' and not state.normalization or (mode ~= nil and mode == state.normalization)
    elseif verb == 'script-message-to' and target == 'quality' then
        if operation == 'select' then item.active = state.quality[argument] == entry.words[5]
        elseif operation == 'toggle-deband' then item.active = state.quality.deband ~= nil end
    elseif verb == 'set' and property and operation and not entry.command:find(';', 1, true) then
        item.active = mp.get_property(property) == operation
    end
    if item.active ~= nil and not current then current = item.active and '当前' or nil end
    if current then item.hint = current .. (entry.key and ' · ' .. entry.key or '') end
end

local groups = {{'视频', 'video', 'vid'}, {'音频', 'audio', 'aid'}, {'主字幕', 'sub', 'sid'}, {'次字幕', 'sub', 'secondary-sid'}}
local function data()
    actions = {}
    local tracks = get('track-list') or {}
    local items = {}
    if view == 'secondary' then
        items = track_items(tracks, 'sub', 'secondary-sid')
    elseif view == 'tracks' then
        for _, group in ipairs(groups) do
            items[#items + 1] = {id = group[3], title = group[1], items = track_items(tracks, group[2], group[3])}
        end
    else
        local state = {idle = get('idle-active'), kinds = {}, count = get('playlist-count') or 0,
            chapters = #(get('chapter-list') or {}) > 0, quality = get('user-data/quality/selected') or {}}
        for _, track in ipairs(tracks) do state.kinds[track.type] = true end
        for _, filter in ipairs(get('af') or {}) do
            if filter.label == 'audio-normalization' and filter.params then
                state.normalization = (filter.params.graph or ''):match('^([%w_]+)')
            end
        end

        local nodes = {}
        for _, entry in ipairs(entries) do
            local parts, path, children = {}, '', items
            for part in entry.path:gmatch('[^>]+') do parts[#parts + 1] = trim(part) end
            for i = 1, #parts - 1 do
                path = path == '' and parts[i] or path .. ' > ' .. parts[i]
                if not nodes[path] then
                    nodes[path] = {id = path, title = parts[i], items = {}}
                    children[#children + 1] = nodes[path]
                end
                children = nodes[path].items
            end
            local item = {id = entry.path, title = parts[#parts], hint = entry.key}
            local reason = unavailable(entry, state)
            if reason then
                item.hint, item.selectable, item.muted = reason, false, true
            else
                status(entry, item, state)
                if entry.choices then item.items = choice_items(entry, tracks)
                else
                    item.value = entry.id
                    local keep = entry.property ~= nil and entry.property ~= 'chapter'
                        or entry.command:match('^af ') ~= nil or entry.command:match('^script%-message%-to quality ') ~= nil
                    action(item, entry.command, keep)
                end
            end
            children[#children + 1] = item
        end
    end
    local titles = {main = '菜单', tracks = '选择轨道', secondary = '选择次字幕'}
    local menu = {type = menu_type, title = titles[view], items = items, search_submenus = true, callback = {name, 'event'}}
    mp.set_property_native('user-data/menu-ui/menu', menu)
    return utils.format_json(menu)
end

local function opened() return get('user-data/uosc/menu/type') == menu_type end
local timer = mp.add_timeout(0.08, function()
    if opened() then mp.commandv('script-message-to', 'uosc', 'update-menu', data()) end
end)
timer:kill()
local function changed()
    if opened() then timer:kill(); timer:resume() end
end
local function watch(property)
    if property and not watched[property] then
        watched[property] = true
        mp.observe_property(property, 'native', changed)
    end
end
for _, entry in ipairs(entries) do watch(entry.property); watch(entry.choices) end
for _, property in ipairs({'idle-active', 'track-list', 'chapter-list', 'playlist-count', 'vid', 'aid', 'sid',
    'secondary-sid', 'af', 'user-data/quality/selected'}) do watch(property) end

local function execute(command)
    local ok, error
    if type(command) == 'table' then ok, error = mp.commandv(unpack(command))
    else ok, error = mp.command(command) end
    if not ok then mp.osd_message('操作失败：' .. tostring(error), 4) end
end

mp.observe_property('user-data/uosc/menu/type', 'native', function(_, kind)
    if pending and kind ~= menu_type then
        local command = pending
        pending = nil
        if kind == nil then execute(command) end
    end
end)

local function open(mode, submenu)
    pending, view = nil, mode
    if get('user-data/mpv/console/open') then mp.commandv('script-message-to', 'console', 'disable') end
    mp.commandv('script-message-to', 'uosc', 'open-menu', data(), submenu or '')
end

local function toggle()
    if opened() then mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
    else open('main') end
end

mp.register_script_message('event', function(json)
    local event = utils.parse_json(json)
    if not event or event.type ~= 'activate' or not opened() or pending then return end
    if event.modifiers and event.modifiers ~= 'alt' then return end
    local selected = actions[event.value]
    if not selected then return end
    if selected.keep then
        execute(selected.command)
        changed()
    else
        pending = selected.command
        mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
    end
end)
mp.register_script_message('open', function(submenu) open('main', submenu) end)
mp.register_script_message('toggle', toggle)
mp.register_script_message('tracks', function() open('tracks') end)
mp.register_script_message('secondary', function() open('secondary') end)

local function connect()
    for _, binding in ipairs({'menu', 'menu-blurred'}) do
        mp.commandv('script-message-to', 'uosc', 'overwrite-binding', binding, 'script-message-to ' .. name .. ' toggle')
    end
end
mp.register_script_message('uosc-version', connect)
mp.add_timeout(0, connect)
