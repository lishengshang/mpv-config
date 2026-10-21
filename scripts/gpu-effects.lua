-- Local GPU UX controller. Uses upstream uosc Menu API and mpv filter labels.
-- Algorithms and user tuning remain in the original shaders/.vpy presets.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local o = {runtime_path = '', probe_timeout = 20, initialization_timeout = 300}
options.read_options(o, 'gpu-effects')
local name, label = mp.get_script_name(), 'gpu-effects'
local presets, order = {}, {}
-- “高级”里仍按算法分组（group 1-4）；面向用户的入口在下面按“需求”组织。
local groups = {'轻量超分', '补帧', '降噪', '超分与组合'}
local function preset(id, label, group, key, shader, meta)
    -- label 面向用户（效果 + 取向），id 面向维护与键位；tech 只在“高级”里露出。
    local p = {id = id, title = label, label = label, group = group, key = key, shader = shader,
        use = meta.use, condition = meta.condition, cost = meta.cost, tech = meta.tech,
        cost_short = meta.cost_short, min_ratio = meta.min_ratio}
    p.path = mp.command_native({'expand-path', shader and
        ('~~/shaders/ArtCNN/' .. id .. '.glsl') or ('~~/vs/' .. id .. '.vpy')})
    presets[id] = p
    order[#order + 1] = p
end
preset('ArtCNN_C4F16', '动画放大 · 省资源', 1, 'CTRL+ALT+1', true, {
    use = '低分辨率动画或番剧放大到更大窗口/屏幕后，线条与边缘更干净。',
    condition = '只在画面确实需要放大时生效（目标宽高都要超过源的 1.3 倍）；按原始尺寸观看可能看不出变化。',
    cost = 'GPU 着色器实时处理，负担相对较低；实际流畅度取决于片源与设备。',
    tech = 'ArtCNN C4F16 · glsl shader · 无需 VS 运行时', cost_short = '负担低', min_ratio = 1.3})
preset('ArtCNN_C4F32', '动画放大 · 增强', 1, 'CTRL+ALT+2', true, {
    use = '低分辨率动画或番剧放大到更大窗口/屏幕后，线条与边缘更干净（模型更大）。',
    condition = '只在画面确实需要放大时生效（目标宽高都要超过源的 1.3 倍）；按原始尺寸观看可能看不出变化。',
    cost = '比 C4F16 更重；设备余量不足时可能出现掉帧。',
    tech = 'ArtCNN C4F32 · glsl shader · 无需 VS 运行时', cost_short = '负担中等', min_ratio = 1.3})
preset('MEMC_RIFE_TRT', '动作更流畅 · 补帧（常用）', 2, '$', false, {
    use = '运动画面不够顺滑时，在原有帧之间生成中间帧。',
    condition = '当前预设为帧率 2 倍（如 24→48、30→60）；源高于 1440p 会先降采样再补帧。',
    cost = 'TRT 首次使用需要构建引擎，可能较慢；能否实时取决于片源与设备。',
    tech = 'RIFE 4.26 · TRT · H_Pre=1440 · 需 VS 运行时与模型', cost_short = '负担高'})
preset('MEMC_DRBA_TRT', '动作更流畅 · 动画补帧（对比方案）', 2, '%', false, {
    use = '动画补帧的备选，观感取向与 RIFE 不同。',
    condition = '同为帧率 2 倍；源高于 1440p 会先降采样。',
    cost = '本机未做两者性能对比；不同片源表现可能不同，建议自己对比。',
    tech = 'distilDRBA v2_lite · TRT · H_Pre=1440 · 需 VS 运行时与模型', cost_short = '负担高'})
preset('MEMC_RIFE_DML', '动作更流畅 · 兼容模式', 2, '@', false, {
    use = 'TRT 不可用（非 RTX，或引擎构建失败）时的补帧方案。',
    condition = '同为帧率 2 倍；本机未做两后端的性能对比。',
    cost = '负担高；先确认能否实时，再决定是否长期使用。',
    tech = 'RIFE 4.26 · DirectML · 需 VS 运行时与模型', cost_short = '负担高'})
preset('MEMC_DRBA_DML', '动画补帧 · 兼容模式', 2, '#', false, {
    use = '动画补帧的备选方案（不走 TRT 时使用）。',
    condition = '同为帧率 2 倍；本机未做两后端的性能对比。',
    cost = '负担高；先确认能否实时。',
    tech = 'distilDRBA v2_lite · DirectML · H_Pre=1440 · 需 VS 运行时与模型', cost_short = '负担高'})
preset('NR_BILATERAL_CUDA', '减少噪点 · 轻度', 3, '!', false, {
    use = '画面有轻微颗粒或噪点时做轻度空间降噪。',
    condition = '只处理亮度平面，不改变分辨率；噪点很强时可能不够。',
    cost = '负担低，不需要 ONNX 模型。',
    tech = 'k7f.BILA_NV · CUDA/RTC · 无需 ONNX 模型', cost_short = '负担低'})
preset('NR_DFTTEST_CUDA', '减少噪点 · 中等（时空）', 3, '+', false, {
    use = '老片、低码率源这类有波动的噪点。',
    condition = '频域时空降噪（强度 4.0）；可能一起抹掉细微纹理。',
    cost = '负担中等。',
    tech = 'k7f.DFTT_NV · Nr_Lv=4.0 · CUDA/NVRTC', cost_short = '负担中等'})
preset('NR_BM3D_CUDA', '减少噪点 · 强', 3, "'", false, {
    use = '噪点明显、需要更强处理时。',
    condition = 'Nr_Lv=[5,0,0]；本仓库既有的强降噪档，可能损失纹理（本机未做强度对比）。',
    cost = '负担高。',
    tech = 'k7f.BM3D_NV · Nr_Lv=[5,0,0] · CUDA/RTC', cost_short = '负担高'})
preset('SR_ARTCNN_TRT', '动画放大 · ArtCNN 2×', 4, '&', false, {
    use = '动画/番剧的 AI 2× 放大（VS 版 ArtCNN）。',
    condition = '源高于 720p 会先降到 720p 处理，输出高度上限 1440p；不是“一键 4K”。',
    cost = 'TRT 首次构建较慢；纹理与线条按模型风格变化。',
    tech = 'ArtCNN R8F64 · TRT · H_Pre=720 / H_Max=1440 · 需 VS 运行时与模型', cost_short = '负担高'})
preset('SR_ARTCNN_CHROMA_TRT', '动画放大 · ArtCNN 2× 含色度重建', 4, 'ALT+&', false, {
    use = '在 ArtCNN 2× 放大的同时重建色度（4:2:0 BT.709）。',
    condition = '同样受 H_Pre=720 / H_Max=1440 限制。',
    cost = '比普通 ArtCNN 略高。',
    tech = 'ArtCNN R8F64 + Chroma · TRT · 需 VS 运行时与模型', cost_short = '负担高'})
preset('SR_AnimeJaNaiV2_TRT', '动画放大 · AnimeJaNai V2', 4, 'ALT+^', false, {
    use = '动画 2× 放大；V3 之前的版本，保留用于与 AnimeJaNai V3 做 A/B 对比。',
    condition = 'H_Pre=720 / H_Max=1440；输出受参数限制。',
    cost = 'TRT 首次构建较慢；与 V3 的差异需要自己对比。',
    tech = 'AnimeJaNai V2L1 x2 fp16 · TRT · 需 VS 运行时与模型', cost_short = '负担高'})
preset('SR_AnimeJaNaiV3_TRT', '动画放大 · AnimeJaNai V3 锐化', 4, '*', false, {
    use = '动画 2× 放大，模型为 sharp HD 变体。',
    condition = 'H_Pre=720 / H_Max=1440。',
    cost = 'TRT 首次构建较慢；出现过锐或振铃时用“暂时关闭，对比效果”判断。',
    tech = 'AnimeJaNai V3L1 sharp HD x2 · TRT · 需 VS 运行时与模型', cost_short = '负担高'})
preset('SR_AnimeJaNaiV2_DML', '动画放大 · AnimeJaNai V2（兼容）', 4, '^', false, {
    use = 'AnimeJaNai V2 的备选方案（不走 TRT 时使用）。',
    condition = '非 RTX 或 TRT 不可用时尝试。',
    cost = '本机未做两后端的性能对比。',
    tech = 'AnimeJaNai V2L1 x2 fp16 · DirectML · 需 VS 运行时与模型', cost_short = '负担高'})
preset('SR_HFA2k_TRT', '真人 AI 超分 · 试用', 4, '(', false, {
    use = '真人/实拍内容的 AI 2× 放大；本机未做片源级验证，属于试用项。',
    condition = '模型为 2×，但内部先把高于 720p 的源降到 720p 处理，输出高度上限 1080p；不是“一键 4K”。',
    cost = '首次构建引擎较慢；真人片源的观感收益需要自己对比确认。',
    tech = 'Phhofm HFA2kCompact x2 · TRT · H_Pre=720 / H_Max=1080 · 需 VS 运行时与模型', cost_short = '负担高'})
preset('SR_Anime1080Fixer_TRT', '动画修复 · 不放大', 4, ')', false, {
    use = '分辨率已经够用，但想尝试修复动画线条与压缩瑕疵。',
    condition = '模型是 1×，画面尺寸基本不变；H_Pre=1080 / H_Max=1440。',
    cost = 'TRT 首次构建较慢；修复类模型可能改变原始质感。',
    tech = 'Zarxrax Anime1080Fixer SUC x1 · TRT · 需 VS 运行时与模型', cost_short = '负担高'})
preset('MIX_SR_MEMC_TRT', '超分＋补帧 · 负担较高', 4, 'ALT+_', false, {
    use = '同时需要更清晰和更流畅时（动画）。',
    condition = '超分只在源 ≤720p 时生效（先降到 720p，输出上限 1200p）；补帧只在源 ≤32fps 时生效，且高于 1200p 的输入会先降到 1200p 再补帧；1080p 源只补帧。',
    cost = '负担最高，建议先单独确认两者都能实时。',
    tech = 'ArtCNN R8F64 + RIFE 4.25lite · TRT · 需 VS 运行时与模型', cost_short = '负担最高'})

local function canon(path)
    return (path or ''):gsub('\\', '/'):lower()
end
local function same(a, b)
    return utils.format_json(a) == utils.format_json(b)
end
local function shaders() return mp.get_property_native('glsl-shaders', {}) end
local function filters() return mp.get_property_native('vf', {}) end
local function owned_filter()
    for _, f in ipairs(filters()) do
        if f.label == label then return f end
    end
end
local baseline, applied_shader, pending, generation = nil, nil, nil, 0
local paused_placeholder
local suspended = nil      -- 对比快照：{id=预设, shader=布尔, path=滤镜文件}
local expected_shaders     -- 脚本自身最后一次写入的 shader 列表（用于区分内部写入与外部改写）
local describe, menu_hint, enough_upscale, source_state  -- 定义在 missing() 之后
local function selected()
    if pending and pending.stage == 'init' then return pending.previous_id end
    local f = owned_filter()
    for _, p in ipairs(order) do
        if p.shader and applied_shader then
            local list = shaders()
            if #list == 1 and canon(list[1]) == canon(p.path) then return p.id end
        elseif f and f.enabled ~= false and f.params and canon(f.params.file) == canon(p.path) then
            return p.id
        end
    end
end
-- 菜单里“选中了哪一项”要包含被暂时关闭（对比中）的方案。
local function chosen()
    if suspended then return suspended.id end
    return selected()
end
-- 所有由本脚本发起的 shader 写入都走这里，便于观察器区分内部写入与外部改写。
local function set_shaders(list)
    expected_shaders = list
    return mp.set_property_native('glsl-shaders', list)
end

local last_message = '增强默认关闭；轻量 shader 无需 VS。'
local refresh_menu
local function publish()
    mp.set_property_native('user-data/gpu-effects', {
        active = selected() or '', pending = pending and pending.id or '',
        compare = suspended and suspended.id or '', message = last_message})
    if refresh_menu then refresh_menu() end
end
local function say(message)
    last_message = message
    mp.msg.info(message)
    mp.osd_message(message, 5)
    publish()
end
local function rollback_filter(job)
    local current, slot = filters(), nil
    for i, f in ipairs(current) do
        if f.label == label and f.params and canon(f.params.file) == canon(presets[job.id].path) then slot = i end
    end
    -- An external clear/replacement owns its new state; don't resurrect our slot.
    if not slot then return true end
    table.remove(current, slot)
    for _, f in ipairs(job.previous_vf) do
        if f.label == label then table.insert(current, math.min(slot, #current + 1), f); break end
    end
    return mp.set_property_native('vf', current)
end
local function cancel(rollback)
    local restored, reason = true, nil
    generation = generation + 1
    paused_placeholder = nil
    if pending then
        local old = pending
        pending = nil
        if old.timer then old.timer:kill() end
        if old.request then mp.abort_async_command(old.request) end
        if old.stage == 'init' then mp.enable_messages('error') end
        if rollback ~= false and old.stage == 'init' then
            local ok, err = rollback_filter(old)
            if not ok then restored, reason = false, err; mp.msg.error('GPU 滤镜回滚失败：' .. tostring(err)) end
        end
    end
    return restored, reason
end

local function restore_shader(force)
    -- 外部（profile/其他脚本）改写时尊重其新列表；对比模式下显式写回基线。
    if applied_shader and (force or same(shaders(), applied_shader)) then
        local ok, err = set_shaders(baseline or {})
        if not ok then return nil, err end
    end
    baseline, applied_shader = nil, nil
    return true
end
local function reset(quiet)
    cancel(false)
    local was_suspended = suspended ~= nil
    suspended = nil
    if owned_filter() then
        local ok, err = mp.commandv('vf', 'remove', '@' .. label)
        if not ok then say('关闭 GPU 滤镜失败：' .. tostring(err)); return end
    end
    local ok, err = restore_shader(was_suspended)
    if not ok then say('恢复 shader 失败：' .. tostring(err)); return end
    if quiet then last_message = '新文件：GPU 临时增强已关闭。'; publish()
    else say('已恢复开启前效果：本次增强已撤销，其他滤镜与调参保留。') end
end

-- “暂时关闭，对比效果”：保留所选方案，只在当前视频里切回开启前的画面。
local function compare()
    if pending then say('正在准备（尚未生效），请等待完成或再次点击取消后再对比。'); return end
    local id = chosen()
    if not id then say('当前没有可对比的增强；先从上面的需求入口开启一项。'); return end
    local p = presets[id]
    -- 滤镜身份必须与所选方案一致，避免把别的方案切掉。
    local function own_filter_matches()
        local f = owned_filter()
        return f and f.params and canon(f.params.file) == canon(p.path)
    end
    if suspended then
        if suspended.id ~= id then
            suspended = nil
            say('对比中的方案已被替换（现为“' .. p.label .. '”），已结束对比。'); publish(); return
        end
        if p.shader then
            local ok, err = set_shaders(applied_shader or {})
            if not ok then say('恢复增强失败：' .. tostring(err)); return end
        else
            if not own_filter_matches() then
                suspended = nil
                say('增强滤镜已不存在，已退出对比模式。'); publish(); return
            end
            if owned_filter().enabled == false then
                local ok, err = mp.commandv('vf', 'toggle', '@' .. label)
                if not ok then say('恢复增强失败：' .. tostring(err)); return end
            end
        end
        suspended = nil
        say('已恢复增强：' .. p.label .. '\n可再次选择“暂时关闭，对比效果”切回原画面。')
    else
        if p.shader then
            suspended = {id = id, shader = true}
            local ok, err = set_shaders(baseline or {})
            if not ok then suspended = nil; say('暂时关闭失败：' .. tostring(err)); return end
        else
            if not own_filter_matches() then
                say('当前滤镜与所选方案不一致，请重新选择方案后再对比。'); return
            end
            if owned_filter().enabled ~= false then
                local ok, err = mp.commandv('vf', 'toggle', '@' .. label)
                if not ok then say('暂时关闭失败：' .. tostring(err)); return end
            end
            suspended = {id = id, shader = false, path = p.path}
        end
        say('已暂时关闭增强（对比原画面）：' .. p.label .. '\n再选一次“暂时关闭，对比效果”即可切回。')
    end
    publish()
end

local function apply(p)
    -- Labels isolate the slot; handle both synchronous and deferred init failure.
    if p.shader then
        local old_filter = owned_filter()
        local old_filters = filters()
        local old_shaders = shaders()
        if old_filter then
            local ok, err = mp.commandv('vf', 'remove', '@' .. label)
            if not ok then say('切换失败：' .. tostring(err)); return end
        end
        local ok, err = set_shaders({p.path})
        if not ok then
            if old_filter then mp.set_property_native('vf', old_filters) end
            say('shader 应用失败：' .. tostring(err)); return
        end
        -- 对比中直接切换方案：列表本来就是基线，保留原基线；否则连续切换共享原基线。
        if suspended then suspended = nil
        elseif not applied_shader or not same(old_shaders, applied_shader) then baseline = old_shaders end
        applied_shader = {p.path}
        expected_shaders = {p.path}
    else
        local old_filters = filters()
        local previous_id = chosen()
        local spec = '@' .. label .. ':vapoursynth=file=%' .. #p.path .. '%' .. p.path
        local job = {id = p.id, stage = 'init', previous_vf = old_filters, previous_id = previous_id}
        pending = job
        -- VS initializes lazily; video-reconfig can precede its evaluation.
        -- Subscribe to debug only during initialization for its positive signal.
        mp.enable_messages('debug')
        job.timer = mp.add_timeout(math.max(1, o.initialization_timeout), function()
            if pending == job then cancel(); say('GPU 初始化超时，已恢复原效果。') end
        end)
        say('正在准备（尚未生效）：' .. p.label .. '\n首次 TRT 引擎构建可能较慢；再次选择同一项可取消。')
        local ok, err = mp.commandv('vf', 'add', spec)
        if not ok then
            cancel()
            say('GPU 初始化失败，保留原效果：' .. tostring(err) .. '\n请查看控制台，或运行 tools/verify-gpu.cmd。')
            return
        end
        if not owned_filter() then cancel(); say('GPU 滤镜未建立，请查看控制台。'); return end
        -- 成功替换后结束旧方案的对比状态；失败时 cancel 回滚并保留旧对比。
        return
    end
    local text = '已启用：' .. p.label .. '\n' .. describe(p)
    if p.min_ratio and not enough_upscale(p) then
        text = text .. '\n提示：估算倍率未达到触发范围，本项可能不生效。'
    end
    say(text)
end

local function runtime()
    return mp.command_native({'expand-path', o.runtime_path ~= '' and o.runtime_path or '~~/../'})
end
local function file_exists(path)
    local info = utils.file_info(path)
    return info and info.is_file
end
local function missing(p)
    if not file_exists(p.path) then return '缺少预设文件：' .. p.id end
    if not p.shader then
        for _, part in ipairs({'python.exe', 'VSScript.dll', 'portable.vs', 'Lib', 'vs-plugins'}) do
            if not utils.file_info(utils.join_path(runtime(), part)) then
                return '未检测到完整 VapourSynth 便携运行时（缺少 ' .. part .. '）。\n请安装可选 VS 增强包；轻量 ArtCNN shader 仍可使用。'
            end
        end
    end
end
-- 只读状态事实：滤镜输出尺寸、渲染目标尺寸、估算倍率、是否 HDR。不做自动选型。
-- 渲染目标已包含窗口缩放；黑边、滤镜阶段差异与实际着色器触发条件仍可能有偏差，故只作“估算”。
source_state = function()
    local vp = mp.get_property_native('video-params', {}) or {}
    local op = mp.get_property_native('video-out-params', {}) or {}
    local tp = mp.get_property_native('video-target-params', {}) or {}
    local sw, sh = op.w or vp.w, op.h or vp.h
    local tw, th = tp.w, tp.h
    local valid = function(v) return type(v) == 'number' and v > 0 end
    local sized = valid(sw) and valid(sh) and valid(tw) and valid(th)
    local gamma, prim = tostring(vp.gamma or ''), tostring(vp.primaries or '')
    return {source_w = sized and sw or nil, source_h = sized and sh or nil,
        target_w = sized and tw or nil, target_h = sized and th or nil,
        -- 取较小方向：着色器要求宽高同时超过阈值。
        ratio = sized and math.min(tw / sw, th / sh) or nil,
        hdr = gamma == 'pq' or gamma == 'hlg' or prim == 'bt.2020'}
end
enough_upscale = function(p)
    local st = source_state()
    if not st.ratio or not p.min_ratio then return true end
    return st.ratio > p.min_ratio
end
describe = function(p)
    return '用途：' .. p.use .. '\n条件：' .. p.condition .. '\n负担：' .. p.cost ..
        '\n操作：再次选择同一项关闭；切换下一个视频会恢复默认。'
end
menu_hint = function(p, reason)
    if reason then return '缺组件 · 点击查看原因' end
    if pending and pending.id == p.id then
        return pending.stage == 'init' and '正在准备，尚未生效…' or '正在检查依赖…'
    end
    local parts = {}
    if p.min_ratio and not enough_upscale(p) then parts[#parts + 1] = '估算倍率未达触发范围' end
    if p.cost_short then parts[#parts + 1] = p.cost_short end
    if p.key then parts[#parts + 1] = p.key end
    return table.concat(parts, ' · ')
end
local function toggle(id)
    local p = presets[id]
    if not p then say('未知 GPU 预设：' .. tostring(id)); return end
    if pending and pending.id == id then cancel(); say('已取消依赖检查。'); return end
    cancel()
    if chosen() == id then reset(); return end
    local reason = missing(p)
    if reason then say(reason .. '\n安装说明：docs/gpu-setup.md'); return end
    if not mp.get_property_native('video-params') or mp.get_property_native('idle-active') then
        say('请先加载有视频轨的媒体，再选择画面增强。'); return
    end
    if p.shader then apply(p); return end
    local probe = mp.command_native({'expand-path', '~~/tools/runtime/gpu_probe.py'})
    if not file_exists(probe) then say('缺少依赖检查工具 tools/runtime/gpu_probe.py'); return end
    local token = generation
    local job = {id = id, vf = filters(), shaders = shaders()}
    pending = job
    say('检查依赖：' .. p.title .. '\nTRT 首次初始化可能需要构建引擎。')
    job.timer = mp.add_timeout(math.max(1, o.probe_timeout), function()
        if pending == job then cancel(); say('VS 依赖检查超时，保留原效果。') end
    end)
    job.request = mp.command_native_async({name = 'subprocess', playback_only = false,
        args = {utils.join_path(runtime(), 'python.exe'), probe, p.path},
        capture_stdout = true, capture_stderr = true}, function(success, result, error)
        if token ~= generation or pending ~= job then return end
        job.timer:kill()
        pending = nil
        local data = success and result and utils.parse_json(result.stdout or '')
        if not data or not data.ok or result.status ~= 0 then
            say((data and data.reason or ('VS 检查进程失败：' .. tostring(error or (result and result.status)))) ..
                '\n保留原效果；说明：docs/gpu-setup.md')
            return
        end
        if not same(job.vf, filters()) or not same(job.shaders, shaders()) then
            say('检查期间滤镜已变化，本次应用已取消。'); return
        end
        apply(p)
    end)
end

local function command(action, arg)
    return {'script-message-to', name, action, arg or ''}
end
-- 面向用户的入口：先问“想改善什么”，再按片源类型给少量方案。
-- 模型名、后端与单项 shader 放在“高级”里，普通用户不需要先理解它们。
-- 方案详情页：选择前就能看到“适合 / 条件 / 负担 / 如何撤销”，技术信息再进一层。
local function preset_page(id, current)
    local p = presets[id]
    local reason = missing(p)
    local kids = {}
    if reason then
        kids[#kids + 1] = {title = reason:gsub('\n', ' '), selectable = false, muted = true}
    end
    kids[#kids + 1] = {title = '适合：' .. p.use, selectable = false, muted = true}
    kids[#kids + 1] = {title = '条件：' .. p.condition, selectable = false, muted = true}
    kids[#kids + 1] = {title = '负担：' .. p.cost, selectable = false, muted = true}
    kids[#kids + 1] = {title = '启用此方案（再次选择关闭；下一视频恢复默认）',
        value = command('toggle', p.id), active = current == p.id, muted = reason ~= nil,
        hint = menu_hint(p, reason)}
    kids[#kids + 1] = {title = '技术详情…', items = {
        {title = p.tech, selectable = false, muted = true},
        {title = '键位：' .. (p.key or '无'), selectable = false, muted = true}}}
    return {title = p.label, items = kids, muted = reason ~= nil, active = current == p.id,
        hint = reason and '缺组件 · 点击查看原因' or p.cost_short}
end
local requirements = {
    {title = '放大后更清楚（超分）…', items = {
        {title = '动画 / 番剧…', items = {
            {id = 'ArtCNN_C4F16'}, {id = 'ArtCNN_C4F32'},
            {title = '更多模型与风格…', items = {
                {id = 'SR_AnimeJaNaiV3_TRT'}, {id = 'SR_AnimeJaNaiV2_TRT'},
                {id = 'SR_ARTCNN_TRT'}, {id = 'SR_ARTCNN_CHROMA_TRT'},
                {id = 'SR_AnimeJaNaiV2_DML'}}}}},
        {title = '真人 / 电影…', items = {
            {id = 'SR_HFA2k_TRT'},
            {title = '不要 AI 超分：撤销并回到内置缩放', value = command('reset'),
                hint = '等于“恢复开启前效果”；内置 HQ 算法组继续工作'}}},
        {title = '不确定片源类型…', items = {
            {title = '动画看线条与大面积平涂，真人看皮肤纹理与噪点；选错可用“暂时关闭，对比效果”切回。',
                selectable = false, muted = true},
            {title = '先试最轻的：动画放大 · 省资源', toggle = 'ArtCNN_C4F16', hint = '负担低'}}}}},
    {title = '动作更流畅（补帧）…', items = {
        {id = 'MEMC_RIFE_TRT'}, {id = 'MEMC_RIFE_DML'},
        {id = 'MEMC_DRBA_TRT'}, {id = 'MEMC_DRBA_DML'}}},
    {title = '减少噪点…', items = {
        {id = 'NR_BILATERAL_CUDA'}, {id = 'NR_DFTTEST_CUDA'}, {id = 'NR_BM3D_CUDA'}}},
    {title = '修复动画画面（不放大）…', items = {{id = 'SR_Anime1080Fixer_TRT'}}},
    {title = '渐变有一圈圈条纹（色带）', deband = true, value = {'cycle', 'deband'},
        hint = 'mpv 内置独立开关 · 不受“恢复开启前效果”与跨文件重置影响'},
    {title = '超分＋补帧（负担较高）…', items = {{id = 'MIX_SR_MEMC_TRT'}}},
}
local function resolve(node, current)
    if node.id then return preset_page(node.id, current) end
    local item = {title = node.title, selectable = node.selectable, muted = node.muted, hint = node.hint}
    if node.deband then
        item.title = '去色带：' .. (mp.get_property_native('deband', false) == true and '已开启' or '关闭')
    end
    if node.toggle then item.value = command('toggle', node.toggle)
    elseif node.value then item.value = node.value end
    if node.items then
        item.items = {}
        for _, child in ipairs(node.items) do item.items[#item.items + 1] = resolve(child, current) end
    end
    return item
end
local function advanced(current)
    local kids = {{title = '当前增强技术详情', selectable = false, muted = true,
        hint = current and presets[current].tech or '未启用增强'}}
    for index, title in ipairs(groups) do
        local children = {}
        for _, p in ipairs(order) do
            if p.group == index then
                local reason = missing(p)
                children[#children + 1] = {title = p.id, value = command('toggle', p.id),
                    active = current == p.id, muted = reason ~= nil, hint = p.tech}
            end
        end
        kids[#kids + 1] = {title = title, items = children}
    end
    kids[#kids + 1] = {title = '着色器组合预设（NNEDI3 / FSRCNNX / ravu / Anime4K…）',
        selectable = false, muted = true, hint = 'ALT+1..8 组合预设；单项 shader 用 CTRL+1..9'}
    kids[#kids + 1] = {title = '清空全部视频滤镜（ALT+~）', value = command('clear-vf')}
    kids[#kids + 1] = {title = '清空全部着色器（CTRL+0）', value = command('clear-shaders')}
    kids[#kids + 1] = {title = '依赖与安装说明', value = command('help')}
    return {title = '高级：模型、算法与渲染设置…', items = kids}
end
local function menu_data()
    local current = chosen()
    local st = source_state()
    local items = {}
    if current then
        items[#items + 1] = {title = '当前效果：' .. presets[current].label .. (suspended and '（已暂时关闭）' or ''),
            selectable = false, muted = true,
            hint = '增强仅当前视频生效，下一视频恢复默认；去色带为独立开关，不受此范围限制'}
    else
        items[#items + 1] = {title = pending and ('当前效果：准备中 · ' .. presets[pending.id].label) or '当前效果：未启用增强',
            selectable = false, muted = true,
            hint = '增强仅当前视频生效，下一视频恢复默认；去色带为独立开关，不受此范围限制'}
    end
    if st.ratio then
        items[#items + 1] = {title = string.format('估算放大 %.2f×（滤镜输出 %d×%d → 渲染目标 %d×%d）',
                st.ratio, math.floor(st.source_w), math.floor(st.source_h),
                math.floor(st.target_w), math.floor(st.target_h)),
            selectable = false, muted = true,
            hint = st.hdr and 'HDR 片源：本机尚未验证，建议先对比' or '估算值：不含黑边与滤镜细节差异'}
    elseif st.hdr then
        items[#items + 1] = {title = 'HDR 片源：本机尚未验证，建议先对比', selectable = false, muted = true}
    end
    for _, node in ipairs(requirements) do items[#items + 1] = resolve(node, current) end
    items[#items + 1] = suspended and
        {title = '切回增强效果（结束对比）', value = command('compare'),
            hint = '当前已暂时关闭：' .. presets[suspended.id].label} or
        {title = '暂时关闭，对比效果', value = command('compare'),
            hint = current and '不撤销选择，切回开启前的画面' or '先开启一项增强'}
    items[#items + 1] = {title = '恢复开启前效果', value = command('reset'),
        hint = '撤销本次增强，恢复开启前的滤镜与 shader'}
    items[#items + 1] = advanced(current)
    items[#items + 1] = {title = '我该选哪个？说明…', value = command('help')}
    return {type = 'gpu-effects', title = '画面增强 · 按需求选择', keep_open = true,
        search_submenus = true, items = items, footnote = last_message:gsub('\n', ' ')}
end
refresh_menu = function()
    if mp.get_property_native('user-data/uosc/menu/type') == 'gpu-effects' then
        mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(menu_data()))
    end
end
mp.register_script_message('menu', function()
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu_data()))
end)
mp.register_script_message('toggle', toggle)
mp.register_script_message('reset', function() reset() end)
mp.register_script_message('compare', compare)
mp.register_script_message('help', function()
    say('按需求选择：放大后更清楚 / 动作更流畅 / 减少噪点 / 修复动画画面 / 去色带 / 超分＋补帧。' ..
        '\n进入任一方案可先看到“适合 / 条件 / 负担 / 启用”，技术信息在“技术详情”里。' ..
        '\n一次只启用一个增强，选另一项会替换；重复选择同一项关闭，下一视频恢复默认。' ..
        '\n想比较效果用“暂时关闭，对比效果”，彻底退出用“恢复开启前效果”。' ..
        '\n去色带是 mpv 内置的独立开关，不受上面两条的恢复范围限制。' ..
        '\n轻量 shader 无需 VS；其他方案需要 VS 增强包与对应模型，见 docs/gpu-setup.md。')
end)
mp.register_script_message('clear-vf', function()
    cancel(false)
    suspended = nil
    local ok, err = mp.commandv('vf', 'clr', '')
    say(ok and '视频滤镜已清空。' or ('清空失败：' .. tostring(err)))
end)
mp.register_script_message('clear-shaders', function()
    cancel()
    suspended = nil
    local ok, err = mp.set_property_native('glsl-shaders', {})
    if ok then baseline, applied_shader = nil, nil end
    say(ok and '着色器已清空。' or ('清空失败：' .. tostring(err)))
end)
mp.enable_messages('error')
local function update_message_level()
    -- Paused seeks can reinitialize an already active VS filter. Observe its
    -- initialization logs while paused, without debug traffic during playback.
    local initializing = pending and pending.stage == 'init'
    mp.enable_messages((initializing or (owned_filter() and mp.get_property_native('pause', false))) and 'debug' or 'error')
end
local function refresh_paused_frame(id, token)
    if not mp.get_property_native('pause', false) then return end
    mp.add_timeout(0.1, function()
        if token == generation and not pending and selected() == id and
            mp.get_property_native('pause', false) then
            mp.commandv('frame-step')
            mp.msg.info('GPU refreshed paused VS dummy frame: ' .. id)
        end
    end)
end
local initialized
mp.register_event('log-message', function(event)
    local f = owned_filter()
    if not f or (event.prefix ~= 'vapoursynth' and
        not (event.prefix == 'vf' and event.text:find(label, 1, true))) then return end
    local job = pending
    if event.prefix == 'vapoursynth' and
        event.text:match('^Returning black dummy frame with 0 duration%.') then
        if job and job.stage == 'init' then job.dummy_frame = true
        elseif not job and selected() then paused_placeholder = {id = selected(), token = generation} end
        return
    end
    if event.prefix == 'vapoursynth' and
        event.text:match('^initialized%.%s*$') then
        initialized()
        return
    end
    if event.level ~= 'error' and event.level ~= 'fatal' then return end
    if job and job.stage == 'init' then
        if not job.failure then
            job.failure = event.text
            mp.add_timeout(0, function()
                if pending ~= job then return end
                local restored, reason = cancel()
                say('GPU 初始化失败，' .. (restored and '已恢复原效果：' or ('回滚失败：' .. tostring(reason) .. '；')) ..
                    job.failure:gsub('\n', ' '))
            end)
        elseif event.text:find('Python exception:', 1, true) then job.failure = event.text end
    else
        -- Later frame/seek failures must not leave a dead filter marked active.
        cancel(false)
        mp.commandv('vf', 'remove', '@' .. label)
        say('GPU 运行失败，已关闭该增强：' .. event.text:gsub('\n', ' '))
    end
end)
initialized = function()
    local job = pending
    if not job then
        local placeholder = paused_placeholder
        paused_placeholder = nil
        if placeholder then refresh_paused_frame(placeholder.id, placeholder.token) end
        return
    end
    if not job or job.stage ~= 'init' or job.failure then return end
    local restored, reason = restore_shader()
    if not restored then cancel(); say('shader 恢复失败，已恢复原滤镜：' .. tostring(reason)); return end
    job.timer:kill()
    pending = nil
    suspended = nil          -- 新方案已生效：结束旧方案的对比状态
    update_message_level()
    if job.dummy_frame and mp.get_property_native('pause', false) then
        -- VS can display a zero-duration placeholder while initializing. A seek
        -- rebuilds VS and can repeat it; step once after init, staying paused.
        refresh_paused_frame(job.id, generation)
    end
    say('已启用：' .. presets[job.id].label .. '\n' .. describe(presets[job.id]) ..
        '\n流畅度尚未评估：可对比开关前后的帧率，或先用“暂时关闭，对比效果”判断。')
end
mp.observe_property('vf', 'native', function() publish(); update_message_level() end)
mp.observe_property('pause', 'bool', update_message_level)
mp.observe_property('glsl-shaders', 'native', function()
    local list = shaders()
    -- 本脚本自己的写入不算外部改写（对比切换、方案切换、恢复都走 set_shaders）。
    if expected_shaders and same(list, expected_shaders) then publish(); return end
    expected_shaders = nil
    if suspended then suspended = nil end
    if applied_shader then baseline, applied_shader = nil, nil end
    publish()
end)
-- 尺寸事实与去色带状态都直接来自 mpv 属性，变化时刷新菜单。
mp.observe_property('osd-dimensions', 'native', publish)
mp.observe_property('video-out-params', 'native', publish)
mp.observe_property('video-target-params', 'native', publish)
mp.observe_property('deband', 'native', publish)
-- Reset before the next file's video chain is built, even if global reset is off.
mp.add_hook('on_load', 9, function() reset(true) end)
mp.register_event('end-file', function() cancel(false); publish() end)
publish()
