-- Sequential, budgeted translation queue. All time/transport/storage effects are injected.
local M = {}
local function characters(text)
    local count = 0
    for _ in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do count = count + 1 end
    return count
end
function M.new(options)
    local job = {state = 'idle', completed = {}, requests = 0, input_chars = 0, tokens = 0,
        done = 0, total = #options.cues, message = '', attempts = 0, last_request = -math.huge}
    local batch, timer, abort, active = nil, nil, nil, false
    local request_limit, char_limit = options.max_requests or 20, options.max_chars or 0
    local request_allowance, char_allowance = request_limit, char_limit
    local cancelled = false
    local request_serial = 0
    local wall_now = options.wall_now or options.now
    local last_wall, cooldown = 0, 0
    local function save()
        return options.save({schema = 1, completed = job.completed, requests = job.requests, input_chars = job.input_chars,
            tokens = job.tokens, request_allowance = request_allowance, char_allowance = char_allowance,
            last_request_wall = last_wall, not_before_wall = wall_now() + math.max(0, cooldown - options.now())})
    end
    function job.snapshot()
        local status = {state = job.state, done = job.done, total = job.total, requests = job.requests,
            input_chars = job.input_chars, tokens = job.tokens, message = job.message,
            request_limit = request_allowance, char_limit = char_allowance}
        if options.describe then options.describe(status, job.completed, batch) end
        return status
    end
    local function publish(state, message)
        job.state, job.message = state, message or ''
        options.publish(job.snapshot())
    end
    local saved = options.load() or {}
    if saved.schema == 1 then
        for _, cue in ipairs(options.cues) do
            if type((saved.completed or {})[cue.key]) == 'string' then
                job.completed[cue.key], job.done = saved.completed[cue.key], job.done + 1
            end
        end
        job.requests, job.input_chars, job.tokens = saved.requests or 0, saved.input_chars or 0, saved.tokens or 0
        request_allowance = math.max(request_limit, saved.request_allowance or 0)
        char_allowance = math.max(char_limit, saved.char_allowance or 0)
        last_wall = saved.last_request_wall or 0
        if last_wall > 0 then job.last_request = options.now() - math.max(0, wall_now() - last_wall) end
        cooldown = options.now() + math.max(0, (saved.not_before_wall or 0) - wall_now())
    end
    local dispatch
    local function later(delay, state, message)
        cooldown = options.now() + delay
        if not save() then publish('failed', '无法保存等待进度，已停止请求'); return end
        publish(state, message)
        local serial = request_serial
        timer = options.schedule(delay, function()
            if cancelled or serial ~= request_serial then return end
            timer = nil; dispatch()
        end)
    end
    local function next_batch()
        if options.next_batch then return options.next_batch(job.completed) end
        local cues, lines = {}, {}
        for _, cue in ipairs(options.cues) do
            if not job.completed[cue.key] then
                cues[#cues + 1] = cue
                lines[#lines + 1] = cue.key .. ' | ' .. cue.text:gsub('[\r\n]+', ' ')
                if #cues == (options.batch_size or 20) then break end
            end
        end
        return {cues = cues, text = table.concat(lines, '\n')}
    end
    local function decode(text)
        if options.decode then return options.decode(text, batch) end
        if type(text) ~= 'string' then return nil end
        local lines = {}
        for line in text:gmatch('[^\r\n]+') do if line:match('%S') then lines[#lines + 1] = line end end
        if #lines ~= #batch.cues then return nil end
        local result = {}
        for i, line in ipairs(lines) do
            local key, words = line:match('^%s*(%d%d:%d%d:%d%d,%d%d%d %-%-> %d%d:%d%d:%d%d,%d%d%d)%s*|%s*(.-)%s*$')
            if key ~= batch.cues[i].key or not words or not words:match('%S') or result[key] then return nil end
            result[key] = words
        end
        return result
    end
    dispatch = function()
        if cancelled or active then return end
        batch = batch or next_batch()
        if #batch.cues == 0 then
            if options.finish(job.completed) then publish('completed', '翻译完成')
            else publish('failed', '无法保存完成译文，可重试') end
            return
        end
        local count = characters(batch.text)
        if (request_limit > 0 and job.requests >= request_allowance) or
            (char_limit > 0 and job.input_chars + count > char_allowance) then
            save(); publish('budget', '已到本次请求或输入上限，手动继续可追加额度'); return
        end
        local delay = math.max(job.last_request + 60 / math.max(1, options.rate or 15), cooldown) - options.now()
        if delay > 0.001 then later(delay, 'waiting', '等待请求速率窗口'); return end
        job.requests, job.input_chars = job.requests + 1, job.input_chars + count
        job.last_request, job.attempts, active = options.now(), job.attempts + 1, true
        last_wall = wall_now()
        if not save() then
            active = false; publish('failed', '无法保存请求预算，已停止发送'); return
        end
        publish('running', batch.stage == 'calibration' and '正在全文校准' or '正在翻译')
        request_serial = request_serial + 1
        local serial, finished = request_serial, false
        local request_abort = options.send(batch.text, function(response)
            if cancelled or serial ~= request_serial then return end
            finished, request_serial = true, request_serial + 1
            active, abort = false, nil
            response = response or {}
            job.tokens = job.tokens + math.max(0, tonumber(response.tokens) or 0)
            local values = response.status == 200 and decode(response.text)
            if values then
                for key, value in pairs(values) do job.completed[key], job.done = value, job.done + 1 end
                batch, job.attempts = nil, 0
                if not save() or not options.partial(job.completed) then publish('failed', '无法保存部分译文，可重试'); return end
                publish('waiting', '已保存当前批次')
                dispatch()
                return
            end
            save()
            local status = tonumber(response.status) or 0
            local retryable = status == 0 or status == 408 or status == 429 or status >= 500
            if retryable and job.attempts <= (options.retries or 2) then
                local backoff = math.max((options.retry_base or 2) * 2 ^ (job.attempts - 1), tonumber(response.retry_after) or 0)
                later(backoff, 'retrying', '接口暂不可用，等待后重试（计入预算）')
            else publish('failed', '翻译失败：' .. tostring(response.error or ('HTTP ' .. status .. ' / 响应格式不符'))) end
        end, batch)
        if not finished and serial == request_serial then abort = request_abort end
    end
    function job.start()
        if active or timer then return end
        if saved.invalid then publish('failed', '任务进度损坏，已停止请求；请保留缓存并检查'); return end
        cancelled = false
        dispatch()
    end
    function job.resume()
        if active or timer then return end
        if saved.invalid then job.start(); return end
        if job.state == 'budget' then
            request_allowance, char_allowance = request_allowance + request_limit, char_allowance + char_limit
        end
        cancelled, job.attempts = false, 0
        save(); dispatch()
    end
    function job.cancel()
        cancelled = true
        request_serial = request_serial + 1
        if timer then timer:kill(); timer = nil end
        if abort then abort(); abort = nil end
        active = false
        save(); publish('cancelled', '翻译已取消，已完成批次保留')
    end
    return job
end
M.characters = characters
function M.retry_after(value, timestamp)
    if not value then return nil end
    local number = tonumber(value)
    if number then return math.max(0, number) end
    local day, month, year, hour, minute, second = value:match('%a+,%s*(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+GMT')
    local months = {Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6, Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12}
    if not day or not months[month] then return nil end
    local now = timestamp or os.time()
    local offset = os.difftime(os.time(os.date('*t', now)), os.time(os.date('!*t', now)))
    local date = os.time({year = tonumber(year), month = months[month], day = tonumber(day), hour = tonumber(hour),
        min = tonumber(minute), sec = tonumber(second), isdst = false})
    return date and math.max(0, date + offset - now)
end
return M
