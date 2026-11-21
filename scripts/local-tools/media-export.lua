local mp = require 'mp'
local utils = require 'mp.utils'
local files = require 'local-files'

local text_subtitles = {subrip = '.srt', ass = '.ass', ssa = '.ass', webvtt = '.srt',
    mov_text = '.srt', text = '.srt'}
local jobs = {}
local align_in_progress

local function ffmpeg()
    return {'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-n'}
end

local function run(args, job, done)
    jobs[job] = files.run_async(args, function(result)
        if not jobs[job] then return end
        jobs[job] = nil
        done(result)
    end)
end

local function finish(job, name, title, extension, result)
    local output
    if result then
        output = files.publish(job, name, title, extension)
        if output then mp.osd_message('已保存\n' .. output, 4) end
    else
        mp.osd_message('处理失败，详情见 mpv 日志', 4)
    end
    files.clean(job)
    return output
end

local function extract_subtitle(context, track, path)
    local source = files.track_path(context, track)
    if not source or not track['ff-index'] then return end
    local args = ffmpeg()
    local ext = path:match('%.[^.]+$')
    local codec = (track.codec == 'subrip' or track.codec == 'ass' or track.codec == 'hdmv_pgs_subtitle')
        and 'copy' or (ext == '.ass' and 'ass' or 'srt')
    for _, arg in ipairs({'-i', source, '-map', '0:' .. track['ff-index'], '-c:s', codec, path}) do
        args[#args + 1] = arg
    end
    return args
end

local function export_subtitle()
    local context, track = files.context(), files.track('sub')
    if not context or not track or track.external then
        mp.osd_message('请先选择要导出的内封主字幕'); return
    end
    local ext = text_subtitles[track.codec] or (track.codec == 'hdmv_pgs_subtitle' and '.sup')
    if not ext then mp.osd_message('该字幕格式无法单独导出'); return end
    local job = files.export_job('subtitles')
    if not job then return end
    local name = 'subtitle' .. ext
    local title = mp.get_property('filename/no-ext') .. ' - 字幕 ' .. track.id
    local args = extract_subtitle(context, track, utils.join_path(job.temp, name))
    if not args then finish(job); return end
    mp.osd_message('正在导出当前字幕')
    run(args, job, function(result) finish(job, name, title, ext, result) end)
end

local function align_subtitle()
    if align_in_progress then mp.osd_message('正在对轴，请等待当前任务完成'); return end
    local context, audio, subtitle = files.context(), files.track('audio'), files.track('sub')
    local ext = subtitle and text_subtitles[subtitle.codec]
    local audio_path = context and audio and files.track_path(context, audio)
    if not audio_path or not audio['ff-index'] or not subtitle then
        mp.osd_message('请先选择音轨和主字幕'); return
    end
    if not ext then mp.osd_message('自动对轴需要文本字幕，例如 SRT 或 ASS'); return end
    local job = files.export_job('subtitles')
    if not job then return end
    local title = mp.get_property('filename/no-ext') .. ' - 对轴 ' .. subtitle.id
    local input_name, output_name = 'source' .. ext, 'aligned' .. ext
    local input_path = utils.join_path(job.temp, input_name)
    local reference = utils.join_path(job.temp, 'reference.wav')
    local audio_args = ffmpeg()
    for _, arg in ipairs({'-copyts', '-start_at_zero', '-i', audio_path, '-map', '0:' .. audio['ff-index'],
        '-af', 'aresample=async=1:first_pts=0', '-c:a', 'pcm_s16le', '-ar', '16000', '-ac', '1', reference}) do
        audio_args[#audio_args + 1] = arg
    end

    local function done(result)
        align_in_progress = false
        local output = finish(job, output_name, title, ext, result)
        local current_sub, current_audio = files.track('sub'), files.track('audio')
        if output and files.is_current(context) and current_sub and current_audio
            and current_sub.id == subtitle.id and current_audio.id == audio.id
            and mp.commandv('sub-add', output, 'select') then
            mp.set_property_number('sub-delay', 0)
            mp.set_property_native('sub-visibility', true)
        end
    end

    local function sync(input)
        run(audio_args, job, function(result)
            if not result then done(nil); return end
            run({'alass', reference, input, utils.join_path(job.temp, output_name)}, job, done)
        end)
    end

    align_in_progress = true
    mp.osd_message('正在以当前音轨对轴…', 4)
    local external = subtitle.external and files.track_path(context, subtitle)
    if external and external:sub(-#ext) == ext then
        sync(external)
    else
        local args = extract_subtitle(context, subtitle, input_path)
        if not args then done(nil); return end
        run(args, job, function(result)
            if result then sync(input_path) else done(nil) end
        end)
    end
end

mp.register_event('shutdown', function()
    for job, command in pairs(jobs) do
        mp.abort_async_command(command)
        files.clean(job)
    end
    jobs = {}
end)

mp.register_script_message('subtitle-align', align_subtitle)
mp.register_script_message('subtitle-export', export_subtitle)
