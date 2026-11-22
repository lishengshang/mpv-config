-- Local diagnostics and timed playback samples. Never changes playback options.
local u = require 'mp.utils'
local o = {sample_seconds = 30, warmup_seconds = 2}
require('mp.options').read_options(o, 'player-health')
local menu, sampling, timer, sequence = nil, nil, nil, 0
local diagnostic = {state = 'idle'}
local sample_state = {state = 'idle'}
local function expand(path)
    local value = mp.command_native({'expand-path', path})
    return mp.command_native({'normalize-path', value ~= '' and value or '.'})
end
local root = expand('~~/cache/player-health')
local function exists(path) return u.file_info(path) ~= nil end
local function mkdir()
    local r = mp.command_native({name = 'subprocess', playback_only = false, capture_stdout = true, capture_stderr = true,
        args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
            "[IO.Directory]::CreateDirectory('" .. root:gsub("'", "''") .. "') | Out-Null"}})
    return r and r.status == 0
end
local function save(kind, data)
    sequence = sequence + 1
    local path = root .. '/' .. kind .. '-' .. os.date('%Y%m%d-%H%M%S') .. '-' .. mp.get_property('pid') .. '-' .. sequence .. '.json'
    local f, err = io.open(path, 'wb')
    if not f then return nil, err end
    local ok = f:write(u.format_json(data) .. '\n'); local closed = f:close()
    if ok and closed then return path end
    return nil, 'Cannot write report'
end
local function publish()
    mp.set_property_native('user-data/player-health', {diagnostic = diagnostic, sample = sample_state})
    if menu and mp.get_property_native('user-data/uosc/menu/type') == 'player-health' then
        mp.commandv('script-message-to', 'uosc', 'update-menu', u.format_json(menu()))
    end
end
local function context()
    local result = {}
    for _, name in ipairs({'mpv-version', 'ffmpeg-version', 'video-params', 'video-out-params', 'hwdec-current',
        'current-vo', 'options/gpu-api', 'speed', 'container-fps', 'estimated-vf-fps', 'display-fps', 'vf', 'glsl-shaders'}) do
        result[name] = mp.get_property_native(name)
    end
    result.enhancement = mp.get_property_native('user-data/gpu-effects/active', '')
    result.filename = mp.get_property('filename', '')
    local w, h = mp.get_osd_size()
    result.window = {w = w, h = h}
    return result
end
local function counters()
    local result = {}
    for _, key in ipairs({'frame-drop-count', 'decoder-frame-drop-count', 'mistimed-frame-count', 'vo-delayed-frame-count'}) do
        result[key] = mp.get_property_number(key)
    end
    return result
end
local function signature()
    local result = {}
    for _, key in ipairs({'path', 'vf', 'glsl-shaders', 'speed', 'hwdec-current', 'current-vo', 'video-params'}) do
        result[key] = mp.get_property_native(key)
    end
    local w, h = mp.get_osd_size()
    result.window = {w = w, h = h}
    return u.format_json(result)
