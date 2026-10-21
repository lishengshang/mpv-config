package.path = mp.command_native({'expand-path', '~~/script-modules/?.lua'}) .. ';' .. package.path
local queue, utils = require 'ai-translation-job', require 'mp.utils'
local pipeline = require 'ai-subtitle-pipeline'
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
        send = function(text, callback, batch)
            f.sent[#f.sent + 1] = {text = text, callback = callback, at = f.clock, batch = batch}
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
    for _, language in ipairs({'Chinese', 'zh-CN', 'Mandarin', 'Cantonese', 'en-US', 'English', 'unknown', 'auto'}) do
        check(not pipeline.auto({language}), 'no automatic API for ' .. language)
    end
    check(pipeline.auto({'ja'}) and pipeline.auto({'Japanese', 'ko', 'French'}), 'foreign language metadata enables auto')
    check(not pipeline.auto({}) and not pipeline.auto({'ja', 'en'}), 'unknown and mixed excluded language are conservative')
    local plan = pipeline.plan(cues, 'Chinese')
    local function planned(persisted)
        return fixture({cues = plan.cues, next_batch = plan.next_batch, decode = plan.decode,
            describe = plan.describe, max_requests = 1, max_chars = 0}, persisted)
    end
    f = planned(); f.job.start()
    check(f.sent[1].batch.stage == 'calibration' and f.sent[1].text:find(cues[1].text, 1, true) and
        f.sent[1].text:find(cues[2].text, 1, true), 'calibration is a single complete transcript request')
    local corrected = cues[1].key .. ' | Corrected first.\n' .. cues[2].key .. ' | 修正后的第二句。'
    f.sent[1].callback({status = 200, text = corrected})
    check(f.job.state == 'budget' and f.job.snapshot().calibrated and #f.sent == 1, 'calibration shares persisted request budget')
    local checkpoint = utils.parse_json(utils.format_json(f.saved))
    g = planned(checkpoint); g.job.start()
    check(g.job.state == 'budget' and #g.sent == 0, 'restart does not repeat calibration or reset budget')
    g.job.resume(); g.advance(1)
    check(#g.sent == 1 and g.sent[1].batch.stage == 'translation' and g.sent[1].text == corrected,
        'translation receives only validated corrected transcript after restart')
    g.sent[1].callback({status = 200, text = cues[1].key .. ' | 第一条译文。\n' .. cues[2].key .. ' | 第二条译文。'})
    check(g.finished and g.job.snapshot().done == 2 and g.job.requests == 2, 'both stages finish with shared accounting')
    check(cues[1].text == 'First.' and cues[2].text == '第二句。', 'pipeline does not overwrite original ASR cues')
    check(not plan.valid({[cues[1].key] = 'translation without calibration'}), 'translation-only checkpoint rejected')
    check(not plan.valid({__calibration = 'truncated'}), 'invalid calibration checkpoint rejected')
    for _, bad in ipairs({cues[1].key .. ' | missing second', '00:00:09,000 --> 00:00:10,000 | wrong',
        corrected .. '\nExtra commentary.'}) do
        f = planned(); f.job.start(); f.sent[1].callback({status = 200, text = bad})
        check(f.job.state == 'failed' and #f.sent == 1 and not f.job.snapshot().calibrated,
            'invalid whole-transcript calibration cannot proceed to translation')
    end
    local long = {{key = cues[1].key, text = string.rep('text ', 5000)}}
    local long_plan = pipeline.plan(long, 'Chinese')
    f = fixture({cues = long_plan.cues, next_batch = long_plan.next_batch, decode = long_plan.decode, max_chars = 0})
    f.job.start()
    check(#f.sent == 1 and #f.sent[1].text > 20000 and f.job.input_chars > 20000,
        'whole calibration has no 20000 character truncation or default character budget')
    f.job.cancel()
    f.sent[1].callback({status = 200, text = long[1].key .. ' | late'})
    check(f.job.done == 0, 'cancelled calibration ignores late output')
    f = fixture()
    f.job.start()
    local stale = f.sent[1].callback
    f.job.cancel(); f.job.resume(); f.advance(1)
    check(#f.sent == 2, 'resume issues a fresh request')
    stale({status = 200, text = cues[1].key .. ' | Stale result.', tokens = 999})
    check(f.job.done == 0 and f.job.tokens == 0 and not f.finished,
        'cancelled callback must stay invalid after immediate resume')
    f.success(2, 1); f.advance(1); f.success(3, 2)
    check(f.finished and f.job.done == 2, 'fresh callbacks complete after cancelled request is ignored')
    local writes = 0
    f = fixture({save = function() writes = writes + 1; return writes == 1 end})
    f.job.start(); f.sent[1].callback({status=429,retry_after=5})
    check(f.job.state == 'failed' and #f.timers == 0, 'failed retry checkpoint stops scheduling more requests')
end
mp.add_timeout(0.1, function()
    local ok, err = pcall(suite)
    mp.msg.info(ok and ('TRANSLATION JOB PASS: ' .. checks .. ' assertions') or ('TRANSLATION JOB FAIL: ' .. tostring(err)))
    mp.commandv('quit', ok and 0 or 3)
end)
