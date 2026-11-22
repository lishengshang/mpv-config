-- The Base only registers menu messages; disk reads happen when a menu is opened.
local mp = require 'mp'
local utils = require 'mp.utils'
local features, ordered_features
local function registry()
    if features then return features end
    local file = assert(io.open(mp.find_config_file('release/base/extensions.json'), 'r'))
    local data = utils.parse_json(file:read('*a'))
    file:close()
    ordered_features = assert(data, 'Invalid extension registry')
    features = {}
    for _, feature in ipairs(ordered_features) do features[feature.id] = feature end
    return features
end

local function enabled(id)
    local settings = mp.get_property_native('options/script-opts', {})
    return settings['extensions-' .. id] == 'yes'
end

local busy = false

local function menu(title, items, kind)
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json({title = title, type = kind or 'extensions', items = items}))
end

local function item(title, message, ...)
    return {title = title, value = {'script-message-to', 'extensions', message, ...}}
end

local function configured(id)
    local path = mp.command_native({'expand-path', '~~/state/' .. id .. '.conf'})
    local file = io.open(path, 'r')
    if not file then return false, false end
    local text = file:read('*a')
    file:close()
    return text:find('# Installed', 1, true) ~= nil,
        text:find('script-opts-append=extensions-' .. id .. '=yes', 1, true) ~= nil
end

local function run(action, id, device)
    if busy then mp.osd_message('扩展操作正在进行'); return end
    if not registry()[id] then return end
    local allowed = {Whisper = true, VapourSynth = true, Enable = true, Disable = true, Rollback = true}
    if not allowed[action] then return end
    busy = true
    mp.osd_message('正在处理扩展。播放可以继续。', 4)
    local program = mp.command_native({'expand-path', '~~/tools/first-setup.ps1'})
    mp.command_native_async({name = 'subprocess', playback_only = false,
        capture_stdout = true, capture_stderr = true,
        args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', program, '-Action', action, '-Feature', id, '-Device', device or 'cpu'}},
        function(success, result)
            busy = false
            if success and result and result.status == 0 then
                mp.osd_message('已保存。重新打开播放器后生效。', 6)
            else
                mp.msg.error('Extension setup failed: ' .. (result and (result.stderr or ''):sub(-1500) or ''))
                mp.osd_message('扩展操作失败。请双击 first-setup.cmd 查看具体原因。', 7)
            end
        end)
end

local function manage(id)
    local feature = registry()[id]
    if not feature then return end
    local items = {}
    if configured(id) then
        if enabled(id) then
            items[#items + 1] = {title = '使用功能', value = {'script-message-to', feature.target, feature.message}}
        end
        items[#items + 1] = item('启用', 'run', 'Enable', id)
        items[#items + 1] = item('关闭', 'run', 'Disable', id)
        items[#items + 1] = item('恢复上次配置', 'run', 'Rollback', id)
    end
    if id == 'whisper' then
        items[#items + 1] = item('安装或修复 Whisper · CPU', 'run', feature.install, id, 'cpu')
        items[#items + 1] = item('安装或修复 Whisper · NVIDIA CUDA', 'run', feature.install, id, 'cuda')
    else
        items[#items + 1] = item('安装或修复 ' .. feature.title, 'run', feature.install, id)
    end
    menu(feature.title, items, 'extensions-' .. id)
end

mp.register_script_message('run', run)
mp.register_script_message('manage', manage)
mp.register_script_message('menu', function()
    registry()
    local items = {}
    for _, feature in ipairs(ordered_features) do
        local installed, selected = configured(feature.id)
        local entry = item(feature.title, 'manage', feature.id)
        if not installed then entry.hint = '未安装'
        elseif selected ~= enabled(feature.id) then entry.hint = '重新打开后生效'
        else entry.hint = selected and '已启用' or '已关闭' end
        items[#items + 1] = entry
    end
    menu('扩展', items)
end)
mp.register_script_message('whisper', function()
    if enabled('whisper') then
        local feature = registry().whisper
        mp.commandv('script-message-to', feature.target, feature.message)
    else
        manage('whisper')
    end
end)
