-- Local Chinese shortcut reference, using uosc's public menu/binding API.
-- Descriptions stay beside the commands in input.conf and InputEvent's config.
local mp = require 'mp'
local utils = require 'mp.utils'
local name, menu_type = mp.get_script_name(), 'keybinds'
local actions = {}
local function trim(text) return (text or ''):match('^%s*(.-)%s*$') end
local function normalize(command) return trim(command):gsub('%s+', ' ') end
local function read(path)
    if path:sub(1, 9) == 'memory://' then return path:sub(10) end
    local file = io.open(mp.command_native({'expand-path', path}), 'r')
    if not file then return '' end
    local source = file:read('*a'); file:close()
    return source
end
local function split_comment(text)
    local quote, escaped
    for i = 1, #text do
        local c = text:sub(i, i)
        if escaped then escaped = false
        elseif c == '\\' then escaped = true
        elseif quote then if c == quote then quote = nil end
        elseif c == '"' or c == "'" then quote = c
        elseif c == '#' then return trim(text:sub(1, i - 1)), text:sub(i + 1) end
    end
    return trim(text), ''
end
local function description(comment)
    local menu = comment:match('^menu:%s*([^#]+)')
    if menu then return trim(menu):gsub('%s*>%s*', ' · ') end
    return trim(comment:match('^([^#]+)'))
end
local function input_source()
    local path = mp.get_property('input-conf', '')
    return read(path ~= '' and path or '~~/input.conf')
end
local function labels(source)
    local result = {}
    for line in source:gmatch('[^\r\n]+') do
        local key, rest = line:match('^%s*(%S+)%s+(.+)$')
        if key and (key == '#' or key:sub(1, 1) ~= '#') then
            local command, comment = split_comment(rest)
            local label = description(comment)
            local id = normalize(command)
            if command ~= '' and label ~= '' and (not result[id] or comment:match('^menu:')) then result[id] = label end
        end
    end
    return result
end
local event_names = {click = '单击', double_click = '双击', triple_click = '三击',
    quatra_click = '四击', penta_click = '五击', press = '长按', release = '松开', ['repeat'] = '重复'}
local function event_bindings(source)
    local opts = {enable_external_config = false, external_config = '~~/script-opts/inputevent_key.conf', prefix = 'event'}
    require('mp.options').read_options(opts, 'inputevent')
    if opts.enable_external_config then source = read(opts.external_config) end
    local result = {}
    for line in source:gmatch('[^\r\n]+') do
        local key, rest = line:match('^%s*([^#%s]+)%s+(.+)$')
        if key then
            local command, comment = split_comment(rest)
            local event, label
            for part in comment:gmatch('[^#]+') do
                local prefix, value = part:match('^%s*(.-)%s*:%s*(.-)%s*$')
                if prefix == opts.prefix then event = value end
                if prefix == 'desc' then label = value end
            end
            if event then
                local gesture, condition = event:match('^(.-)%s*|%s*(.*)$')
                gesture = trim(gesture or event)
                if not event_names[gesture] then gesture = 'click' end
                result[key] = result[key] or {}
                result[key][#result[key] + 1] = {command = command, gesture = gesture,
                    condition = condition, label = label}
            end
        end
    end
    return result
end
local function human_key(key) return key:gsub('SHARP', '#') end
local function label_for(command, descriptions, owner)
    return descriptions[normalize(command)]
        or ('脚本操作 · ' .. (owner or command:match('script%-binding ([^%s]+)') or '自定义命令'))
end
local function data()
    local source = input_source()
    local descriptions, events = labels(source), event_bindings(source)
    -- Native key names preserve letter case. Resolve the winning binding first;
    -- disabled sections and weak/overridden bindings must not leak into the list.
    local active = {}
    for _, bind in ipairs(mp.get_property_native('input-bindings', {})) do
        if bind.owner ~= 'uosc' and bind.priority >= 0 then
            local old = active[bind.key]
            if not old or (old.is_weak and not bind.is_weak)
                or (old.is_weak == bind.is_weak and bind.priority > old.priority) then active[bind.key] = bind end
        end
    end
    local items = {}
    actions = {}
    local function add(key, title, command, gesture)
        local id = tostring(#items + 1)
        items[#items + 1] = {title = title, hint = human_key(key) .. (gesture and ' · ' .. gesture or ''), value = id}
        actions[id] = {command = command, title = title}
    end
    for key, bind in pairs(active) do
        if bind.owner == 'inputevent' and events[key] then
            for _, event in ipairs(events[key]) do
                if event.label or event.command ~= 'ignore' then
                    local title = event.label or label_for(event.command, descriptions, bind.owner)
                    if event.condition and not event.label then title = title .. '（条件：' .. event.condition .. '）' end
                    -- These rows describe gestures; executing a hold/release in
                    -- isolation could leave playback speed or UI state changed.
                    add(key, title, nil, event_names[event.gesture])
                end
            end
        elseif bind.cmd ~= '' and bind.cmd ~= 'ignore' then
            add(key, label_for(bind.cmd, descriptions, bind.owner), bind.cmd)
        end
    end
    table.sort(items, function(a, b) return a.hint == b.hint and a.title < b.title or a.hint < b.hint end)
    local result = {type = menu_type, title = '所有快捷键', search_style = 'palette', items = items,
        footnote = '可搜索中文说明或键位；单击／长按／松开条目请使用对应按键', callback = {name, 'event'}}
    mp.set_property_native('user-data/keybinds-menu/menu', result)
    return result
end
local function open()
    if mp.get_property_native('user-data/uosc/menu/type') == menu_type then
        mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
    else
        mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(data()))
    end
end
mp.register_script_message('open', open)
mp.register_script_message('event', function(json)
    local event = utils.parse_json(json)
    if not event or event.type ~= 'activate' or mp.get_property_native('user-data/uosc/menu/type') ~= menu_type then return end
    if event.action or event.modifiers then return end
    local selected = actions[event.value]
    if not selected then return end
    if not selected.command then mp.osd_message(selected.title .. '：请使用右侧所示按键', 3); return end
    mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
    mp.command(selected.command)
end)
local function connect()
    mp.commandv('script-message-to', 'uosc', 'overwrite-binding', 'keybinds', 'script-message-to ' .. name .. ' open')
end
mp.register_script_message('uosc-version', connect)
mp.add_timeout(0, connect)
