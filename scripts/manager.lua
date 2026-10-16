-- Upstream manager entry points retained; local preview/backup implementation.
-- See docs/config-checks.md before replacing with an upstream version.
local utils = require 'mp.utils'
package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local guard = require 'managed-update'
local o = {config = '~~/manager.json', root = '~~/cache/manager'}
require('mp.options').read_options(o, 'manager')
local function expand(path)
    local value = mp.command_native({'expand-path', path})
    return mp.command_native({'normalize-path', value ~= '' and value or '.'})
end
local root, plan = expand(o.root), nil
local function run(args)
    local r = mp.command_native({name = 'subprocess', args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true})
    assert(r and r.status == 0, 'Command failed: ' .. tostring(r and r.stderr or 'no result'))
    return r.stdout or ''
end
local function mkdir(path)
    run({'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
        "[IO.Directory]::CreateDirectory('" .. path:gsub("'", "''") .. "') | Out-Null"})
end
local function matches(path, patterns)
    for pattern in (patterns or ''):gmatch('[^|]+') do if path:match(pattern) then return true end end
    return false
end
local function relative(path)
    if path:find('\\', 1, true) or path:match('^/') or path:find(':', 1, true) then return false end
    for part in path:gmatch('[^/]+') do if part == '..' or part == '.' or part:lower() == '.git' then return false end end
    return path ~= ''
