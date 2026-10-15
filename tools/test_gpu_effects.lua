-- Dependency-free controller regression, hosted by mpv's Lua runtime.
-- Run: mpv --no-config --load-scripts=no --script=tools/test_gpu_effects.lua --idle=yes
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
    check(data.type == 'gpu-effects' and #data.items == 7, 'menu groups and reset/help entries')
    check(data.items[3].items[1].value[2] == 'gpu_effects', 'uosc routes normalized script identifier')
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
end
host.add_timeout(0.1, function()
    local ok, err = pcall(suite)
    host.msg.info(ok and ('GPU UX MOCK PASS: ' .. passed .. ' assertions') or ('GPU UX MOCK FAIL: ' .. tostring(err)))
    host.commandv('quit', ok and 0 or 3)
end)
