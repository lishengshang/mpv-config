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
    -- Translation target language
    translate = "Chinese",
    -- Specify the font to be used for the generated ass captions
    font_name = "sans-serif",
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

local start_index = 1
local subtitle_count = 1
local append_subtitle_count = 1
local in_progress_batches = 0
local translated_batches_count = 0
local translation_source
local subtitles_written = false
local whisper_running = false
local gpt_api_enabled = false
local state = {}
local time_ranges = {}
local progress_cache = {}
local translated_cache = {}
local management_menu

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
    local identity = utils.format_json({'asr-cache-v1', source,
        tostring(info.size or ''), tostring(info.mtime or ''),
        tostring(mp.get_property_native('aid', 'auto')), fast_whisper_path,
        tostring(backend.size or ''), tostring(backend.mtime or ''),
        o.model, o.device, o.compute_type, o.language, tostring(o.use_segment),
        tostring(o.segment_duration), tostring(o.max_line_width),
        o.translate, o.api_mode, subtitle_cache.digest(o.api_url),
        tostring(o.api_temperature), o.font_name, extra or ''})
    if selected_backend == 'qwen' then
        -- Keep existing Whisper identities unchanged; Qwen has an independent namespace.
        identity = utils.format_json({'qwen-asr-cache-v1', source,
            tostring(info.size or ''), tostring(info.mtime or ''),
            tostring(mp.get_property_native('aid', 'auto')), qwen_python, qwen_model, qwen_aligner,
            subtitle_cache.digest(subtitle_cache.read(qwen_model .. '/revision.json') or
                subtitle_cache.read(qwen_model .. '/config.json') or ''),
            subtitle_cache.digest(subtitle_cache.read(qwen_aligner .. '/revision.json') or
                subtitle_cache.read(qwen_aligner .. '/config.json') or ''),
            subtitle_cache.digest(subtitle_cache.read(qwen_runner) or ''),
            'cuda:bfloat16:sdpa', o.language, tostring(o.qwen_chunk_seconds), tostring(o.max_line_width),
            o.translate, o.api_mode, subtitle_cache.digest(o.api_url),
            tostring(o.api_temperature), o.font_name, extra or ''})
    elseif o.use_segment and o.segment_silence then
        -- Keep whole/fixed-slice identities intact; silence slicing has its own result.
        identity = utils.format_json({'whisper-silence-v1', identity})
    end
    return subtitle_cache.entry(cache_root, identity)
end

local function publish_status()
    local entry = current_entry()
    local cached = entry and subtitle_cache.lookup(entry) ~= nil or false
    mp.set_property_native('user-data/ai-subtitles/status', {backend = selected_backend,
        running = whisper_running, cached = cached, media = entry ~= nil})
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

local function is_text_identical(text1, text2)
    local function normalize_text(text)
        text = text:gsub("，", ",")
                  :gsub("。", ".")
                  :gsub("！", "!")
                  :gsub("？", "?")
                  :gsub("；", ";")
                  :gsub("：", ":")
                  :gsub("“", "\"")
                  :gsub("”", "\"")
                  :gsub("‘", "'")
                  :gsub("’", "'")
                  :gsub("（", "(")
                  :gsub("）", ")")
                  :gsub("【", "[")
                  :gsub("】", "]")
                  :gsub("《", "<")
                  :gsub("》", ">")
                  :gsub("、", "/")
                  :gsub("～", "~")

        text = text:gsub("[%p%s]", "")
        text = text:lower()
        return text
    end

    local clean_text1 = normalize_text(text1)
    local clean_text2 = normalize_text(text2)
    return clean_text1 == clean_text2
end

local function format_time(time_str)
    local h, m, s, ms = nil, nil, nil, nil
    if time_str:match("^%d+:%d+:%d+[%.:]%d+$") then
        h, m, s, ms = time_str:match("(%d+):(%d+):(%d+)[%.:](%d+)")
    elseif time_str:match("^%d+:%d+[%.:]%d+$") then
        h = 0
        m, s, ms = time_str:match("(%d+):(%d+)[%.:](%d+)")
    else
        return time_str
    end

    return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
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
        if sub.external and not is_protocol(sub["external-filename"])
        and sub["external-filename"]:lower():match("%.srt$") then
            return sub["external-filename"]
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
            normalize(external_filename) == normalize(sub_file) then
            return true, track["id"]
        end
    end
    return false, nil
