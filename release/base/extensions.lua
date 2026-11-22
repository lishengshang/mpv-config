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

local busy, whisper_plan = false, nil
local whisper_plan_kind = 'extensions-whisper-plan'

local function menu(title, items, kind, update)
    mp.commandv('script-message-to', 'uosc', update and 'update-menu' or 'open-menu',
        utils.format_json({title = title, type = kind or 'extensions', items = items}))
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

local function setup(action, id, device, callback)
    local program = mp.command_native({'expand-path', '~~/tools/first-setup.ps1'})
    mp.command_native_async({name = 'subprocess', playback_only = false,
        capture_stdout = true, capture_stderr = true,
        args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', program, '-Action', action, '-Feature', id, '-Device', device or 'cpu'}},
        function(success, result)
            busy = false
            callback(success and result and result.status == 0, result or {})
        end)
end

local function setup_error(result)
    mp.msg.error('Extension setup failed: ' .. (result.stderr or ''):sub(-1500))
    mp.osd_message('扩展安装未完成。可重新打开扩展菜单重试，或用 first-setup.cmd 查看详情。', 7)
end

local function progress(assets)
    local directory = mp.command_native({'expand-path', '~~/cache/first-setup/downloads'})
    local expected = 0
    for _, asset in ipairs(assets) do expected = expected + asset.bytes end
    return mp.add_periodic_timer(1, function()
        local downloaded = 0
        for _, asset in ipairs(assets) do
            local path = utils.join_path(directory, asset.name)
            local ready = utils.file_info(path)
            local partial = utils.file_info(path .. '.part')
            downloaded = downloaded + math.min(asset.bytes, (partial or ready or {}).size or 0)
        end
        if downloaded < expected then
            mp.osd_message(string.format('正在下载 Whisper · %d%%', math.floor(100 * downloaded / expected)), 2)
        else
            mp.osd_message('正在校验并安装 Whisper…', 2)
        end
    end)
end

local function run(action, id, device, plan)
    if busy then mp.osd_message('扩展操作正在进行'); return end
    if not registry()[id] then return end
    busy = true
    local timer = plan and progress(plan.assets)
    mp.osd_message('正在处理扩展。播放可以继续。', 4)
    setup(action, id, device, function(success, result)
        if timer then timer:kill() end
        if success then
            mp.osd_message('已保存。重新打开播放器后生效。', 6)
        else
            setup_error(result)
        end
    end)
end

local function gb(bytes)
    if bytes == 0 then return '0 MB' end
    if bytes < 1e9 then return string.format('%.0f MB', bytes / 1e6) end
    return string.format('%.2f GB', bytes / 1e9)
end

local function plan_whisper()
    if busy then mp.osd_message('扩展操作正在进行'); return end
    busy, whisper_plan = true, nil
    mp.set_property_native('user-data/extensions/whisper-plan', nil)
    local kind = whisper_plan_kind
    local title = '安装 AI 字幕 · Whisper'
    menu(title, {{title = '正在检查下载缓存和磁盘空间…', selectable = false}}, kind)
    setup('PlanWhisper', 'whisper', nil, function(success, result)
        if mp.get_property_native('user-data/uosc/menu/type') ~= kind then return end
        local plan = success and utils.parse_json(result.stdout or '')
        if type(plan) ~= 'table' then
            setup_error(result)
            menu(title, {item('重新检查', 'whisper-plan')}, kind, true)
            return
        end
        local items = {
            {title = '预计还需下载  ' .. gb(plan.download_bytes), selectable = false},
            {title = '安装后预计占用  ' .. gb(plan.installed_bytes), selectable = false,
                hint = '含已校验下载缓存'},
            {title = '安装所需空闲空间  ' .. gb(plan.required_free_bytes), selectable = false},
            {title = '当前可用  ' .. gb(plan.free_bytes), selectable = false, hint = plan.drive},
        }
        if plan.free_bytes >= plan.required_free_bytes then
            whisper_plan = plan
            local choices = plan.cuda_available and {{'NVIDIA CUDA（推荐）', 'cuda'}, {'CPU', 'cpu'}}
                or {{'CPU（推荐）', 'cpu'}, {'NVIDIA CUDA', 'cuda', '需要兼容显卡及驱动'}}
            for _, choice in ipairs(choices) do
                local label = plan.download_bytes > 0 and '下载并安装 · ' or '安装或重新配置 · '
                local confirm = item(label .. choice[1], 'whisper-install', choice[2])
                confirm.hint = choice[3]
                confirm.keep_open = true
                items[#items + 1] = confirm
            end
        else
            items[#items + 1] = {title = '空间不足，请释放空间后重试', selectable = false}
            items[#items + 1] = item('重新检查', 'whisper-plan')
        end
        items[#items + 1] = {title = '稍后', value = {'script-message-to', 'uosc', 'close-menu'}}
        menu(title, items, kind, true)
        mp.set_property_native('user-data/extensions/whisper-plan', plan)
    end)
end

local function manage(id)
    local feature = registry()[id]
    if not feature then return end
    local installed = configured(id)
    if id == 'whisper' and not installed then plan_whisper(); return end
    local items = {}
    if installed then
        if enabled(id) then
            items[#items + 1] = {title = '使用功能', value = {'script-message-to', feature.target, feature.message}}
        end
        items[#items + 1] = item('启用', 'run', 'Enable', id)
        items[#items + 1] = item('关闭', 'run', 'Disable', id)
        items[#items + 1] = item('恢复上次配置', 'run', 'Rollback', id)
    end
    if id == 'whisper' then
        items[#items + 1] = item('重新配置 Whisper…', 'whisper-plan')
    else
        items[#items + 1] = item('安装或修复 ' .. feature.title, 'run', feature.install, id)
    end
    menu(feature.title, items, 'extensions-' .. id)
end

mp.register_script_message('run', function(action, id)
    if action == 'Enable' or action == 'Disable' or action == 'Rollback' or
        (action == 'VapourSynth' and id == 'rtx') then
        run(action, id)
    end
end)
mp.observe_property('user-data/uosc/menu/type', 'string', function(_, kind)
    if kind ~= whisper_plan_kind then
        whisper_plan = nil
        mp.set_property_native('user-data/extensions/whisper-plan', nil)
    end
end)
mp.register_script_message('whisper-plan', plan_whisper)
mp.register_script_message('whisper-install', function(device)
    local plan = whisper_plan
    if not plan or busy or (device ~= 'cpu' and device ~= 'cuda') or
        mp.get_property_native('user-data/uosc/menu/type') ~= whisper_plan_kind then return end
    whisper_plan = nil
    mp.commandv('script-message-to', 'uosc', 'close-menu')
    run('Whisper', 'whisper', device, plan)
end)
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
local function open_whisper(show_menu)
    if enabled('whisper') then
        local feature = registry().whisper
        mp.commandv('script-message-to', feature.target, show_menu and 'sub-fastwhisper-manager' or feature.message)
    else
        manage('whisper')
    end
end
mp.register_script_message('whisper', function() open_whisper(false) end)
mp.register_script_message('whisper-manager', function() open_whisper(true) end)