end
local function list_local(dir, prefix, result)
    for _, name in ipairs(utils.readdir(dir, 'files') or {}) do result[#result + 1] = prefix .. name end
    for _, name in ipairs(utils.readdir(dir, 'dirs') or {}) do
        if name ~= '.git' then list_local(dir .. '/' .. name, prefix .. name .. '/', result) end
    end
end
local function baseline_path(target) return root .. '/baselines/' .. guard.key(target:gsub('\\', '/'):lower()) .. '.json' end
local function baseline(target)
    local data = utils.parse_json(guard.read(baseline_path(target)) or '')
    if data and data.target == target then return data.content end
end
local function menu()
    local items, counts = {}, {create = 0, update = 0, unchanged = 0, conflict = 0}
    for _, item in ipairs(plan or {}) do counts[item.state] = counts[item.state] + 1 end
    items[1] = {title = '应用安全更新并备份', hint = (counts.create + counts.update) .. ' 个文件',
        value = {'script-message-to', 'manager', 'manager-apply'}}
    for _, item in ipairs(plan or {}) do
        if item.state ~= 'unchanged' then items[#items + 1] = {title = item.display, selectable = false,
            hint = ({create = '新增', update = '可更新', conflict = '本地差异，保留'})[item.state]} end
    end
    items[#items + 1] = {title = '取消', value = {'script-message-to', 'manager', 'manager-cancel'}}
    return {type = 'manager-preview', title = '脚本与着色器更新预览', items = items,
        footnote = '未知来源或已修改的文件保留；相同文件会建立后续更新基线。'}
end
local function preview()
    plan = nil
    mp.set_property_native('user-data/manager', {state = 'fetching'})
    local config = utils.parse_json(guard.read(expand(o.config)) or '')
    assert(type(config) == 'table' and #config > 0, 'Invalid manager configuration')
    mkdir(root .. '/sources'); mkdir(root .. '/baselines')
    local pending, seen = {}, {}
    local config_root = expand('~~/'):gsub('\\', '/'):lower():gsub('/+$', '') .. '/'
    for _, info in ipairs(config) do
        assert(type(info.git) == 'string', 'Missing upstream source')
        local dest = expand(info.dest or '~~/scripts'):gsub('\\', '/'):gsub('/+$', '')
        assert((dest:lower() .. '/'):sub(1, #config_root) == config_root, 'Destination must stay inside portable_config')
        local files, source = {}, info.local_repo
        if source then
            source = expand(source)
            assert(utils.file_info(source), 'Local upstream source missing')
            list_local(source, '', files)
        else
            source = root .. '/sources/' .. guard.key(info.git)
            mkdir(source)
            if not utils.file_info(source .. '/.git') then run({'git', 'init', source}) end
            run({'git', '-C', source, 'fetch', '--depth=1', info.git, info.branch or 'master'})
            for path in run({'git', '-c', 'core.quotepath=false', '-C', source, 'ls-tree', '-r', '--name-only', 'FETCH_HEAD'}):gmatch('[^\r\n]+') do files[#files + 1] = path end
        end
        local selected, base = {}, nil
        for _, file in ipairs(files) do
            assert(relative(file), 'Unsafe upstream path')
            local lower = file:lower()
            if ((info.whitelist or '') == '' or matches(lower, info.whitelist)) and not matches(lower, info.blacklist) then
                selected[#selected + 1] = file
                local dir = file:match('^(.*)/') or ''
                if base == nil then base = dir end
                while base ~= '' and (dir .. '/'):sub(1, #base + 1) ~= base .. '/' do base = base:match('^(.*)/') or '' end
            end
        end
        for _, file in ipairs(selected) do
            local suffix = info.flatten_folders and file:match('[^/]+$') or file:sub((base == '' and 0 or #base + 1) + 1)
            local target = dest .. '/' .. suffix
            assert(not seen[target:lower()], 'Overlapping upstream targets: ' .. target)
            seen[target:lower()] = true
            local data = info.local_repo and guard.read(source .. '/' .. file) or run({'git', '-C', source, 'show', 'FETCH_HEAD:' .. file})
            assert(data ~= nil, 'Upstream file unreadable')
            local before = guard.read(target)
            pending[#pending + 1] = {target = target, display = suffix, before = before, data = data,
                state = guard.classify(before, data, baseline(target))}
            mp.msg.info(pending[#pending].state .. ': ' .. target)
        end
    end
    assert(#pending > 0, 'No matching upstream files')
    plan = pending
    mp.set_property_native('user-data/manager', {state = 'preview', files = #plan})
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu()))
    mp.osd_message('更新预览已就绪；本地差异会保留，请在菜单应用安全更新。', 6)
end
local function apply()
    assert(plan, 'Preview required before applying updates')
    mp.set_property_native('user-data/manager', {state = 'applying'})
    local backup = root .. '/backups/' .. os.date('%Y%m%d-%H%M%S') .. '-' .. tostring(mp.get_time())
    mkdir(backup)
    local manifest = {}
    local backup_index = 0
    for i, item in ipairs(plan) do
        local old
        if item.state ~= 'conflict' then
            mkdir(item.target:match('^(.*)/')); backup_index = backup_index + 1
            if item.before ~= nil then old = backup_index .. '.old' end
        end
        manifest[i] = {target = item.target, state = item.state, original = old}
    end
    assert(guard.write(backup .. '/manifest.json', utils.format_json(manifest)), 'Cannot write backup manifest')
    local count, err = guard.apply(plan, backup, function(item)
        return guard.write(baseline_path(item.target), utils.format_json({target = item.target, content = item.data}))
    end)
    plan = nil
    assert(count, err)
    mp.set_property_native('user-data/manager', {state = 'applied', updated = count, backup = backup})
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'manager-preview')
    mp.osd_message('安全更新完成：' .. count .. ' 个文件；本地差异已保留。重启播放器后生效。', 6)
end
local function safe(callback)
    return function()
        local ok, err = pcall(callback)
        if not ok then
            plan = nil
            mp.set_property_native('user-data/manager', {state = 'failed', error = tostring(err)})
            mp.msg.error(tostring(err)); mp.osd_message('更新中止：' .. tostring(err), 8)
        end
    end
end
mp.add_key_binding(nil, 'manager-update-all', safe(preview))
mp.register_script_message('manager-update-all', safe(preview))
mp.register_script_message('manager-apply', safe(apply))
mp.register_script_message('manager-cancel', function()
    plan = nil
    mp.set_property_native('user-data/manager', {state = 'cancelled'})
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'manager-preview')
end)
