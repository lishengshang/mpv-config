-- User-facing ASR choices. Keep engine identifiers stable for existing messages.
local M = {}
M.choices = {
    {id='whisper-context', backend='whisper', mode='context', title='Whisper · 多语言均衡', hint='默认 · 连贯优先；中英日语、课程与影视'},
    {id='whisper-fast', backend='whisper', mode='fast', title='Whisper · 连贯提速', hint='保留上下文与逐词校时；文字可能变化，建议抽查'},
    {id='whisper-balanced', backend='whisper', mode='balanced', title='Whisper · 批量提速', hint='可选速度档；长片可能出现无效时间轴，保留逐词校时'},
    {id='sensevoice', backend='sensevoice', title='SenseVoice · 中文课程', hint='中英粤日韩；轻量识别与 CTC 时间轴'},
    {id='qwen-small', backend='qwen', mode='small', title='Qwen · 轻量 0.6B', hint='多语言；批量识别后单独校时'},
    {id='qwen-quality', backend='qwen', mode='quality', title='Qwen · 质量 1.7B', hint='多语言；较大模型，速度需按片源比较'},
}
M.languages = {{'', '自动检测'}, {'zh', '中文'}, {'en', '英语'}, {'ja', '日语'}, {'yue', '粤语'}, {'ko', '韩语'}}
function M.find(id)
    for _, choice in ipairs(M.choices) do if choice.id == id then return choice end end
end
function M.current(backend, options)
    local mode = backend == 'whisper' and options.whisper_mode or options.qwen_variant
    for _, choice in ipairs(M.choices) do
        if choice.backend == backend and (not choice.mode or choice.mode == mode) then return choice end
    end
    return M.choices[1]
end
function M.language_title(code)
    for _, language in ipairs(M.languages) do if language[1] == code then return language[2] end end
    return code
end
function M.validate(options, backend)
    local function integer(value, low, high)
        return type(value) == 'number' and value == math.floor(value) and value >= low and value <= high
    end
    if backend == 'whisper' then
        if options.whisper_mode ~= 'balanced' and options.whisper_mode ~= 'context' and options.whisper_mode ~= 'fast' then
            return 'Whisper 模式应为 context、fast 或 balanced'
        end
        if not integer(options.whisper_batch_size, 1, 32) then return 'Whisper batch 应为 1–32 的整数' end
    elseif backend == 'qwen' then
        if options.qwen_variant ~= 'quality' and options.qwen_variant ~= 'small' then return 'Qwen 型号应为 quality 或 small' end
        if not integer(options.qwen_batch_size, 1, 8) then return 'Qwen batch 应为 1–8 的整数' end
    elseif backend == 'sensevoice' then
        if not integer(options.sensevoice_batch_size, 1, 16) then return 'SenseVoice batch 应为 1–16 的整数' end
        if not integer(options.sensevoice_chunk_seconds, 2, 30) then return 'SenseVoice 切片应为 2–30 秒的整数' end
        if not ({['']=true, zh=true, en=true, ja=true, yue=true, ko=true})[options.language] then
            return 'SenseVoice 仅支持中、英、粤、日、韩语；请选择其他方案或自动检测'
        end
    end
end
return M
