--[[
    * sub-fastwhisper.lua
    *
    * AUTHORS: dyphire
    * License: MIT
    * link: https://github.com/dyphire/mpv-sub-fastwhisper
]]

local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require "mp.options"
-- Local cache/lifecycle changes: see docs/ai-subtitles.md before upstream updates.
package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local subtitle_cache = require 'ai-subtitle-cache'
local subtitle_layout = require 'ai-subtitle-layout'
local translation_queue = require 'ai-translation-job'

---- Script Options ----
local o = {
    -- Default engine; menu selection lasts for this player session.
    backend = 'whisper',
    qwen_python = 'python',
    qwen_model = '~~/cache/qwen-asr/models/Qwen3-ASR-1.7B',
    qwen_aligner = '~~/cache/qwen-asr/models/Qwen3-ForcedAligner-0.6B',
    qwen_chunk_seconds = 20,
    ffmpeg_path = 'ffmpeg',
    -- Path to the faster-whisper executable, you can download it from here:
    -- https://github.com/Purfview/whisper-standalone-win
    -- Supports absolute and relative paths
    fast_whisper_path = "faster-whisper",
    -- Model to use, available models are: base, small，medium, large, large-v2, large-v3, turbo
    model = "base",
    -- Device to use, available devices are: cpu, cuda
    device = "cpu",
    -- Compute type to use, 
    -- available types are: default,auto,int8,int8_float16,int8_float32,int8_bfloat16,int16,float16,float32,bfloat16
    compute_type = "default",
    -- Specify the language of transcription
    -- Leave it blank and it will be automatically detected
    language = "",
    -- Number of cpu threads to use
    -- Default value is 0 will auto-detect but max 4 threads
    threads = "0",
    -- The maximum number of characters in a line before breaking the line
    max_line_width = "100",
    -- Cache root. Legacy "source" is redirected; media directories remain untouched.
    output_path = "~~/cache/ai-subtitles",
    -- Specify how many subtitles are generated before updating
    -- to avoid frequent flickering of subtitles
    update_interval = 20,
    -- Uses segmentation for speech transcription, 
    -- which significantly improves the speed of subtitle initialization.
    -- but it will reduce the accuracy and overall speed of subtitle generation, 
    -- which is more suitable for long video scenarios.
    --! Depends on FFmpeg
    use_segment = false,
    segment_silence = true,
    -- Segment duration in seconds
    segment_duration = 10,
    ---- GPT API Options ----
    -- Compatible with other AI API with the same structure as the GPT API
    api_url = "https://api.openai.com/v1/chat/completions",
    api_key = "",
    api_mode = "gpt-4o",
    api_temperature = 0.7,
    -- Rate per minute used by the API
    -- See the corresponding API documentation for instructions
    api_rate = 15,
    translation_max_requests = 20,
    translation_max_chars = 20000,
    translation_retries = 2,
    translation_retry_base = 2,
    -- Translation target language
    translate = "Chinese",
    -- Specify the font to be used for the generated ass captions
    font_name = "sans-serif",
    font_scale = 0.8,
    layout_line_width = 56,
    layout_max_lines = 2,
    layout_max_seconds = 6,
}

options.read_options(o, _, function() end)
------------------------

local fast_whisper_path = mp.command_native({ "expand-path", o.fast_whisper_path })
local selected_backend = o.backend == 'qwen' and 'qwen' or 'whisper'
mp.set_property_native('user-data/ai-subtitles/backend', selected_backend)
local qwen_python = mp.command_native({'expand-path', o.qwen_python})
local qwen_model = mp.command_native({'expand-path', o.qwen_model})
local qwen_aligner = mp.command_native({'expand-path', o.qwen_aligner})
local qwen_runner = mp.command_native({'expand-path', '~~/tools/qwen_subtitles.py'})
local ffmpeg_path = mp.command_native({'expand-path', o.ffmpeg_path})
local cache_root = mp.command_native({ "expand-path",
    o.output_path == "source" and "~~/cache/ai-subtitles" or o.output_path })
local output_path
local pid = mp.get_property_native('pid')
local temp_path = os.getenv("TEMP") or "/tmp/"
local active_entry, active_work, subtitles_file
local generation, recognition_job = 0, nil
local pending_jobs, pending_timers = {}, {}

local function later(seconds, callback)
    local token = generation
    local timer
    timer = mp.add_timeout(seconds, function()
        pending_timers[timer] = nil
        if token == generation then callback() end
    end)
    pending_timers[timer] = true
    return timer
end

local subtitle_count = 1
local append_subtitle_count = 1
local translation_job
local translation_path
local translation_cached
local translation_migrations = {}
local subtitles_written = false
local whisper_running = false
local gpt_api_enabled = false
local state = {}
local time_ranges = {}
local management_menu
local generate_ass

local is_windows = package.config:sub(1, 1) == "\\"

local function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

local function file_exists(path)
    if path then
        local meta = utils.file_info(path)
        return meta and meta.is_file
    end
    return false
end

local function check_and_remove_empty_file(file_path)
    if file_exists(file_path) then
        local file = io.open(file_path, "r")
        if file then
            local content = file:read("*all")
            file:close()
            if content == "" then
                os.remove(file_path)
            end
        end
    end
end

local function normalize(path)
    if normalize_path ~= nil then
        if normalize_path then
            path = mp.command_native({"normalize-path", path})
        else
            local directory = mp.get_property("working-directory", "")
            path = utils.join_path(directory, path:gsub('^%.[\\/]',''))
            if is_windows then path = path:gsub("\\", "/") end
        end
        return path
    end

    normalize_path = false

    local commands = mp.get_property_native("command-list", {})
    for _, command in ipairs(commands) do
        if command.name == "normalize-path" then
            normalize_path = true
            break
        end
    end
    return normalize(path)
end

