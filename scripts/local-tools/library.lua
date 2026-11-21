local mp = require 'mp'
local utils = require 'mp.utils'
local files = require 'local-files'

local bookmark_dir = files.state_path('bookmarks')
local pending_bookmark

local function read_bookmark(id)
    if type(id) ~= 'string' or #id ~= 64 or id:find('[^%x]') then return end
    local path = utils.join_path(bookmark_dir, id .. '.json')
    local file = io.open(path, 'rb')
    if not file then return end
    local entry = utils.parse_json(file:read('*a'))
    file:close()
    if type(entry) == 'table' and type(entry.path) == 'string' and entry.path:sub(1, 1) == '/'
        and type(entry.title) == 'string' and type(entry.added) == 'number'
        and (entry.position == nil or (type(entry.position) == 'number' and entry.position >= 0)) then
        return entry, path
    end
end

local function save_bookmark(mode)
    local context = files.context()
    local position = mp.get_property_number('time-pos')
    if not context or not position then
        mp.osd_message('请先打开本地或 OpenList 挂载中的视频')
        return
    end
    local entry = {
        path = context.path, title = mp.get_property('filename'),
        added = os.time(),
    }
    if mode == 'position' then entry.position = math.floor(math.max(0, position) * 1000 + 0.5) / 1000 end
    local id = files.hash(utils.format_json({entry.path, entry.position or 'file'}))
    if not id then mp.osd_message('无法生成书签文件名'); return end
    local path = utils.join_path(bookmark_dir, id .. '.json')
    if files.save_state(path, utils.format_json(entry)) then
        mp.osd_message(entry.position and ('已添加进度书签 · ' .. mp.format_time(entry.position)) or '已添加文件书签')
    end
end

local function bookmark_menu(action)
    local entries = {}
    for _, name in ipairs(utils.readdir(bookmark_dir, 'files') or {}) do
        local id = name:match('^(%x+)%.json$')
        local entry = id and read_bookmark(id)
        if entry then
            entry.id = id
            entries[#entries + 1] = entry
        end
    end
    if #entries == 0 then mp.osd_message('暂无书签'); return end
    table.sort(entries, function(a, b)
        if a.added ~= b.added then return a.added > b.added end
        return a.id < b.id
    end)
    local items = {}
    for i, entry in ipairs(entries) do
        items[i] = {
            title = entry.title,
            hint = entry.position and mp.format_time(entry.position) or '文件',
            value = {'script-message-to', mp.get_script_name(), action, entry.id},
        }
    end
    files.menu('bookmarks', action == 'delete-bookmark' and '删除书签' or '书签', items)
end

local function open_bookmark(id)
    local entry = read_bookmark(id)
    if not entry then mp.osd_message('书签已不存在'); return end
    local info = utils.file_info(entry.path)
    if not info or not info.is_file then
        mp.osd_message('找不到书签文件，请检查挂载\n' .. entry.path, 4)
        return
    end
    local context = files.context()
    if context and context.path == entry.path then
        if entry.position then mp.commandv('seek', entry.position, 'absolute+exact') end
        return
    end
    pending_bookmark = entry.position and entry or nil
    for index, item in ipairs(mp.get_property_native('playlist', {})) do
        if files.path(item.filename) == entry.path then
            mp.commandv('playlist-play-index', index - 1)
            return
        end
    end
    -- OpenList's on_load hook expands a single mounted episode into its directory.
    mp.commandv('loadfile', entry.path, 'replace')
end

mp.register_event('file-loaded', function()
    local bookmark = pending_bookmark
    pending_bookmark = nil
    if bookmark and files.path(mp.get_property('path')) == bookmark.path then
        mp.commandv('seek', bookmark.position, 'absolute+exact')
    end
end)

mp.register_event('end-file', function(event)
    if event.reason == 'error' then pending_bookmark = nil end
end)

local function natural_key(name)
    return (name:lower():gsub('%d+', function(digits)
        digits = digits:gsub('^0+', '')
        return ('%08d%s'):format(#digits, digits)
    end))
end

local function sort_playlist(direction)
    local current = mp.get_property_native('playlist', {})
    local sorted, positions = {}, {}
    for i, entry in ipairs(current) do
        local _, basename = utils.split_path(entry.filename)
        sorted[i] = {id = entry.id, index = i, key = natural_key(basename)}
        positions[entry.id] = i
    end
    table.sort(sorted, function(a, b)
        if a.key == b.key then return a.index < b.index end
        if direction == 'desc' then return a.key > b.key end
        return a.key < b.key
    end)
    for i, entry in ipairs(sorted) do
        local from = positions[entry.id]
        if from > i then
            mp.commandv('playlist-move', from - 1, i - 1)
            for j = from, i + 1, -1 do
                current[j] = current[j - 1]
                positions[current[j].id] = j
            end
            current[i] = entry
            positions[entry.id] = i
        end
    end
    if #current > 0 then mp.osd_message('播放列表已按文件名排序') end
end

local function save_playlist()
    local playlist = mp.get_property_native('playlist', {})
    if #playlist == 0 then mp.osd_message('播放列表为空'); return end
    local lines = {'#EXTM3U'}
    for _, entry in ipairs(playlist) do
        local path = files.path(entry.filename)
        if not path or path:find('[\r\n]') then
            mp.osd_message('列表含网址或换行文件名，无法保存为本地路径列表', 4)
            return
        end
        lines[#lines + 1] = path
    end
    local job = files.export_job('playlists')
    if not job then return end
    if files.write(utils.join_path(job.temp, 'list.m3u8'), table.concat(lines, '\n') .. '\n') then
        local context = files.context()
        local folder = context and utils.split_path(context.path):gsub('/+$', '')
        local title = folder and folder:match('([^/]+)$') or '播放列表'
        local output = files.publish(job, 'list.m3u8', title, '.m3u8')
        if output then mp.osd_message('播放列表已保存\n' .. output, 4) end
    else
        mp.osd_message('无法写入播放列表')
    end
    files.clean(job)
end

mp.register_script_message('save-bookmark', save_bookmark)
mp.register_script_message('bookmarks', function() bookmark_menu('open-bookmark') end)
mp.register_script_message('remove-bookmarks', function() bookmark_menu('delete-bookmark') end)
mp.register_script_message('open-bookmark', open_bookmark)
mp.register_script_message('delete-bookmark', function(id)
    local entry, path = read_bookmark(id)
    if entry and os.remove(path) then mp.osd_message('已删除书签 · ' .. entry.title) end
end)
mp.register_script_message('sort-playlist', sort_playlist)
mp.register_script_message('save-playlist', save_playlist)
