package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local queue, utils = require 'ai-translation-job', require 'mp.utils'
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local cues = {{key = '00:00:00,000 --> 00:00:02,000', text = 'First.'}, {key = '00:00:02,000 --> 00:00:04,000', text = '第二句。'}}
local function fixture(overrides, persisted)
    local f = {clock = 0, sent = {}, timers = {}, saved = persisted, writes = 0, aborted = 0}
    local options = {cues = cues, batch_size = 1, rate = 60, max_requests = 20, max_chars = 20000,
        retries = 2, now = function() return f.clock end,
        schedule = function(delay, callback)
            local timer = {at = f.clock + delay, callback = callback}
            function timer:kill() self.killed = true end
            f.timers[#f.timers + 1] = timer
            return timer
        end,
        send = function(text, callback)
            f.sent[#f.sent + 1] = {text = text, callback = callback, at = f.clock}
            return function() f.aborted = f.aborted + 1 end
        end,
        publish = function(status) f.status = status end,
        save = function(value) f.saved = utils.parse_json(utils.format_json(value)); return true end,
        load = function() return f.saved end,
        partial = function() f.writes = f.writes + 1; return true end,
        finish = function() f.finished = true; return true end}
    for key, value in pairs(overrides or {}) do options[key] = value end
    f.job = queue.new(options)
    function f.advance(seconds)
        f.clock = f.clock + seconds
        local timers = f.timers; f.timers = {}
        for _, timer in ipairs(timers) do
            if not timer.killed and timer.at <= f.clock then timer.callback()
            elseif not timer.killed then f.timers[#f.timers + 1] = timer end
        end
    end
    function f.success(index, cue)
        f.sent[index].callback({status = 200, text = cues[cue].key .. ' | Translation ' .. cue .. '.', tokens = 7})
    end
    return f
end
local function suite()
    check(queue.characters('甲 a😀') == 4, 'Unicode character budget excludes UTF-8 byte expansion')
    check(queue.retry_after('5') == 5 and queue.retry_after('bad date') == nil, 'numeric and invalid Retry-After')
    local now = os.time()
    check(math.abs(queue.retry_after(os.date('!%a, %d %b %Y %H:%M:%S GMT', now + 30), now) - 30) < 1,
        'HTTP-date Retry-After is timezone independent')
    local f = fixture({max_requests = 1})
    f.job.start(); f.success(1, 1)
    check(f.job.state == 'budget' and #f.sent == 1, 'request limit pauses before another billable request')
    f.job.resume(); f.advance(1); f.success(2, 2)
    check(f.job.state == 'completed' and f.job.done == 2 and f.job.tokens == 14, 'manual allowance resumes only missing cue and counts usage')
    check(f.sent[2].at - f.sent[1].at >= 1, 'request spacing enforces configured rate')
    local g = fixture({max_requests = 1}, f.saved)
    g.job.start()
    check(g.finished and #g.sent == 0, 'complete checkpoint does not issue another request')
    f = fixture({max_chars = queue.characters(cues[1].key .. ' | ' .. cues[1].text)})
    f.job.start(); f.success(1, 1)
    check(f.job.state == 'budget' and #f.sent == 1, 'input character limit checked before dispatch')
    f.job.resume(); f.advance(1); f.success(2, 2)
    check(f.finished, 'character allowance can be extended explicitly')
    f = fixture()
    f.job.start(); f.sent[1].callback({status = 429, retry_after = 5})
    f.advance(4)
    check(#f.sent == 1 and f.job.state == 'retrying', 'Retry-After is respected')
    f.advance(1); f.success(2, 1); f.advance(1); f.success(3, 2)
    check(f.finished and f.job.requests == 3, 'retry counts against request budget')
    f = fixture()
    f.job.start(); f.sent[1].callback({status = 401})
    check(f.job.state == 'failed' and #f.timers == 0, 'authentication failure is not retried automatically')
    f.job.start(); f.advance(1)
    check(#f.sent == 2, 'failed task can be retried explicitly')
    f.job.cancel(); f.success(2, 1)
    check(f.job.done == 0 and f.aborted == 1, 'cancellation ignores late transport callback')
    f = fixture()
    f.job.start(); f.sent[1].callback({status = 0}); f.advance(2)
    f.sent[2].callback({status = 503}); f.advance(4); f.sent[3].callback({status = 503})
    check(f.job.state == 'failed' and #f.sent == 3, 'retry count is finite')
    f = fixture({save = function() return false end})
    f.job.start()
    check(f.job.state == 'failed' and #f.sent == 0, 'storage failure stops external request before budget is lost')
    f = fixture()
    f.job.start(); f.success(1, 1); f.job.cancel(); f.advance(10)
    check(#f.sent == 1 and f.job.done == 1, 'cancelled wait never dispatches another batch')
    g = fixture(nil, f.saved); g.job.start(); g.advance(1); g.success(1, 2)
    check(g.finished and g.job.requests == 2, 'new session resumes missing work and retains accumulated request count')
    f = fixture()
    f.job.start(); f.sent[1].callback({status = 200, text = '00:00:09,000 --> 00:00:10,000 | Changed.'})
    check(f.job.state == 'failed' and f.job.done == 0, 'altered timestamp never becomes completed translation')
    f = fixture(nil, {invalid = true})
    f.job.start(); f.job.resume()
    check(f.job.state == 'failed' and #f.sent == 0, 'corrupt budget checkpoint cannot silently reset spending allowance')
end
mp.add_timeout(0.1, function()
    local ok, err = pcall(suite)
    mp.msg.info(ok and ('TRANSLATION JOB PASS: ' .. checks .. ' assertions') or ('TRANSLATION JOB FAIL: ' .. tostring(err)))
    mp.commandv('quit', ok and 0 or 3)
end)
