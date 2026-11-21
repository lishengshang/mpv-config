-- Chapter sidecar formats follow dyphire's chapter-make-read in dev.
local mp = require 'mp'
local input = require 'mp.input'
local utils = require 'mp.utils'
local files = require 'local-files'

local function timestamp(seconds)
    local ms = math.floor(seconds * 1000 + 0.5)
    return ('%02d:%02d:%02d.%03d'):format(math.floor(ms / 3600000),
        math.floor(ms / 60000) % 60, math.floor(ms / 1000) % 60, ms % 1000)
end

local function parse_time(value)
    local hours, minutes, seconds = value:match('^(%d+):(%d%d):(%d%d[.,]?%d*)$')
    if hours then return hours * 3600 + minutes * 60 + tonumber((seconds:gsub(',', '.'))) end
    return tonumber(value)
end

local function read_chapters(path, allow_empty)
    local file = io.open(path, 'rb')
    if not file then return end
    local chapters, by_number = {}, {}
    local saved = false
    for raw in file:lines() do
        local line = raw:gsub('^\239\187\191', ''):gsub('\r$', '')
        if line == '# mpv chapters' then saved = true end
        local time, title = line:match('^(%d+:%d%d:%d%d[.,]?%d*)%s*(.*)$')
        local number, ogm_time = line:match('^CHAPTER(%d+)=(.+)$')
        if time then
            chapters[#chapters + 1] = {time = parse_time(time), title = title}
        elseif number and parse_time(ogm_time) then
            local chapter = {time = parse_time(ogm_time), title = ''}
            chapters[#chapters + 1], by_number[number] = chapter, chapter
        else
            local id, name = line:match('^CHAPTER(%d+)NAME=(.*)$')
            if by_number[id] then by_number[id].title = name end
        end
    end
    file:close()
    if #chapters > 0 or (allow_empty and saved) then return chapters end
end

local function chapter_path(path)
    local hash = files.hash(path)
    if hash then return utils.join_path(files.state_path('chapters'), hash .. '.chp') end
end

local function apply_chapters(chapters)
    local order = {}
    for index, chapter in ipairs(chapters) do order[chapter] = index end
    table.sort(chapters, function(a, b)
        if a.time == b.time then return order[a] < order[b] end
        return a.time < b.time
    end)
    mp.set_property_native('chapter-list', chapters)
end

mp.add_hook('on_preloaded', 50, function()
    local path = files.path(mp.get_property('path'))
    if not path then return end
    local saved = chapter_path(path)
    local edited = saved and read_chapters(saved, true)
    if edited then apply_chapters(edited); return end
    -- Embedded chapters keep precedence until a local edit is saved.
    if mp.get_property_number('chapter-list/count', 0) > 0 then return end
    local dir, name = utils.split_path(path)
    for _, root in ipairs({utils.join_path(dir, 'chapters'), dir}) do
        for _, extension in ipairs({'.chp', '.ogm'}) do
            local chapters = read_chapters(utils.join_path(root, name .. extension))
            if chapters then apply_chapters(chapters); return end
        end
    end
end)

local function edit_chapter(action)
    local context = files.context()
    local time = mp.get_property_number('time-pos')
    local chapters = mp.get_property_native('chapter-list', {})
    local index = mp.get_property_number('chapter', -1) + 1
    if not context or not time then mp.osd_message('请先打开本地或挂载中的视频'); return end
    local chapter = chapters[index]
    if action ~= 'add' and not chapter then mp.osd_message('当前位置没有章节'); return end
    if action == 'remove' then
        table.remove(chapters, index)
        apply_chapters(chapters)
        mp.osd_message('已删除当前章节。用菜单保存修改。')
        return
    end
    local adding = action == 'add'
    local changing_time = action == 'time'
    if adding then chapter = {time = time, title = '章节 ' .. (#chapters + 1)} end
    input.get({
        prompt = changing_time and '章节时间（时:分:秒.毫秒或秒）' or '章节标题',
        default_text = changing_time and timestamp(chapter.time) or (chapter.title or ''),
        submit = function(value)
            if not files.is_current(context) then return end
            if changing_time then
                local new_time = parse_time(value)
                if not new_time or new_time ~= new_time or new_time < 0
                    or new_time >= mp.get_property_number('duration', math.huge) then
                    mp.osd_message('章节时间超出视频范围'); return
                end
                chapter.time = new_time
            else
                chapter.title = value:gsub('[\r\n]', ' ')
            end
            if adding then chapters[#chapters + 1] = chapter end
            apply_chapters(chapters)
            mp.osd_message('章节已修改。用菜单保存修改。')
        end,
    })
end

local function save_chapters(format)
    local context = files.context()
    if not context then return end
    local ogm = format == 'ogm'
    local lines = ogm and {} or {'# mpv chapters'}
    for i, chapter in ipairs(mp.get_property_native('chapter-list', {})) do
        local time, title = timestamp(chapter.time), (chapter.title or ''):gsub('[\r\n]', ' ')
        if ogm then
            lines[#lines + 1] = ('CHAPTER%02d=%s\nCHAPTER%02dNAME=%s'):format(i, time, i, title)
        else
            lines[#lines + 1] = time .. ' ' .. title
        end
    end
    local content = table.concat(lines, '\n') .. '\n'
    if not ogm then
        local path = chapter_path(context.path)
        if path and files.save_state(path, content) then mp.osd_message('章节已保存到本机') end
        return
    end
    if #lines == 0 then mp.osd_message('没有可导出的章节'); return end
    local job = files.export_job('chapters')
    if not job then return end
    if files.write(utils.join_path(job.temp, 'chapters.ogm'), content) then
        local output = files.publish(job, 'chapters.ogm', mp.get_property('filename/no-ext'), '.ogm')
        if output then mp.osd_message('章节已导出\n' .. output, 4) end
    else
        mp.osd_message('无法写入章节')
    end
    files.clean(job)
end

local kind_names = {opening = '片头', ending = '片尾'}
local skip_marks, mark_starts, segments = {}, {}, {}
local marks_path, last_prompt, silence_job, local_media

local function chapter_kind(title)
    local name = (title or ''):lower():match('^%s*(.-)%s*$')
    if name == 'op' or name:match('^op[%s%p%d]') or name:match(' op$')
        or name:match('^opening') or name:match('^intro[%s%-]*start')
        or name:match('^片头') or name:match('^オープニング') then return 'opening' end
    if name == 'ed' or name:match('^ed[%s%p%d]') or name:match(' ed$')
        or name:match('^ending') or name:match('^credits')
        or name:match('^片尾') or name:match('^エンディング') then return 'ending' end
end

local function update_segments()
    segments = {}
    local chapters = mp.get_property_native('chapter-list', {})
    local duration = mp.get_property_number('duration', 0)
    for i, chapter in ipairs(chapters) do
        local kind = chapter_kind(chapter.title)
        local next_chapter = chapters[i + 1]
        local ending = next_chapter and next_chapter.time or duration
        if kind and not skip_marks[kind] and ending > chapter.time and (next_chapter or kind == 'ending') then
            segments[#segments + 1] = {kind = kind, first = chapter.time, last = ending}
        end
    end
    for kind, mark in pairs(skip_marks) do
        if kind_names[kind] and type(mark) == 'table' and type(mark.first) == 'number'
            and type(mark.last) == 'number' and mark.first >= 0 and mark.first < mark.last
            and mark.last <= duration + 0.01 then
            segments[#segments + 1] = {kind = kind, first = mark.first, last = math.min(duration, mark.last)}
        end
    end
end

local function active_segment(position)
    if not position or not local_media then return end
    for _, segment in ipairs(segments) do
        if position >= segment.first and position < segment.last then return segment end
    end
end

mp.register_event('start-file', function()
    marks_path, last_prompt, local_media = nil, nil, false
    skip_marks, mark_starts, segments = {}, {}, {}
    if silence_job then mp.abort_async_command(silence_job); silence_job = nil end
end)

mp.register_event('file-loaded', function()
    local context = files.context()
    local_media = context ~= nil
    local hash = context and files.hash(context.path)
    marks_path = hash and utils.join_path(files.state_path('skip-marks'), hash .. '.json')
    local file = marks_path and io.open(marks_path, 'rb')
    if file then
        local data = utils.parse_json(file:read('*a'))
        if type(data) == 'table' then skip_marks = data end
        file:close()
    end
    update_segments()
end)

mp.observe_property('chapter-list', 'native', update_segments)
mp.observe_property('duration', 'number', update_segments)
mp.observe_property('time-pos', 'number', function(_, position)
    local segment = active_segment(position)
    if segment == last_prompt then return end
    last_prompt = segment
    if segment then
        mp.osd_message('检测到' .. kind_names[segment.kind] .. ' · 右键 → 播放 → 片头片尾 → 跳过当前段', 5)
    end
end)

local function mark_segment(kind, boundary)
    local position = mp.get_property_number('time-pos')
    if not position or not marks_path or not kind_names[kind] then return end
    if boundary == 'start' then
        mark_starts[kind] = position
        mp.osd_message(kind_names[kind] .. '起点 · ' .. mp.format_time(position))
        return
    end
    local first = mark_starts[kind]
    if not first or position <= first then mp.osd_message('请先标记更早的起点'); return end
    local old = skip_marks[kind]
    skip_marks[kind] = {first = first, last = position}
    if files.save_state(marks_path, utils.format_json(skip_marks)) then
        mark_starts[kind] = nil
        update_segments()
        mp.osd_message(kind_names[kind] .. '已保存到本机')
    else
        skip_marks[kind] = old
    end
end

local function skip_to_silence()
    local context = files.context()
    local audio = files.track('audio')
    local position = mp.get_property_number('time-pos')
    local path = context and audio and files.track_path(context, audio)
    if not path or not position or not audio['ff-index'] then mp.osd_message('请先选择可读取的音轨'); return end
    if silence_job then mp.osd_message('正在查找下一处静音'); return end
    local start = position + 1
    mp.osd_message('正在查找下一处静音')
    local request
    request = files.run_async({'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'info',
        '-ss', tostring(start), '-i', path, '-map', '0:' .. audio['ff-index'], '-t', '120',
        '-af', 'silencedetect=n=-40dB:d=0.7', '-f', 'null', '-'}, function(result)
        if silence_job ~= request then return end
        silence_job = nil
        local selected = files.track('audio')
        if not files.is_current(context) or not selected or selected.id ~= audio.id then return end
        local offset = result and tonumber(result.stderr:match('silence_start:%s*([%d%.]+)'))
        if not offset then mp.osd_message('未来两分钟内未找到静音'); return end
        local target = start + offset
        if target > mp.get_property_number('time-pos', target) then
            mp.commandv('seek', target, 'absolute+exact')
        else
            mp.osd_message('已播过检测到的静音位置')
        end
    end)
    silence_job = request
end

mp.register_script_message('chapter-edit', edit_chapter)
mp.register_script_message('chapter-save', save_chapters)
mp.register_script_message('skip-mark', mark_segment)
mp.register_script_message('skip-segment', function()
    local segment = active_segment(mp.get_property_number('time-pos'))
    if segment then
        mp.commandv('seek', segment.last, 'absolute+exact')
    else
        mp.osd_message('当前没有可跳过的片头或片尾')
    end
end)
mp.register_script_message('skip-to-silence', skip_to_silence)
