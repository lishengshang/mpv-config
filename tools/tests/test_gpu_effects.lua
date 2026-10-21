-- Dependency-free controller regression, hosted by mpv's Lua runtime.
-- Run: mpv --no-config --load-scripts=no --script=tools/tests/test_gpu_effects.lua --idle=yes
local host, json = mp, require 'mp.utils'
local function copy(value) return json.parse_json(json.format_json(value)) end
local state, handlers, hooks, jobs, timers, observations, missing, commands
local function boot()
    state = {vf = {}, ['glsl-shaders'] = {}, ['video-params'] = {w = 640, h = 360}}
    handlers, hooks, jobs, timers, observations, missing, commands = {}, {}, {}, {}, {}, {}, {}
    local fake = {msg = {info = function() end, error = function() end}, get_script_name = function() return 'gpu_effects' end}
    function fake.get_property_native(key, default) return copy(state[key] or default) end
    function fake.get_property(key) return state[key] end
    function fake.set_property_native(key, value)
        if state.fail_shader and key == 'glsl-shaders' then return nil, 'shader failed' end
        state[key] = copy(value)
        return true
    end
    function fake.command_native(args) return args[2]:gsub('~~/', 'config/') end
    function fake.commandv(cmd, op, arg, payload)
        commands[#commands + 1] = {cmd, op, arg, payload}
        if cmd == 'vf' then
            if op == 'add' then
                if state.fail_vf then return nil, 'initialization failed' end
                local path = arg:match('file=%%%d+%%(.+)')
                local list = {}
                for _, f in ipairs(state.vf) do if f.label ~= 'gpu-effects' then list[#list + 1] = f end end
                list[#list + 1] = {name = 'vapoursynth', label = 'gpu-effects', params = {file = path}}
                state.vf = list
            elseif op == 'remove' then
                for i = #state.vf, 1, -1 do if state.vf[i].label == 'gpu-effects' then table.remove(state.vf, i) end end
            elseif op == 'toggle' then
                local want = (arg or ''):gsub('^@', '')
                for _, f in ipairs(state.vf) do
                    if f.label == want then f.enabled = f.enabled == false end
                end
            elseif op == 'clr' then state.vf = {} end
        end
        return true
    end
    function fake.command_native_async(spec, callback)
        jobs[#jobs + 1] = {spec = spec, callback = callback}
        return #jobs
    end
    function fake.abort_async_command(id) jobs[id].aborted = true end
    function fake.add_timeout(_, callback)
        local t = {callback = callback, kill = function(self) self.killed = true end}
        timers[#timers + 1] = t
        return t
    end
    function fake.osd_message(message) state.osd = message end
    function fake.register_script_message(id, callback) handlers[id] = callback end
    function fake.observe_property(key, _, callback) observations[key] = callback end
    function fake.add_hook(id, _, callback) hooks[id] = callback end
    function fake.register_event(id, callback) hooks[id] = callback end
    function fake.enable_messages() end
    local imports = {mp = fake, ['mp.options'] = {read_options = function() end}}
    imports['mp.utils'] = {
        format_json = json.format_json, parse_json = json.parse_json,
        join_path = function(a, b) return a .. '/' .. b end,
        file_info = function(path) if not missing[path] then return {is_file = true} end end}
    local chunk = assert(loadfile('scripts/gpu-effects.lua'))
    setfenv(chunk, setmetatable({require = function(id) return imports[id] or require(id) end}, {__index = _G}))
    chunk()
end
local passed = 0
local function check(ok, message) assert(ok, message); passed = passed + 1 end
local function active() return state['user-data/gpu-effects'].active end
local function complete(result)
    jobs[#jobs].callback(true, {status = result.ok and 0 or 1, stdout = json.format_json(result)}, nil)
end
local function start_vs(id)
    handlers.toggle(id or 'NR_BILATERAL_CUDA')
    complete({ok = true})
    hooks['log-message']({prefix = 'vapoursynth', level = 'debug', text = 'initialized.\n'})
end
local function suite()
    boot()
    state['glsl-shaders'] = {'user.glsl'}
    state.vf = {{name = 'crop', label = 'user-crop'}}
    handlers.toggle('ArtCNN_C4F16')
    check(active() == 'ArtCNN_C4F16', 'light selection')
    handlers.toggle('ArtCNN_C4F32')
    handlers.reset()
    check(state['glsl-shaders'][1] == 'user.glsl', 'restore original shader across replacement')
    check(#state.vf == 1, 'reset preserves unrelated filter')
    start_vs()
    check(active() == 'NR_BILATERAL_CUDA' and #state.vf == 2, 'VS preserves unrelated filter')
    start_vs('NR_DFTTEST_CUDA')
    check(active() == 'NR_DFTTEST_CUDA' and #state.vf == 2, 'VS replacement does not stack')
    handlers.toggle('NR_DFTTEST_CUDA')
    check(active() == '' and #state.vf == 1, 'repeat VS closes without cycling counter')
    handlers.toggle('ArtCNN_C4F16')
    start_vs()
    check(state['glsl-shaders'][1] == 'user.glsl', 'shader to VS restores baseline')
    handlers.toggle('ArtCNN_C4F16')
    check(#state.vf == 1 and active() == 'ArtCNN_C4F16', 'VS to shader removes owned VF')
    hooks.on_load()
    check(active() == '' and state['glsl-shaders'][1] == 'user.glsl', 'next file resets shader')
    start_vs()
    hooks.on_load()
    check(active() == '' and #state.vf == 1, 'next file resets owned VS')
    start_vs()
    handlers['clear-vf']()
    start_vs()
    check(active() == 'NR_BILATERAL_CUDA', 'clear then same key enables again')
    handlers.toggle('ArtCNN_C4F16')
    handlers['clear-shaders']()
    handlers.reset()
    check(#state['glsl-shaders'] == 0, 'explicit clear never resurrects baseline')
    handlers.toggle('ArtCNN_C4F16')
    state['glsl-shaders'] = {'profile.glsl'}
    observations['glsl-shaders']()
    handlers.reset()
    check(state['glsl-shaders'][1] == 'profile.glsl', 'profile override respected')

    boot()
    handlers.toggle('ArtCNN_C4F16')
    missing['config/..//VSScript.dll'] = true
    handlers.toggle('NR_BILATERAL_CUDA')
    check(#jobs == 0 and active() == 'ArtCNN_C4F16' and state.osd:find('VapourSynth'), 'no VS hint preserves shader')
    missing = {}
    handlers.toggle('SR_ARTCNN_TRT')
    complete({ok = false, reason = '缺少模型：test.onnx'})
    check(active() == 'ArtCNN_C4F16' and state.osd:find('缺少模型'), 'probe failure preserves current')
    handlers.toggle('NR_BILATERAL_CUDA')
    handlers.reset()
    complete({ok = true})
    check(active() == '' and jobs[#jobs].aborted, 'reset cancels stale callback')
    handlers.toggle('NR_BILATERAL_CUDA')
    hooks.on_load()
    complete({ok = true})
    check(active() == '', 'next file cancels stale callback')
    handlers.toggle('NR_BILATERAL_CUDA')
    handlers['clear-vf']()
    complete({ok = true})
    check(#state.vf == 0, 'clear cancels stale callback')
    handlers.toggle('NR_BILATERAL_CUDA')
    timers[#timers].callback()
    complete({ok = true})
    check(state.osd:find('超时') and #state.vf == 0, 'probe timeout')
    handlers.toggle('NR_BILATERAL_CUDA')
    state.vf = {{name = 'crop'}}
    complete({ok = true})
    check(#state.vf == 1 and active() == '', 'external edit cancels application')
    handlers.toggle('NR_BILATERAL_CUDA')
    handlers.toggle('NR_DFTTEST_CUDA')
    jobs[#jobs - 1].callback(true, {status = 0, stdout = '{"ok":true}'})
    complete({ok = true})
    hooks['log-message']({prefix = 'vapoursynth', level = 'debug', text = 'initialized.\n'})
    check(active() == 'NR_DFTTEST_CUDA', 'latest request wins')
    state.fail_vf = true
    handlers.toggle('NR_BILATERAL_CUDA')
    complete({ok = true})
    check(active() == 'NR_DFTTEST_CUDA' and state.osd:find('初始化失败'), 'initialization failure retains old VF')
    state.fail_shader = true
    handlers.toggle('ArtCNN_C4F16')
    check(active() == 'NR_DFTTEST_CUDA', 'failed shader setting restores VF')
    state.fail_shader = nil
    state.vf = {}
    observations.vf()
    check(active() == '', 'external VF clear updates status')
    state['user-data/uosc/menu/type'] = 'gpu-effects'
    handlers.menu()
    local data = json.parse_json(commands[#commands][4])
    check(data.type == 'gpu-effects' and (data.title or ''):find('画面增强'), 'menu title is user-facing')
    check(#data.items == 11 and data.items[1].title:find('当前效果'),
        'requirement entries plus compare, restore, advanced and help')
    local rife = data.items[3].items[1]
    check(rife.title == '动作更流畅 · 补帧（常用）' and rife.items[4].value[2] == 'gpu_effects',
        'preset opens a detail page and routes through script messages')
    check(rife.items[1].title:find('适合：') and rife.items[2].title:find('条件：') and
        rife.items[3].title:find('负担：'), 'detail page answers use, condition and cost before enabling')
    check(data.items[8].title:find('暂时关闭') and data.items[9].title:find('恢复开启前效果')
        and data.items[10].title:find('高级'), 'compare, restore and advanced are separate actions')
    check(data.items[10].items[1].title:find('技术详情'), 'advanced keeps model/backend details')
    observations.vf()
    check(commands[#commands][3] == 'update-menu', 'open menu updates after external changes')
    boot()
    state['glsl-shaders'] = {'user.glsl'}
    handlers.toggle('ArtCNN_C4F16')
    state.fail_shader = true
    start_vs()
    check(active() == 'ArtCNN_C4F16' and #state.vf == 0, 'failed baseline restore rolls VS back')
    boot()
    start_vs()
    handlers.toggle('NR_DFTTEST_CUDA')
    complete({ok = true})
    check(state['user-data/gpu-effects'].pending == 'NR_DFTTEST_CUDA' and active() == 'NR_BILATERAL_CUDA',
        'command acceptance is not initialization success')
    state.vf[#state.vf + 1] = {name = 'crop', label = 'external'}
    hooks['log-message']({prefix = 'vapoursynth', level = 'fatal', text = 'Python exception: broken preset'})
    timers[#timers].callback()
    check(active() == 'NR_BILATERAL_CUDA' and #state.vf == 2, 'deferred failure preserves old VS and new external edit')
    handlers.toggle('NR_DFTTEST_CUDA')
    complete({ok = true})
    state.vf = {}
    hooks['log-message']({prefix = 'vapoursynth', level = 'error', text = 'old error after external clear'})
    handlers.toggle('ArtCNN_C4F16')
    check(#state.vf == 0, 'cancel never resurrects externally cleared VS')
    boot()
    start_vs()
    handlers.toggle('SR_ARTCNN_TRT')
    hooks['log-message']({prefix = 'vapoursynth', level = 'error', text = 'frame failed'})
    complete({ok = true})
    check(active() == '' and #state.vf == 0 and state['user-data/gpu-effects'].pending == '',
        'late frame failure closes dead slot and cancels pending probe')

    -- 对比：暂时关闭不丢失选择，可再切回
    boot()
    start_vs()
    handlers.compare()
    check(active() == '' and state['user-data/gpu-effects'].compare == 'NR_BILATERAL_CUDA' and #state.vf == 1,
        'compare turns VS off without losing the selection')
    handlers.compare()
    check(active() == 'NR_BILATERAL_CUDA' and state['user-data/gpu-effects'].compare == '', 'compare restores VS')
    handlers.reset()
    check(active() == '' and #state.vf == 0, 'reset after compare removes VS')

    boot()
    state['glsl-shaders'] = {'user.glsl'}
    handlers.toggle('ArtCNN_C4F16')
    handlers.compare()
    check(active() == '' and state['glsl-shaders'][1] == 'user.glsl' and
        state['user-data/gpu-effects'].compare == 'ArtCNN_C4F16', 'compare shader falls back to baseline')
    handlers.compare()
    check(active() == 'ArtCNN_C4F16' and #state['glsl-shaders'] == 1, 'compare restores shader')
    state['glsl-shaders'] = {'profile.glsl'}
    observations['glsl-shaders']()
    check(state['user-data/gpu-effects'].compare == '' and active() == '', 'external shader edit ends compare')

    -- 说明与状态提示
    boot()
    handlers.toggle('ArtCNN_C4F16')
    check(state.osd:find('用途：') and state.osd:find('条件：') and state.osd:find('负担：') and state.osd:find('操作：'),
        'apply message answers use, condition, cost and undo')

    boot()
    state['video-out-params'] = {w = 640, h = 360}
    state['video-target-params'] = {w = 400, h = 225}
    state['user-data/uosc/menu/type'] = 'gpu-effects'
    handlers.menu()
    local small = json.parse_json(commands[#commands][4])
    check(#small.items == 12 and small.items[2].title:find('估算放大') and
        small.items[2].title:find('滤镜输出 640×360') and small.items[2].title:find('渲染目标 400×225'),
        'header reports estimated scale from filter output and render target')
    local page = small.items[3].items[1].items[1]
    check(page.title == '动画放大 · 省资源' and page.items[1].title:find('适合：') and
        page.items[4].hint:find('估算倍率未达触发范围') and page.items[4].hint:find('CTRL+ALT+1', 1, true),
        'detail page warns the estimated scale misses the trigger range')

    boot()
    handlers.toggle('NR_BILATERAL_CUDA')
    complete({ok = true})
    handlers.menu()
    local pend = json.parse_json(commands[#commands][4])
    check(pend.items[4].items[1].items[4].hint:find('正在准备'), 'pending state is visible in the menu')
    hooks['log-message']({prefix = 'vapoursynth', level = 'debug', text = 'initialized.\n'})
    handlers.menu()
    local ready = json.parse_json(commands[#commands][4])
    check(ready.items[4].items[1].hint:find('负担低') and ready.items[4].items[1].active,
        'active leaf after initialization')

    -- 对比中切换方案：新方案生效并结束旧对比，恢复仍能回到原始基线
    boot()
    state['glsl-shaders'] = {'user.glsl'}
    handlers.toggle('ArtCNN_C4F16')
    handlers.compare()
    check(active() == '' and state['glsl-shaders'][1] == 'user.glsl', 'compare shader suspends first')
    handlers.toggle('ArtCNN_C4F32')
    check(active() == 'ArtCNN_C4F32' and #state['glsl-shaders'] == 1 and
        state['glsl-shaders'][1]:find('C4F32') and state['user-data/gpu-effects'].compare == '',
        'switching shader preset during compare ends compare and keeps the new preset')
    handlers.reset()
    check(active() == '' and #state['glsl-shaders'] == 1 and state['glsl-shaders'][1] == 'user.glsl',
        'reset after compare switch restores the original shader list')

    -- 对比中切换 VS：成功替换后结束旧快照，切回时启用的是新滤镜
    boot()
    start_vs('NR_BILATERAL_CUDA')
    handlers.compare()
    check(active() == '' and state['user-data/gpu-effects'].compare == 'NR_BILATERAL_CUDA',
        'VS compare snapshot binds to the selected preset')
    handlers.toggle('NR_DFTTEST_CUDA')
    complete({ok = true})
    hooks['log-message']({prefix = 'vapoursynth', level = 'debug', text = 'initialized.\n'})
    check(active() == 'NR_DFTTEST_CUDA' and state['user-data/gpu-effects'].compare == '',
        'successful replacement ends the old compare snapshot')
    handlers.compare()
    check(active() == '' and state['user-data/gpu-effects'].compare == 'NR_DFTTEST_CUDA',
        'the replaced preset can be compared')
    handlers.compare()
    local owned
    for _, f in ipairs(state.vf) do if f.label == 'gpu-effects' then owned = f end end
    check(owned and owned.enabled ~= false and active() == 'NR_DFTTEST_CUDA' and
        state['user-data/gpu-effects'].compare == '', 'compare resumes the same filter identity')

    -- 初始化期间禁止对比
    boot()
    handlers.toggle('NR_BILATERAL_CUDA')
    handlers.compare()
    check(state.osd:find('正在准备') and active() == '' and state['user-data/gpu-effects'].compare == '',
        'compare is blocked while initializing')

    -- 暂停时 VS 占位黑帧只刷新一次；旧任务、取消和恢复播放不得补步。
    local function paused_dummy()
        boot()
        state.pause = true
        handlers.toggle('MIX_SR_MEMC_TRT')
        complete({ok = true})
        hooks['log-message']({prefix = 'vapoursynth', level = 'warn', text = 'Returning black dummy frame with 0 duration.\n'})
        local before = #timers
        hooks['log-message']({prefix = 'vapoursynth', level = 'debug', text = 'initialized.\n'})
        check(#timers == before + 1, 'paused dummy frame schedules one refresh after init')
        return timers[#timers]
    end
    local refresh = paused_dummy()
    local before = #commands
    refresh.callback()
    check(#commands == before + 1 and commands[#commands][1] == 'frame-step' and state.pause,
        'dummy frame refresh requests a frame while keeping pause')
    refresh = paused_dummy()
    handlers.reset()
    before = #commands
    refresh.callback()
    check(#commands == before, 'reset invalidates a queued dummy-frame refresh')
    refresh = paused_dummy()
    state.pause = false
    before = #commands
    refresh.callback()
    check(#commands == before, 'resuming playback cancels the paused refresh')
    boot()
    state.pause = true
    handlers.toggle('NR_BILATERAL_CUDA')
    complete({ok = true})
    before = #timers
    hooks['log-message']({prefix = 'vapoursynth', level = 'debug', text = 'initialized.\n'})
    check(#timers == before, 'paused initialization without dummy frames does not step')
    hooks['log-message']({prefix = 'vapoursynth', level = 'warn', text = 'Returning black dummy frame with 0 duration.\n'})
    before = #timers
    hooks['log-message']({prefix = 'vapoursynth', level = 'debug', text = 'initialized.\n'})
    check(#timers == before + 1, 'paused seek reinitialization refreshes an already active VS filter')
    refresh = timers[#timers]
    before = #commands
    refresh.callback()
    check(#commands == before + 1 and commands[#commands][1] == 'frame-step',
        'paused seek replaces its zero-duration placeholder')

    -- 去色带是独立开关，不在恢复范围内
    boot()
    state.deband = true
    state['user-data/uosc/menu/type'] = 'gpu-effects'
    handlers.menu()
    local dd = json.parse_json(commands[#commands][4])
    check(dd.items[6].title:find('去色带：已开启'), 'deband shows its own on/off state')
    handlers.reset()
    check(state.deband == true, 'restore does not change the deband switch')
end
host.add_timeout(0.1, function()
    local ok, err = pcall(suite)
    host.msg.info(ok and ('GPU UX MOCK PASS: ' .. passed .. ' assertions') or ('GPU UX MOCK FAIL: ' .. tostring(err)))
    host.commandv('quit', ok and 0 or 3)
end)
