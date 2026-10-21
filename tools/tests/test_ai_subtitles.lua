-- Cache and lifecycle regression in mpv's Lua runtime; all files stay in the supplied fixture.
local host, utils = mp, require 'mp.utils'
local opts = {root = '', script = ''}
require('mp.options').read_options(opts, 'asr-test')
package.path = host.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local cache = require 'ai-subtitle-cache'
local good = '1\n00:00:00,000 --> 00:00:02,000\nA valid subtitle.\n\n'
local passed, fake, events, hooks, handlers, jobs, state, settings, commands, aborted, timers, clock = 0
local function check(value, reason)
    assert(value, reason)
    passed = passed + 1
end
local function path(name) return utils.join_path(opts.root, name) end
local function boot(media, overrides)
    state = {path = media, aid = 1, ['track-list'] = {}, ['cache'] = 'yes', duration = 4}
    events, hooks, handlers, jobs, commands, aborted = {}, {}, {}, {}, {}, {}
    timers, clock = {}, 0
    settings = {output_path = path('results'), fast_whisper_path = 'fake-whisper',
        model = 'large-v3-turbo', device = 'cuda', compute_type = 'float16', api_key = '', segment_silence = false}
    for key, value in pairs(overrides or {}) do settings[key] = value end
    fake = {msg = {info = function() end, error = function() end, warn = function() end,
        debug = function() end, verbose = function() end}}
    function fake.get_property(key, default)
        if key == 'filename/no-ext' then local _, name = utils.split_path(state.path); return name:gsub('%.%w+$', '') end
        if key == 'working-directory' then return opts.root end
        if state[key] == nil then return default end
        return state[key]
    end
    fake.get_property_number = fake.get_property
    function fake.get_time() return clock end
    function fake.set_property_native(key, value) state[key] = value end
    function fake.get_property_native(key, default)
        if key == 'pid' then return host.get_property_native('pid') end
        if key == 'command-list' then return {{name = 'normalize-path'}} end
        if key == 'current-tracks/sub' then return state.sub end
        if state[key] == nil then return default end
        return state[key]
    end
    function fake.command_native(spec)
        if spec.name == 'subprocess' then
            if spec.args[1] == 'curl' then error('empty key must not call API') end
            if spec.args[1] == 'ffmpeg' or spec.args[1] == 'fake-whisper' then
                error('recognition and extraction must be asynchronous')
            end
            return host.command_native(spec) -- cache mkdir only
        end
        if spec[1] == 'expand-path' and spec[2] == '~~/cache/ai-subtitles' then return path('results') end
        return host.command_native(spec)
    end
    function fake.command_native_async(spec, callback)
        if spec[1] == 'sub-add' or spec[1] == 'sub-reload' then
            if settings.defer_subtitle_load then
                state.subtitle_jobs = state.subtitle_jobs or {}
                state.subtitle_jobs[#state.subtitle_jobs + 1] = {spec = spec, callback = callback}
                return 0
            end
            fake.commandv(spec[1], spec[2], spec[3])
            callback(true)
            return 0
        end
        jobs[#jobs + 1] = {spec = spec, callback = callback}
        return #jobs
    end
    function fake.abort_async_command(id) aborted[id] = true end
    function fake.commandv(name, a, b, c)
        commands[#commands + 1] = {name, a, b, c}
        if name == 'set' and a == 'sid' then state.sid = b
        elseif name == 'sub-add' then
            local id = #state['track-list'] + 1
            state['track-list'][id] = {id = id, type = 'sub', ['external-filename'] = a}
        elseif name == 'sub-remove' then
            for index, track in ipairs(state['track-list']) do
                if track.id == tonumber(a) then table.remove(state['track-list'], index); break end
            end
        elseif name == 'sub-reload' and settings.reassign_sub_id then
            for _, track in ipairs(state['track-list']) do
                if track.id == tonumber(a) then track.id = track.id + 100 end
            end
        end
        return true
    end
    function fake.osd_message(message) state.osd = message end
    function fake.get_osd_size() return 640, 360, 1 end
    function fake.create_osd_overlay()
        local overlay = {}
        function overlay:update() state.overlay = self.data end
        function overlay:remove() state.overlay = '' end
        return overlay
    end
    function fake.set_osd_ass() end
    function fake.register_script_message(name, handler) handlers[name] = handler end
    function fake.register_event(name, handler) events[name] = handler end
    function fake.add_hook(name, _, handler) hooks[name] = handler end
    function fake.add_timeout(delay, callback)
        local timer = {callback = callback, delay = delay, killed = false}
        function timer:kill() self.killed = true end
        timers[#timers + 1] = timer
        return timer
    end
    _G.mp = fake
    package.loaded['mp.msg'] = fake.msg
    package.loaded['mp.options'] = {read_options = function(o) for key, value in pairs(settings) do o[key] = value end end}
    assert(loadfile(opts.script))()
end
local function advance()
    local pending = timers
    timers = {}
    for _, timer in ipairs(pending) do
        if not timer.killed then clock = clock + timer.delay; timer.callback() end
    end
end
local function calibrate()
    local job = jobs[#jobs]
    local body
    for i, arg in ipairs(job.spec.args) do if arg == '--data-binary' then body = job.spec.args[i + 1]:sub(2) end end
    local payload = assert(utils.parse_json(cache.read(body)))
    check(payload.messages[1].content:find('COMPLETE', 1, true), 'calibration receives complete original before translation')
    job.callback(true, {status = 0, stdout = utils.format_json({choices = {{message = {content = payload.messages[2].content}}}})})
    advance()
end
local function translation_track(command)
    if command[1] ~= 'sub-add' then return nil end
    local file = command[2]
    if file:find('%.translate%.srt$') then return file end
    if file:find('%.Chinese%.ass$') then
        local data = file:gsub('%.Chinese%.ass$', '.translate.srt')
        if cache.read(data) then return data end
    end
end
local function output(job)
    for i, arg in ipairs(job.spec.args) do if arg == '--output_dir' then return job.spec.args[i + 1] end end
end
local function complete(data, status)
    local job = jobs[#jobs]
    local file
    for i, arg in ipairs(job.spec.args) do if arg == '--output' then file = job.spec.args[i + 1] end end
    if not file then
        local _, name = utils.split_path(job.spec.args[2])
        file = utils.join_path(output(job), name:gsub('%.%w+$', '.srt'))
    end
    check(cache.write(file, data), 'fixture output writable')
    job.callback(true, {status = status or 0, stderr = ''})
end
local function suite()
    check(cache.valid_srt(good), 'valid SRT accepted')
    check(not cache.valid_srt(''), 'empty result rejected')
    check(not cache.valid_srt(good .. '2\ninvalid\n\n'), 'malformed later block rejected')
    local ext = utils.file_info(path('A/clip.mkv')) and '.mkv' or '.wav'
    local a, b = path('A/clip' .. ext), path('B/clip' .. ext)
    boot(a)
    handlers['sub-fastwhisper']()
    check(#jobs == 1 and output(jobs[1]):gsub('\\', '/'):find('/results/', 1, true),
        'recognition output in cache: jobs=' .. #jobs .. ', OSD=' .. tostring(state.osd) ..
        ', output=' .. tostring(jobs[1] and output(jobs[1])))
    complete(good)
    check(#state['track-list'] == 1 and state.osd:find('原文字幕'), 'zero exit and SRT loads completed cache')
    local completed = state['track-list'][1]['external-filename']:gsub('%.ai%.ass$', '.srt')
    check(not utils.file_info(path('A/clip.srt')), 'no sidecar created')
    hooks.on_unload()
    check(cache.read(completed) == good, 'unload preserves complete subtitle')
    boot(a)
    events['file-loaded']()
    check(#state['track-list'] == 1 and #jobs == 0, 'fresh session auto-reuses result')
    handlers['sub-fastwhisper']()
    check(#jobs == 0, 'trigger on cached media avoids backend')
    boot(b)
    handlers['sub-fastwhisper']()
    check(#jobs == 1 and output(jobs[1]) ~= utils.split_path(completed), 'same name in different folder misses cache')
    local late = jobs[1].callback
    hooks.on_unload()
    state.path = a
    events['file-loaded']()
    local before = #commands
    late(true, {status = 0})
    check(aborted[1] and #commands == before, 'unload aborts and ignores stale callback')
    boot(a, {model = 'large-v3'})
    handlers['sub-fastwhisper']()
    check(#jobs == 1, 'different model misses cache')
    complete(good, 7)
    check(#state['track-list'] == 0 and state.osd:find('失败'), 'nonzero exit rejects even valid output')
    hooks.on_unload()
    boot(a, {model = 'large-v3'})
    events['file-loaded']()
    check(#state['track-list'] == 0, 'failed work never auto-reused')
    handlers['sub-fastwhisper']()
    complete('', 0)
    check(#state['track-list'] == 0, 'zero exit without valid output rejected')
    hooks.on_unload()
    boot(a, {output_path = 'source'})
    events['file-loaded']()
    check(#state['track-list'] == 1, 'legacy source redirects to cache')
    boot(b)
    handlers['sub-fastwhisper']()
    local pending = jobs[1].callback
    handlers['sub-fastwhisper-cancel']()
    pending(true, {status = 0})
    check(aborted[1] and #state['track-list'] == 0, 'manual cancellation ignores late success')
    check(not state['user-data/ai-subtitles/feedback'].active and state.overlay == '', 'cancel clears persistent feedback and own overlay')
    check(cache.read(completed) == good, 'cancellation keeps other completed cache')
    for _, override in ipairs({{language = 'ja'}, {compute_type = 'int8_float16'}}) do
        boot(a, override)
        events['file-loaded']()
        check(#state['track-list'] == 0, 'changed recognition settings miss cache')
    end
    boot(a)
    state.aid = 2
    events['file-loaded']()
    check(#state['track-list'] == 0, 'different audio track misses cache')
    check(cache.write(completed, good .. 'broken'), 'corruption fixture written')
    boot(a)
    events['file-loaded']()
    check(#state['track-list'] == 0, 'corrupted completed output rejected')
    check(cache.write(completed, good), 'original fixture restored')
    boot(a)
    state.sid = '2'
    events['file-loaded']()
    check(commands[#commands][1] == 'sub-add' and commands[#commands][3] == 'auto',
        'automatic reuse does not override an already selected subtitle')
    local model, aligner = path('qwen-model'), path('qwen-aligner')
    check(cache.mkdir(model) and cache.write(model .. '/config.json', '{}') and
        cache.mkdir(aligner) and cache.write(aligner .. '/config.json', '{}'), 'Qwen local model fixtures')
    local qwen_opts = {qwen_python = 'fake-qwen-python', qwen_model = model, qwen_aligner = aligner}
    boot(a, qwen_opts)
    events['file-loaded']()
    state['track-list'][#state['track-list'] + 1] = {id = 99, type = 'sub', ['external-filename'] = path('professional.srt')}
    handlers['sub-fastwhisper-backend']('qwen')
    check(#state['track-list'] == 1 and state['track-list'][1].id == 99,
        'engine switch removes only AI cached tracks and preserves professional subtitles')
    handlers['sub-fastwhisper']()
    check(#jobs == 1 and jobs[1].spec.args[1] == 'fake-qwen-python' and
        jobs[1].spec.args[3] == '--input' and not output(jobs[1]), 'Qwen uses independent Python command')
    complete(good)
    local qwen_result = state['track-list'][#state['track-list']]['external-filename']:gsub('%.ai%.ass$', '.srt')
    check(qwen_result ~= completed, 'Qwen and Whisper cache identities are isolated')
    handlers['sub-fastwhisper-backend']('whisper')
    handlers['sub-fastwhisper']()
    check(#jobs == 1, 'switch back to Whisper reuses original cache')
    handlers['sub-fastwhisper-backend']('qwen')
    handlers['sub-fastwhisper']()
    check(#jobs == 1, 'switch back to Qwen reuses its cache')
    handlers['sub-fastwhisper-backend-menu']()
    local menu = utils.parse_json(commands[#commands][4])
    check(menu.items[3].active and menu.items[1].value[2] == 'sub_fastwhisper', 'menu selection and receiver agree')
    boot(b, qwen_opts)
    handlers['sub-fastwhisper-backend']('qwen')
    handlers['sub-fastwhisper']()
    local stale = jobs[1].callback
    handlers['sub-fastwhisper-backend']('whisper')
    local count = #commands
    stale(true, {status = 0})
    check(aborted[1] and #commands == count, 'switch aborts Qwen and ignores stale completion')
    handlers['sub-fastwhisper-backend']('invalid')
    handlers['sub-fastwhisper']()
    check(jobs[2].spec.args[1] == 'fake-whisper', 'unknown backend cannot replace active engine')
    hooks.on_unload()
    boot(a, {backend = 'qwen', qwen_model = path('missing')})
    handlers['sub-fastwhisper']()
    check(#jobs == 0 and state.osd:find('未配置'), 'missing Qwen model fails before starting work')
    boot(a, {api_key = 'mock-only'})
    local external = path('translation-input/original.srt')
    check(cache.mkdir(utils.split_path(external)) and cache.write(external, good), 'translation fixture')
    state.sub = {external = true, ['external-filename'] = external}
    handlers['sub-translate']()
    check(#jobs == 1 and jobs[1].spec.args[1] == 'curl', 'translation uses mocked API only')
    calibrate()
    jobs[2].callback(true, {status = 0, stdout = utils.format_json({choices = {{message = {
        content = '00:00:00,000 --> 00:00:02,000 | Translation in cache.'}}}})})
    check(cache.read(external) == good and not cache.read(external:gsub('%.srt$', '.translate.srt')),
        'manual translation never writes next to selected source subtitle')
    local translated
    for _, command in ipairs(commands) do
        if translation_track(command) then
            translated = translation_track(command)
            check(command[3] == 'select', 'manual translation explicitly selects its subtitle track')
        end
    end
    check(translated and translated:gsub('\\', '/'):find('/results/', 1, true) and
        cache.valid_srt(cache.read(translated)), 'translated SRT is in cache')
    check(cache.read(translated .. '.complete') == cache.digest(cache.read(translated)),
        'translation completion checksum recorded')
    local requests_before_reload = #jobs
    handlers['sub-fastwhisper-load-original']()
    handlers['sub-fastwhisper-load-bilingual']()
    check(#jobs == requests_before_reload and state.osd:find('未调用 API'), 'explicit raw/bilingual load never starts another API request')
    for _, item in ipairs({{'original','subtitles.srt'}, {'calibrated','subtitles.calibrated.srt'}, {'translated','subtitles.translate.srt'}}) do
        handlers['sub-fastwhisper-export'](path('export-' .. item[1] .. '.srt'), item[1])
        local args, source = jobs[#jobs].spec.args
        for i, arg in ipairs(args) do if arg == '-Source' then source = args[i + 1] end end
        check(source and source:sub(-#item[2]) == item[2] and cache.valid_srt(cache.read(source)), 'export selects complete artifact: ' .. item[1])
    end
    hooks.on_unload()
    boot(a, {api_key = 'mock-only', api_mode = 'translation-failure-regression'})
    state.sub = {external = true, ['external-filename'] = external}
    handlers['sub-translate']()
    jobs[1].callback(true, {status = 0, stdout = utils.format_json({error = {message = 'Unauthorized'}})})
    local failed_translation
    for _, command in ipairs(commands) do
        if translation_track(command) then failed_translation = translation_track(command) end
    end
    check(not failed_translation or not cache.read(failed_translation .. '.complete'),
        'API failure must not mark original text as completed translation')
    handlers['sub-translate']()
    advance()
    check(#jobs == 2, 'explicit translation retries failed API request')
    jobs[2].callback(true, {status = 0, stdout = utils.format_json({choices = {{message = {
        content = '00:00:00,000 --> 00:00:02,000 | Retried translation.'}}}})})
    advance()
    jobs[3].callback(true, {status = 0, stdout = utils.format_json({choices = {{message = {
        content = '00:00:00,000 --> 00:00:02,000 | Retried translation.'}}}})})
    local retried
    for _, command in ipairs(commands) do
        if translation_track(command) then retried = translation_track(command) end
    end
    check(retried and cache.read(retried .. '.complete'), 'successful retry completes translation')
    hooks.on_unload()
    for index, response in ipairs({{choices = {{}}}, {choices = {{message = {content = {}}}}},
        {choices = {{message = {content = ''}}}},
        {choices = {{message = {content = '00:00:00,000 --> 00:00:02,000 | One.\nExtra commentary.'}}}},
        {choices = {{message = {content = '00:00:02,000 --> 00:00:03,000 | Wrong timestamp.'}}}},
        {choices = {{finish_reason = 'length', message = {content = '00:00:00,000 --> 00:00:02,000 | Truncated.'}}}}}) do
        boot(a, {api_key = 'mock-only', api_mode = 'translation-invalid-' .. index})
        state.sub = {external = true, ['external-filename'] = external}
        handlers['sub-translate']()
        jobs[1].callback(true, {status = 0, stdout = utils.format_json(response)})
        local result
        for _, command in ipairs(commands) do
            if translation_track(command) then result = translation_track(command) end
        end
        check(not result, 'malformed API response cannot install a translated subtitle')
        hooks.on_unload()
    end
    boot(a, {api_key = 'mock-only', api_mode = 'translation-order', reassign_sub_id = true})
    local ordered = path('translation-input/ordered.srt')
    check(cache.write(ordered, good .. '2\n00:00:02,000 --> 00:00:04,000\nAnother cue.\n\n'), 'ordered fixture')
    state.sub = {external = true, ['external-filename'] = ordered}
    handlers['sub-translate']()
    calibrate()
    jobs[2].callback(true, {status = 0, stdout = utils.format_json({choices = {{message = {
        content = '00:00:00,000 --> 00:00:02,000 | First.\n00:00:02,000 --> 00:00:04,000 | Second.'}}}})})
    local ordered_result
    for _, command in ipairs(commands) do
        if translation_track(command) then ordered_result = translation_track(command) end
    end
    check(cache.read(ordered_result) == '1\n00:00:00,000 --> 00:00:02,000\nFirst.\n\n' ..
        '2\n00:00:02,000 --> 00:00:04,000\nSecond.\n\n', 'translated cues keep source order')
    local last = commands[#commands]
    local current_id
    for _, track in ipairs(state['track-list']) do
        if track['external-filename']:find('%.ass$') then current_id = track.id end
    end
    check(last[1] == 'set' and last[2] == 'sid' and tonumber(last[3]) == current_id,
        'reload selects newly allocated subtitle track ID')
    local before = #jobs
    handlers['sub-translate']()
    check(#jobs == before, 'repeated completed translation makes no new API request')
    hooks.on_unload()
    boot(a, {api_key = 'mock-only', api_mode = 'translation-order'})
    state.sub = {external = true, ['external-filename'] = ordered}
    handlers['sub-translate']()
    check(#jobs == 0, 'completed translation is reused across player sessions')
    hooks.on_unload()
    boot(a, {api_key = 'mock-only', api_mode = 'translation-cancel'})
    state.sub = {external = true, ['external-filename'] = external}
    handlers['sub-translate']()
    local late_translation = jobs[1].callback
    hooks.on_unload()
    local command_count = #commands
    late_translation(true, {status = 0, stdout = utils.format_json({choices = {{message = {
        content = '00:00:00,000 --> 00:00:02,000 | Cancelled output.'}}}})})
    check(aborted[1] and #commands == command_count, 'cancel ignores late translation API callback')
    hooks.on_unload()
    boot(a, {api_key = 'mock-only', api_mode = 'translation-parallel'})
    local parallel, source_cues, expected_cues, replies = path('translation-input/parallel.srt'), {}, {}, {{}, {}}
    for i = 1, 21 do
        local timestamp = string.format('00:00:%02d,000 --> 00:00:%02d,000', i - 1, i)
        source_cues[i] = i .. '\n' .. timestamp .. '\nSource ' .. i .. '.\n\n'
        expected_cues[i] = i .. '\n' .. timestamp .. '\nTranslation ' .. i .. '.\n\n'
        table.insert(replies[i <= 20 and 1 or 2], timestamp .. ' | Translation ' .. i .. '.')
    end
    check(cache.write(parallel, table.concat(source_cues)), 'parallel translation fixture')
    state.sub = {external = true, ['external-filename'] = parallel}
    handlers['sub-translate']()
    check(#jobs == 1, 'translation dispatches one budgeted batch at a time')
    calibrate()
    for _, i in ipairs({1, 2}) do
        if i > 1 then advance() end
        jobs[i + 1].callback(true, {status = 0, stdout = utils.format_json({choices = {{message = {
            content = table.concat(replies[i], '\n')}}}})})
    end
    local parallel_result
    for _, command in ipairs(commands) do
        if translation_track(command) then parallel_result = translation_track(command) end
    end
    check(cache.read(parallel_result) == table.concat(expected_cues), 'sequential batches keep complete source timeline')
    check(cache.read(parallel_result .. '.complete') == cache.digest(cache.read(parallel_result)),
        'multiple batches finish with one valid completion checksum')
    hooks.on_unload()
    boot(a)
    events['file-loaded']()
    handlers['sub-fastwhisper-manager']()
    local manager = utils.parse_json(commands[#commands][4])
    check(manager.type == 'ai-subtitle-manager' and manager.items[2].title == '加载原文字幕', 'management shows current completed cache')
    handlers['sub-fastwhisper-regenerate']()
    check(#jobs == 1 and cache.read(completed) == good, 'regeneration bypasses reuse and retains old completed result')
    complete('', 7)
    check(cache.read(completed) == good, 'failed regeneration preserves completed cache')
    handlers['sub-fastwhisper-regenerate']()
    local cancelled = jobs[#jobs].callback
    handlers['sub-fastwhisper-cancel']()
    cancelled(true, {status = 0})
    check(cache.read(completed) == good, 'cancelled regeneration preserves old result')
    local old_translation = completed:gsub('%.srt$', '.translate.srt')
    check(cache.write(old_translation, good) and cache.write(old_translation .. '.complete', cache.digest(good)), 'old translation fixture')
    handlers['sub-fastwhisper-regenerate']()
    complete((good:gsub('A valid subtitle.', 'A newly generated subtitle.')))
    check(cache.read(completed):find('newly generated') and not cache.read(old_translation .. '.complete'),
        'successful regeneration replaces transcript and invalidates old translation')
    check(state['user-data/ai-subtitles/status'].cached and not state['user-data/ai-subtitles/status'].running,
        'published status matches completed task')
    handlers['sub-fastwhisper-export'](path('chosen-export.srt'))
    check(jobs[#jobs].spec.args[1] == 'powershell.exe' and jobs[#jobs].spec.args[#jobs[#jobs].spec.args] == path('chosen-export.srt'),
        'export uses explicit destination in argument array')
    hooks.on_unload()
    local transaction = cache.entry(path('results'), 'transaction rollback fixture')
    check(cache.prepare(transaction, 1, 1) and cache.write(path('new.srt'), good) and cache.commit(transaction, path('new.srt')), 'completed transaction fixture')
    check(cache.write(path('new.srt'), (good:gsub('valid', 'replacement'))), 'replacement transaction fixture')
    local rename = os.rename
    for _, target in ipairs({transaction.srt, transaction.manifest}) do
        os.rename = function(from, to) if to == target then return nil, 'injected install failure' end; return rename(from, to) end
        local ok = cache.commit(transaction, path('new.srt'))
        os.rename = rename
        check(not ok and cache.lookup(transaction) and cache.read(transaction.srt) == good, 'SRT/marker install failure restores completed result')
    end
    boot(a, {use_segment = true, model = 'segment-fixture'})
    state.duration = 65.25
    state['current-tracks/audio'] = {['ff-index'] = 3}
    handlers['sub-fastwhisper']()
    check(#jobs == 1 and jobs[1].spec.args[1] == 'ffmpeg' and
        state['user-data/ai-subtitles/status'].running, 'segmented extraction is asynchronous and publishes running state')
    local function arg(job, name)
        for i, value in ipairs(job.spec.args) do if value == name then return job.spec.args[i + 1] end end
    end
    local function extracted()
        local job = jobs[#jobs]
        check(cache.write(job.spec.args[#job.spec.args], 'mock PCM'), 'segment audio fixture')
        job.callback(true, {status = 0})
    end
    check(arg(jobs[1], '-c:a') == 'pcm_s16le' and arg(jobs[1], '-ar') == '16000' and
        arg(jobs[1], '-map') == '0:3' and tonumber(arg(jobs[1], '-t')) == 10,
        'first slice decodes selected audio to short PCM')
    extracted()
    complete((good:gsub('A valid subtitle.', '123')))
    local partial = state['track-list'][1]['external-filename']:gsub('%.ai%.ass$', '.srt')
    check(cache.read(partial):find('123', 1, true) and state['user-data/ai-subtitles/status'].running and
        not state['user-data/ai-subtitles/status'].cached, 'numeric partial text loads before completion')
    check(tonumber(arg(jobs[#jobs], '-ss')) == 10 and tonumber(arg(jobs[#jobs], '-t')) == 40,
        'second slice continues at first boundary and grows to forty seconds')
    extracted(); complete(good)
    check(cache.read(partial):find('00:00:10,000', 1, true), 'second slice timestamps shifted')
    check(tonumber(arg(jobs[#jobs], '-ss')) == 50 and tonumber(arg(jobs[#jobs], '-t')) == 15.25,
        'fractional tail is clamped to media duration')
    extracted(); complete(good)
    check(not state['user-data/ai-subtitles/status'].running and state['user-data/ai-subtitles/status'].cached,
        'all slices finalize one completed cache')
    check(#state['track-list'] == 1 and state['track-list'][1]['external-filename'] ~= partial,
        'completed track replaces partial track')
    handlers['sub-fastwhisper']()
    check(#jobs == 6, 'segmented completed cache reuses without another process')
    handlers['sub-fastwhisper-regenerate']()
    local old = jobs[#jobs]
    handlers['sub-fastwhisper-cancel']()
    local job_count = #jobs
    old.callback(true, {status = 0})
    check(aborted[job_count] and #jobs == job_count and state['user-data/ai-subtitles/status'].cached,
        'cancel aborts extraction, ignores stale callback and preserves completed cache')
    boot(b, {use_segment = true, model = 'segment-fixture'})
    state.duration = 65.25
    handlers['sub-fastwhisper']()
    extracted(); complete(good)
    local stale_segment = jobs[#jobs]
    handlers['sub-fastwhisper-cancel']()
    job_count = #jobs
    stale_segment.callback(true, {status = 0})
    check(#state['track-list'] == 0 and not state['user-data/ai-subtitles/status'].cached and #jobs == job_count,
        'cancel removes partial track and never marks incomplete transcript complete')
    boot(b, {use_segment = true, segment_duration = 1.25, model = 'fractional-segment'})
    state.duration = 42
    handlers['sub-fastwhisper']()
    extracted(); complete(good)
    partial = state['track-list'][1]['external-filename']:gsub('%.ai%.ass$', '.srt')
    check(cache.read(partial):find('00:00:01,250', 1, true), 'backend timestamps clipped to slice boundary')
    check(tonumber(arg(jobs[#jobs], '-ss')) == 1.25, 'fractional start is not rounded to an integer second')
    extracted(); complete('')
    check(state['user-data/ai-subtitles/status'].running and #jobs == 5,
        'empty silence-only middle slice continues recognition')
    extracted(); complete(good)
    check(state['user-data/ai-subtitles/status'].cached, 'silent slice does not discard valid speech')
    for _, stage in ipairs({'extraction', 'recognition'}) do
        boot(b, {use_segment = true, model = 'failed-' .. stage})
        handlers['sub-fastwhisper']()
        if stage == 'recognition' then extracted() end
        jobs[#jobs].callback(true, {status = 7, stderr = 'injected failure'})
        check(not state['user-data/ai-subtitles/status'].running and not state['user-data/ai-subtitles/status'].cached,
            stage .. ' failure clears running state without completing cache')
    end
    boot(b, {use_segment = true, model = 'empty-segment'})
    handlers['sub-fastwhisper']()
    extracted(); complete('')
    check(not state['user-data/ai-subtitles/status'].cached and #state['track-list'] == 0,
        'all-silent media never produces a false completed cache')
    boot(b, {use_segment = true, segment_duration = 0})
    handlers['sub-fastwhisper']()
    check(#jobs == 0 and not (state['user-data/ai-subtitles/status'] or {}).running, 'invalid duration cannot start an endless loop')
    boot(a, {use_segment = true, segment_silence = true, model = 'silence-fixture'})
    state.duration = 65
    state['current-tracks/audio'] = {['ff-index'] = 3}
    handlers['sub-fastwhisper']()
    check(arg(jobs[1], '-af'):find('silencedetect', 1, true) and tonumber(arg(jobs[1], '-ss')) == 7 and
        tonumber(arg(jobs[1], '-t')) == 6 and arg(jobs[1], '-map') == '0:3', 'silence scan is limited to boundary window and selected audio')
    jobs[1].callback(true, {status = 0, stderr = '[silencedetect] silence_start: 3.6\n[silencedetect] silence_end: 4.1 | silence_duration: 0.5\n' ..
        '[silencedetect] silence_start: 5.6\n[silencedetect] silence_end: 5.9 | silence_duration: 0.3'})
    check(math.abs(tonumber(arg(jobs[#jobs], '-t')) - 10.85) < 0.0001, 'first cut moves to midpoint of nearby silence')
    extracted(); complete(good)
    local detection = jobs[#jobs]
    check(arg(detection, '-af') ~= nil, 'next boundary is analyzed asynchronously')
    detection.callback(true, {status = 0, stderr = 'ordinary ffmpeg output without silence'})
    check(math.abs(tonumber(arg(jobs[#jobs], '-ss')) - 10.85) < 0.0001 and tonumber(arg(jobs[#jobs], '-t')) == 40,
        'no nearby silence falls back to fixed length without timestamp gap')
    extracted(); complete(good)
    check(arg(jobs[#jobs], '-af') == nil, 'media tail does not need a boundary scan')
    extracted(); complete(good)
    check(state['user-data/ai-subtitles/status'].cached, 'silence-based slices commit complete result')
    local silence_result = state['track-list'][1]['external-filename']
    boot(a, {use_segment = true, segment_silence = false, model = 'silence-fixture'})
    events['file-loaded']()
    check(#state['track-list'] == 0 and cache.read(silence_result), 'fixed and silence slice caches are separate and retained')
    boot(b, {use_segment = true, segment_silence = true, model = 'cancel-silence'})
    handlers['sub-fastwhisper']()
    local stale_detection = jobs[1]
    handlers['sub-fastwhisper-cancel']()
    stale_detection.callback(true, {status = 0, stderr = ''})
    check(aborted[1] and #jobs == 1, 'cancel aborts boundary analysis and ignores late completion')
    boot(b, {use_segment = true, segment_silence = true, segment_duration = 100, model = 'capped-silence'})
    state.duration = 65
    handlers['sub-fastwhisper']()
    check(tonumber(arg(jobs[1], '-ss')) == 12 and tonumber(arg(jobs[1], '-t')) == 3,
        'first boundary scan cannot extend beyond fifteen seconds')
    jobs[1].callback(true, {status = 0, stderr = 'silence_start: 2.5\nsilence_end: 3'})
    check(tonumber(arg(jobs[#jobs], '-t')) == 14.75, 'first silence-based slice stays within latency cap')
    handlers['sub-fastwhisper-cancel']()
    boot(b, {use_segment = true, segment_silence = true, model = 'failed-silence'})
    handlers['sub-fastwhisper']()
    jobs[1].callback(true, {status = 7, stderr = 'analysis failed'})
    check(not state['user-data/ai-subtitles/status'].running and not state['user-data/ai-subtitles/status'].cached,
        'failed analysis cannot be reported as successful recognition')
    boot(a, {api_key = 'mock-only', api_mode = 'layout-current-track'})
    state.sub = {external = true, ['external-filename'] = completed:gsub('%.srt$', '.ai.ass')}
    handlers['sub-translate']()
    check(#jobs == 1 and jobs[1].spec.args[1] == 'curl', 'manual translation resolves AI display ASS back to preserved SRT')
    hooks.on_unload()
    for _, override in ipairs({{api_mode = 'another-provider-model'}, {translate = 'English'}, {font_name = 'Another font'}}) do
        boot(a, override); events['file-loaded']()
        check(#jobs == 0 and #state['track-list'] > 0, 'translation/style change reuses recognition without inference')
    end
    local identity = utils.parse_json(cache.read(utils.join_path(utils.split_path(completed), 'complete.json'))).identity
    local projected = utils.parse_json(identity)
    local legacy = {'asr-cache-v1'}
    for i = 2, 15 do legacy[i] = projected[i] end
    legacy[16], legacy[17], legacy[18], legacy[19], legacy[20], legacy[21] = 'OldTarget', 'OldModel', 'OldURL', '1', 'OldFont', projected[16]
    local migration_root = path('legacy-cache')
    local old = cache.entry(migration_root, utils.format_json(legacy))
    local source_text = cache.read(completed)
    check(cache.prepare(old, 1, 1) and cache.write(path('legacy-source.srt'), source_text) and
        cache.commit(old, path('legacy-source.srt')), 'legacy ASR fixture')
    local target = cache.entry(migration_root, identity)
    check(cache.lookup_recognition(target, migration_root) and cache.read(target.srt) == source_text and
        cache.read(old.srt) == source_text, 'legacy cache safely migrates independently of provider without removing original')
    local progress = path('progress-transaction.json')
    check(cache.write_atomic(progress, 'old progress'), 'progress transaction fixture')
    local original_rename = os.rename
    os.rename = function(from, to)
        if from == progress .. '.pending' and to == progress then return nil, 'injected replacement failure' end
        return original_rename(from, to)
    end
    local wrote = cache.write_atomic(progress, 'new progress')
    os.rename = original_rename
    check(not wrote and cache.read(progress) == 'old progress', 'progress installation failure preserves previous budget')
    for i, item in ipairs({{'en', false}, {'English', false}, {'zh', false}, {'zh-TW', false}, {'yue', false},
        {'ja', true}, {'Japanese', true}, {'ko', true}, {'fr', true}, {'', false}}) do
        boot(b, {model = 'auto-language-' .. i, api_key = 'mock-only', language = item[1]})
        handlers['sub-fastwhisper'](); complete(good)
        check((#jobs == 2) == item[2], 'automatic language rule: ' .. item[1])
        hooks.on_unload()
    end
    boot(b, {model = 'auto-disabled', api_key = 'mock-only', language = 'ja', auto_translate = 'no'})
    handlers['sub-fastwhisper'](); complete(good)
    check(#jobs == 1, 'auto off keeps Japanese original without API')
    handlers['sub-fastwhisper-auto-translate-toggle']()
    handlers['sub-fastwhisper']()
    check(#jobs == 2, 'explicit generate on cached Japanese can start calibration after enabling auto')
    hooks.on_unload()
    boot(b, {model = 'detected-ja', api_key = 'mock-only'})
    handlers['sub-fastwhisper']()
    check(cache.write(utils.join_path(output(jobs[1]), 'clip.json'), utils.format_json({language = 'ja'})), 'detected language fixture')
    complete(good)
    check(#jobs == 2, 'backend-detected Japanese starts calibration without forced language')
    hooks.on_unload()
    boot(a, {api_key = 'mock-only', api_mode = 'review-selected-source'})
    state.sub = {external = true, ['external-filename'] = external}
    handlers['sub-translate'](); calibrate()
    jobs[#jobs].callback(true, {status = 0, stdout = utils.format_json({choices = {{message = {
        content = '00:00:00,000 --> 00:00:02,000 | Old source translation.'}}}})})
    local newer = path('translation-input/new-selection.srt')
    check(cache.write(newer, good:gsub('A valid subtitle.', 'A different selected subtitle.')), 'second external subtitle fixture')
    state.sub = {external = true, ['external-filename'] = newer}
    handlers['sub-fastwhisper-manager']()
    manager = state['user-data/ai-subtitles/menu']
    local reload
    for _, item in ipairs(manager.items) do if item.id == 'translate' then reload = item end end
    check(reload and reload.title ~= '加载双语字幕', 'changing selected SRT must not offer previous source translation')
    local before = #jobs
    handlers['sub-fastwhisper-translate-resume'](); advance()
    check(#jobs == before + 1, 'translation action must process newly selected subtitle instead of resuming completed old job')
    local body
    for i, value in ipairs(jobs[#jobs].spec.args) do if value == '--data-binary' then body = jobs[#jobs].spec.args[i + 1]:sub(2) end end
    check(cache.read(body):find('different selected subtitle', 1, true), 'request body belongs to the new selected source')
    handlers['sub-fastwhisper-translation-cancel']()
    state.sub = {external=false, codec='ass'}
    handlers['sub-fastwhisper-manager']()
    local selected_action
    for _, item in ipairs(state['user-data/ai-subtitles/menu'].items) do if item.id == 'translate' then selected_action = item end end
    check(selected_action and not selected_action.selectable, 'unsupported selected track must not silently translate a previously selected SRT')
    hooks.on_unload()
    boot(b, {model = 'review-multiple-audio'})
    state.aid = 2
    state['track-list'] = {{id=1,type='audio',['ff-index']=1}, {id=2,type='audio',['ff-index']=2}}
    state['current-tracks/audio'] = {id=2,['ff-index']=2}
    handlers['sub-fastwhisper']()
    local extraction = jobs[1]
    check(extraction.spec.args[1] == 'ffmpeg' and arg(extraction, '-map') == '0:2', 'whole recognition explicitly extracts the selected second audio stream')
    local pcm = extraction.spec.args[#extraction.spec.args]
    check(cache.write(pcm, 'pcm fixture'), 'whole audio extraction fixture')
    extraction.callback(true, {status=0})
    check(#jobs == 2 and jobs[2].spec.args[2] == pcm, 'Whisper receives selected stream PCM instead of original multi-track video')
    complete(good)
    check(state['user-data/ai-subtitles/status'].cached and not cache.read(pcm), 'selected stream result cached and intermediate PCM removed')
    hooks.on_unload()
    boot(b, {model='review-selection-preserved'})
    state.sid = '1'
    handlers['sub-fastwhisper']()
    state.sid, state.sub = '7', {external=true,['external-filename']=newer}
    complete(good)
    local loaded
    for _, command in ipairs(commands) do if command[1] == 'sub-add' then loaded = command end end
    check(loaded and loaded[3] == 'auto', 'recognition result must not replace a subtitle selected while working')
    hooks.on_unload()
    boot(a, {api_key='mock-only', api_mode='review-deferred-selection', defer_subtitle_load=true})
    state.sid, state.sub = '1', {external=true,['external-filename']=external}
    handlers['sub-translate'](); calibrate()
    state.sid, state.sub = '7', {external=true,['external-filename']=newer}
    jobs[#jobs].callback(true, {status=0, stdout=utils.format_json({choices={{message={
        content='00:00:00,000 --> 00:00:02,000 | Deferred translated result.'}}}})})
    check(#state.subtitle_jobs == 1, 'partial/final result coalesce while the same background track is loading')
    local subtitle_job = state.subtitle_jobs[1]
    fake.commandv(subtitle_job.spec[1], subtitle_job.spec[2], subtitle_job.spec[3])
    state.sid = tostring(state['track-list'][1].id)
    subtitle_job.callback(true)
    check(state.sid == '7', 'async track loading completion restores user selection after mpv auto-selects result')
    state.sid, state.sub = 'no', nil
    handlers['sub-fastwhisper-load-bilingual']()
    check(state.sid ~= 'no', 'explicit load bilingual action re-enables subtitles after the user disabled them')
    hooks.on_unload()
    boot(b, {model='review-user-disabled', defer_subtitle_load=true})
    state.sid = '7'
    handlers['sub-fastwhisper'](); state.sid = 'no'; complete(good)
    check(#state.subtitle_jobs == 1, 'user disabling subtitles during recognition requests a preserving load')
    subtitle_job = state.subtitle_jobs[1]
    fake.commandv(subtitle_job.spec[1], subtitle_job.spec[2], subtitle_job.spec[3])
    state.sid = tostring(state['track-list'][1].id)
    subtitle_job.callback(true)
    check(state.sid == 'no', 'recognition completion keeps subtitles disabled by the user')
    hooks.on_unload()
    boot(b, {model='review-auto-selection', api_key='mock-only', language='ja', defer_subtitle_load=true})
    state.sid, state.sub = '1', {external=true,['external-filename']=external}
    handlers['sub-fastwhisper']()
    state.sid, state.sub = '7', {external=true,['external-filename']=newer}
    complete(good); calibrate()
    jobs[#jobs].callback(true, {status=0, stdout=utils.format_json({choices={{message={
        content='00:00:00,000 --> 00:00:02,000 | Automatic translated result.'}}}})})
    for _, pending_sub in ipairs(state.subtitle_jobs) do
        fake.commandv(pending_sub.spec[1], pending_sub.spec[2], pending_sub.spec[3])
        state.sid = tostring(state['track-list'][#state['track-list']].id)
        pending_sub.callback(true)
    end
    check(state.sid == '7', 'automatic translation also preserves a subtitle selected during preceding recognition')
    hooks.on_unload()
    boot(b, {model='review-no-audio'}); state.aid = false
    handlers['sub-fastwhisper']()
    check(#jobs == 0 and state.osd:find('音轨'), 'disabled audio cannot silently recognize a different stream')
    boot(b, {model='review-external-audio'})
    state['current-tracks/audio'] = {external=true}
    handlers['sub-fastwhisper']()
    check(#jobs == 0 and state.osd:find('外挂'), 'unsupported external audio fails before starting wrong-source recognition')
    boot('https://example.invalid/review.mkv', {model='review-network'})
    state.cache, state['demuxer-cache-state'] = 'auto', {['seekable-ranges']={{start=0,['end']=4}}}
    handlers['sub-fastwhisper']()
    check(#jobs == 1 and state['user-data/ai-subtitles/status'].running, 'network recognition is asynchronous and cancellable')
    complete(good)
    handlers['sub-fastwhisper-cancel'](); advance()
    check(not state['user-data/ai-subtitles/status'].running and #jobs == 1, 'network wait/recognition cancellation prevents further work')
    boot('https://example.invalid/finite.mkv', {model='review-network-eof'})
    state.cache, state['demuxer-cache-state'] = 'auto', {['seekable-ranges']={{start=0,['end']=3.96}}, ['eof-cached']=true}
    handlers['sub-fastwhisper'](); complete(good); advance()
    check(state['user-data/ai-subtitles/status'].cached and not state['user-data/ai-subtitles/status'].running,
        'fully cached finite video completes when last packet timestamp precedes media duration')
    hooks.on_unload()
    boot('https://example.invalid/gapped.mkv', {model='review-network-gap'})
    state.cache, state['demuxer-cache-state'] = 'auto', {['seekable-ranges']={{start=1,['end']=4}}, ['eof-cached']=true}
    handlers['sub-fastwhisper'](); complete(good); advance()
    check(not state['user-data/ai-subtitles/status'].cached and not state['user-data/ai-subtitles/status'].running,
        'network cache missing the beginning is never committed as a full transcript')
end
host.add_timeout(0.1, function()
    local ok, err = pcall(suite)
    _G.mp = host
    host.msg.info(ok and ('ASR CACHE MOCK PASS: ' .. passed .. ' assertions') or ('ASR CACHE MOCK FAIL: ' .. tostring(err)))
    host.commandv('quit', ok and 0 or 3)
end)