end

local function append_sub(sub_file, auto)
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
    if not entry or not subtitle_cache.lookup(entry) then return false end
    active_entry, subtitles_file = entry, entry.srt
    -- Auto-add preserves an existing subtitle, but otherwise the cached subtitle should be visible.
    if auto and mp.get_property('sid', 'no') == 'no' then auto = false end
    append_sub(entry.srt, auto)
    local translated = entry.srt:gsub('%.srt$', '.translate.srt')
    local translation = subtitle_cache.read(translated)
    if translation and subtitle_cache.valid_srt(translation) and
        subtitle_cache.read(translated .. '.complete') == subtitle_cache.digest(translation) then
        local ass = entry.srt:gsub('%.srt$', '.' .. o.translate .. '.ass')
        if file_exists(ass) then append_sub(ass, auto) else append_sub(translated, auto) end
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
    start_index, in_progress_batches, translated_batches_count = 1, 0, 0
    translation_source = nil
    time_ranges, progress_cache, translated_cache, state = {}, {}, {}, {}
    mp.set_osd_ass(0, 0, '')
    publish_status()
end

local function parse_sub(filename)
    local subtitles = {}
    local file = io.open(filename, "r")
    if not file then return nil end

    local index, start_time, end_time, text
    for line in file:lines() do
        line = line:gsub("[\r\n]+", "")
        if line:match("^%d+$") then
            index = tonumber(line)
        elseif line:match("^%d%d:%d%d:%d%d,%d%d%d%s%-%->%s%d%d:%d%d:%d%d,%d%d%d$") then
            start_time, end_time = line:match("^(%d%d:%d%d:%d%d,%d%d%d)%s%-%->%s(%d%d:%d%d:%d%d,%d%d%d)$")
            start_time = start_time:gsub(",", "."):sub(1, -2)
            end_time = end_time:gsub(",", "."):sub(1, -2)
        elseif line:match("^%s*$") then
            if index and start_time and end_time and text then
                table.insert(subtitles, {index = index, start_time = start_time, end_time = end_time, text = text})
            end
            index, start_time, end_time, text = nil, nil, nil, nil
        else
            text = (text and text .. "\n" or "") .. line
        end
    end
    file:close()
    return subtitles
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
local function merge_subtitles(sub1, sub2)
    local merged = {}
    local used1, used2 = {}, {}

    for i, s1 in ipairs(sub1) do
        for j, s2 in ipairs(sub2) do
            if not used1[i] and not used2[j] and s1.start_time == s2.start_time then
                table.insert(merged, {
                    start_time = s1.start_time,
                    end_time = s1.end_time or s2.end_time,
                    text = s1.text .. (s1.text ~= "" and s2.text ~= "" and "\n" or "") .. s2.text
                })
                used1[i] = true
                used2[j] = true
            end
        end
    end

    for i, s1 in ipairs(sub1) do
        if not used1[i] then
            table.insert(merged, {
                start_time = s1.start_time,
                end_time = s1.end_time,
                text = s1.text
            })
        end
    end

    for j, s2 in ipairs(sub2) do
        if not used2[j] then
            table.insert(merged, {
                start_time = s2.start_time,
                end_time = s2.end_time,
                text = s2.text
            })
        end
    end

    table.sort(merged, function(a, b)
        return a.start_time < b.start_time
    end)

    return merged
end