local function current_entry(extra)
    local path = mp.get_property('path')
    if not path then return nil end
    local protocol = is_protocol(path)
    path = protocol and path or normalize(path)
    local info = protocol and {} or utils.file_info(path)
    if not info or (not protocol and not info.is_file) then return nil end
    local backend = utils.file_info(fast_whisper_path) or {}
    -- URLs may contain credentials; only their hash is persisted.
    local source = protocol and ('url:' .. subtitle_cache.digest(path)) or path
    if is_windows and not protocol then source = source:gsub('\\', '/'):lower() end
    local identity = utils.format_json({'asr-cache-v2', source,
        tostring(info.size or ''), tostring(info.mtime or ''),
        tostring(mp.get_property_native('aid', 'auto')), fast_whisper_path,
        tostring(backend.size or ''), tostring(backend.mtime or ''),
        o.model, o.device, o.compute_type, o.language, tostring(o.use_segment),
        tostring(o.segment_duration), tostring(o.max_line_width),
        extra or ''})
    if selected_backend == 'qwen' then
        -- Qwen has an independent recognition namespace; translator/style settings stay separate.
        identity = utils.format_json({'qwen-asr-cache-v2', source,
            tostring(info.size or ''), tostring(info.mtime or ''),
            tostring(mp.get_property_native('aid', 'auto')), qwen_python, qwen_model, qwen_aligner,
            subtitle_cache.digest(subtitle_cache.read(qwen_model .. '/revision.json') or
                subtitle_cache.read(qwen_model .. '/config.json') or ''),
            subtitle_cache.digest(subtitle_cache.read(qwen_aligner .. '/revision.json') or
                subtitle_cache.read(qwen_aligner .. '/config.json') or ''),
            subtitle_cache.digest(subtitle_cache.read(qwen_runner) or ''),
            'cuda:bfloat16:sdpa', o.language, tostring(o.qwen_chunk_seconds), tostring(o.max_line_width),
            extra or ''})
    elseif o.use_segment and o.segment_silence then
        -- Keep whole/fixed-slice identities intact; silence slicing has its own result.
        identity = utils.format_json({'whisper-silence-v2', identity})
    end
    return subtitle_cache.entry(cache_root, identity)
end

local function translation_paths(source)
    local data = subtitle_cache.read(source)
    if not subtitle_cache.valid_srt(data) then return nil end
    local identity = utils.format_json({'translation-v1', subtitle_cache.digest(data), o.translate,
        o.api_mode, subtitle_cache.digest(o.api_url), tostring(o.api_temperature)})
    local dir = utils.join_path(utils.split_path(source), 'translations/' .. subtitle_cache.digest(identity))
    local item = {dir = dir, identity = identity, srt = utils.join_path(dir, 'subtitles.translate.srt'),
        ass = utils.join_path(dir, 'subtitles.' .. o.translate .. '.ass'), progress = utils.join_path(dir, 'progress.json')}
    if not translation_migrations[dir] then
        translation_migrations[dir] = true
        local meta = utils.parse_json(subtitle_cache.read(utils.join_path(utils.split_path(source), 'complete.json')) or '')
        for _, old in ipairs(meta and subtitle_cache.legacy_candidates(cache_root, meta.identity) or {}) do
            local fields = utils.parse_json(old.identity)
            if fields and fields[1] == 'whisper-silence-v1' then fields = utils.parse_json(fields[2]) end
            local previous = old.srt:gsub('%.srt$', '.translate.srt')
            local words = subtitle_cache.read(previous)
            if fields and fields[16] == o.translate and fields[17] == o.api_mode and
                fields[18] == subtitle_cache.digest(o.api_url) and fields[19] == tostring(o.api_temperature) and
                subtitle_cache.read(old.srt) == data and subtitle_cache.valid_srt(words) and
                subtitle_cache.read(previous .. '.complete') == subtitle_cache.digest(words) and subtitle_cache.mkdir(dir) then
                if subtitle_cache.write(item.srt, words) then subtitle_cache.write(item.srt .. '.complete', subtitle_cache.digest(words)) end
                break
            end
        end
    end
    return item
end

local function publish_status()
    local entry = current_entry()
    local cached = entry and subtitle_cache.lookup(entry) ~= nil or false
    mp.set_property_native('user-data/ai-subtitles/status', {backend = selected_backend,
        running = whisper_running or (translation_job and (translation_job.state == 'running' or
            translation_job.state == 'waiting' or translation_job.state == 'retrying')) or false,
        cached = cached, media = entry ~= nil, translation = translation_job and translation_job.snapshot() or translation_cached})
    if management_menu and mp.get_property_native('user-data/uosc/menu/type') == 'ai-subtitle-manager' then
        mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(management_menu()))
    end
end

local function begin_work(entry)
    generation = generation + 1
    local work, err = subtitle_cache.prepare(entry, pid, generation)
    if not work then mp.osd_message(err, 5); msg.error(err); return false end
    active_entry, active_work = entry, work
    output_path, temp_path = work, work
    subtitles_file = utils.join_path(work, 'incremental.srt')
    return true
end

local function timestamp_to_seconds(timestamp)
    local h, m, s, ms = timestamp:match("(%d+):(%d+):(%d+),(%d+)")
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

local function seconds_to_timestamp(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds / 60) % 60
    local s = math.floor(seconds % 60)
    local ms = math.floor((seconds - math.floor(seconds)) * 1000)
    return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
end

