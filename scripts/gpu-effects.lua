-- Local GPU UX controller. Uses upstream uosc Menu API and mpv filter labels.
-- Algorithms and user tuning remain in the original shaders/.vpy presets.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local o = {runtime_path = '', probe_timeout = 20, initialization_timeout = 300}
options.read_options(o, 'gpu-effects')
local name, label = mp.get_script_name(), 'gpu-effects'
local presets, order = {}, {}
local groups = {'轻量超分', '补帧', '降噪', '超分与组合'}
local function preset(id, title, group, key, shader)
    local p = {id = id, title = title, group = group, key = key, shader = shader}
    p.path = mp.command_native({'expand-path', shader and
        ('~~/shaders/ArtCNN/' .. id .. '.glsl') or ('~~/vs/' .. id .. '.vpy')})
    presets[id] = p
    order[#order + 1] = p
end
preset('ArtCNN_C4F16', 'ArtCNN C4F16 · 轻量 shader', 1, 'CTRL+ALT+1', true)
preset('ArtCNN_C4F32', 'ArtCNN C4F32 · 均衡 shader', 1, 'CTRL+ALT+2', true)
preset('MEMC_RIFE_TRT', 'RIFE · TRT', 2, '$')
preset('MEMC_DRBA_TRT', 'DRBA · TRT', 2, '%')
preset('MEMC_RIFE_DML', 'RIFE · DML', 2, '@')
preset('MEMC_DRBA_DML', 'DRBA · DML', 2, '#')
preset('NR_BILATERAL_CUDA', 'Bilateral · 轻度空间降噪 · CUDA', 3, '!')
preset('NR_DFTTEST_CUDA', 'DFTTest · 频域时空降噪 · CUDA', 3, '+')
preset('NR_BM3D_CUDA', 'BM3D · 强降噪 · CUDA', 3, "'")
preset('SR_ARTCNN_TRT', 'ArtCNN R8F64 · TRT', 4, '&')
preset('SR_ARTCNN_CHROMA_TRT', 'ArtCNN 亮度+色度 · TRT', 4, 'ALT+&')
preset('SR_AnimeJaNaiV2_TRT', '动画 AnimeJaNai V2 · TRT', 4, 'ALT+^')
preset('SR_AnimeJaNaiV3_TRT', '动画 AnimeJaNai V3 锐化 · TRT', 4, '*')
preset('SR_AnimeJaNaiV2_DML', '动画 AnimeJaNai V2 · DML', 4, '^')
preset('SR_HFA2k_TRT', '真人 HFA2k · TRT', 4, '(')
preset('SR_Anime1080Fixer_TRT', '动画 1080p 修复 · TRT', 4, ')')
preset('MIX_SR_MEMC_TRT', '超分+补帧组合 · TRT', 4, 'ALT+_')

local function canon(path)
    return (path or ''):gsub('\\', '/'):lower()
end
local function same(a, b)
    return utils.format_json(a) == utils.format_json(b)
end
local function shaders() return mp.get_property_native('glsl-shaders', {}) end
local function filters() return mp.get_property_native('vf', {}) end
local function owned_filter()
    for _, f in ipairs(filters()) do
        if f.label == label then return f end
    end
end
local baseline, applied_shader, pending, generation = nil, nil, nil, 0
local function selected()
    if pending and pending.stage == 'init' then return pending.previous_id end
    local f = owned_filter()
    for _, p in ipairs(order) do
        if p.shader and applied_shader then
            local list = shaders()
            if #list == 1 and canon(list[1]) == canon(p.path) then return p.id end
        elseif f and f.enabled ~= false and f.params and canon(f.params.file) == canon(p.path) then
            return p.id
        end
    end
end

local last_message = '增强默认关闭；轻量 shader 无需 VS。'
local refresh_menu
local function publish()
    mp.set_property_native('user-data/gpu-effects', {
        active = selected() or '', pending = pending and pending.id or '',
        message = last_message})
    if refresh_menu then refresh_menu() end
end
local function say(message)
    last_message = message
    mp.msg.info(message)
    mp.osd_message(message, 5)
    publish()
end
local function rollback_filter(job)
    local current, slot = filters(), nil
    for i, f in ipairs(current) do
        if f.label == label and f.params and canon(f.params.file) == canon(presets[job.id].path) then slot = i end
    end
    -- An external clear/replacement owns its new state; don't resurrect our slot.
    if not slot then return true end
    table.remove(current, slot)
    for _, f in ipairs(job.previous_vf) do
        if f.label == label then table.insert(current, math.min(slot, #current + 1), f); break end
    end
    return mp.set_property_native('vf', current)
end
local function cancel(rollback)
    local restored, reason = true, nil
    generation = generation + 1
    if pending then
        local old = pending
        pending = nil
        if old.timer then old.timer:kill() end
        if old.request then mp.abort_async_command(old.request) end
        if old.stage == 'init' then mp.enable_messages('error') end
        if rollback ~= false and old.stage == 'init' then
            local ok, err = rollback_filter(old)
            if not ok then restored, reason = false, err; mp.msg.error('GPU 滤镜回滚失败：' .. tostring(err)) end
        end
    end
    return restored, reason
end

local function restore_shader()
    -- If a profile or another shader control changed the list, respect its edit.
    if applied_shader and same(shaders(), applied_shader) then
        local ok, err = mp.set_property_native('glsl-shaders', baseline or {})
        if not ok then return nil, err end
    end
    baseline, applied_shader = nil, nil
    return true
end
local function reset(quiet)
    cancel(false)
    if owned_filter() then
        local ok, err = mp.commandv('vf', 'remove', '@' .. label)
        if not ok then say('关闭 GPU 滤镜失败：' .. tostring(err)); return end
    end
    local ok, err = restore_shader()
    if not ok then say('恢复 shader 失败：' .. tostring(err)); return end
    if quiet then last_message = '新文件：GPU 临时增强已关闭。'; publish()
    else say('已关闭本菜单的 GPU 增强；保留其他滤镜与调参。') end
end

local function apply(p)
    -- Labels isolate the slot; handle both synchronous and deferred init failure.
    if p.shader then
        local old_filter = owned_filter()
        local old_filters = filters()
        local old_shaders = shaders()
        if old_filter then
            local ok, err = mp.commandv('vf', 'remove', '@' .. label)
            if not ok then say('切换失败：' .. tostring(err)); return end
        end
        local ok, err = mp.set_property_native('glsl-shaders', {p.path})
        if not ok then
            if old_filter then mp.set_property_native('vf', old_filters) end
            say('shader 应用失败：' .. tostring(err)); return
        end
        -- Consecutive light preset changes share the original baseline.
        if not applied_shader or not same(old_shaders, applied_shader) then baseline = old_shaders end
        applied_shader = {p.path}
    else
        local old_filters = filters()
        local previous_id = selected()
        local spec = '@' .. label .. ':vapoursynth=file=%' .. #p.path .. '%' .. p.path
        local job = {id = p.id, stage = 'init', previous_vf = old_filters, previous_id = previous_id}
        pending = job
        -- VS initializes lazily; video-reconfig can precede its evaluation.
        -- Subscribe to debug only during initialization for its positive signal.
        mp.enable_messages('debug')
        job.timer = mp.add_timeout(math.max(1, o.initialization_timeout), function()
            if pending == job then cancel(); say('GPU 初始化超时，已恢复原效果。') end
        end)
        say('正在初始化：' .. p.title .. '\n首次 TRT 引擎构建可能较慢。')
        local ok, err = mp.commandv('vf', 'add', spec)
        if not ok then
            cancel()
            say('GPU 初始化失败，保留原效果：' .. tostring(err) .. '\n请查看控制台，或运行 tools/verify-gpu.cmd。')
            return
        end
        if not owned_filter() then cancel(); say('GPU 滤镜未建立，请查看控制台。'); return end
        -- Confirm on video reconfiguration; errors may arrive after vf add returns.
        return
    end
    say('已选择：' .. p.title .. '\n首次 shader 编译可能较慢。')
end

local function runtime()
    return mp.command_native({'expand-path', o.runtime_path ~= '' and o.runtime_path or '~~/../'})
end
local function file_exists(path)
    local info = utils.file_info(path)
    return info and info.is_file
end
local function missing(p)
    if not file_exists(p.path) then return '缺少预设文件：' .. p.id end
    if not p.shader then
        for _, part in ipairs({'python.exe', 'VSScript.dll', 'portable.vs', 'Lib', 'vs-plugins'}) do
            if not utils.file_info(utils.join_path(runtime(), part)) then
                return '未检测到完整 VapourSynth 便携运行时（缺少 ' .. part .. '）。\n请安装可选 VS 增强包；轻量 ArtCNN shader 仍可使用。'
            end
        end
    end
end
local function toggle(id)
    local p = presets[id]
    if not p then say('未知 GPU 预设：' .. tostring(id)); return end
    if pending and pending.id == id then cancel(); say('已取消依赖检查。'); return end
    cancel()
    if selected() == id then reset(); return end
    local reason = missing(p)
    if reason then say(reason .. '\n安装说明：docs/gpu-setup.md'); return end
    if not mp.get_property_native('video-params') or mp.get_property_native('idle-active') then
        say('请先加载有视频轨的媒体，再选择 GPU 增强。'); return
    end
    if p.shader then apply(p); return end
    local probe = mp.command_native({'expand-path', '~~/tools/gpu_probe.py'})
    if not file_exists(probe) then say('缺少依赖检查工具 tools/gpu_probe.py'); return end
    local token = generation
    local job = {id = id, vf = filters(), shaders = shaders()}
    pending = job
    say('检查依赖：' .. p.title .. '\nTRT 首次初始化可能需要构建引擎。')
    job.timer = mp.add_timeout(math.max(1, o.probe_timeout), function()
        if pending == job then cancel(); say('VS 依赖检查超时，保留原效果。') end
    end)
    job.request = mp.command_native_async({name = 'subprocess', playback_only = false,
        args = {utils.join_path(runtime(), 'python.exe'), probe, p.path},
        capture_stdout = true, capture_stderr = true}, function(success, result, error)
        if token ~= generation or pending ~= job then return end
        job.timer:kill()
        pending = nil
        local data = success and result and utils.parse_json(result.stdout or '')
        if not data or not data.ok or result.status ~= 0 then
            say((data and data.reason or ('VS 检查进程失败：' .. tostring(error or (result and result.status)))) ..
                '\n保留原效果；说明：docs/gpu-setup.md')
            return
        end
        if not same(job.vf, filters()) or not same(job.shaders, shaders()) then
            say('检查期间滤镜已变化，本次应用已取消。'); return
        end
        apply(p)
    end)
end

local function command(action, arg)
    return {'script-message-to', name, action, arg or ''}
end
local function menu_data()
    local current = selected()
    local items = {{title = current and ('当前：' .. presets[current].title) or '当前：未启用本菜单增强',
        selectable = false, muted = true},
        {title = '关闭本菜单增强', value = command('reset'), hint = '撤销本入口增强，恢复开启前状态'}}
    for index, title in ipairs(groups) do
        local children = {}
        for _, p in ipairs(order) do
            if p.group == index then
                local reason = missing(p)
                children[#children + 1] = {title = p.title, value = command('toggle', p.id),
                    active = current == p.id, muted = reason ~= nil,
                    hint = pending and pending.id == p.id and (pending.stage == 'init' and '初始化中…' or '检查中…') or
                        (reason and '缺依赖 · 点击查看' or p.key)}
            end
        end
        items[#items + 1] = {title = title, items = children}
    end
    items[#items + 1] = {title = '依赖与使用说明', value = command('help')}
    return {type = 'gpu-effects', title = 'GPU 增强', keep_open = true,
        search_submenus = true, items = items, footnote = last_message:gsub('\n', ' ')}
end
refresh_menu = function()
    if mp.get_property_native('user-data/uosc/menu/type') == 'gpu-effects' then
        mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(menu_data()))
    end
end
mp.register_script_message('menu', function()
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu_data()))
end)
mp.register_script_message('toggle', toggle)
mp.register_script_message('reset', function() reset() end)
mp.register_script_message('help', function()
    say('轻量 shader 无需 VS；其他预设需要 VS 增强包及对应插件/模型。\n一次选择一个增强，重复选择关闭，下一文件恢复默认。\n部署：docs/gpu-setup.md；实际产帧自检：tools/verify-gpu.cmd。')
end)
mp.register_script_message('clear-vf', function()
    cancel(false)
    local ok, err = mp.commandv('vf', 'clr', '')
    say(ok and '视频滤镜已清空。' or ('清空失败：' .. tostring(err)))
end)
mp.register_script_message('clear-shaders', function()
    cancel()
    local ok, err = mp.set_property_native('glsl-shaders', {})
    if ok then baseline, applied_shader = nil, nil end
    say(ok and '着色器已清空。' or ('清空失败：' .. tostring(err)))
end)
mp.enable_messages('error')
local initialized
mp.register_event('log-message', function(event)
    local f = owned_filter()
    if not f or (event.prefix ~= 'vapoursynth' and
        not (event.prefix == 'vf' and event.text:find(label, 1, true))) then return end
    local job = pending
    if job and job.stage == 'init' and event.prefix == 'vapoursynth' and
        event.text:match('^initialized%.%s*$') then
        initialized()
        return
    end
    if event.level ~= 'error' and event.level ~= 'fatal' then return end
    if job and job.stage == 'init' then
        if not job.failure then
            job.failure = event.text
            mp.add_timeout(0, function()
                if pending ~= job then return end
                local restored, reason = cancel()
                say('GPU 初始化失败，' .. (restored and '已恢复原效果：' or ('回滚失败：' .. tostring(reason) .. '；')) ..
                    job.failure:gsub('\n', ' '))
            end)
        elseif event.text:find('Python exception:', 1, true) then job.failure = event.text end
    else
        -- Later frame/seek failures must not leave a dead filter marked active.
        cancel(false)
        mp.commandv('vf', 'remove', '@' .. label)
        say('GPU 运行失败，已关闭该增强：' .. event.text:gsub('\n', ' '))
    end
end)
initialized = function()
    local job = pending
    if not job or job.stage ~= 'init' or job.failure then return end
    local restored, reason = restore_shader()
    if not restored then cancel(); say('shader 恢复失败，已恢复原滤镜：' .. tostring(reason)); return end
    job.timer:kill()
    pending = nil
    mp.enable_messages('error')
    say('已应用：' .. presets[job.id].title)
end
mp.observe_property('vf', 'native', publish)
mp.observe_property('glsl-shaders', 'native', function()
    if applied_shader and not same(shaders(), applied_shader) then baseline, applied_shader = nil, nil end
    publish()
end)
-- Reset before the next file's video chain is built, even if global reset is off.
mp.add_hook('on_load', 9, function() reset(true) end)
mp.register_event('end-file', function() cancel(false); publish() end)
publish()