-- Generating ASS subtitles files
local function generate_ass(subtitles_file)
    local ass_name = string.format(".%s.ass", o.translate)
    local translated_file = subtitles_file:gsub("%.srt$", ".translate.srt")
    local merge_file = subtitles_file:gsub("%.srt$", ass_name)
    if file_exists(subtitles_file) and file_exists(translated_file) then
        local sub1 = parse_sub(translated_file)
        local sub2 = parse_sub(subtitles_file)
        if sub1 and sub2 then
            merged = merge_subtitles(sub1, sub2)

            if #merged == 0 then return end
        end
    end
    local file = io.open(merge_file, "w")
    if not file then return end
    file:write("[Script Info]\n")
    file:write("Title: Bilingual Subtitles\n")
    file:write("ScriptType: v4.00+\n")
    file:write("WrapStyle: 0\n")
    file:write("ScaledBorderAndShadow: yes\n")
    file:write("PlayResX: 1920\n")
    file:write("PlayResY: 1080\n")
    file:write("\n")
    file:write("[V4+ Styles]\n")
    file:write("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n")
    file:write("Style: Default,".. o.font_name .. ",70,&H00FFFFFF,&HF0000000,&H00000000,&H32000000,0,0,0,0,100,100,0,0.00,1,2,1,2,5,5,2,-1\n")
    file:write("\n")
    file:write("[Events]\n")
    file:write("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")

    for _, sub in pairs(merged) do
        local translate_text, original_text = sub.text:gsub("\n$", ""):match("^(.-)\n+(.*)$")
        if translate_text and original_text then
            local translate_text = translate_text:gsub("^%s*(.-)%s*$", "%1")
            local original_text = original_text:gsub("^%s*(.-)%s*$", "%1")
            if is_text_identical(translate_text, original_text) then
                file:write(string.format("Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n", sub.start_time, sub.end_time, translate_text))
            else
                file:write(string.format("Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n", sub.start_time, sub.end_time, translate_text ..
                '\\N{\\fn'.. o.font_name .. '}{\\b0}{\\fs50}{\\c&H62A8EB&}{\\shad1}' .. original_text))
            end
        end
    end

    file:close()
    append_sub(merge_file)
end

-------------Translation function----------------
-- Call the GPT API
local function call_gpt_api(subtitles, callback)
    if not o.api_key or o.api_key:match('^%s*$') then return nil end
    msg.info("AI subtitle translation in progress")
    local prompt = string.format("You are a professional translation assistant, " ..
    "Translate the following subtitles from the original language to %s. " ..
    "Return exactly one line per input cue, preserving its timestamp and | separator. " ..
    "Do not add commentary, Markdown, or extra lines.", o.translate)

    local request_body = {
        messages = {
            {
                role = "system",
                content = prompt
            },
            {
                role = "user",
                content = subtitles
            }
        },
        model = o.api_mode,
        temperature = o.api_temperature
    }

    local request_json = utils.format_json(request_body)

    local command = {
        "curl", "-s", "--fail-with-body", "--connect-timeout", "10", "--max-time", "60", "-X", "POST", o.api_url,
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " .. o.api_key,
        "-d", request_json
    }
    local function response_content(data)
        local response = utils.parse_json(data or '')
        local choice = type(response) == 'table' and type(response.choices) == 'table' and response.choices[1]
        local content = type(choice) == 'table' and type(choice.message) == 'table' and choice.message.content
        if type(content) == 'string' and content:match('%S') then return content end
    end

    if not callback then
        local result = mp.command_native({
            name = "subprocess",
            args = command,
            capture_stdout = true,
            capture_stderr = true,
        })

        if not result or result.status ~= 0 then
            msg.info("API request failed: " .. tostring(result and result.stderr or "Unknown error"))
            return nil
        end

        local content = response_content(result.stdout)
        if content then
            return content
        else
            msg.info("Unable to parse API response")
            return nil
        end
    end

    local abort_signal
    local token = generation
    abort_signal = mp.command_native_async({
        name = "subprocess",
        args = command,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, result, error)
        pending_jobs[abort_signal] = nil
        if token ~= generation then return end
        if not success or not result or result.status ~= 0 then
            msg.info("API request failed: " .. tostring(result and result.stderr or "Unknown error"))
            callback(nil)
            return
        end

        local content = response_content(result.stdout)
        if content then
            callback(content)
        else
            msg.info("Unable to parse API response")
            callback(nil)
        end
    end)
    pending_jobs[abort_signal] = true

    return function()
        mp.abort_async_command(abort_signal)
    end
end

-- Parse .srt file
local function parse_srt(file_path)
    local file = io.open(file_path, "r")
    if not file then
        msg.error("Unable to open file: " .. file_path)
        return nil
    end

    local subtitles = {}
    local current_entry = {}

    for line in file:lines() do
        line = line:gsub("[\r\n]+", "")

        if line:match("^%d+$") then
            if current_entry.text then
                table.insert(subtitles, current_entry)
            end
            current_entry = { id = line, timestamp = nil, text = nil }
        elseif line:match("^%d%d:%d%d:%d%d,%d%d%d%s*%-%-%>%s*%d%d:%d%d:%d%d,%d%d%d$") then
            current_entry.timestamp = line
        elseif line ~= "" then
            current_entry.text = (current_entry.text and current_entry.text .. "\n" or "") .. line
        end
    end

    if current_entry.text then
        table.insert(subtitles, current_entry)
    end

    file:close()
    return subtitles