local function get_current_sub()
    local sub = mp.get_property_native("current-tracks/sub")
    if sub then
        local file = sub['external-filename']
        if sub.external and file and not is_protocol(file) then
            if file:lower():match('%.srt$') then return file end
            local root = normalize(cache_root):gsub('\\', '/'):lower():gsub('/+$', '') .. '/'
            if normalize(file):gsub('\\', '/'):lower():sub(1, #root) == root then
                local mapped = subtitle_cache.read(file .. '.source')
                if mapped and normalize(mapped):gsub('\\', '/'):lower():sub(1, #root) == root and
                    subtitle_cache.valid_srt(subtitle_cache.read(mapped)) then return mapped end
                for _, suffix in ipairs({'.ai.ass', '.' .. o.translate .. '.ass'}) do
                    if file:sub(-#suffix) == suffix then
                        local source = file:sub(1, -#suffix - 1) .. '.srt'
                        if subtitle_cache.valid_srt(subtitle_cache.read(source)) then return source end
                    end
                end
            end
        end
    end
    return nil
end

local function check_sub(sub_file)
    local tracks = mp.get_property_native("track-list")
    local _, sub_title = utils.split_path(sub_file)
    for _, track in ipairs(tracks) do
        local external_filename = track["external-filename"]
        local track_title = track["title"]
        if external_filename then
            _, track_title = utils.split_path(external_filename)
        end

        if track["type"] == "sub" and external_filename and
            (normalize(external_filename) == normalize(sub_file) or
            normalize(external_filename) == normalize(sub_file:gsub('%.srt$', '.ai.ass'))) then
            return true, track["id"]
        end
    end
    return false, nil
end

local function append_sub(sub_file, auto)
    -- Scale AI tracks through a derived ASS, preserving global/user subtitle settings.
    local root = normalize(cache_root):gsub('\\', '/'):lower():gsub('/+$', '') .. '/'
    if sub_file:match('%.srt$') and not sub_file:match('%.translate%.srt$') and
        normalize(sub_file):gsub('\\', '/'):lower():sub(1, #root) == root then
        local ass = subtitle_layout.render(subtitle_cache.read(sub_file), nil, {scale = o.font_scale,
            font = o.font_name, line_width = o.layout_line_width, max_lines = o.layout_max_lines,
            max_seconds = o.layout_max_seconds, plain_font_size = mp.get_property_number('sub-font-size', 50)})
        local display = sub_file:gsub('%.srt$', '.ai.ass')
        if ass and subtitle_cache.write(display, ass) then sub_file = display end
    end
    local sub, id = check_sub(sub_file)
    if not sub then
        if auto then
            mp.commandv('sub-add', sub_file, 'auto')
        else
            mp.commandv('sub-add', sub_file, 'select')
        end
    else
        local selected = mp.get_property('sid', 'no') == tostring(id)
        mp.commandv('sub-reload', id)
        -- mpv may allocate a new track ID during reload; the old ID can select "no".
        local present, current_id = check_sub(sub_file)
        if present and (not auto or selected) then mp.commandv('set', 'sid', tostring(current_id)) end
    end
end

local function load_cached(entry, auto)
    if is_protocol(mp.get_property('path')) then return false end
    if not entry or not subtitle_cache.lookup_recognition(entry, cache_root) then return false end
    active_entry, subtitles_file = entry, entry.srt
    -- Auto-add preserves an existing subtitle, but otherwise the cached subtitle should be visible.
    if auto and mp.get_property('sid', 'no') == 'no' then auto = false end
    append_sub(entry.srt, auto)
    local item = translation_paths(entry.srt)
    local translated = item and subtitle_cache.read(item.srt)
    if item and subtitle_cache.valid_srt(translated) and
        subtitle_cache.read(item.srt .. '.complete') == subtitle_cache.digest(translated) then
        local saved = utils.parse_json(subtitle_cache.read(item.progress) or '')
        translation_cached = saved and saved.job or {requests = 0, input_chars = 0, tokens = 0}
        translation_cached.state, translation_cached.message = 'completed', '已复用完成译文'
        translation_cached.done = #(subtitle_layout.parse(subtitle_cache.read(entry.srt)) or {})
        translation_cached.total = translation_cached.done
        generate_ass(entry.srt, auto, item)
    end
    msg.info('AI subtitle cache reused: ' .. entry.key)
    publish_status()
    if not auto then mp.osd_message('已复用 AI 字幕缓存', 4) end
    return true
end

local function finish_recognition(source)
    local ok, err = subtitle_cache.commit(active_entry, source)
    if not ok then mp.osd_message('AI 字幕生成失败：' .. err, 5); msg.error(err); return false end
    -- New recognition invalidates translations of the previous transcript only on success.
    for _, path in ipairs({(active_entry.srt:gsub('%.srt$', '.translate.srt')),
        (active_entry.srt:gsub('%.srt$', '.' .. o.translate .. '.ass'))}) do
        local exists, id = check_sub(path)
        if exists then mp.commandv('sub-remove', id) end
        os.remove(path); os.remove(path .. '.complete')
    end
    local present, track = check_sub(subtitles_file)
    if present then mp.commandv('sub-remove', track) end
    subtitles_file = active_entry.srt
    append_sub(subtitles_file)
    mp.osd_message('AI 字幕已生成并缓存', 5)
    msg.info('AI subtitle cache completed: ' .. active_entry.key)
    publish_status()
    return true
end

local function cleanup_work(work)
    if not work then return end
    -- Only a job's flat work directory; never the cache root or completed results.
    for _, name in ipairs(utils.readdir(work, 'files') or {}) do
        os.remove(utils.join_path(work, name))
    end
    os.remove(work)
end

local function reset_session()
    if translation_job then translation_job.cancel(); translation_job = nil; translation_path = nil end
    translation_cached = nil
    generation = generation + 1
    if recognition_job then mp.abort_async_command(recognition_job); recognition_job = nil end
    for id in pairs(pending_jobs) do mp.abort_async_command(id) end
    for timer in pairs(pending_timers) do timer:kill() end
    pending_jobs, pending_timers = {}, {}
    -- Incomplete progressive tracks must not survive cancellation or a new job.
    if active_work then
        local prefix = normalize(active_work):gsub('\\', '/'):lower():gsub('/+$', '') .. '/'
        for _, track in ipairs(mp.get_property_native('track-list', {})) do
            local path = track['external-filename']
            if track.type == 'sub' and path and normalize(path):gsub('\\', '/'):lower():sub(1, #prefix) == prefix then
                mp.commandv('sub-remove', track.id)
            end
        end
    end
    cleanup_work(active_work)
    active_entry, active_work, subtitles_file = nil, nil, nil
    whisper_running, subtitles_written, gpt_api_enabled = false, false, false
    time_ranges, state = {}, {}
    mp.set_osd_ass(0, 0, '')
    publish_status()
end

local function shift_subtitle_timestamps(temp_srt, srt_file, subtitle_count, start_time, duration)
    if duration then
        -- Parse blocks so numeric dialogue is kept; clip backend overshoot at slice boundaries.
        local data = subtitle_cache.read(temp_srt)
        if data ~= '' and not subtitle_cache.valid_srt(data) then return nil end
        local output = {}
        for block in ((data or ''):gsub('\r\n', '\n'):gsub('^\239\187\191', '') .. '\n\n'):gmatch('(.-)\n%s*\n') do
            if block:match('%S') then
                local first, last, words = block:match('^%s*%d+\n(%d%d:%d%d:%d%d,%d%d%d)%s+%-%->%s+(%d%d:%d%d:%d%d,%d%d%d)[^\n]*\n(.+)$')
                local from = math.min(timestamp_to_seconds(first), duration)
                local to = math.min(timestamp_to_seconds(last), duration)
                if from < to then
                    output[#output + 1] = tostring(subtitle_count) .. '\n' ..
                        seconds_to_timestamp(start_time + from) .. ' --> ' .. seconds_to_timestamp(start_time + to) .. '\n' ..
                        words:gsub('%s+$', '') .. '\n\n'
                    subtitle_count = subtitle_count + 1
                end
            end
        end
        local file = io.open(srt_file, 'ab')
        if not file then return nil end
        local wrote = file:write(table.concat(output))
        local closed = file:close()
        if not wrote or not closed then return nil end
        os.remove(temp_srt)
        return subtitle_count
    end
    local temp_file = io.open(temp_srt, "r")
    local main_file = io.open(srt_file, "a")

    if not temp_file or not main_file then
        msg.error("Failed to open temporary or main SRT file.")
        return subtitle_count
    end

    local subtitle_number = subtitle_count
    if subtitle_number == 1 then
        mp.osd_message("AI subtitles are loaded and updated in real time", 5)
        msg.info("AI subtitles are loaded and updated in real time")
    end
    for line in temp_file:lines() do
        if line:match("%d+:%d+:%d+,%d+%D+%d+:%d+:%d+,%d+") then
            local start_ts, end_ts = line:match("(%d+:%d+:%d+,%d+)%D+(%d+:%d+:%d+,%d+)")
            if start_ts and end_ts then
                local start_seconds = timestamp_to_seconds(start_ts) + start_time
                local end_seconds = timestamp_to_seconds(end_ts) + start_time
                main_file:write(subtitle_number .. "\n")
                main_file:write(seconds_to_timestamp(start_seconds) .. " --> " .. seconds_to_timestamp(end_seconds) .. "\n")
                subtitle_number = subtitle_number + 1
            end
        elseif line == '' then
            main_file:write('\n')
        elseif not tonumber(line) then
            main_file:write(line .. "\n")
        end
    end

    temp_file:close()
    main_file:close()

    os.remove(temp_srt)

    return subtitle_number
end

-- Merge two subtitles
-- Generating ASS subtitles files
generate_ass = function(subtitles_file, auto, item)
    item = item or translation_paths(subtitles_file)
    if not item then return false end
    local translated_file, merge_file = item.srt, item.ass
    local ass, err = subtitle_layout.render(subtitle_cache.read(subtitles_file), subtitle_cache.read(translated_file), {
        scale = o.font_scale, font = o.font_name, line_width = o.layout_line_width,
        max_lines = o.layout_max_lines, max_seconds = o.layout_max_seconds})
    if not ass or not subtitle_cache.write(merge_file, ass) then
        msg.warn('AI subtitle layout failed: ' .. tostring(err or merge_file))
        return false
    end
    subtitle_cache.write(merge_file .. '.source', subtitles_file)
    append_sub(merge_file, auto)
    return true
end

-------------Translation function----------------
-- Call the GPT API
local request_sequence = 0
local function call_gpt_api(subtitles, callback)
    if not o.api_key or o.api_key:match('^%s*$') then callback({status = 401, error = '未配置 API key'}); return function() end end
    local dir = utils.join_path(cache_root, '_requests')
    if not subtitle_cache.mkdir(dir) then callback({status = 400, error = '无法创建请求目录'}); return function() end end
    request_sequence = request_sequence + 1
    local base = utils.join_path(dir, tostring(pid) .. '-' .. generation .. '-' .. request_sequence)
    local auth, body, headers = base .. '.auth', base .. '.json', base .. '.headers'
    local prompt = 'Translate these subtitles into ' .. o.translate ..
        '. Return exactly one line per input cue, preserving its timestamp and | separator. No commentary or Markdown.'
    local payload = utils.format_json({model = o.api_mode, temperature = o.api_temperature,
        messages = {{role = 'system', content = prompt}, {role = 'user', content = subtitles}}})
    local function cleanup() os.remove(auth); os.remove(body); os.remove(headers) end
    if not subtitle_cache.write(auth, 'Authorization: Bearer ' .. o.api_key .. '\nContent-Type: application/json\n') or
        not subtitle_cache.write(body, payload) then
        cleanup(); callback({status = 400, error = '无法保存请求参数'}); return function() end
    end
    msg.info('AI subtitle translation in progress')
    local signal, token = nil, generation
    signal = mp.command_native_async({name = 'subprocess', capture_stdout = true, capture_stderr = true,
        args = {'curl', '-sS', '--fail-with-body', '--connect-timeout', '10', '--max-time', '60',
            '--header', '@' .. auth, '--data-binary', '@' .. body, '--dump-header', headers,
            '--write-out', '\nMPV_HTTP_STATUS:%{http_code}', o.api_url}}, function(ok, result)
        pending_jobs[signal] = nil
        local response_headers = subtitle_cache.read(headers) or ''
        cleanup()
        if token ~= generation then return end
        result = result or {}
        local output = result.stdout or ''
        local status = tonumber(output:match('\nMPV_HTTP_STATUS:(%d+)%s*$')) or (ok and result.status == 0 and 200 or 0)
        output = output:gsub('\nMPV_HTTP_STATUS:%d+%s*$', '')
        local data = utils.parse_json(output)
        local choice = type(data) == 'table' and type(data.choices) == 'table' and data.choices[1]
        local text = type(choice) == 'table' and type(choice.message) == 'table' and choice.message.content
        local usage = type(data) == 'table' and type(data.usage) == 'table' and data.usage.total_tokens
        local retry_after = translation_queue.retry_after(response_headers:match('[Rr]etry%-[Aa]fter:%s*([^\r\n]+)'))
        callback({status = status, text = type(text) == 'string' and text or nil,
            tokens = tonumber(usage) or 0, retry_after = retry_after,
            error = status == 200 and (type(text) ~= 'string' and '响应结构不符' or nil) or ('HTTP ' .. status)})
    end)
    pending_jobs[signal] = true
    return function() pending_jobs[signal] = nil; mp.abort_async_command(signal); cleanup() end
end

-- Parse .srt file
-- Translate subtitles and write to file
local function translate_and_write(subtitles, source, item)
    if translation_job and translation_path == item.dir then
        translation_job.start()
        return
    end
    if translation_job then translation_job.cancel() end
    if not subtitle_cache.mkdir(item.dir) then mp.osd_message('无法创建译文缓存', 5); return end
    translation_path = item.dir
    translation_cached = nil
    local function serialize(values)
        local lines, count = {}, 0
        for _, cue in ipairs(subtitles) do
            if values[cue.key] then
                count = count + 1
                lines[#lines + 1] = count .. '\n' .. cue.key .. '\n' .. values[cue.key] .. '\n\n'
            end
        end
        return table.concat(lines)
    end
    translation_job = translation_queue.new({cues = subtitles, rate = o.api_rate, retries = o.translation_retries,
        retry_base = o.translation_retry_base, max_requests = o.translation_max_requests, max_chars = o.translation_max_chars,
        now = function() return mp.get_time() end, wall_now = os.time, schedule = later, send = call_gpt_api,
        publish = function(status)
            publish_status()
            if status.state == 'failed' or status.state == 'budget' then mp.osd_message(status.message, 6) end
        end,
        load = function()
            local found = false
            for _, path in ipairs({item.progress, item.progress .. '.pending', item.progress .. '.previous'}) do
                local data = subtitle_cache.read(path)
                if data then
                    found = true
                    local saved = utils.parse_json(data)
                    if saved and saved.identity == item.identity and type(saved.job) == 'table' and saved.job.schema == 1 then
                        local valid = type(saved.job.completed) == 'table'
                        for _, name in ipairs({'requests', 'input_chars', 'tokens', 'request_allowance', 'char_allowance'}) do
                            valid = valid and type(saved.job[name]) == 'number' and saved.job[name] >= 0
                        end
                        if valid then return saved.job end
                    end
                    if path == item.progress then return {invalid = true} end
                end
            end
            if found then return {invalid = true} end
        end,
        save = function(job)
            return subtitle_cache.write_atomic(item.progress, utils.format_json({identity = item.identity, job = job}) .. '\n')
        end,
        partial = function(values)
            local ok = subtitle_cache.write_atomic(item.srt, serialize(values))
            if ok then generate_ass(source, false, item) end
            return ok
        end,
        finish = function(values)
            local data = serialize(values)
            if not subtitle_cache.valid_srt(data) or not subtitle_cache.write_atomic(item.srt, data) or
                not subtitle_cache.write_atomic(item.srt .. '.complete', subtitle_cache.digest(data)) then return false end
            generate_ass(source, false, item)
            msg.info('Subtitle translation completed!')
            return true
        end})
    translation_job.start()
end

-- Translate .srt file
local function translate_srt_file(subtitles_file)
    if not o.api_key or o.api_key:match('^%s*$') then
        mp.osd_message('请先在 local.conf 配置翻译接口与 key', 5); return
    end
    if not subtitles_file then
        subtitles_file = get_current_sub()
    end
    if not subtitles_file then
        return
    end

    -- Translating an existing sidecar must also keep all new output inside cache.
    local expanded = normalize(subtitles_file):gsub('\\', '/')
    local root = normalize(cache_root):gsub('\\', '/') .. '/'
    if is_windows then expanded, root = expanded:lower(), root:lower() end
    if expanded:sub(1, #root) ~= root then
        local data = subtitle_cache.read(subtitles_file)
        if not subtitle_cache.valid_srt(data) then return end
        local entry = current_entry('external-srt:' .. subtitle_cache.digest(data))
        if not entry or not subtitle_cache.mkdir(entry.dir) then return end
        local ok = subtitle_cache.commit(entry, subtitles_file)
        if not ok then return end
        subtitles_file = entry.srt
    end

    local item = translation_paths(subtitles_file)
    if not item then return end
    if translation_job and translation_path ~= item.dir then
        translation_job.cancel(); translation_job, translation_path = nil, nil
    end
    local completed = subtitle_cache.read(item.srt)
    if subtitle_cache.valid_srt(completed) and subtitle_cache.read(item.srt .. '.complete') == subtitle_cache.digest(completed) then
        local saved = utils.parse_json(subtitle_cache.read(item.progress) or '')
        translation_cached = saved and saved.job or {requests = 0, input_chars = 0, tokens = 0}
        translation_cached.state, translation_cached.message = 'completed', '已复用完成译文'
        translation_cached.total = #(subtitle_layout.parse(subtitle_cache.read(subtitles_file)) or {})
        translation_cached.done = translation_cached.total
        generate_ass(subtitles_file, false, item)
        publish_status()
        return
    end
    local subtitles = subtitle_layout.parse(subtitle_cache.read(subtitles_file))
    if not subtitles then mp.osd_message('无有效 SRT 可翻译', 5); return end
    translate_and_write(subtitles, subtitles_file, item)
end
--------------------------------------------------

local function fastwhisper_cmd(file_path, sub_path)
    local args = {
        fast_whisper_path,
        file_path,
        "--beep_off",
        "--model", o.model,
        "--device", o.device,
        "--max_line_width", o.max_line_width,
        "--threads", o.threads,
        "--output_dir", sub_path,
        "--output_format", "srt",
    }

    if o.language ~= "" then
        table.insert(args, "--language")
        table.insert(args, o.language)
    end

    if o.compute_type ~= "" and o.compute_type ~= "default" then
        table.insert(args, "--compute_type")
        table.insert(args, o.compute_type)
    end

    return args
end

local function fastwhisper()
    local path = mp.get_property("path")
    local fname = mp.get_property("filename/no-ext")
    if not path or is_protocol(path) then return end
    path = normalize(path)
    local result_file = utils.join_path(output_path, fname .. '.srt')

    local screenx, screeny, aspect = mp.get_osd_size()
    mp.set_osd_ass(screenx, screeny, "{\\an9}● ")
    mp.osd_message((selected_backend == 'qwen' and 'Qwen3-ASR' or 'Whisper') .. ' 正在生成 AI 字幕…', 9)
    msg.info('AI subtitle generation in progress: ' .. selected_backend)

    subtitle_count = 1
    append_subtitle_count = 1
    subtitles_written = false
    whisper_running = true
    publish_status()

    local args = fastwhisper_cmd(path, output_path)
    if selected_backend == 'qwen' then
        result_file = utils.join_path(output_path, 'qwen.srt')
        local track = mp.get_property_native('current-tracks/audio', {})
        local audio_map = track['ff-index'] and ('0:' .. track['ff-index']) or '0:a:0'
        args = {qwen_python, qwen_runner, '--input', path, '--output', result_file,
            '--model', qwen_model, '--aligner', qwen_aligner, '--ffmpeg', ffmpeg_path,
            '--audio-map', audio_map, '--language', o.language,
            '--chunk-seconds', tostring(o.qwen_chunk_seconds), '--max-line-width', o.max_line_width}
    end
    local token, job_work = generation, active_work
    recognition_job = mp.command_native_async({ name = "subprocess", capture_stdout = true,
        capture_stderr = true, args = args }, function(success, res)
        if token ~= generation then cleanup_work(job_work); return end
        recognition_job = nil
        mp.set_osd_ass(screenx, screeny, "")
        if success and res and res.status == 0 then
            if selected_backend == 'qwen' then msg.info(res.stdout or '') end
            if finish_recognition(result_file) then
                if selected_backend == 'qwen' then
                    local stats = utils.parse_json(subtitle_cache.read(utils.join_path(output_path, 'qwen-stats.json')) or '')
                    if stats and stats.coarse_chunks > 0 then
                        mp.osd_message('AI 字幕已缓存；该语种使用分段时间范围，建议检查时间轴', 6)
                    end
                end
                if gpt_api_enabled then translate_srt_file(subtitles_file) end
            end
        else
            mp.osd_message("AI subtitle generation failed, check console for more info.")
            msg.error('AI subtitle generation failed: ' .. tostring(res and res.stderr or 'subprocess failed'))
        end
        whisper_running = false
        publish_status()
    end)
end
------------------------

local function audio_segment_args(video_path, segment_audio_file, start_time, duration, audio_map, detect_silence)
    local args = {
        ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", detect_silence and "info" or "error",
        "-ss", tostring(start_time),
        "-i", video_path,
        "-t", tostring(duration),
        "-map", audio_map,
        "-vn",
        "-sn",
        "-ac", "1", "-ar", "16000",
    }
    if detect_silence then
        args[#args + 1] = '-af'
        args[#args + 1] = 'asetpts=PTS-STARTPTS,silencedetect=noise=-35dB:d=0.25'
        args[#args + 1] = '-f'; args[#args + 1] = 'null'
    else
        args[#args + 1] = '-c:a'; args[#args + 1] = 'pcm_s16le'
    end
    args[#args + 1] = segment_audio_file
    return args
end

local function process_audio_segment(segment_audio_file, subtitle_count)
    local temp_srt_path = utils.split_path(segment_audio_file)
    local temp_srt = segment_audio_file:gsub("%.[^%.]+$", ".srt")

    local args = fastwhisper_cmd(segment_audio_file, temp_srt_path)
    local res = mp.command_native({ name = "subprocess", capture_stdout = true, capture_stderr = true, args = args })

    if not res or res.status ~= 0 then
        msg.error("faster-whisper failed for: " .. segment_audio_file .. "\n" .. tostring(res and res.stderr))
        return subtitle_count, temp_srt, false
    end

    local data = subtitle_cache.read(temp_srt)
    -- Silence-only segments may be empty; the complete cached result must be nonempty.
    return subtitle_count, temp_srt, data == '' or subtitle_cache.valid_srt(data)
end

-- Progressive display: the first slice stays short so subtitles appear quickly,
-- then later slices grow to cut per-slice model reloads. These constants do not
-- change the configured value; fixed-slice cache identities stay stable.
local FIRST_SEGMENT_SECONDS = 15
local LATER_SEGMENT_SECONDS = 40
local SILENCE_SEARCH_SECONDS = 3

local function silence_boundary(log, window_start, target, lower, upper)
    local silence_start, nearest
    for line in (log or ''):gmatch('[^\r\n]+') do
        local first = tonumber(line:match('silence_start:%s*([%d%.eE+%-]+)'))
        local last = tonumber(line:match('silence_end:%s*([%d%.eE+%-]+)'))
        if first then silence_start = first end
        if last and silence_start then
            local midpoint = window_start + (silence_start + last) / 2
            if midpoint >= lower and midpoint <= upper and
                (not nearest or math.abs(midpoint - target) < math.abs(nearest - target)) then
                nearest = midpoint
            end
            silence_start = nil
        end
    end
    return nearest
end

local function process_video_incrementally(video_path, srt_file, segment_duration)
    local start_time = 0
    local subtitle_count = 1
    local segment_index = 1
    local file_duration = mp.get_property_number('duration')
    local track = mp.get_property_native('current-tracks/audio', {})
    local audio_map = track['ff-index'] and ('0:' .. track['ff-index']) or '0:a:0'
    local token, job_work = generation, active_work
    local function stop(reason)
        whisper_running = false
        publish_status()
        mp.osd_message('AI 字幕分段生成失败，未保存为完成缓存', 5)
        msg.error('AI subtitle segment failed: ' .. tostring(reason))
    end
    local function run(args, callback)
        recognition_job = mp.command_native_async({name = 'subprocess', capture_stdout = true,
            capture_stderr = true, args = args}, function(ok, result)
            if token ~= generation then cleanup_work(job_work); return end
            recognition_job = nil
            if not ok or not result or result.status ~= 0 then
                stop(result and ('exit ' .. tostring(result.status) .. ': ' .. tostring(result.stderr)) or 'subprocess failed'); return
            end
            callback(result)
        end)
    end
    local next_segment
    next_segment = function()
        if start_time >= file_duration then
            if finish_recognition(srt_file) and gpt_api_enabled then translate_srt_file(subtitles_file) end
            whisper_running = false
            publish_status()
            return
        end
        local slice
        if segment_index == 1 then
            slice = math.min(segment_duration, FIRST_SEGMENT_SECONDS)
        else
            slice = math.max(segment_duration, LATER_SEGMENT_SECONDS)
        end
        if start_time + slice > file_duration then
            slice = file_duration - start_time
        end

        local segment_audio_file = utils.join_path(temp_path, "whisper-" .. pid .. ".wav")
        local temp_srt_file = utils.join_path(temp_path, "whisper-" .. pid .. ".srt")
        if file_exists(segment_audio_file) then
            os.remove(segment_audio_file)
        end
        if file_exists(temp_srt_file) then
            os.remove(temp_srt_file)
        end

        local function recognize_slice()
            msg.info(string.format('AI subtitle segment: %d start=%.3f duration=%.3f', segment_index, start_time, slice))
            run(audio_segment_args(video_path, segment_audio_file, start_time, slice, audio_map), function()
                if not file_exists(segment_audio_file) then stop('missing extracted audio'); return end
                run(fastwhisper_cmd(segment_audio_file, temp_path), function()
                    local count = shift_subtitle_timestamps(temp_srt_file, srt_file, subtitle_count, start_time, slice)
                    if not count then stop('invalid or unwritable SRT output'); return end
                    subtitle_count = count
                    if subtitle_cache.valid_srt(subtitle_cache.read(srt_file)) then append_sub(srt_file) end
                    start_time = start_time + slice
                    segment_index = segment_index + 1
                    next_segment()
                end)
            end)
        end
        if not o.segment_silence or start_time + slice >= file_duration then recognize_slice(); return end
        local lower = math.max(slice - SILENCE_SEARCH_SECONDS, slice / 2)
        local upper = math.min(slice + SILENCE_SEARCH_SECONDS, file_duration - start_time)
        if segment_index == 1 then upper = math.min(upper, FIRST_SEGMENT_SECONDS) end
        run(audio_segment_args(video_path, '-', start_time + lower, upper - lower, audio_map, true), function(result)
            local boundary = silence_boundary(result.stderr, lower, slice, lower, upper)
            if boundary then slice = boundary end
            msg.info(boundary and 'AI subtitle boundary: silence' or 'AI subtitle boundary: fixed fallback (no nearby silence)')
            recognize_slice()
        end)
    end
    next_segment()
end

local function fastwhisper_segment()
    local path = mp.get_property("path")
    local fname = mp.get_property("filename/no-ext")
    if not path or is_protocol(path) then return end
    path = normalize(path)

    mp.osd_message("AI subtitle generation in progress", 9)
    msg.info("AI subtitle generation in progress")

    whisper_running = true
    publish_status()
    process_video_incrementally(path, subtitles_file, o.segment_duration)
end
------------------------

local function adjust_time_range(strat_time, end_time)
    for _, range in ipairs(time_ranges) do
        if not (end_time <= range.start or strat_time >= range.finish) then
            if strat_time >= range.start and end_time <= range.finish then
                return nil, nil
            end
            if strat_time < range.finish and end_time > range.start then
                if strat_time < range.finish then
                    strat_time = range.finish
                end
                if end_time > range.start then
                    end_time = range.start
                end
            end
        end
    end
    return strat_time, end_time
end

local function get_time_range(strat_time, end_time)
    local strat_time, end_time = adjust_time_range(strat_time, end_time)
    if strat_time and strat_time < end_time then
        return true, strat_time, end_time
    else
        return false
    end
end

local function fastwhisper_cache(current_pos, subtitle_count)
    local temp_video_file = utils.join_path(temp_path, "whisper-" .. pid .. ".mkv")
    local srt_file = subtitles_file
    local file_duration = mp.get_property_number('duration', math.huge)
    local cache_state = mp.get_property_native("demuxer-cache-state")
    local cache_ranges = cache_state and cache_state["seekable-ranges"] or {}
    local cache_start = cache_ranges[1] and cache_ranges[1]["start"] or current_pos
    local cache_end = cache_ranges[1] and cache_ranges[1]["end"] or current_pos

    if current_pos < cache_start or cache_start < state.pos then
        current_pos = cache_start
        state.pos = current_pos
    end

    if current_pos >= file_duration then
        if file_exists(srt_file) then
            if gpt_api_enabled then
                append_sub(srt_file, true)
                translate_srt_file(srt_file)
            else
                append_sub(srt_file)
            end
        end
        return
    end

    local valid_range, strat_time, end_time = get_time_range(current_pos, cache_end)
    if strat_time and end_time then
        current_pos = strat_time
        cache_end = end_time
    end

    if not valid_range or cache_end <= current_pos then
        later(1, function() fastwhisper_cache(current_pos, subtitle_count) end)
        return
    end

    if subtitle_count == 0 then
        mp.osd_message("AI subtitle generation in progress", 9)
        msg.info("AI subtitle generation in progress")
        local files_to_remove = {
            temp_srt_file1 = utils.join_path(temp_path, "whisper.srt"),
            temp_srt_file2 = utils.join_path(temp_path, "whisper-" .. pid .. ".srt"),
            temp_srt_file3 = utils.join_path(temp_path, "whisper.translate.srt"),
            temp_srt_file4 = utils.join_path(temp_path, "whisper." .. o.translate .. ".ass")
        }

        for _, file in pairs(files_to_remove) do
            if file_exists(file) then
                os.remove(file)
            end
        end
    end

    whisper_running = true
    mp.commandv("dump-cache", math.ceil(current_pos), math.floor(cache_end), temp_video_file)
    local subtitle_number, temp_srt = process_audio_segment(temp_video_file, subtitle_count)
    whisper_running = false

    if file_exists(temp_srt) then
        subtitle_number = shift_subtitle_timestamps(temp_srt, srt_file, subtitle_number, current_pos)
    end

    if file_exists(srt_file) then
        subtitle_count = subtitle_count + 1
        if gpt_api_enabled then
            translate_srt_file(srt_file)
        else
            append_sub(srt_file)
        end
    end

    table.insert(time_ranges, {start = current_pos, finish = cache_end})
    table.sort(time_ranges, function(a, b) return a.start < b.start end)

    current_pos = cache_end

    -- Callback
    later(1, function() fastwhisper_cache(current_pos, subtitle_count) end)
end
------------------------

local function whisper(force)
    if whisper_running then mp.osd_message('AI 字幕任务正在进行，可先取消任务', 4); return end
    if selected_backend == 'qwen' then
        if is_protocol(mp.get_property('path')) then
            mp.osd_message('Qwen 目前支持本地媒体；网络媒体请选择 Whisper', 5); return
        end
        local track = mp.get_property_native('current-tracks/audio', {})
        if track.external then mp.osd_message('Qwen 暂不支持外挂音轨，请选择内置音轨', 5); return end
        if not file_exists(qwen_runner) or not file_exists(qwen_model .. '/config.json') or
            not file_exists(qwen_aligner .. '/config.json') then
            mp.osd_message('Qwen 本地依赖未配置，参见 docs/ai-subtitles.md；可切回 Whisper', 6); return
        end
    end
    local entry = current_entry()
    if not entry then mp.osd_message('请先打开媒体文件', 4); return end
    if selected_backend == 'whisper' and o.use_segment and not is_protocol(mp.get_property('path')) then
        local duration = mp.get_property_number('duration', 0)
        if o.segment_duration <= 0 or o.segment_duration ~= o.segment_duration or o.segment_duration == math.huge or
            duration <= 0 or duration == math.huge or duration ~= duration then
            mp.osd_message('分段识别需要有限的正数时长与有效媒体长度', 5); return
        end
        if mp.get_property_native('current-tracks/audio', {}).external then
            mp.osd_message('分段识别暂不支持外挂音轨，请选择内置音轨', 5); return
        end
    end
    if not force and load_cached(entry, false) then return end
    reset_session()
    if not begin_work(entry) then return end
    gpt_api_enabled = o.api_key and not o.api_key:match('^%s*$') or false
    if selected_backend == 'qwen' then fastwhisper(); return end
    local path =  mp.get_property_native("path")
    local cache = mp.get_property_native("cache")
    local cache_state = mp.get_property_native("demuxer-cache-state")
    local cache_ranges = cache_state and cache_state["seekable-ranges"] or {}
    if path and is_protocol(path) or (cache == "auto" and #cache_ranges > 0) then
        if #cache_ranges == 0 then mp.osd_message('当前网络媒体没有可用缓存范围', 5); return end
        time_ranges = {}
        local subtitle_count = 0
        local current_pos = mp.get_property_native("time-pos")
        local cache_start = cache_ranges[1]["start"]
        state.pos = cache_start or current_pos
        fastwhisper_cache(cache_start, subtitle_count)
        return
    end
    if o.use_segment then
        fastwhisper_segment()
    else
        fastwhisper()
    end
end

local function backend_menu()
    local items = {}
    for _, backend in ipairs({'whisper', 'qwen'}) do
        items[#items + 1] = {title = backend == 'whisper' and ('Whisper ' .. o.model) or 'Qwen3-ASR 1.7B',
            active = selected_backend == backend,
            hint = backend == 'whisper' and '默认方案' or '本地识别 + 时间轴对齐',
            value = {'script-message-to', 'sub_fastwhisper', 'sub-fastwhisper-backend', backend}}
    end
    return {type = 'ai-subtitle-backend', title = 'AI 字幕识别方案', keep_open = true,
        footnote = '选择在当前播放器内保持；Alt+f 生成或复用对应缓存', items = items}
end

local function select_backend(backend)
    if backend ~= 'whisper' and backend ~= 'qwen' then msg.error('Unknown ASR backend'); return end
    if selected_backend ~= backend then
        reset_session()
        -- Remove only tracks from our cache, preserving externally provided subtitles.
        local prefix = normalize(cache_root):gsub('\\', '/'):lower():gsub('/+$', '') .. '/'
        for _, track in ipairs(mp.get_property_native('track-list', {})) do
            local path = track['external-filename']
            if track.type == 'sub' and path and normalize(path):gsub('\\', '/'):lower():sub(1, #prefix) == prefix then
                mp.commandv('sub-remove', track.id)
            end
        end
        selected_backend = backend
        mp.set_property_native('user-data/ai-subtitles/backend', selected_backend)
        if mp.get_property('path') then load_cached(current_entry(), true) end
    end
    mp.osd_message('AI 字幕方案：' .. (selected_backend == 'qwen' and 'Qwen3-ASR 1.7B' or ('Whisper ' .. o.model)), 4)
    publish_status()
    if mp.get_property_native('user-data/uosc/menu/type') == 'ai-subtitle-backend' then
        mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(backend_menu()))
    end
end

management_menu = function()
    local entry = current_entry()
    local cached = entry and subtitle_cache.lookup(entry) ~= nil
    local function action(title, message, hint)
        return {title = title, hint = hint, value = {'script-message-to', 'sub_fastwhisper', message}}
    end
    local translation = translation_job and translation_job.snapshot() or translation_cached
    local names = {running = '请求中', waiting = '等待速率窗口', retrying = '等待重试', budget = '预算到限',
        failed = '失败，可重试', completed = '已完成', cancelled = '已取消', idle = '未开始'}
    local title = whisper_running and '任务：正在识别' or '任务：空闲'
    if translation then title = string.format('翻译：%s · %d/%d 条', names[translation.state] or translation.state,
        translation.done or 0, translation.total or 0) end
    return {type = 'ai-subtitle-manager', title = 'AI 字幕管理', keep_open = true,
        footnote = '重新生成成功前保留旧缓存；导出位置由你选择，媒体目录不自动新增文件。', items = {
            {title = '当前方案：' .. (selected_backend == 'qwen' and 'Qwen3-ASR 1.7B' or ('Whisper ' .. o.model)), selectable = false},
            {title = title, selectable = false},
            {title = cached and '缓存：有有效完成字幕' or '缓存：当前设置无完成字幕', selectable = false},
            action('生成／复用 AI 字幕', 'sub-fastwhisper'),
            action('强制重新生成', 'sub-fastwhisper-regenerate', '成功后替换当前方案的缓存'),
            action('导出完成字幕…', 'sub-fastwhisper-export', cached and 'SRT' or '需先完成生成'),
            action('打开缓存目录', 'sub-fastwhisper-open-cache'),
            action('选择识别方案…', 'sub-fastwhisper-backend-menu'),
            action('取消当前任务', 'sub-fastwhisper-cancel'),
            {title = translation and string.format('翻译用量：%d/%d 次 · %d/%d 字符 · %d tokens',
                translation.requests or 0, translation.request_limit or translation.request_allowance or o.translation_max_requests,
                translation.input_chars or 0, translation.char_limit or translation.char_allowance or o.translation_max_chars,
                translation.tokens or 0) or
                string.format('翻译预算：每任务 %d 次请求 / %d 字符', o.translation_max_requests, o.translation_max_chars), selectable = false},
            {title = '重试计入预算；token 用量由接口返回，不等于账单金额。', selectable = false},
            action(translation and translation.state == 'budget' and '继续翻译／追加一档预算' or '翻译当前字幕／继续任务',
                'sub-fastwhisper-translate-resume', '已有成功批次不会重复请求'),
            action('仅取消翻译', 'sub-fastwhisper-translation-cancel')}}
end

local function export_cached(destination)
    local entry = current_entry()
    local source = entry and subtitle_cache.lookup(entry)
    if not source then mp.osd_message('当前方案没有有效的完成字幕，请先生成', 5); return end
    local args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', mp.command_native({'expand-path', '~~/tools/export-ai-subtitle.ps1'}),
        '-Source', source, '-SuggestedName', mp.get_property('filename/no-ext', 'subtitles') .. '.srt'}
    if destination and destination ~= '' then args[#args + 1] = '-Destination'; args[#args + 1] = destination end
    local token = generation
    mp.command_native_async({name = 'subprocess', args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true}, function(ok, result)
        if token ~= generation then return end
        if ok and result and result.status == 0 then mp.osd_message('AI 字幕已导出', 4)
        elseif result and result.status == 2 then mp.osd_message('已取消导出', 3)
        else msg.error('Subtitle export failed: ' .. tostring(result and result.stderr)); mp.osd_message('字幕导出失败，请查看控制台；已有文件不会被静默覆盖', 6) end
    end)
end

mp.add_hook('on_unload', 50, reset_session)
mp.register_event('file-loaded', function() load_cached(current_entry(), true); publish_status() end)

mp.register_script_message("sub-translate", translate_srt_file)
mp.register_script_message("sub-fastwhisper", function() whisper(false) end)
mp.register_script_message('sub-fastwhisper-regenerate', function() whisper(true) end)
mp.register_script_message('sub-fastwhisper-manager', function()
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(management_menu()))
end)
mp.register_script_message('sub-fastwhisper-export', export_cached)
mp.register_script_message('sub-fastwhisper-open-cache', function()
    local entry = current_entry()
    local path = entry and utils.file_info(entry.dir) and entry.dir or cache_root
    local ok, err = subtitle_cache.mkdir(path)
    if not ok then msg.error(tostring(err)); return end
    mp.commandv('run', 'explorer.exe', path:gsub('/', '\\'))
end)
mp.register_script_message('sub-fastwhisper-cancel', reset_session)
mp.register_script_message('sub-fastwhisper-translate-resume', function()
    if translation_job then translation_job.resume()
    else
        local entry = current_entry()
        translate_srt_file(get_current_sub() or (entry and subtitle_cache.lookup(entry)))
    end
end)
mp.register_script_message('sub-fastwhisper-translation-cancel', function()
    if translation_job then translation_job.cancel() end
end)
mp.register_script_message('sub-fastwhisper-backend', select_backend)
mp.register_script_message('sub-fastwhisper-backend-menu', function()
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(backend_menu()))
end)