end
local function finish_sample(reason)
    if not sampling then return end
    local current = sampling
    sampling = nil
    if timer then timer:kill(); timer = nil end
    current.reason, current.valid = reason, reason == nil
    if current.valid and (#current.samples < 4 or not current.anchor) then current.valid, current.reason = false, '有效采样不足' end
    if current.valid then
        current.elapsed = mp.get_time() - current.anchor
        current.media_seconds = mp.get_property_number('time-pos', current.position) - current.position
        current.timeline_ratio = current.media_seconds / current.elapsed / current.speed
        local last = counters()
        current.counter_deltas = {}
        for key, value in pairs(last) do
            if current.counters[key] then current.counter_deltas[key] = value - current.counters[key] end
        end
        local times = {}
        for _, value in ipairs(current.samples) do if value.vo_fresh_ms then times[#times + 1] = value.vo_fresh_ms end end
        table.sort(times)
        if #times == 0 then current.valid, current.reason = false, '当前 VO 未提供有效渲染耗时，不能作为性能基线'
        else current.vo_fresh_ms = {p50 = times[math.ceil(#times * 0.5)], p95 = times[math.ceil(#times * 0.95)], max = times[#times]} end
    end
    current.signature = nil
    current.notes = {'VO pass 耗时不含完整 VS/解码耗时；不是完整流水线 FPS。',
        'timeline_ratio 仅表示媒体时间相对墙钟的推进；需结合掉帧一起判断。',
        '显存数据若存在，为整卡占用，包含播放器及其他程序。'}
    local path, err = save('sample', current)
    sample_state = {state = path and (current.valid and 'complete' or 'invalid') or 'failed', report = path,
        reason = current.reason or err, samples = #current.samples}
    publish()
    mp.msg.info('Playback sample ' .. sample_state.state .. ': ' .. tostring(path or err))
    mp.osd_message(current.valid and path and '播放采样完成，报告已保存' or ('播放采样无效：' .. tostring(current.reason or err)), 6)
end
local function start_sample(seconds)
    if sampling then mp.osd_message('播放采样正在进行', 3); return end
    seconds = tonumber(seconds) or o.sample_seconds
    if seconds < 2 or seconds > 120 then mp.osd_message('采样时长须为 2–120 秒', 4); return end
    if mp.get_property_native('pause') or not mp.get_property_native('video-params') then
        mp.osd_message('请先正常播放视频，再开始采样', 5); return
    end
    if mp.get_property_native('user-data/gpu-effects/pending', '') ~= '' then mp.osd_message('请等待 GPU 增强初始化完成', 5); return end
    if not mkdir() then mp.osd_message('无法创建诊断缓存目录', 5); return end
    sampling = {schema = 1, context = context(), seconds = seconds, speed = mp.get_property_number('speed', 1),
        warmup = math.max(0, o.warmup_seconds), warm_until = mp.get_time() + math.max(0, o.warmup_seconds),
        signature = signature(), samples = {}, gpu_samples = {}}
    sample_state = {state = 'running', seconds = seconds}
    publish()
    local last_gpu = -10
    timer = mp.add_periodic_timer(0.25, function()
        local job = sampling
        if not job then return end
        if mp.get_property_native('pause') then finish_sample('采样期间暂停'); return end
        if signature() ~= job.signature then finish_sample('采样期间媒体、滤镜、窗口或播放参数变化'); return end
        local now = mp.get_time()
        if now < job.warm_until then return end
        if not job.anchor then job.anchor, job.position, job.counters = now, mp.get_property_number('time-pos', 0), counters() end
        local position = mp.get_property_number('time-pos', job.position)
        local previous = job.samples[#job.samples]
        if previous and math.abs((position - previous.position) - (now - previous.time) * job.speed) > 1 then finish_sample('采样期间跳转或时间轴不连续'); return end
        local passes, total = mp.get_property_native('vo-passes', {}), nil
        for _, pass in ipairs(passes.fresh or {}) do if type(pass.avg) == 'number' then total = (total or 0) + pass.avg / 1000000 end end
        job.samples[#job.samples + 1] = {time = now, position = position, vo_fresh_ms = total, avsync = mp.get_property_number('avsync')}
        if now - last_gpu > 2 then
            last_gpu = now
            mp.command_native_async({name = 'subprocess', args = {'nvidia-smi', '--query-gpu=name,memory.used,memory.total,utilization.gpu',
                '--format=csv,noheader,nounits'}, capture_stdout = true, capture_stderr = true}, function(ok, res)
                if sampling == job and ok and res and res.status == 0 then job.gpu_samples[#job.gpu_samples + 1] = {time = now, devices = res.stdout} end
            end)
        end
        if now - job.anchor >= job.seconds then finish_sample() end
    end)
    mp.osd_message('开始播放采样：预热后 ' .. seconds .. ' 秒，请保持片段、窗口和增强设置不变', 5)
end
local function resolve(program)
    local path = mp.command_native({'expand-path', program})
    if exists(path) then return expand(path) end
    if not path:find('[/\\]') then
        local r = mp.command_native({name = 'subprocess', args = {'where.exe', path}, capture_stdout = true, capture_stderr = true})
        if r and r.status == 0 then return (r.stdout or ''):match('[^\r\n]+') end
    end
    return path
end
local diagnostic_jobs, diagnostic_token = {}, 0
local function diagnose()
    if diagnostic.state == 'running' then mp.osd_message('诊断正在进行', 3); return end
    if not mkdir() then mp.osd_message('无法创建诊断目录', 4); return end
    diagnostic_token = diagnostic_token + 1
    local token = diagnostic_token
    local opts = mp.get_property_native('options/script-opts', {})
    local runtime = expand(opts['gpu-effects-runtime_path'] or '~~/../')
    local python = exists(runtime .. '/python.exe') and runtime .. '/python.exe' or 'python'
    local report = {schema = 1, context = context(), files = {}, checks = {},
        notes = {'文件存在与导入通过不代表 GPU 产帧；请用 verify-gpu 做实际输出检查。',
            '本次 VS 探针仅检查 Bilateral 所需依赖；Whisper 不执行识别，Qwen 不加载模型。'}}
    for _, name in ipairs({'mpv.exe', 'python.exe', 'VSScript.dll', 'portable.vs', 'Lib', 'vs-plugins'}) do
        report.files[#report.files + 1] = {component = name, exists = exists(runtime .. '/' .. name)}
    end
    local function option(key, default) return opts['sub_fastwhisper-' .. key] or default end
    local whisper = resolve(option('fast_whisper_path', 'faster-whisper'))
    report.files[#report.files + 1] = {component = 'Whisper executable (inference untested)', exists = exists(whisper)}
    for _, pair in ipairs({{'qwen_model', 'Qwen3-ASR-1.7B'}, {'qwen_aligner', 'Qwen3-ForcedAligner-0.6B'}}) do
        local path = expand(option(pair[1], '~~/cache/qwen-asr/models/' .. pair[2]))
        report.files[#report.files + 1] = {component = pair[2] .. '/config.json (weights/inference untested)', exists = exists(path .. '/config.json')}
    end
    local checks = {
        {'配置与原生接线', {python, expand('~~/tools/maintenance/check_config.py'), '--mpv', '--json'}},
        {'VS Bilateral 依赖初检', {python, expand('~~/tools/runtime/gpu_probe.py'), expand('~~/vs/NR_BILATERAL_CUDA.vpy')}},
        {'Qwen Python / CUDA（不加载模型）', {resolve(option('qwen_python', 'python')), '-c',
            'import json,torch,qwen_asr; print(json.dumps(dict(torch=torch.__version__,cuda=torch.cuda.is_available(),device=torch.cuda.get_device_name() if torch.cuda.is_available() else None)))'}},
        {'FFmpeg 可执行文件', {resolve(option('ffmpeg_path', 'ffmpeg')), '-version'}},
        {'NVIDIA 驱动与整卡显存', {'nvidia-smi', '--query-gpu=name,driver_version,memory.used,memory.total', '--format=csv,noheader'}}}
    diagnostic = {state = 'running'}; publish()
    local remaining = #checks
    local function completed(label, ok, res, timed_out)
        if token ~= diagnostic_token then return end
        local output = res and res.stdout or ''
        local parsed = u.parse_json(output)
        local passed = ok and res and res.status == 0 and not timed_out or false
        if label:find('Qwen Python', 1, true) then passed = passed and type(parsed) == 'table' and parsed.cuda == true end
        report.checks[#report.checks + 1] = {name = label, ok = passed,
            timed_out = timed_out or false, exit_code = res and res.status, data = parsed or output:sub(1, 16000),
            error = res and (res.stderr or ''):sub(1, 3000)}
        remaining = remaining - 1
        if remaining == 0 then
            local path, err = save('diagnostic', report)
            local failures = 0
            for _, check in ipairs(report.checks) do if not check.ok then failures = failures + 1 end end
            for _, file in ipairs(report.files) do if not file.exists then failures = failures + 1 end end
            diagnostic = {state = path and 'complete' or 'failed', report = path, error = err, failures = failures}
            publish(); mp.osd_message(path and '诊断完成，请在诊断菜单打开报告目录查看检查项' or tostring(err), 6)
        end
    end
    for _, check in ipairs(checks) do
        local label, args, id, timeout, done = check[1], check[2], nil, nil, false
        local function finish(ok, res, expired)
            if done then return end
            done = true
            if timeout then timeout:kill() end
            diagnostic_jobs[id] = nil
            completed(label, ok, res, expired)
        end
        id = mp.command_native_async({name = 'subprocess', playback_only = false, args = args, capture_stdout = true, capture_stderr = true},
            function(ok, res) finish(ok, res, false) end)
        diagnostic_jobs[id] = true
        timeout = mp.add_timeout(40, function() mp.abort_async_command(id); finish(false, nil, true) end)
    end
end
menu = function()
    local labels = {idle = '尚未运行', running = '进行中', complete = '已完成', invalid = '无效，请查看原因', failed = '失败'}
    local function action(title, message) return {title = title, value = {'script-message-to', 'player_health', message}} end
    return {type = 'player-health', title = '诊断与播放性能', keep_open = true, items = {
        {title = '组件诊断：' .. labels[diagnostic.state] .. (diagnostic.failures and ('（' .. diagnostic.failures .. ' 项未通过）') or ''), selectable = false},
        {title = '播放采样：' .. labels[sample_state.state], selectable = false},
        action('检查配置与可选组件', 'health-diagnose'),
        action('采样当前播放 ' .. o.sample_seconds .. ' 秒', 'health-sample'),
        action('取消播放采样', 'health-cancel'), action('打开报告目录', 'health-open-reports')},
        footnote = '采样期间请保持播放设置不变；VO 渲染耗时不等同完整滤镜处理速度。'}
end
mp.register_script_message('health-menu', function() mp.commandv('script-message-to', 'uosc', 'open-menu', u.format_json(menu())) end)
mp.register_script_message('health-diagnose', diagnose)
mp.register_script_message('health-sample', start_sample)
mp.register_script_message('health-cancel', function() finish_sample('用户取消') end)
mp.register_script_message('health-open-reports', function() if mkdir() then mp.commandv('run', 'explorer.exe', root:gsub('/', '\\')) end end)
mp.add_hook('on_unload', 50, function() finish_sample('切换或关闭媒体') end)
mp.register_event('shutdown', function() diagnostic_token = diagnostic_token + 1; for id in pairs(diagnostic_jobs) do mp.abort_async_command(id) end end)
publish()