end

-- Translate subtitles and write to file
local function translate_and_write(subtitles, subtitles_file)
    local batch_size = 20
    local max_calls_per_minute = o.api_rate
    local delay_between_calls = 60 / max_calls_per_minute
    local translated_file = subtitles_file:gsub("%.srt$", ".translate.srt")
    local total_batches = math.ceil(#subtitles / batch_size)
    local function fail_batch(first, last, reason)
        for i = first, last do progress_cache[subtitles[i].timestamp] = nil end
        in_progress_batches = in_progress_batches - 1
        msg.warn('Translation failed: ' .. reason)
        mp.osd_message('字幕翻译失败，保留原字幕；请检查接口后重试。', 5)
    end

    -- Dynamically calculate parallelism
    local function calculate_parallel_calls()
        local available_time = 60
        local required_time_per_call = delay_between_calls
        local max_parallel_calls = math.floor(available_time / required_time_per_call)
        return math.min(max_parallel_calls, 4)
    end

    -- Process each batch of translations in parallel
    local function process_batch(batch_start_index)
        -- Calculate the end index for the current batch
        local end_index = math.min(batch_start_index + batch_size - 1, #subtitles)
        local batch = {}

        -- Combine timestamp and subtitle text
        for i = batch_start_index, end_index do
            local subtitle = subtitles[i]
            -- Only process untranslated subtitles
            if not translated_cache[subtitle.timestamp] and not progress_cache[subtitle.timestamp] then
                table.insert(batch, subtitle.timestamp .. " | " .. subtitle.text:gsub('[\r\n]+', ' '))
                progress_cache[subtitle.timestamp] = true  -- Mark as in translation
            end
        end

        -- Skip the batch if no new subtitles need translation
        if #batch == 0 then
            msg.debug("No new subtitles to translate for batch: " .. batch_start_index .. " to " .. end_index)
            return
        end

        -- Combine the batch into a single string
        local batch_text = table.concat(batch, "\n")

        -- Call GPT API for asynchronous translation
        local cancel = call_gpt_api(batch_text, function(translated_text)
            -- Handle API call failure
            if not translated_text then
                fail_batch(batch_start_index, end_index, 'API response unavailable')
                return
            end

            -- Split the translated text into lines
            local translated_lines = {}
            for line in translated_text:gmatch("[^\r\n]+") do
                table.insert(translated_lines, line)
            end

            -- Ensure the number of translated lines matches the original batch
            if #translated_lines ~= #batch then
                fail_batch(batch_start_index, end_index, 'response cue count mismatch')
                return
            end

            -- Write the translated subtitles to the file
            local latest_content = {}
            for i = 1, #translated_lines do
                local translated_line = translated_lines[i]
                local timestamp, text = translated_line:match("(%d+:%d+:%d+[%.,:]%d+%D+%d+:%d+:%d+[%.,:]%d+)%s*(.*)$")

                if text then
                    text = text:gsub("^%s*|%s*", ""):gsub("^%s*(.-)%s*$", "%1")
                end

                -- Handle translation failure
                if not timestamp or not text or text == "" then
                    fail_batch(batch_start_index, end_index, 'invalid translated cue')
                    return
                end

                if timestamp and text then
                    local text_pattern = "(%d+:%d+:%d+[%.,:]%d+)%D+(%d+:%d+:%d+[%.,:]%d+)%s*"
                    local start_time_srt, end_time_srt = timestamp:match(text_pattern)

                    if start_time_srt and end_time_srt then
                        local start_time = format_time(start_time_srt)
                        local end_time = format_time(end_time_srt)
                        timestamp = start_time .. " --> " .. end_time
                    else
                        msg.warn("Invalid timestamp: " .. timestamp)
                    end

                    local expected = subtitles[batch_start_index + i - 1]
                    if not expected or timestamp ~= expected.timestamp or latest_content[timestamp] then
                        fail_batch(batch_start_index, end_index, 'response timestamps changed or reordered')
                        return
                    end
                    latest_content[timestamp] = text
                end
            end

            -- Concurrent callbacks must serialize in source order, never Lua hash order.
            local serialized, current_index = {}, 1
            for _, subtitle in ipairs(subtitles) do
                local text = latest_content[subtitle.timestamp] or translated_cache[subtitle.timestamp]
                if text then
                    serialized[#serialized + 1] = current_index .. '\n' .. subtitle.timestamp .. '\n' .. text .. '\n\n'
                    current_index = current_index + 1
                end
            end
            if not subtitle_cache.write(translated_file, table.concat(serialized)) then
                fail_batch(batch_start_index, end_index, 'cannot write translated subtitles')
                return
            end
            for timestamp, text in pairs(latest_content) do
                translated_cache[timestamp] = text
                progress_cache[timestamp] = nil
            end

            -- Update translated batch count
            translated_batches_count = translated_batches_count + 1
            msg.info("Translated and written batch: " .. batch_start_index .. " to " .. end_index)
            -- Add the translated subtitles
            append_sub(translated_file)
            generate_ass(subtitles_file)

            -- Update in-progress batch count
            in_progress_batches = in_progress_batches - 1

            -- Check if all subtitles have been translated
            if translated_batches_count == total_batches then
                msg.info("Subtitle translation completed!")
                append_sub(translated_file)
                generate_ass(subtitles_file)
                local data = subtitle_cache.read(translated_file)
                if subtitle_cache.valid_srt(data) then
                    subtitle_cache.write(translated_file .. '.complete', subtitle_cache.digest(data))
                end
            end
        end)

        -- Increase in-progress batch count
        in_progress_batches = in_progress_batches + 1
    end

    while start_index <= #subtitles do
        local max_parallel_calls = calculate_parallel_calls()

        -- Wait for available slots for parallel processing
        if in_progress_batches < max_parallel_calls then
            process_batch(start_index)
            start_index = start_index + batch_size
        else
            -- If maximum parallel translations reached, wait before trying again
            later(delay_between_calls, function()
                translate_and_write(subtitles, subtitles_file)
            end)
            return
        end
    end

    start_index = #subtitles + 1
end

-- Translate .srt file
local function translate_srt_file(subtitles_file)
    if not o.api_key or o.api_key:match('^%s*$') then return end
    -- A failed request can be retried explicitly after the current batches finish.
    if in_progress_batches == 0 then start_index = 1 end
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

    local translated = subtitles_file:gsub('%.srt$', '.translate.srt')
    local completed = subtitle_cache.read(translated)
    if subtitle_cache.valid_srt(completed) and
        subtitle_cache.read(translated .. '.complete') == subtitle_cache.digest(completed) then
        generate_ass(subtitles_file)
        return
    end

    -- Parse the original subtitle file
    if translation_source ~= subtitles_file then
        if in_progress_batches > 0 then
            mp.osd_message('请先等待当前字幕翻译完成，或取消当前任务。', 5)
            return
        end
        translation_source = subtitles_file
        translated_cache, progress_cache = {}, {}
        start_index, translated_batches_count = 1, 0
    end
    local subtitles = parse_srt(subtitles_file)
    if not subtitles then
        msg.error("Failed to parse .srt file")
        return
    end

    -- Start translating
    translate_and_write(subtitles, subtitles_file)
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
    return {type = 'ai-subtitle-manager', title = 'AI 字幕管理', keep_open = true,
        footnote = '重新生成成功前保留旧缓存；导出位置由你选择，媒体目录不自动新增文件。', items = {
            {title = '当前方案：' .. (selected_backend == 'qwen' and 'Qwen3-ASR 1.7B' or ('Whisper ' .. o.model)), selectable = false},
            {title = whisper_running and '任务：正在生成' or '任务：空闲', selectable = false},
            {title = cached and '缓存：有有效完成字幕' or '缓存：当前设置无完成字幕', selectable = false},
            action('生成／复用 AI 字幕', 'sub-fastwhisper'),
            action('强制重新生成', 'sub-fastwhisper-regenerate', '成功后替换当前方案的缓存'),
            action('导出完成字幕…', 'sub-fastwhisper-export', cached and 'SRT' or '需先完成生成'),
            action('打开缓存目录', 'sub-fastwhisper-open-cache'),
            action('选择识别方案…', 'sub-fastwhisper-backend-menu'),
            action('取消当前任务', 'sub-fastwhisper-cancel')}}
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
mp.register_script_message('sub-fastwhisper-backend', select_backend)
mp.register_script_message('sub-fastwhisper-backend-menu', function()
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(backend_menu()))
end)
