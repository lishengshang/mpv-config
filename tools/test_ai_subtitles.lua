-- Cache and lifecycle regression in mpv's Lua runtime; all files stay in the supplied fixture.
local host, utils = mp, require 'mp.utils'
local opts = {root = '', script = ''}
require('mp.options').read_options(opts, 'asr-test')
package.path = host.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local cache = require 'ai-subtitle-cache'
local good = '1\n00:00:00,000 --> 00:00:02,000\nA valid subtitle.\n\n'
local passed, fake, events, hooks, handlers, jobs, state, settings, commands, aborted = 0
local function check(value, reason)
    assert(value, reason)
    passed = passed + 1
end
local function path(name) return utils.join_path(opts.root, name) end
local function boot(media, overrides)
    state = {path = media, aid = 1, ['track-list'] = {}, ['cache'] = 'yes', duration = 4}
    events, hooks, handlers, jobs, commands, aborted = {}, {}, {}, {}, {}, {}
    settings = {output_path = path('results'), fast_whisper_path = 'fake-whisper',
        model = 'large-v3-turbo', device = 'cuda', compute_type = 'float16', api_key = ''}
    for key, value in pairs(overrides or {}) do settings[key] = value end
    fake = {msg = {info = function() end, error = function() end, warn = function() end,
        debug = function() end, verbose = function() end}}
    function fake.get_property(key, default)
        if key == 'filename/no-ext' then local _, name = utils.split_path(state.path); return name:gsub('%.%w+$', '') end
        if key == 'working-directory' then return opts.root end
        return state[key] or default
    end
    fake.get_property_number = fake.get_property
    function fake.set_property_native(key, value) state[key] = value end
    function fake.get_property_native(key, default)
        if key == 'pid' then return host.get_property_native('pid') end
        if key == 'command-list' then return {{name = 'normalize-path'}} end
        if key == 'current-tracks/sub' then return state.sub end
        return state[key] or default
    end
    function fake.command_native(spec)
        if spec.name == 'subprocess' then
            if spec.args[1] == 'curl' then error('empty key must not call API') end
            return host.command_native(spec) -- cache mkdir only
        end
        if spec[1] == 'expand-path' and spec[2] == '~~/cache/ai-subtitles' then return path('results') end
        return host.command_native(spec)
    end
    function fake.command_native_async(spec, callback)
        jobs[#jobs + 1] = {spec = spec, callback = callback}
        return #jobs
    end
    function fake.abort_async_command(id) aborted[id] = true end
    function fake.commandv(name, a, b, c)
        commands[#commands + 1] = {name, a, b, c}
        if name == 'sub-add' then
            local id = #state['track-list'] + 1
            state['track-list'][id] = {id = id, type = 'sub', ['external-filename'] = a}
        elseif name == 'sub-remove' then
            for index, track in ipairs(state['track-list']) do
                if track.id == tonumber(a) then table.remove(state['track-list'], index); break end
            end
        end
        return true
    end
    function fake.osd_message(message) state.osd = message end
    function fake.get_osd_size() return 640, 360, 1 end
    function fake.set_osd_ass() end
    function fake.register_script_message(name, handler) handlers[name] = handler end
    function fake.register_event(name, handler) events[name] = handler end
    function fake.add_hook(name, _, handler) hooks[name] = handler end
    function fake.add_timeout(_, callback) return {callback = callback, kill = function() end} end
    _G.mp = fake
    package.loaded['mp.msg'] = fake.msg
    package.loaded['mp.options'] = {read_options = function(o) for key, value in pairs(settings) do o[key] = value end end}
    assert(loadfile(opts.script))()
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
    check(#state['track-list'] == 1 and state.osd:find('缓存'), 'zero exit and SRT loads completed cache')
    local completed = state['track-list'][1]['external-filename']
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
    check(#state['track-list'] == 0 and state.osd:find('failed'), 'nonzero exit rejects even valid output')
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
    local qwen_result = state['track-list'][#state['track-list']]['external-filename']
    check(qwen_result ~= completed, 'Qwen and Whisper cache identities are isolated')
    handlers['sub-fastwhisper-backend']('whisper')
    handlers['sub-fastwhisper']()
    check(#jobs == 1, 'switch back to Whisper reuses original cache')
    handlers['sub-fastwhisper-backend']('qwen')
    handlers['sub-fastwhisper']()
    check(#jobs == 1, 'switch back to Qwen reuses its cache')
    handlers['sub-fastwhisper-backend-menu']()
    local menu = utils.parse_json(commands[#commands][4])
    check(menu.items[2].active and menu.items[1].value[2] == 'sub_fastwhisper', 'menu selection and receiver agree')
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
    jobs[1].callback(true, {status = 0, stdout = utils.format_json({choices = {{message = {
        content = '00:00:00,000 --> 00:00:02,000 | Translation in cache.'}}}})})
    check(cache.read(external) == good and not cache.read(external:gsub('%.srt$', '.translate.srt')),
        'manual translation never writes next to selected source subtitle')
    local translated
    for _, command in ipairs(commands) do
        if command[1] == 'sub-add' and command[2]:find('%.translate%.srt$') then translated = command[2] end
    end
    check(translated and translated:gsub('\\', '/'):find('/results/', 1, true) and
        cache.valid_srt(cache.read(translated)), 'translated SRT is in cache')
    check(cache.read(translated .. '.complete') == cache.digest(cache.read(translated)),
        'translation completion checksum recorded')
    hooks.on_unload()
    boot(a)
    events['file-loaded']()
    handlers['sub-fastwhisper-manager']()
    local manager = utils.parse_json(commands[#commands][4])
    check(manager.type == 'ai-subtitle-manager' and manager.items[3].title:find('有有效'), 'management shows current completed cache')
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
end
host.add_timeout(0.1, function()
    local ok, err = pcall(suite)
    _G.mp = host
    host.msg.info(ok and ('ASR CACHE MOCK PASS: ' .. passed .. ' assertions') or ('ASR CACHE MOCK FAIL: ' .. tostring(err)))
    host.commandv('quit', ok and 0 or 3)
end)
